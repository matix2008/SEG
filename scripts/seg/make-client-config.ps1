param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$ClientName,

    [Parameter(Mandatory = $false, Position = 1)]
    [string]$ServerName
)

# SEG mode of make-client-config.ps1 (roadmap, item 25): (re)creates the profile of an existing client,
# clients\generated\seg\<name>.json with its metadata. The profile is a complete sing-box 1.14.4 configuration
# built from the template, seg.env, seg-list.json, servers.txt and the UUID of the client; it is verified before
# it is written. Nothing on the VPS changes.

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

Write-Log -Level 'START' -Message 'SEG: creating a client profile.'

if ($ServerName) {
    throw 'SEG mode has a single gateway: the server argument is not used. Run: make-client-config.ps1 -Mode SEG <client>.'
}

$Context = Get-SegProjectContext -Root $Root
$Clients = @(Read-SegClients -Root $Root)

if ($Clients.Count -eq 0) {
    throw 'There are no SEG clients. Create one with add-client.ps1 -Mode SEG <client>.'
}

# The state of every profile is shown first, so that it is clear which profiles need to be recreated.
foreach ($item in $Clients) {
    $itemStatus = Get-SegProfileStatus -Root $Root -Client $item -SegList $Context.SegList -Env $Context.Env -Gateway $Context.Gateway

    if ($itemStatus.State -in @('CURRENT', 'DISABLED')) {
        Write-Log -Level 'INFO' -Message "Client $($item.Name): profile $($itemStatus.State)."
    }
    else {
        Write-Log -Level 'WARN' -Message "Client $($item.Name): profile $($itemStatus.State) - $($itemStatus.Reasons -join '; ')."
    }
}

if (-not $ClientName) {
    $ClientName = ([string](Read-Host 'Client name')).Trim()
}

# The name goes into file paths: it must be valid before it is used.
$reason = Test-SegClientName -Name $ClientName

if ($reason) {
    throw "Invalid client name '$ClientName': $reason"
}

$Client = $Clients | Where-Object { $_.Name.ToLowerInvariant() -eq $ClientName.ToLowerInvariant() } | Select-Object -First 1

if (-not $Client) {
    throw "SEG client not found: $ClientName. Existing clients: $(($Clients | ForEach-Object { $_.Name }) -join ', ')"
}

if (-not $Client.Enabled) {
    throw "SEG client $($Client.Name) is disabled (enabled = false): VPS2 does not accept its UUID, so a profile would not work. Enable the client first."
}

$Status = Get-SegProfileStatus -Root $Root -Client $Client -SegList $Context.SegList -Env $Context.Env -Gateway $Context.Gateway

if ($Status.State -eq 'CURRENT') {
    Write-Log -Level 'OK' -Message "The profile of $($Client.Name) is current (seg-list version $($Context.SegList.Version))."

    if (-not (Confirm-Action 'The profile is current. Recreate it anyway?')) {
        Write-Log -Level 'DONE' -Message 'Nothing changed.'
        exit 0
    }
}
else {
    Write-Log -Level 'INFO' -Message "Profile state of $($Client.Name): $($Status.State) - $($Status.Reasons -join '; ')."

    if (-not (Confirm-Action 'Create the profile?')) {
        Write-Log -Level 'DONE' -Message 'CANCELLED.'
        exit 0
    }
}

$Paths = Save-SegClientProfile -Root $Root -Client $Client -Context $Context

Write-Log -Level 'OK' -Message 'The profile was built and verified (structure and sing-box check). The UUID is not logged.'
Write-Log -Level 'OK' -Message "Client profile created: $($Paths.Profile)"
Write-Log -Level 'WARN' -Message 'The profile contains the UUID: hand it over through a secure channel only.'
Write-Log -Level 'WARN' -Message 'Run sync-servers.ps1 -Mode SEG all before the client connects: VPS2 must know the UUID and the current REALITY and list settings.'
Write-Log -Level 'DONE' -Message "SUCCESS. Log: $($script:LogFile)"
exit 0
