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
    $segScript = Join-Path $PSScriptRoot 'seg\make-client-config.ps1'

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


$ServersFile  = Join-Path $Root 'servers.txt'
$ClientsDir   = Join-Path $Root 'clients'
$GeneratedDir = Join-Path $ClientsDir 'generated'

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

if (-not (Test-Path $ServersFile)) {
    throw "Required file not found: $ServersFile"
}

Write-Log -Level 'OK' -Message 'servers.txt verified.'

if (-not $ClientName) {
    $ClientName = (Read-Host 'Client name').Trim()
}

if ($ClientName -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Invalid client name: $ClientName"
}

$GeneratedClientDir = Join-Path $GeneratedDir $ClientName
$ClientFile = Join-Path $ClientsDir "$ClientName.conf"

if (-not (Test-Path $ClientFile)) {
    throw "Client config not found: $ClientFile"
}

Write-Log -Level 'OK' -Message "Source client config found: $ClientFile"

$Servers = @(
    Import-Csv `
        $ServersFile `
        -Delimiter ';' |
    Where-Object {
        (-not [string]::IsNullOrWhiteSpace([string]$_.Enabled)) -and ([string]$_.Enabled).Trim().ToLowerInvariant() -eq 'true'
    }
)

if ($Servers.Count -eq 0) {
    throw "No enabled servers in servers.txt"
}

if (-not $ServerName) {

    Write-Log -Level 'INFO' -Message 'Available endpoint servers:'

    foreach ($server in $Servers) {
        Write-Log -Level 'INFO' -Message "  $($server.Name)  $($server.IP):$($server.Port)"
    }

    $ServerName = (Read-Host 'Server name').Trim()
}

$Server = $Servers |
    Where-Object { $_.Name -eq $ServerName } |
    Select-Object -First 1

Write-Log -Level 'INFO' -Message "Requested endpoint server: $ServerName"

if (-not $Server) {
    throw "Enabled server not found: $ServerName"
}

Write-Log -Level 'INFO' -Message "Endpoint selected: $($Server.Name) $($Server.IP):$($Server.Port)"

if ([string]::IsNullOrWhiteSpace($Server.IP)) {
    throw "Selected endpoint server has an empty IP: $($Server.Name)"
}


if (
    $Server.Port -notmatch '^\d+$' -or
    [int]$Server.Port -lt 1 -or
    [int]$Server.Port -gt 65535
) {
    throw "Invalid server port: $($Server.Port)"
}

$Config = Get-Content $ClientFile -Raw

$EndpointMatches = [regex]::Matches(
    $Config,
    '(?m)^\s*Endpoint\s*=\s*.+$'
)

if ($EndpointMatches.Count -ne 1) {
    throw "Expected exactly one Endpoint in $ClientFile; found $($EndpointMatches.Count)"
}

$NewEndpoint = "$($Server.IP):$($Server.Port)"

$GeneratedConfig = [regex]::Replace(
    $Config,
    '(?m)^\s*Endpoint\s*=\s*.+$',
    "Endpoint = $NewEndpoint",
    1
)

New-Item `
    -ItemType Directory `
    -Force `
    -Path $GeneratedClientDir |
    Out-Null

$OutputFile = Join-Path `
    $GeneratedClientDir `
    "$ServerName.conf"

Write-Utf8Lf `
    -Path $OutputFile `
    -Text $GeneratedConfig

Write-Log -Level 'OK' -Message "Derived client config created: $OutputFile"

Write-Log -Level 'OK' -Message 'CLIENT_CONFIG_CREATED'
Write-Log -Level 'INFO' -Message "Client: $ClientName"
Write-Log -Level 'INFO' -Message "Server: $ServerName"
Write-Log -Level 'INFO' -Message "Endpoint: $NewEndpoint"
Write-Log -Level 'INFO' -Message "Config: $OutputFile"
Write-Log -Level 'INFO' -Message 'This is a derived client profile.'
Write-Log -Level 'INFO' -Message "Source of truth: $ClientFile"
Write-Log -Level 'DONE' -Message "CLIENT_CONFIG_CREATED: client=$ClientName; server=$ServerName; endpoint=$NewEndpoint. Log: $LogFile"
