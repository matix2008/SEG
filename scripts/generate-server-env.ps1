param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('VPN', 'SEG')]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$NoBackup,

    [Parameter(Mandatory = $false)]
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $PSBoundParameters.ContainsKey('Mode')) {
    [Console]::Error.WriteLine('ERROR: parameter -Mode is required. Use -Mode VPN or -Mode SEG.')
    exit 1
}

if ($Mode -eq 'SEG') {
    $segScript = Join-Path $PSScriptRoot 'seg\generate-server-env.ps1'

    if (-not (Test-Path -LiteralPath $segScript)) {
        [Console]::Error.WriteLine("ERROR: SEG mode is not available: $segScript was not found.")
        exit 1
    }

    $segArgs = @{}
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -ne 'Mode') {
            $segArgs[$key] = $PSBoundParameters[$key]
        }
    }

    $global:LASTEXITCODE = 0

    try {
        & $segScript @segArgs
    }
    catch {
        [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
        exit 1
    }

    exit $global:LASTEXITCODE
}

# ============================================================
# Paths
# ============================================================

$Root    = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $Root 'config\server.env'

# ============================================================
# Logging
# ============================================================

$ScriptName = Split-Path -Leaf $PSCommandPath
$RunId      = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$LogsDir    = Join-Path $Root 'logs'
$LogFile    = Join-Path $LogsDir 'amnezia.log'

$LogMaxBytes    = 10MB
$LogBackupCount = 3
$LogEncoding    = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null

function Invoke-LogRotation {
    if (-not (Test-Path -LiteralPath $LogFile)) {
        return
    }

    $size = (Get-Item -LiteralPath $LogFile).Length

    if ($size -lt $LogMaxBytes) {
        return
    }

    $oldest = "$LogFile.$LogBackupCount"
    Remove-Item -LiteralPath $oldest -Force -ErrorAction SilentlyContinue

    for ($i = $LogBackupCount - 1; $i -ge 1; $i--) {
        $source = "$LogFile.$i"

        if (Test-Path -LiteralPath $source) {
            $destination = "$LogFile.$($i + 1)"
            Move-Item -LiteralPath $source -Destination $destination -Force
        }
    }

    Move-Item -LiteralPath $LogFile -Destination "$LogFile.1" -Force
}

Invoke-LogRotation

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('START', 'INFO', 'OK', 'WARN', 'ERROR', 'DONE')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [switch]$LogOnly
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$timestamp [$ScriptName] [$RunId] [$Level] $Message"

    [System.IO.File]::AppendAllText(
        $LogFile,
        $line + "`n",
        $LogEncoding
    )

    if (-not $LogOnly) {
        if ($Level -eq 'ERROR') {
            Microsoft.PowerShell.Utility\Write-Host $line -ForegroundColor Red
        }
        elseif ($Level -eq 'WARN') {
            Microsoft.PowerShell.Utility\Write-Host $line -ForegroundColor Yellow
        }
        else {
            Microsoft.PowerShell.Utility\Write-Host $line
        }
    }
}

trap {
    Write-Log -Level 'ERROR' -Message $_.Exception.Message

    if ($_.ScriptStackTrace) {
        Write-Log -Level 'ERROR' -Message $_.ScriptStackTrace -LogOnly
    }

    Write-Log -Level 'DONE' -Message "FAILED. Log: $LogFile"
    exit 1
}

Write-Log -Level 'START' -Message $(if ($Restore) { 'Restoring server.env from backup.' } else { 'Generating complete server.env.' })
Write-Log -Level 'INFO' -Message "PowerShell version: $($PSVersionTable.PSVersion)"

# ============================================================
# Helpers
# ============================================================

function Confirm-Action {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    while ($true) {
        $answer = (Read-Host "$Message [y/N]").Trim().ToLowerInvariant()

        if ([string]::IsNullOrWhiteSpace($answer)) {
            Write-Log -Level 'INFO' -Message "Confirmation: $Message -> NO (default)"
            return $false
        }

        if ($answer -in @('y', 'yes', 'д', 'да')) {
            Write-Log -Level 'INFO' -Message "Confirmation: $Message -> YES"
            return $true
        }

        if ($answer -in @('n', 'no', 'н', 'нет')) {
            Write-Log -Level 'INFO' -Message "Confirmation: $Message -> NO"
            return $false
        }
    }
}

function Write-Utf8Lf {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $Text = $Text -replace "`r`n", "`n"
    $Text = $Text -replace "`r", "`n"

    $utf8 = New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllText(
        $Path,
        $Text,
        $utf8
    )
}

