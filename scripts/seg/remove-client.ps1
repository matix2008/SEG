param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$ClientName
)

# SEG mode of remove-client.ps1 (roadmap, item 24): removes the client record clients\seg\<name>.json and its
# generated profile. VPS2 is not touched: access ends when sync-servers.ps1 -Mode SEG all removes the UUID
# from the sing-box users. UUID rotation: remove the client, create it again, run sync.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $PSScriptRoot '..\lib\segclients.ps1')

Initialize-Logging -Root $Root -ScriptName (Split-Path -Leaf $PSCommandPath)

trap {
    Write-Log -Level 'ERROR' -Message (Get-ErrorDescription -ErrorRecord $_)

    if ($_.ScriptStackTrace) {
        Write-Log -Level 'ERROR' -Message $_.ScriptStackTrace -LogOnly
    }

    Write-Log -Level 'DONE' -Message "FAILED. Log: $($script:LogFile)"
    exit 1
}

Write-Log -Level 'START' -Message 'SEG: removing a client.'

$Clients = @(Read-SegClients -Root $Root)

if (-not $ClientName) {
    if ($Clients.Count -eq 0) {
        throw 'There are no SEG clients.'
    }

    Write-Log -Level 'INFO' -Message "SEG clients: $(($Clients | ForEach-Object { $_.Name }) -join ', ')"
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

$ProfilePaths = Get-SegProfilePaths -Root $Root -Name $Client.Name
$Targets = @($Client.Path, $ProfilePaths.Profile, $ProfilePaths.Meta) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

Write-Log -Level 'INFO' -Message "Client to remove: name=$($Client.Name); enabled=$($Client.Enabled); files=$($Targets.Count)"

if (-not (Confirm-Action 'Remove client?')) {
    Write-Log -Level 'DONE' -Message 'CANCELLED.'
    exit 0
}

# The profile first: if something fails, the record stays and the command can be repeated.
foreach ($path in @($ProfilePaths.Profile, $ProfilePaths.Meta, $Client.Path)) {
    if ($path -and (Test-Path -LiteralPath $path)) {
        Remove-Item -LiteralPath $path -Force
        Write-Log -Level 'OK' -Message "Removed: $path"
    }
}

$Left = @($Clients | Where-Object { $_.Name -ne $Client.Name })

if (@($Left | Where-Object { $_.Enabled }).Count -eq 0) {
    Write-Log -Level 'WARN' -Message 'No enabled SEG clients are left: after the sync nobody can connect.'
}

Write-Log -Level 'WARN' -Message 'Access of this client ends only after sync-servers.ps1 -Mode SEG all removes its UUID from VPS2 (active connections end when sing-box restarts).'
Write-Log -Level 'DONE' -Message "SUCCESS. Log: $($script:LogFile)"
exit 0
