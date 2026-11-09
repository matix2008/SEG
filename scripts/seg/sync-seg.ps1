param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$ServerName,

    [Parameter(Mandatory = $false)]
    [switch]$Check
)

# SEG mode of sync-servers.ps1: converges the seg-gateway / seg-exit pair (roadmap, items 12 and 27).
# The pair is one unit: only the target "all" is supported and a failure stops the remaining nodes.
# Implemented stages: local validation, SSH, upgrade. The remaining stages are added by roadmap items 13-28.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ============================================================
# Paths and libraries
# ============================================================

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $PSScriptRoot '..\lib\servers.ps1')
. (Join-Path $PSScriptRoot '..\lib\segenv.ps1')
. (Join-Path $PSScriptRoot '..\lib\seglist.ps1')

Initialize-Logging -Root $Root -ScriptName (Split-Path -Leaf $PSCommandPath)

trap {
    Write-Log -Level 'ERROR' -Message (Get-ErrorDescription -ErrorRecord $_)

    if ($_.ScriptStackTrace) {
        Write-Log -Level 'ERROR' -Message $_.ScriptStackTrace -LogOnly
    }

    Write-Log -Level 'DONE' -Message "FAILED. Log: $($script:LogFile)"
    exit 1
}

Write-Log -Level 'START' -Message 'SEG: synchronization started.'
Write-Log -Level 'INFO' -Message "PowerShell version: $($PSVersionTable.PSVersion)"

if ($Check) {
    Write-Log -Level 'INFO' -Message 'CHECK mode: nothing is changed locally or on the VPS, no confirmations are asked.'
}

$ServersFile  = Join-Path $Root 'servers.txt'
$SegEnvFile   = Join-Path $Root 'config\seg.env'
$VpnEnvFile   = Join-Path $Root 'config\server.env'
$SegListFile  = Join-Path $Root 'config\seg-list.json'
$UpgradeFile  = Join-Path $Root 'upgrade.sh'
$TemplatesDir = Join-Path $Root 'seg\templates'

$RequiredTemplates = @(
    'awg-backhaul-vps1.conf.template',
    'awg-backhaul-vps2.conf.template',
    'seg-exit-fw.service.template',
    'seg-exit-keepalive.service.template',
    'seg-exit.nft.template',
    'seg-failclosed.nft.template',
    'seg-failclosed.service.template',
    'sing-box-client-tun.json.template',
    'sing-box-vps2.json.template',
    'sing-box.service.template',
    'unbound-seg.conf.template'
)

# ============================================================
# Step 1 (item 27): local configuration
# ============================================================

$requiredFiles = @($ServersFile, $SegEnvFile, $SegListFile, $UpgradeFile, (Join-Path $Root 'seg\sing-box.sha256')) +
    @($RequiredTemplates | ForEach-Object { Join-Path $TemplatesDir $_ })

foreach ($file in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $file)) {
        throw "Required file not found: $file$(if ($file -eq $SegEnvFile) { '. Run generate-server-env.ps1 -Mode SEG first.' })"
    }
}

Write-Log -Level 'OK' -Message 'Required local files verified.'

$SegEnv = Read-SegEnvFile -Path $SegEnvFile
Test-SegEnvironment -Env $SegEnv -ReservedNetworks @(Get-SegReservedNetworks -VpnEnvFile $VpnEnvFile)
Write-Log -Level 'OK' -Message 'seg.env validated. Secret values are not logged.'

$SegList = Read-SegList -Path $SegListFile
Write-Log -Level 'OK' -Message "seg-list.json validated: version $($SegList.Version), SHA-256 $($SegList.Sha256)."

$ServersLoaded = Read-ServersFile -Path $ServersFile

if ($ServersLoaded.Format -eq 'legacy') {
    throw 'servers.txt uses the legacy format (Name;IP;Port;Enabled) and has no SEG servers. Run sync-servers.ps1 -Mode VPN once to migrate it, then add the seg-gateway and seg-exit rows.'
}

