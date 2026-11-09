param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('VPN', 'SEG')]
    [string]$Mode,

    [Parameter(Mandatory = $false, Position = 0)]
    [string]$ClientName,

    [Parameter(Mandatory = $false, Position = 1)]
    [string]$ServerName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $PSBoundParameters.ContainsKey('Mode')) {
    [Console]::Error.WriteLine('ERROR: parameter -Mode is required. Use -Mode VPN or -Mode SEG.')
    exit 1
}

if ($Mode -eq 'SEG') {
    $segScript = Join-Path $PSScriptRoot 'seg\add-client.ps1'

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

$Root = Split-Path -Parent $PSScriptRoot

. (Join-Path $PSScriptRoot 'lib\servers.ps1')

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
        [ValidateSet('START', 'INFO', 'OK', 'WARN', 'ERROR', 'DONE', 'OUTPUT')]
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

function Write-LogOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    foreach ($line in ($Text -split '\r\n|\n|\r')) {
        if ($line.Length -eq 0) {
            continue
        }

        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $record = "$timestamp [$Source] [$RunId] [OUTPUT] $line"

        [System.IO.File]::AppendAllText(
            $LogFile,
            $record + "`n",
            $LogEncoding
        )

        Microsoft.PowerShell.Utility\Write-Host $record
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

Write-Log -Level 'START' -Message 'Script started.'
Write-Log -Level 'INFO' -Message "PowerShell version: $($PSVersionTable.PSVersion)"


$EnvFile      = Join-Path $Root 'config\server.env'
$TemplateFile = Join-Path $Root 'config\awg0.conf.template'
$ServersFile  = Join-Path $Root 'servers.txt'
$ClientsDir   = Join-Path $Root 'clients'

# ============================================================
# Helpers
# ============================================================

function Read-EnvFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $result = @{}

    foreach ($raw in Get-Content $Path) {
        $line = $raw.Trim()

        if (-not $line -or $line.StartsWith('#')) {
            continue
        }

        $parts = @($line -split '=', 2)

        if ($parts.Count -ne 2) {
            throw "Invalid line in server.env: $line"
        }

        $name  = $parts[0].Trim()
        $value = $parts[1].Trim()

        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "Empty parameter name in server.env"
        }

        $result[$name] = $value
    }

    return $result
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
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw @"
awg.exe was not found.

AmneziaWG tools must be installed on the local Windows computer
and awg.exe must either be in PATH or in the standard installation directory.
"@
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

# ============================================================
# Validate source files
# ============================================================

foreach ($file in @(
    $EnvFile,
    $TemplateFile,
    $ServersFile
)) {
    if (-not (Test-Path $file)) {
        throw "Required file not found: $file"
    }
}

Write-Log -Level 'OK' -Message 'Required local files verified.'

New-Item `
    -ItemType Directory `
    -Force `
    -Path $ClientsDir |
    Out-Null

$Env = Read-EnvFile $EnvFile

$RequiredEnv = @(
    'WG_IPV4_NETWORK',
    'WG_IPV4_SERVER',
    'WG_IPV6_NETWORK',
    'WG_IPV6_SERVER',
    'DNS1',
    'DNS2',
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

foreach ($name in $RequiredEnv) {

    if (
        -not $Env.ContainsKey($name) -or
        [string]::IsNullOrWhiteSpace($Env[$name])
    ) {
        throw "Missing or empty server.env parameter: $name"
    }
}

if ($Env['SERVER_PUBLIC_KEY'] -notmatch '^[A-Za-z0-9+/]{43}=$') {
    throw 'SERVER_PUBLIC_KEY does not look like a valid WireGuard/AmneziaWG base64 key'
}

# ============================================================
# Validate AWG parameters
# ============================================================

$RandomTrailers = $Env['RANDOM_TRAILERS'].ToLowerInvariant()

if ($RandomTrailers -notin @('on', 'off')) {
    throw "RANDOM_TRAILERS must be 'on' or 'off'"
}

if ($RandomTrailers -eq 'on') {

    $sizes = @(
        @(
            $Env['S1'],
            $Env['S2'],
            $Env['S3'],
            $Env['S4']
        ) | Select-Object -Unique
    )

    if ($sizes.Count -ne 1) {
        throw "RandomTrailers=on requires S1=S2=S3=S4 in this configuration"
    }
}

$headers = @(
    @(
        $Env['H1'],
        $Env['H2'],
        $Env['H3'],
        $Env['H4']
    ) | Select-Object -Unique
)

if ($headers.Count -ne 4) {
    throw "H1, H2, H3 and H4 must be different"
}

Write-Log -Level 'OK' -Message 'server.env validated.'

# ============================================================
# Client name
# ============================================================

if (-not $ClientName) {
    $ClientName = (Read-Host 'Client name').Trim()
}

if ($ClientName -notmatch '^[A-Za-z0-9._-]+$') {
    throw @"
Invalid client name: $ClientName

Allowed characters:
A-Z a-z 0-9 . _ -
"@
}

$ClientFile = Join-Path $ClientsDir "$ClientName.conf"

if (Test-Path $ClientFile) {
    throw "Client config already exists: $ClientFile"
}

$Template = Get-Content $TemplateFile -Raw

$escapedName = [regex]::Escape($ClientName)

if ($Template -match "(?m)^# BEGIN_PEER $escapedName\s*$") {
    throw "Client already exists in awg0.conf.template: $ClientName"
}

if ($Template -notmatch '(?m)^# PEERS\s*$') {
    throw "Marker '# PEERS' not found in awg0.conf.template"
}

# ============================================================
# Select initial endpoint server for client config
# ============================================================

$ServersLoaded = Read-ServersFile -Path $ServersFile

if ($ServersLoaded.Format -eq 'legacy') {
    throw 'servers.txt uses the legacy format (Name;IP;Port;Enabled). Run sync-servers.ps1 -Mode VPN first: it migrates the file.'
}

$Servers = @(
    Select-ServersForMode -Servers @($ServersLoaded.Servers) -Mode VPN |
    Where-Object { $_.IsEnabled }
)

if ($Servers.Count -eq 0) {
    throw "No enabled servers in servers.txt"
}

if ($ServerName) {

    $Server = $Servers |
        Where-Object { $_.Name -eq $ServerName } |
        Select-Object -First 1

    if (-not $Server) {
        throw "Enabled server not found: $ServerName"
    }

}
elseif ($Servers.Count -eq 1) {

    $Server = $Servers[0]

    Write-Log -Level 'INFO' -Message "Only one enabled server; initial endpoint: $($Server.Name) $($Server.IP):$($Server.Port)"

}
else {

    Write-Log -Level 'INFO' -Message 'Available endpoint servers:'

    foreach ($item in $Servers) {
        Write-Log -Level 'INFO' -Message "  $($item.Name)  $($item.IP):$($item.Port)"
    }

    $ServerName = (Read-Host 'Endpoint server').Trim()

    $Server = $Servers |
        Where-Object { $_.Name -eq $ServerName } |
        Select-Object -First 1

    if (-not $Server) {
        throw "Enabled server not found: $ServerName"
    }
}

Write-Log -Level 'INFO' -Message "Initial endpoint selected: $($Server.Name) $($Server.IP):$($Server.Port)"

if (
    $Server.Port -notmatch '^\d+$' -or
    [int]$Server.Port -lt 1 -or
    [int]$Server.Port -gt 65535
) {
    throw "Invalid AWG UDP port for endpoint server $($Server.Name): $($Server.Port)"
}

if ([string]::IsNullOrWhiteSpace($Server.IP)) {
    throw "Endpoint server has an empty IP: $($Server.Name)"
}


# ============================================================
# Allocate client IP
# Current scheme requires IPv4 /24
# ============================================================

if ($Env['WG_IPV4_NETWORK'] -notmatch '^(\d+)\.(\d+)\.(\d+)\.0/24$') {
    throw "WG_IPV4_NETWORK must currently be an IPv4 /24 network"
}

$IPv4Prefix = "$($matches[1]).$($matches[2]).$($matches[3])"

$UsedNumbers = @()

$peerMatches = [regex]::Matches(
    $Template,
    "AllowedIPs\s*=\s*$([regex]::Escape($IPv4Prefix))\.(\d+)/32"
)

foreach ($match in $peerMatches) {
    $UsedNumbers += [int]$match.Groups[1].Value
}

$ClientNumber = 2

while ($UsedNumbers -contains $ClientNumber) {
    $ClientNumber++
}

if ($ClientNumber -gt 254) {
    throw "No free client IPv4 addresses in $($Env['WG_IPV4_NETWORK'])"
}

$ClientIPv4 = "$IPv4Prefix.$ClientNumber"

# ============================================================
# Allocate IPv6 address
# ============================================================

$IPv6Network = ($Env['WG_IPV6_NETWORK'] -split '/', 2)[0]

if (-not $IPv6Network.EndsWith('::')) {
    throw @"
WG_IPV6_NETWORK must currently use a network ending in ::
Example: fddd:2c4:2c4:2c4::/64
"@
}

$IPv6Suffix = $ClientNumber.ToString('x')
$ClientIPv6 = "$IPv6Network$IPv6Suffix"

Write-Log -Level 'INFO' -Message "Allocated client addresses: IPv4=$ClientIPv4, IPv6=$ClientIPv6"

# ============================================================
# Generate keys
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

$PresharedKey = Invoke-AwgSecretCommand `
    -Awg $Awg `
    -Command 'genpsk'

Write-Log -Level 'OK' -Message 'Client key pair and preshared key generated. Secret values are not logged.'

# ============================================================
# Prepare server peer
# ============================================================

$PeerBlock = @"
# BEGIN_PEER $ClientName
[Peer]
PublicKey = $PublicKey
PresharedKey = $PresharedKey
AllowedIPs = $ClientIPv4/32, $ClientIPv6/128
# END_PEER $ClientName
"@

$NewTemplate = [regex]::Replace(
    $Template,
    '(?m)^# PEERS\s*$',
    "$PeerBlock`n`n# PEERS",
    1
)

# ============================================================
# Prepare single persistent client config
# ============================================================

$ClientConfig = @"
[Interface]
Address = $ClientIPv4/24, $ClientIPv6/64
DNS = $($Env['DNS1']), $($Env['DNS2'])
PrivateKey = $PrivateKey
Jc = $($Env['JC'])
Jmin = $($Env['JMIN'])
Jmax = $($Env['JMAX'])
S1 = $($Env['S1'])
S2 = $($Env['S2'])
S3 = $($Env['S3'])
S4 = $($Env['S4'])
H1 = $($Env['H1'])
H2 = $($Env['H2'])
H3 = $($Env['H3'])
H4 = $($Env['H4'])
RandomTrailers = $($Env['RANDOM_TRAILERS'])

[Peer]
PublicKey = $($Env['SERVER_PUBLIC_KEY'])
PresharedKey = $PresharedKey
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $($Server.IP):$($Server.Port)
PersistentKeepalive = 25
"@

# ============================================================
# Confirmation
# ============================================================

Write-Log -Level 'INFO' -Message "Client candidate: name=$ClientName; IPv4=$ClientIPv4; IPv6=$ClientIPv6; Endpoint=$($Server.IP):$($Server.Port)"

if (-not (Confirm-Action 'Create client?')) {
    Write-Log -Level 'DONE' -Message "Cancelled by user. Log: $LogFile"
    exit 0
}

# ============================================================
# Atomic-ish local update with rollback
# ============================================================

$TemplateBackup = "$TemplateFile.bak"

Copy-Item `
    -LiteralPath $TemplateFile `
    -Destination $TemplateBackup `
    -Force

try {

    Write-Utf8Lf `
        -Path $ClientFile `
        -Text $ClientConfig

    Write-Log -Level 'OK' -Message "Client config created: $ClientFile"

    Write-Utf8Lf `
        -Path $TemplateFile `
        -Text $NewTemplate

    Write-Log -Level 'OK' -Message "Peer added to template: $TemplateFile"

}
catch {

    Remove-Item `
        -LiteralPath $ClientFile `
        -Force `
        -ErrorAction SilentlyContinue

    Copy-Item `
        -LiteralPath $TemplateBackup `
        -Destination $TemplateFile `
        -Force

    Write-Log -Level 'WARN' -Message 'Local changes rolled back after failure.'
    throw
}
finally {

    Remove-Item `
        -LiteralPath $TemplateBackup `
        -Force `
        -ErrorAction SilentlyContinue
}

# ============================================================
# Result
# ============================================================

Write-Log -Level 'OK' -Message 'CLIENT_CREATED'
Write-Log -Level 'INFO' -Message "Name: $ClientName"
Write-Log -Level 'INFO' -Message "IPv4: $ClientIPv4"
Write-Log -Level 'INFO' -Message "IPv6: $ClientIPv6"
Write-Log -Level 'INFO' -Message "Endpoint: $($Server.IP):$($Server.Port)"
Write-Log -Level 'INFO' -Message "Config: $ClientFile"
Write-Log -Level 'INFO' -Message "Peer added to: $TemplateFile"
Write-Log -Level 'DONE' -Message "Client creation completed successfully. Log: $LogFile"
