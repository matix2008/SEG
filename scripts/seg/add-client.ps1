param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$ClientName,

    [Parameter(Mandatory = $false, Position = 1)]
    [string]$ServerName
)

# SEG mode of add-client.ps1 (roadmap, item 23): creates the client record clients\seg\<name>.json (random UUID)
# and its profile clients\generated\seg\<name>.json with the metadata. VPS2 is not touched: the UUID reaches
# the sing-box users with the next sync-servers.ps1 -Mode SEG all.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $PSScriptRoot '..\lib\servers.ps1')
. (Join-Path $PSScriptRoot '..\lib\segenv.ps1')
. (Join-Path $PSScriptRoot '..\lib\seglist.ps1')
. (Join-Path $PSScriptRoot '..\lib\segclients.ps1')
. (Join-Path $PSScriptRoot '..\lib\segprofile.ps1')

Initialize-Logging -Root $Root -ScriptName (Split-Path -Leaf $PSCommandPath)

trap {
    Write-Log -Level 'ERROR' -Message (Get-ErrorDescription -ErrorRecord $_)

    if ($_.ScriptStackTrace) {
        Write-Log -Level 'ERROR' -Message $_.ScriptStackTrace -LogOnly
    }

    Write-Log -Level 'DONE' -Message "FAILED. Log: $($script:LogFile)"
    exit 1
}

Write-Log -Level 'START' -Message 'SEG: creating a client.'

if ($ServerName) {
    throw 'SEG mode has a single gateway: the server argument is not used. Run: add-client.ps1 -Mode SEG <client>.'
}

if (-not $ClientName) {
    $ClientName = ([string](Read-Host 'Client name')).Trim()
}

$reason = Test-SegClientName -Name $ClientName

if ($reason) {
    throw "Invalid client name '$ClientName': $reason"
}

# ============================================================
# Preconditions: configuration, existing clients
# ============================================================

$Context = Get-SegProjectContext -Root $Root
Write-Log -Level 'OK' -Message "SEG configuration validated: gateway $($Context.Gateway.IP):$($Context.Gateway.Port), seg-list version $($Context.SegList.Version)."

$ExistingClients = @(Read-SegClients -Root $Root)

if (@($ExistingClients | Where-Object { $_.Name.ToLowerInvariant() -eq $ClientName.ToLowerInvariant() }).Count -gt 0) {
    throw "SEG client already exists: $ClientName"
}

# A leftover profile without a record would be overwritten silently: stop and let the user decide.
$ProfilePaths = Get-SegProfilePaths -Root $Root -Name $ClientName

foreach ($leftover in @($ProfilePaths.Profile, $ProfilePaths.Meta)) {
    if (Test-Path -LiteralPath $leftover) {
        throw "A generated profile file already exists without a client record: $leftover. Delete it first."
    }
}

# ============================================================
# Build and verify the profile before anything is written
# ============================================================

$Client = New-SegClient -Name $ClientName

$ProfileText = New-SegClientProfileText -Root $Root -Env $Context.Env -SegList $Context.SegList -Client $Client -Gateway $Context.Gateway
Test-SegClientProfile -Text $ProfileText -Env $Context.Env -SegList $Context.SegList -Client $Client -Gateway $Context.Gateway -Exit $Context.Exit
Invoke-SingBoxClientCheck -Root $Root -Text $ProfileText
Write-Log -Level 'OK' -Message 'The client profile was built and verified (structure and sing-box check). The UUID is not logged.'

Write-Log -Level 'INFO' -Message "Client candidate: name=$ClientName; gateway=$($Context.Gateway.IP):$($Context.Gateway.Port)"

if (-not (Confirm-Action 'Create client?')) {
    Write-Log -Level 'DONE' -Message 'CANCELLED.'
    exit 0
}

# ============================================================
# Write: the record first, then the profile; a failure removes what was written
# ============================================================

$RecordPath = Save-SegClient -Root $Root -Client $Client

try {
    [void](Write-SegClientProfile -Root $Root -Client $Client -Text $ProfileText -Env $Context.Env -SegList $Context.SegList -Gateway $Context.Gateway)
}
catch {
    Remove-Item -LiteralPath $RecordPath -Force -ErrorAction SilentlyContinue
    throw
}

Write-Log -Level 'OK' -Message "Client record created: $RecordPath"
Write-Log -Level 'OK' -Message "Client profile created: $($ProfilePaths.Profile)"
Write-Log -Level 'WARN' -Message 'VPS2 does not know the new client yet: run sync-servers.ps1 -Mode SEG all to add the UUID to sing-box.'
Write-Log -Level 'WARN' -Message 'The profile contains the UUID: hand it over through a secure channel only.'
Write-Log -Level 'DONE' -Message "SUCCESS. Log: $($script:LogFile)"
exit 0