$SegServers = @(Select-ServersForMode -Servers @($ServersLoaded.Servers) -Mode SEG)
Assert-SegTopology -Servers $SegServers

$Gateway = @($SegServers | Where-Object { $_.Role -eq 'seg-gateway' -and $_.IsEnabled })[0]
$Exit    = @($SegServers | Where-Object { $_.Role -eq 'seg-exit' -and $_.IsEnabled })[0]
$Nodes   = @($Gateway, $Exit)

Write-Log -Level 'OK' -Message "servers.txt loaded: seg-gateway $($Gateway.Name) $($Gateway.IP):$($Gateway.Port), seg-exit $($Exit.Name) $($Exit.IP)."

if (-not $ServerName) {
    $ServerName = ([string](Read-Host 'Target (only "all" is supported in SEG mode)')).Trim()
}

if ($ServerName -ne 'all') {
    throw "SEG mode synchronizes the whole pair: use the target 'all' (got '$ServerName')."
}

# ============================================================
# Helpers
# ============================================================

$Results = New-Object System.Collections.Generic.List[object]

function Add-NodeResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Node,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $endpoint = if ($Node.Port) { "$($Node.IP):$($Node.Port)" } else { $Node.IP }

    $Results.Add([PSCustomObject]@{
        Name     = $Node.Name
        Role     = $Node.Role
        Endpoint = $endpoint
        Status   = $Status
        Message  = $Message
    })
}

function Skip-RemainingNodes {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Remaining,

        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    foreach ($node in $Remaining) {
        Add-NodeResult -Node $node -Status 'SKIPPED' -Message $Reason
    }
}

function Get-SegNodeBaseInfo {
    # Read-only: OS, running kernel and the pending-reboot flag.
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP
    )

    $command = @'
. /etc/os-release
echo "OS=${ID:-unknown} ${VERSION_ID:-unknown}"
echo "KERNEL=$(uname -r)"
if [ -f /var/run/reboot-required ]; then echo "REBOOT_REQUIRED=yes"; else echo "REBOOT_REQUIRED=no"; fi
'@

    $result = Invoke-Remote -IP $IP -Command $command -Quiet
    $info = @{}

    foreach ($line in ($result.Output -split "`n")) {
        if ($line -match '^(OS|KERNEL|REBOOT_REQUIRED)=(.*)$') {
            $info[$Matches[1]] = $Matches[2].Trim()
        }
    }

    foreach ($key in @('OS', 'KERNEL', 'REBOOT_REQUIRED')) {
        if (-not $info.ContainsKey($key)) {
            throw "Unable to read $key from $IP"
        }
    }

    return $info
}

# ============================================================
# Main
# ============================================================

$temp = $null

