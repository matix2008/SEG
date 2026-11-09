# Common functions for SEG scripts (roadmap, principle 3).
# Copies of the tested helpers from the VPN scripts: the VPN scripts are not changed to use this file.
# Keep this file ASCII-only: .ps1 files are read by Windows PowerShell 5.1.

# ============================================================
# Logging
# ============================================================

function Invoke-LogRotation {
    if (-not (Test-Path -LiteralPath $script:LogFile)) {
        return
    }

    $size = (Get-Item -LiteralPath $script:LogFile).Length

    if ($size -lt $script:LogMaxBytes) {
        return
    }

    $oldest = "$($script:LogFile).$($script:LogBackupCount)"
    Remove-Item -LiteralPath $oldest -Force -ErrorAction SilentlyContinue

    for ($i = $script:LogBackupCount - 1; $i -ge 1; $i--) {
        $source = "$($script:LogFile).$i"

        if (Test-Path -LiteralPath $source) {
            Move-Item -LiteralPath $source -Destination "$($script:LogFile).$($i + 1)" -Force
        }
    }

    Move-Item -LiteralPath $script:LogFile -Destination "$($script:LogFile).1" -Force
}

function Initialize-Logging {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$ScriptName
    )

    $script:ScriptName = $ScriptName
    $script:RunId = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $script:LogsDir = Join-Path $Root 'logs'
    $script:LogFile = Join-Path $script:LogsDir 'amnezia.log'
    $script:LogMaxBytes = 10MB
    $script:LogBackupCount = 3
    $script:LogEncoding = New-Object System.Text.UTF8Encoding($false)

    New-Item -ItemType Directory -Force -Path $script:LogsDir | Out-Null

    Invoke-LogRotation
}

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
    $line = "$timestamp [$($script:ScriptName)] [$($script:RunId)] [$Level] $Message"

    [System.IO.File]::AppendAllText($script:LogFile, $line + "`n", $script:LogEncoding)

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

        if ($answer -in @('y', 'yes', [string][char]0x0434, ([string][char]0x0434 + [char]0x0430))) {
            Write-Log -Level 'INFO' -Message "Confirmation: $Message -> YES"
            return $true
        }

        if ($answer -in @('n', 'no', [string][char]0x043d, ([string][char]0x043d + [char]0x0435 + [char]0x0442))) {
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

    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-EnvFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $result = @{}
    $leaf = Split-Path -Leaf $Path

    foreach ($raw in Get-Content -LiteralPath $Path) {
        $line = $raw.Trim()

        if (-not $line -or $line.StartsWith('#')) {
            continue
        }

        $parts = @($line -split '=', 2)

        if ($parts.Count -ne 2) {
            throw "Invalid line in ${leaf}: $line"
        }

        $name = $parts[0].Trim()

        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "Invalid empty parameter name in $leaf"
        }

        $result[$name] = $parts[1].Trim()
    }

    return $result
}

# ============================================================
# Cryptography
# ============================================================

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

function New-AwgKeyPair {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Awg
    )

    $private = Invoke-AwgSecretCommand -Awg $Awg -Command 'genkey'
    $public = Invoke-AwgSecretCommand -Awg $Awg -Command 'pubkey' -InputText $private

    if ($private -notmatch '^[A-Za-z0-9+/]{43}=$' -or $public -notmatch '^[A-Za-z0-9+/]{43}=$') {
        throw 'Generated AmneziaWG key pair has an unexpected format.'
    }

    return [pscustomobject]@{ Private = $private; Public = $public }
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

function New-RandomHexString {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Bytes
    )

    $buffer = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    try {
        $rng.GetBytes($buffer)
    }
    finally {
        $rng.Dispose()
    }

    return (($buffer | ForEach-Object { $_.ToString('x2') }) -join '')
}

function New-AwgHeaderValues {
    $values = @()

    while ($values.Count -lt 4) {
        [uint32]$value = Get-CryptoRandomInt -Min 5 -Max 2147483647

        # 0 and compatibility values 1..4 are intentionally excluded.
        if ($value -le 4 -or $values -contains $value) {
            continue
        }

        $values += $value
    }

    return $values
}

function Resolve-SingBoxExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$RequiredVersion
    )

    $local = Join-Path $Root 'tools\sing-box.exe'
    $exe = $null

    if (Test-Path -LiteralPath $local) {
        $exe = $local
    }
    else {
        $command = Get-Command sing-box.exe -ErrorAction SilentlyContinue

        if ($command) {
            $exe = $command.Source
        }
    }

    if (-not $exe) {
        throw "sing-box $RequiredVersion was not found. Put sing-box.exe into $(Join-Path $Root 'tools') or add it to PATH."
    }

    $previousErrorActionPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = 'Continue'
        $first = @(& $exe version 2>&1 | ForEach-Object { [string]$_ } | Select-Object -First 1)
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($first.Count -eq 0 -or $first[0] -notmatch "^sing-box version $([regex]::Escape($RequiredVersion))\s*$") {
        throw "sing-box $RequiredVersion is required; $exe reports: $($first -join ' ')"
    }

    return $exe
}

# ============================================================
# Env file backups (parameterized by file)
# ============================================================

function Get-EnvBackups {
    # The timestamp in the name sorts chronologically; newest first.
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvFile
    )

    $dir = Split-Path -Parent $EnvFile
    $leaf = Split-Path -Leaf $EnvFile

    if (-not (Test-Path -LiteralPath $dir)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $dir -Filter "$leaf.*.bak" -File |
        Sort-Object Name -Descending
    )
}

function New-EnvBackup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvFile,

        [Parameter(Mandatory = $false)]
        [int]$KeepCount = 3
    )

    $leaf = Split-Path -Leaf $EnvFile
    $path = Join-Path (Split-Path -Parent $EnvFile) ("$leaf." + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '.bak')

    Copy-Item -LiteralPath $EnvFile -Destination $path

    Write-Log -Level 'OK' -Message "Backup of the current $leaf created: $path"

    @(Get-EnvBackups -EnvFile $EnvFile | Select-Object -Skip $KeepCount) | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force
        Write-Log -Level 'INFO' -Message "Old backup removed (keeping the last $KeepCount): $($_.Name)"
    }

    return $path
}
