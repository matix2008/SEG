param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('VPN', 'SEG')]
    [string]$Mode,

    [Parameter(Mandatory = $false, Position = 0)]
    [string]$ClientName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $PSBoundParameters.ContainsKey('Mode')) {
    [Console]::Error.WriteLine('ERROR: parameter -Mode is required. Use -Mode VPN or -Mode SEG.')
    exit 1
}

if ($Mode -eq 'SEG') {
    $segScript = Join-Path $PSScriptRoot 'seg\remove-client.ps1'

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

$Root = Split-Path -Parent $PSScriptRoot

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


$TemplateFile = Join-Path $Root 'config\awg0.conf.template'
$ClientsDir   = Join-Path $Root 'clients'
$GeneratedDir = Join-Path $ClientsDir 'generated'

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

if (-not (Test-Path $TemplateFile)) {
    throw "Required file not found: $TemplateFile"
}

Write-Log -Level 'OK' -Message 'Template file verified.'

if (-not $ClientName) {
    $ClientName = (Read-Host 'Client name').Trim()
}

if ($ClientName -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Invalid client name: $ClientName"
}

$ClientFile = Join-Path $ClientsDir "$ClientName.conf"

$Template = Get-Content $TemplateFile -Raw
$EscapedName = [regex]::Escape($ClientName)

$PeerPattern = (
    '(?ms)^# BEGIN_PEER ' +
    $EscapedName +
    '\s*\r?\n.*?^# END_PEER ' +
    $EscapedName +
    '\s*\r?\n?'
)

$PeerExists = [regex]::IsMatch(
    $Template,
    $PeerPattern
)

$ClientFileExists = Test-Path $ClientFile

Write-Log -Level 'INFO' -Message "Client lookup: name=$ClientName; peerInTemplate=$PeerExists; clientConfig=$ClientFileExists"

if (-not $PeerExists -and -not $ClientFileExists) {
    throw "Client not found: $ClientName"
}

Write-Log -Level 'INFO' -Message "Client: $ClientName"
Write-Log -Level 'INFO' -Message "Peer in template: $PeerExists"
Write-Log -Level 'INFO' -Message "Client config exists: $ClientFileExists"

if (-not (Confirm-Action 'Remove client?')) {
    Write-Log -Level 'DONE' -Message "Cancelled by user. Log: $LogFile"
    exit 0
}

$TemplateBackup = "$TemplateFile.bak"
$ClientBackup = $null

Copy-Item `
    -LiteralPath $TemplateFile `
    -Destination $TemplateBackup `
    -Force

if ($ClientFileExists) {
    $ClientBackup = "$ClientFile.bak"

    Copy-Item `
        -LiteralPath $ClientFile `
        -Destination $ClientBackup `
        -Force
}

try {

    if ($PeerExists) {

        $NewTemplate = [regex]::Replace(
            $Template,
            $PeerPattern,
            ''
        )

        # Убираем лишние пустые строки, но не меняем структуру файла.
        $NewTemplate = $NewTemplate -replace "(`r?`n){3,}", "`n`n"

        Write-Utf8Lf `
            -Path $TemplateFile `
            -Text $NewTemplate

        Write-Log -Level 'OK' -Message "Peer removed from template: $ClientName"
    }

    if ($ClientFileExists) {
        Remove-Item `
            -LiteralPath $ClientFile `
            -Force

        Write-Log -Level 'OK' -Message "Client config removed: $ClientFile"
    }

    # Derived profiles are isolated by client name.
    $GeneratedClientDir = Join-Path $GeneratedDir $ClientName

    if (Test-Path -LiteralPath $GeneratedClientDir) {
        Remove-Item -LiteralPath $GeneratedClientDir -Recurse -Force
        Write-Log -Level 'OK' -Message "Removed derived client profile directory: $GeneratedClientDir"
    }

}
catch {

    Copy-Item `
        -LiteralPath $TemplateBackup `
        -Destination $TemplateFile `
        -Force

    if ($ClientBackup -and (Test-Path $ClientBackup)) {
        Copy-Item `
            -LiteralPath $ClientBackup `
            -Destination $ClientFile `
            -Force
    }

    Write-Log -Level 'WARN' -Message 'Local changes rolled back after failure.'
    throw
}
finally {

    Remove-Item `
        -LiteralPath $TemplateBackup `
        -Force `
        -ErrorAction SilentlyContinue

    if ($ClientBackup) {
        Remove-Item `
            -LiteralPath $ClientBackup `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

Write-Log -Level 'OK' -Message 'CLIENT_REMOVED'
Write-Log -Level 'INFO' -Message "Name: $ClientName"
Write-Log -Level 'INFO' -Message 'Local source of truth has been updated.'
Write-Log -Level 'INFO' -Message 'Run sync-servers.ps1 to remove the peer from VPS servers.'
Write-Log -Level 'DONE' -Message "CLIENT_REMOVED: $ClientName. Run sync-servers.ps1 to propagate the change. Log: $LogFile"