try {
    # ----------------------------------------------------
    # Step 2 (item 27): SSH to both nodes
    # ----------------------------------------------------

    $unreachable = @()

    foreach ($node in $Nodes) {
        if (-not (Test-Ssh -IP $node.IP)) {
            $unreachable += $node
        }
    }

    if ($unreachable.Count -gt 0) {
        foreach ($node in $unreachable) {
            Add-NodeResult -Node $node -Status 'UNREACHABLE' -Message 'SSH connection failed.'
        }

        Skip-RemainingNodes `
            -Remaining @($Nodes | Where-Object { $_.Name -notin @($unreachable | ForEach-Object { $_.Name }) }) `
            -Reason 'The pair is not processed: the other node is unreachable.'
    }
    elseif ($Check) {
        # Only the base checks exist so far; the checks of the SEG stages come with items 13-26.
        foreach ($node in $Nodes) {
            $info = Get-SegNodeBaseInfo -IP $node.IP
            Write-Log -Level 'INFO' -Message "Check: $($node.Name) ($($node.Role)) os=$($info['OS']) kernel=$($info['KERNEL']) reboot-required=$($info['REBOOT_REQUIRED'])"

            if ($info['OS'] -ne 'ubuntu 24.04') {
                Write-Log -Level 'WARN' -Message "$($node.Name): Ubuntu 24.04 is required; found '$($info['OS'])'."
            }

            if ($info['REBOOT_REQUIRED'] -eq 'yes') {
                Write-Log -Level 'WARN' -Message "$($node.Name): a reboot is pending (applied by the next synchronization after confirmation)."
            }

            Add-NodeResult -Node $node -Status 'INCOMPLETE' -Message 'SSH works; the checks of the SEG configuration are not implemented yet (roadmap items 13-26).'
        }
    }
    else {
        # ----------------------------------------------------
        # Step 3 (item 27): upgrade (upgrade.sh is idempotent)
        # ----------------------------------------------------

        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('seg-sync-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temp | Out-Null
        Write-Log -Level 'INFO' -Message "Temporary directory created: $temp"

        $upgradeCopy = New-LinuxCopy -Source $UpgradeFile -TempDirectory $temp

        for ($i = 0; $i -lt $Nodes.Count; $i++) {
            $node = $Nodes[$i]

            try {
                Copy-ToServer -IP $node.IP -Files @($upgradeCopy)

                if (-not (Invoke-UpgradeStage -IP $node.IP)) {
                    Add-NodeResult -Node $node -Status 'PENDING' -Message 'Upgrade stopped by user (reboot declined).'
                    Skip-RemainingNodes -Remaining @($Nodes | Select-Object -Skip ($i + 1)) -Reason 'Not processed: the upgrade of the previous node was not completed.'
                    break
                }

                Add-NodeResult -Node $node -Status 'PENDING' -Message 'Upgrade completed; the SEG configuration stages are not implemented yet (roadmap items 13-20).'
            }
            catch {
                $description = Get-ErrorDescription -ErrorRecord $_
                Write-Log -Level 'ERROR' -Message "$($node.Name): $description"
                Add-NodeResult -Node $node -Status 'ERROR' -Message $description
                Skip-RemainingNodes -Remaining @($Nodes | Select-Object -Skip ($i + 1)) -Reason 'Not processed: the previous node failed.'
                break
            }
        }
    }
}
finally {
    if ($temp -and (Test-Path -LiteralPath $temp)) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log -Level 'INFO' -Message 'Temporary files removed.'
    }
}

# ============================================================
# Summary
# ============================================================

Write-Log -Level 'INFO' -Message 'Final SEG summary:'

foreach ($result in $Results) {
    $level = if ($result.Status -eq 'OK') { 'OK' }
    elseif ($result.Status -in @('ERROR', 'UNREACHABLE')) { 'ERROR' }
    else { 'WARN' }

    Write-Log -Level $level -Message "$($result.Name) ($($result.Role)) $($result.Endpoint) $($result.Status) - $($result.Message)"
}

$failed = @($Results | Where-Object { $_.Status -in @('ERROR', 'UNREACHABLE') })

if ($failed.Count -gt 0) {
    Write-Log -Level 'DONE' -Message "Completed with errors: $($failed.Count) node(s) failed. Log: $($script:LogFile)"
    exit 1
}

if ($Check) {
    $open = @($Results | Where-Object { $_.Status -ne 'OK' })

    if ($open.Count -gt 0) {
        Write-Log -Level 'DONE' -Message "Check completed: the SEG pair is not confirmed as current ($($open.Count) node(s)). Nothing was changed. Log: $($script:LogFile)"
        exit 2
    }

    Write-Log -Level 'DONE' -Message "Check completed: the SEG pair is current. Nothing was changed. Log: $($script:LogFile)"
    exit 0
}

$pending = @($Results | Where-Object { $_.Status -in @('PENDING', 'SKIPPED') })

if ($pending.Count -gt 0) {
    Write-Log -Level 'DONE' -Message "Completed without technical errors; $($pending.Count) node(s) pending/skipped. Log: $($script:LogFile)"
    exit 0
}

Write-Log -Level 'DONE' -Message "SEG pair synchronized successfully. Log: $($script:LogFile)"
exit 0
