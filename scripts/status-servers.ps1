param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('VPN', 'SEG')]
    [string]$Mode
)

# Read-only status of the servers: resources, services, backhaul and the connected clients.
# Only -Mode SEG is implemented (scripts\seg\status-seg.ps1); -Mode VPN is not available.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $PSBoundParameters.ContainsKey('Mode')) {
    [Console]::Error.WriteLine('ERROR: parameter -Mode is required. Use -Mode SEG.')
    exit 1
}

if ($Mode -ne 'SEG') {
    [Console]::Error.WriteLine('ERROR: the status script is available only in -Mode SEG.')
    exit 1
}

$segScript = Join-Path $PSScriptRoot 'seg\status-seg.ps1'

if (-not (Test-Path -LiteralPath $segScript)) {
    [Console]::Error.WriteLine("ERROR: SEG mode is not available: $segScript was not found.")
    exit 1
}

$global:LASTEXITCODE = 0

try {
    & $segScript
}
catch {
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
    exit 1
}

exit $global:LASTEXITCODE