function Resolve-AwgExecutable {
    $command = Get-Command awg.exe -ErrorAction SilentlyContinue

    if ($command) {
        return $command.Source
    }

    $command = Get-Command awg -ErrorAction SilentlyContinue

    if ($command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'AmneziaWG\awg.exe'),
        (Join-Path $env:ProgramFiles 'AmneziaVPN\awg.exe'),
        (Join-Path $env:LOCALAPPDATA 'AmneziaWG\awg.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw 'awg.exe was not found. Install AmneziaWG tools or add awg.exe to PATH.'
}

function Invoke-AwgSecretCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Awg,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$InputText
    )

    $previousErrorActionPreference = $ErrorActionPreference

    try {
        # Windows PowerShell 5.1 can turn stderr from a native executable
        # into a terminating PowerShell error when ErrorActionPreference is Stop.
        # awg.exe success/failure is determined by its exit code.
        $ErrorActionPreference = 'Continue'

        $output = if ($PSBoundParameters.ContainsKey('InputText')) {
            # Piping from PowerShell prepends a UTF-8 BOM when the console
            # code page is 65001, and awg.exe rejects it. Feed stdin through
            # cmd.exe; the secret travels via the environment, not argv.
            $env:AWG_SECRET_INPUT = $InputText
            $env:AWG_SECRET_EXE   = $Awg
            try {
                cmd.exe /d /c "echo %AWG_SECRET_INPUT%| `"%AWG_SECRET_EXE%`" $Command 2>&1"
            }
            finally {
                Remove-Item Env:AWG_SECRET_INPUT, Env:AWG_SECRET_EXE -ErrorAction SilentlyContinue
            }
        }
        else {
            & $Awg $Command 2>&1
        }

        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $lines = @($output | ForEach-Object { [string]$_ })

    if ($code -ne 0) {
        foreach ($line in $lines) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Log -Level 'ERROR' -Message "awg ${Command}: $line"
            }
        }

        throw "awg $Command failed with exit code $code"
    }

    $value = @(
        $lines |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    ) | Select-Object -Last 1

    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "awg $Command returned an empty result"
    }

    return $value.Trim()
}

function Get-CryptoRandomInt {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Min,

        [Parameter(Mandatory = $true)]
        [int]$Max
    )

    if ($Min -gt $Max) {
        throw "Invalid random range: $Min..$Max"
    }

    [uint64]$range = ([uint64]$Max - [uint64]$Min) + 1
    [uint64]$sampleSpace = 4294967296
    [uint64]$limit = $sampleSpace - ($sampleSpace % $range)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    try {
        $bytes = New-Object byte[] 4
        do {
            $rng.GetBytes($bytes)
            [uint64]$sample = [System.BitConverter]::ToUInt32($bytes, 0)
        } while ($sample -ge $limit)

        return [int]([uint64]$Min + ($sample % $range))
    }
    finally {
        $rng.Dispose()
    }
}

function New-RandomHeaderValue {
    return Get-CryptoRandomInt -Min 5 -Max 2147483647
}

function New-AwgHeaderValues {
    $values = @()

    while ($values.Count -lt 4) {
        [uint32]$value = New-RandomHeaderValue

        # 0 and compatibility values 1..4 are intentionally excluded.
        if ($value -le 4 -or $values -contains $value) {
            continue
        }

        $values += $value
    }

    return $values
}

# ============================================================
# server.env backups
# ============================================================

$RequiredEnvKeys = @(
    'WG_IPV4_NETWORK',
    'WG_IPV4_SERVER',
    'WG_IPV6_NETWORK',
    'WG_IPV6_SERVER',
    'DNS1',
    'DNS2',
    'SERVER_PRIVATE_KEY',
    'SERVER_PUBLIC_KEY',
    'JC',
    'JMIN',
    'JMAX',
    'S1',
    'S2',
    'S3',
    'S4',
    'H1',
    'H2',
    'H3',
    'H4',
    'RANDOM_TRAILERS'
)

$BackupKeepCount = 3

function Get-EnvBackups {
    # The timestamp in the name sorts chronologically; newest first.
    $dir = Split-Path -Parent $EnvFile

    if (-not (Test-Path -LiteralPath $dir)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $dir -Filter 'server.env.*.bak' -File |
        Sort-Object Name -Descending
    )
}

function New-EnvBackup {
    $path = Join-Path (Split-Path -Parent $EnvFile) (
        'server.env.' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '.bak'
    )

    Copy-Item -LiteralPath $EnvFile -Destination $path

    Write-Log -Level 'OK' -Message "Backup of the current server.env created: $path"

    @(Get-EnvBackups | Select-Object -Skip $BackupKeepCount) | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force
        Write-Log -Level 'INFO' -Message "Old backup removed (keeping the last $BackupKeepCount): $($_.Name)"
    }

    return $path
}

function Test-EnvText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    foreach ($required in $RequiredEnvKeys) {
        if ($Text -notmatch "(?m)^$([regex]::Escape($required))=\S") {
            return "missing parameter: $required"
        }
    }

    foreach ($keyName in @('SERVER_PRIVATE_KEY', 'SERVER_PUBLIC_KEY')) {
        if ($Text -notmatch "(?m)^$keyName=[A-Za-z0-9+/]{43}=\s*$") {
            return "$keyName has an unexpected format"
        }
    }

    return $null
}

# ============================================================
# Restore mode
# ============================================================

if ($Restore) {
    $backups = @(Get-EnvBackups)

    if ($backups.Count -eq 0) {
        throw "No server.env backups found in $(Split-Path -Parent $EnvFile)"
    }

    $source = $backups[0]
    $problem = Test-EnvText -Text (Get-Content -LiteralPath $source.FullName -Raw)

    if ($problem) {
        throw "Backup $($source.Name) is not a valid server.env: $problem"
    }

    Write-Log -Level 'WARN' -Message "server.env will be restored from the newest backup: $($source.Name)"

    if (-not $NoBackup -and (Test-Path -LiteralPath $EnvFile)) {
        Write-Log -Level 'INFO' -Message 'The current server.env will be saved as a new backup first (a second -Restore undoes this one).'
    }
    elseif (Test-Path -LiteralPath $EnvFile) {
        Write-Log -Level 'WARN' -Message 'No backup of the current server.env will be created because -NoBackup was specified.'
    }

    if (-not $Force) {
        if (-not (Confirm-Action 'Replace the current server.env with the backup?')) {
            Write-Log -Level 'DONE' -Message 'CANCELLED.'
            exit 0
        }
    }

    if (-not $NoBackup -and (Test-Path -LiteralPath $EnvFile)) {
        [void](New-EnvBackup)
    }

    Copy-Item -LiteralPath $source.FullName -Destination $EnvFile -Force

    Write-Log -Level 'OK' -Message "server.env restored from $($source.Name)"
    Write-Log -Level 'WARN' -Message 'VPS servers and client configs still use the previous keys until sync-servers.ps1 is applied.'
    Write-Log -Level 'WARN' -Message 'Derived client profiles must be recreated with make-client-config.ps1 after sync-servers.ps1.'
    Write-Log -Level 'DONE' -Message "SUCCESS. Log: $LogFile"
    exit 0
}

# ============================================================
# Fixed baseline for this infrastructure
# ============================================================

$WG_IPV4_NETWORK = '10.7.0.0/24'
$WG_IPV4_SERVER  = '10.7.0.1'

$WG_IPV6_NETWORK = 'fddd:2c4:2c4:2c4::/64'
$WG_IPV6_SERVER  = 'fddd:2c4:2c4:2c4::1'

$DNS1 = '8.8.8.8'
$DNS2 = '8.8.4.4'

$JC   = Get-CryptoRandomInt -Min 4 -Max 12
$JMIN = Get-CryptoRandomInt -Min 20 -Max 60
$JMAX = Get-CryptoRandomInt -Min ($JMIN + 20) -Max 120

$SCommon = Get-CryptoRandomInt -Min 15 -Max 150
$S1 = $SCommon
$S2 = $SCommon
$S3 = $SCommon
$S4 = $SCommon

$RANDOM_TRAILERS = 'on'

# ============================================================
# Confirmation
# ============================================================

if (Test-Path -LiteralPath $EnvFile) {
    Write-Log -Level 'WARN' -Message "Existing server.env will be replaced: $EnvFile"

    if ($NoBackup) {
        Write-Log -Level 'WARN' -Message 'No backup will be created (-NoBackup), so the old private key is not retained.'
    }
    else {
        Write-Log -Level 'WARN' -Message "The current server.env will be saved as config\server.env.<time>.bak (unencrypted; the last $BackupKeepCount copies are kept). Use -NoBackup if the old private key is compromised."
    }

    if (-not $Force) {
        if (-not (Confirm-Action 'Generate a new server.env and replace the existing one?')) {
            Write-Log -Level 'DONE' -Message 'CANCELLED.'
            exit 0
        }
    }
    else {
        Write-Log -Level 'INFO' -Message 'Overwrite confirmation skipped because -Force was specified.'
    }
}

# ============================================================
# Generate server key pair
# ============================================================

$Awg = Resolve-AwgExecutable
Write-Log -Level 'INFO' -Message "Using AWG executable: $Awg"

$PrivateKey = Invoke-AwgSecretCommand `
    -Awg $Awg `
    -Command 'genkey'

$PublicKey = Invoke-AwgSecretCommand `
    -Awg $Awg `
    -Command 'pubkey' `
    -InputText $PrivateKey

if (
    $PrivateKey -notmatch '^[A-Za-z0-9+/]{43}=$' -or
    $PublicKey -notmatch '^[A-Za-z0-9+/]{43}=$'
) {
    throw 'Generated server key pair has an unexpected format.'
}

Write-Log -Level 'OK' -Message 'New server key pair generated. Key values are not written to the log.'

# ============================================================
# Generate AWG headers
# ============================================================

$Headers = New-AwgHeaderValues

$H1 = $Headers[0]
$H2 = $Headers[1]
$H3 = $Headers[2]
$H4 = $Headers[3]

$uniqueHeaders = @(
    @($H1, $H2, $H3, $H4) | Select-Object -Unique
)

if ($uniqueHeaders.Count -ne 4) {
    throw 'Generated H1-H4 values are not unique.'
}

Write-Log -Level 'OK' -Message 'New unique H1-H4 values generated.'

# ============================================================
# Build complete server.env
# ============================================================

$Content = @"
WG_IPV4_NETWORK=$WG_IPV4_NETWORK
WG_IPV4_SERVER=$WG_IPV4_SERVER

WG_IPV6_NETWORK=$WG_IPV6_NETWORK
WG_IPV6_SERVER=$WG_IPV6_SERVER

DNS1=$DNS1
DNS2=$DNS2

SERVER_PRIVATE_KEY=$PrivateKey
SERVER_PUBLIC_KEY=$PublicKey

JC=$JC
JMIN=$JMIN
JMAX=$JMAX

S1=$S1
S2=$S2
S3=$S3
S4=$S4

H1=$H1
H2=$H2
H3=$H3
H4=$H4

RANDOM_TRAILERS=$RANDOM_TRAILERS
"@

$ConfigDir = Split-Path -Parent $EnvFile
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

$TempFile = Join-Path $ConfigDir ('.server.env.' + [Guid]::NewGuid().ToString('N') + '.tmp')

try {
    Write-Utf8Lf -Path $TempFile -Text $Content

    $check = Get-Content -LiteralPath $TempFile -Raw

    $problem = Test-EnvText -Text $check

    if ($problem) {
        throw "Generated server.env is invalid: $problem"
    }

    # Back up only after a successful generation, right before the replacement.
    if ((Test-Path -LiteralPath $EnvFile) -and -not $NoBackup) {
        $BackupPath = New-EnvBackup
    }

    Copy-Item -LiteralPath $TempFile -Destination $EnvFile -Force
}
finally {
    Remove-Item -LiteralPath $TempFile -Force -ErrorAction SilentlyContinue
}

# ============================================================
# Result
# ============================================================

Write-Log -Level 'OK' -Message "server.env created: $EnvFile"
Write-Log -Level 'INFO' -Message "IPv4 network: $WG_IPV4_NETWORK; server: $WG_IPV4_SERVER"
Write-Log -Level 'INFO' -Message "IPv6 network: $WG_IPV6_NETWORK; server: $WG_IPV6_SERVER"
Write-Log -Level 'INFO' -Message "DNS: $DNS1, $DNS2"
Write-Log -Level 'INFO' -Message "AWG: JC=$JC JMIN=$JMIN JMAX=$JMAX S1-S4=$S1 RandomTrailers=$RANDOM_TRAILERS"
Write-Log -Level 'INFO' -Message 'H1-H4 generated; values are not written to the log.'

$ExistingBackups = @(Get-EnvBackups)

if ($NoBackup -and $ExistingBackups.Count -gt 0) {
    Write-Log -Level 'WARN' -Message "$($ExistingBackups.Count) earlier server.env backup(s) remain in $ConfigDir and may contain the old private key; delete them if it is compromised."
}

Write-Log -Level 'WARN' -Message 'All existing client configs now reference the old SERVER_PUBLIC_KEY until sync-servers.ps1 updates them.'
Write-Log -Level 'WARN' -Message 'All configured VPS servers continue using the old SERVER_PRIVATE_KEY until sync-servers.ps1 is applied.'
Write-Log -Level 'DONE' -Message "SUCCESS. Log: $LogFile"
