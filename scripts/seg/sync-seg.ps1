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
$BootstrapFile = Join-Path $Root 'seg\bootstrap-seg.sh'
$SecureFile   = Join-Path $Root 'seg\secure-seg.sh'
$ApplyFile    = Join-Path $Root 'seg\apply-seg.sh'
$CheckBackhaulFile = Join-Path $Root 'seg\check-backhaul.sh'
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

$requiredFiles = @($ServersFile, $SegEnvFile, $SegListFile, $UpgradeFile, $BootstrapFile, $SecureFile, $ApplyFile, $CheckBackhaulFile, (Join-Path $Root 'seg\sing-box.sha256')) +
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

$SingBoxVersion = $script:SegSingBoxVersion
$SingBoxPackage = Get-VerifiedSingBoxLinuxPackage -Root $Root -Version $SingBoxVersion
$SingBoxPackageSha256 = (Read-HashFile -Path (Join-Path $Root 'seg\sing-box.sha256'))[(Split-Path -Leaf $SingBoxPackage)]
Write-Log -Level 'OK' -Message "sing-box $SingBoxVersion Linux package verified: $(Split-Path -Leaf $SingBoxPackage)"

$SegClients = @(Read-SegClients -Root $Root)
$EnabledClients = @($SegClients | Where-Object { $_.Enabled })
Write-Log -Level 'OK' -Message "SEG clients: $($SegClients.Count) ($($EnabledClients.Count) enabled)."

if ($EnabledClients.Count -eq 0) {
    Write-Log -Level 'WARN' -Message 'There are no enabled SEG clients: sing-box starts, but nobody can connect.'
}

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

function Invoke-PairStage {
    # Runs one stage on the nodes (gateway first; -Role limits it to one role). Action receives the node and
    # returns $false when the user declined to continue. The first failure or refusal stops the run: the
    # nodes get results and the function returns $false.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $false)]
        [string]$Role
    )

    Write-Log -Level 'START' -Message "Stage: $Title"

    foreach ($node in @($Nodes | Where-Object { -not $Role -or $_.Role -eq $Role })) {
        $failure = $null
        $stopped = $false

        try {
            if (-not (& $Action $node)) {
                $stopped = $true
                $failure = [PSCustomObject]@{ Status = 'PENDING'; Message = "$Title stopped by user." }
            }
        }
        catch {
            $description = Get-ErrorDescription -ErrorRecord $_
            Write-Log -Level 'ERROR' -Message "$($node.Name): $description"
            $stopped = $true
            $failure = [PSCustomObject]@{ Status = 'ERROR'; Message = $description }
        }

        if ($stopped) {
            Add-NodeResult -Node $node -Status $failure.Status -Message $failure.Message

            foreach ($other in @($Nodes | Where-Object { $_.Name -ne $node.Name })) {
                Add-NodeResult -Node $other -Status 'SKIPPED' -Message "The run stopped at stage '$Title' ($($node.Name))."
            }

            return $false
        }
    }

    Write-Log -Level 'OK' -Message "Stage completed: $Title"
    return $true
}

function Invoke-BackhaulCheck {
    # Runs check-backhaul.sh on the gateway; throws when any check fails (sing-box is then not started or
    # not considered healthy). With SingBoxConfig the selected outbound of that configuration is checked too.
    param(
        [Parameter(Mandatory = $true)]
        [object]$Node,

        [Parameter(Mandatory = $false)]
        [string]$SingBoxConfig
    )

    Copy-ToServer -IP $Node.IP -Files @($checkCopy)

    $arguments = "$backhaulInterface $($SegEnv['SEG_BACKHAUL_VPS1']) $($SegEnv['SEG_BACKHAUL_VPS2']) $($Exit.IP) $($SegEnv['SEG_MARK'])"

    if ($SingBoxConfig) {
        $arguments += " $SingBoxConfig"
    }

    $result = Invoke-Remote -IP $Node.IP -Command "chmod +x /root/check-backhaul.sh`n/root/check-backhaul.sh $arguments" -AllowFailure

    if ($result.Code -ne 0 -or $result.Output -notmatch 'BACKHAUL_CHECK_OK') {
        throw "The backhaul check failed on $($Node.Name). See the log for the failed checks."
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

        $upgradeCopy   = New-LinuxCopy -Source $UpgradeFile -TempDirectory $temp
        $bootstrapCopy = New-LinuxCopy -Source $BootstrapFile -TempDirectory $temp
        $secureCopy    = New-LinuxCopy -Source $SecureFile -TempDirectory $temp
        $applyCopy     = New-LinuxCopy -Source $ApplyFile -TempDirectory $temp
        $checkCopy     = New-LinuxCopy -Source $CheckBackhaulFile -TempDirectory $temp

        # Step 6 (item 27): candidate configurations are rendered before any node is changed,
        # so a template error stops the run early.
        $templateValues = @{}

        foreach ($key in $SegEnv.Keys) {
            $templateValues[$key] = $SegEnv[$key]
        }

        $templateValues['VPS1_PUBLIC_IP'] = $Exit.IP
        $templateValues['VPS2_PUBLIC_IP'] = $Gateway.IP
        $templateValues['SEG_VLESS_PORT'] = [string]$Gateway.Port

        $destination = [string]$SegEnv['SEG_REALITY_DEST']
        $templateValues['SEG_REALITY_DEST_HOST'] = $destination.Substring(0, $destination.LastIndexOf(':'))
        $templateValues['SEG_REALITY_DEST_PORT'] = $destination.Substring($destination.LastIndexOf(':') + 1)

        $templateValues['SEG_VLESS_USERS_JSON'] = ConvertTo-SegVlessUsersJson -Clients $SegClients -Flow $SegEnv['SEG_REALITY_FLOW']
        $templateValues['SEG_POLICY_RULES_JSON'] = Get-SegPolicyRulesJson -Policy $SegEnv['SEG_UNMATCHED_POLICY']

        $fragments = Get-SegRuleSetFragments -SegList $SegList

        foreach ($key in $fragments.Keys) {
            $templateValues[$key] = $fragments[$key]
        }

        $failClosedFiles = @(
            New-RenderedFile -TemplatePath (Join-Path $TemplatesDir 'seg-failclosed.nft.template') -Values $templateValues -Directory $temp
            New-RenderedFile -TemplatePath (Join-Path $TemplatesDir 'seg-failclosed.service.template') -Values $templateValues -Directory $temp
        )

        $backhaulInterface = $SegEnv['SEG_BACKHAUL_INTERFACE']
        $backhaulMtu       = $SegEnv['SEG_BACKHAUL_MTU']

        # The staged name is <interface>.conf: apply-seg.sh backhaul reads it by the interface name.
        $backhaulGatewayFile = New-RenderedFile `
            -TemplatePath (Join-Path $TemplatesDir 'awg-backhaul-vps2.conf.template') `
            -Values $templateValues `
            -Directory $temp `
            -Name "$backhaulInterface.conf"

        # The exit candidates go to their own directory: the backhaul candidate has the same file name.
        $exitDir = Join-Path $temp 'exit'
        New-Item -ItemType Directory -Path $exitDir | Out-Null

        $backhaulExitFile = New-RenderedFile `
            -TemplatePath (Join-Path $TemplatesDir 'awg-backhaul-vps1.conf.template') `
            -Values $templateValues `
            -Directory $exitDir `
            -Name "$backhaulInterface.conf"

        $egressFiles = @(
            foreach ($template in @('seg-exit.nft', 'seg-exit-fw.service', 'seg-exit-keepalive.service', 'unbound-seg.conf')) {
                New-RenderedFile -TemplatePath (Join-Path $TemplatesDir "$template.template") -Values $templateValues -Directory $exitDir
            }
        )

        # The server configuration must be valid JSON before it leaves the laptop; sing-box check itself runs
        # on the gateway with the Linux binary (the Windows build rejects routing_mark).
        $singBoxConfigFile = New-RenderedFile `
            -TemplatePath (Join-Path $TemplatesDir 'sing-box-vps2.json.template') `
            -Values $templateValues `
            -Directory $temp `
            -Name 'sing-box-config.json'

        try {
            [void]([System.IO.File]::ReadAllText($singBoxConfigFile) | ConvertFrom-Json)
        }
        catch {
            throw "The rendered sing-box configuration is not valid JSON: $($_.Exception.Message)"
        }

        $singBoxFiles = @(
            $singBoxConfigFile
            New-RenderedFile -TemplatePath (Join-Path $TemplatesDir 'sing-box.service.template') -Values $templateValues -Directory $temp
        )

        $proceed = Invoke-PairStage -Title 'upgrade' -Action {
            param($node)

            Copy-ToServer -IP $node.IP -Files @($upgradeCopy)
            return (Invoke-UpgradeStage -IP $node.IP)
        }

        # ----------------------------------------------------
        # Packages and role preparation (bootstrap-seg.sh)
        # ----------------------------------------------------

        if ($proceed) {
            $proceed = Invoke-PairStage -Title 'bootstrap' -Action {
                param($node)

                Copy-ToServer -IP $node.IP -Files @($bootstrapCopy)
                Invoke-Remote -IP $node.IP -Command 'install -d -o root -g root -m 700 /root/.seg-sync' -Quiet | Out-Null

                if ($node.Role -eq 'seg-gateway') {
                    Copy-ToServer -IP $node.IP -Files @($SingBoxPackage) -Destination '/root/.seg-sync/'

                    $arguments = "seg-gateway $SingBoxVersion $SingBoxPackageSha256"
                }
                else {
                    $arguments = 'seg-exit'
                }

                $result = Invoke-Remote -IP $node.IP -Command "chmod +x /root/bootstrap-seg.sh`n/root/bootstrap-seg.sh $arguments"

                if ($result.Output -notmatch "BOOTSTRAP_SEG_OK role=$($node.Role)") {
                    throw "bootstrap-seg.sh did not report BOOTSTRAP_SEG_OK on $($node.Name)"
                }

                return $true
            }
        }

        # ----------------------------------------------------
        # Step 4 (item 27): hardening (secure-seg.sh)
        # ----------------------------------------------------

        if ($proceed) {
            $proceed = Invoke-PairStage -Title 'hardening' -Action {
                param($node)

                Copy-ToServer -IP $node.IP -Files @($secureCopy)

                if ($node.Role -eq 'seg-gateway') {
                    $arguments = "seg-gateway $($Gateway.Port) $($SegEnv['SEG_BACKHAUL_PORT']) $($Exit.IP) $($SegEnv['SEG_BACKHAUL_INTERFACE'])"
                }
                else {
                    $arguments = "seg-exit $($SegEnv['SEG_BACKHAUL_INTERFACE']) $($SegEnv['SEG_BACKHAUL_VPS1']) $($SegEnv['SEG_BACKHAUL_VPS2'])"
                }

                $result = Invoke-Remote -IP $node.IP -Command "chmod +x /root/secure-seg.sh`n/root/secure-seg.sh $arguments"

                if ($result.Output -notmatch "SECURE_SEG_OK role=$($node.Role)") {
                    throw "secure-seg.sh did not report SECURE_SEG_OK on $($node.Name)"
                }

                return $true
            }
        }

        # ----------------------------------------------------
        # Step 7 (item 27): fail-closed on the gateway (apply-seg.sh failclosed)
        # ----------------------------------------------------

        if ($proceed) {
            $proceed = Invoke-PairStage -Title 'fail-closed' -Role 'seg-gateway' -Action {
                param($node)

                Copy-ToServer -IP $node.IP -Files @($applyCopy)
                Invoke-Remote -IP $node.IP -Command 'install -d -o root -g root -m 700 /root/.seg-sync' -Quiet | Out-Null
                Copy-ToServer -IP $node.IP -Files $failClosedFiles -Destination '/root/.seg-sync/'

                $result = Invoke-Remote -IP $node.IP -Command "chmod +x /root/apply-seg.sh`n/root/apply-seg.sh failclosed"

                if ($result.Output -notmatch 'APPLY_SEG_OK stage=failclosed') {
                    throw "apply-seg.sh did not report APPLY_SEG_OK for fail-closed on $($node.Name)"
                }

                return $true
            }
        }

        # ----------------------------------------------------
        # Step 8 (item 27): routing of selected traffic on the gateway (apply-seg.sh routing)
        # ----------------------------------------------------

        if ($proceed) {
            $proceed = Invoke-PairStage -Title 'routing' -Role 'seg-gateway' -Action {
                param($node)

                $arguments = "routing $($SegEnv['SEG_BACKHAUL_INTERFACE']) $($SegEnv['SEG_BACKHAUL_MTU'])"
                $result = Invoke-Remote -IP $node.IP -Command "chmod +x /root/apply-seg.sh`n/root/apply-seg.sh $arguments"

                if ($result.Output -notmatch 'APPLY_SEG_OK stage=routing') {
                    throw "apply-seg.sh did not report APPLY_SEG_OK for routing on $($node.Name)"
                }

                return $true
            }
        }

        # ----------------------------------------------------
        # Step 9 (item 27): awg-backhaul on the gateway (apply-seg.sh backhaul)
        # ----------------------------------------------------

        if ($proceed) {
            $proceed = Invoke-PairStage -Title 'backhaul-gateway' -Role 'seg-gateway' -Action {
                param($node)

                Copy-ToServer -IP $node.IP -Files @($backhaulGatewayFile) -Destination '/root/.seg-sync/'

                $result = Invoke-Remote -IP $node.IP -Command "chmod +x /root/apply-seg.sh`n/root/apply-seg.sh backhaul $backhaulInterface $backhaulMtu"

                if ($result.Output -notmatch 'APPLY_SEG_OK stage=backhaul') {
                    throw "apply-seg.sh did not report APPLY_SEG_OK for backhaul on $($node.Name)"
                }

                return $true
            }
        }

        # ----------------------------------------------------
        # Step 10 (item 27): firewall, NAT, DNS and backhaul on the exit
        # ----------------------------------------------------

        if ($proceed) {
            $proceed = Invoke-PairStage -Title 'egress-exit' -Role 'seg-exit' -Action {
                param($node)

                Copy-ToServer -IP $node.IP -Files @($applyCopy)
                Invoke-Remote -IP $node.IP -Command 'install -d -o root -g root -m 700 /root/.seg-sync' -Quiet | Out-Null
                Copy-ToServer -IP $node.IP -Files $egressFiles -Destination '/root/.seg-sync/'

                $arguments = "egress $backhaulInterface $($SegEnv['SEG_BACKHAUL_VPS1']) $($SegEnv['SEG_BACKHAUL_VPS2'])"
                $result = Invoke-Remote -IP $node.IP -Command "chmod +x /root/apply-seg.sh`n/root/apply-seg.sh $arguments"

                if ($result.Output -notmatch 'APPLY_SEG_OK stage=egress') {
                    throw "apply-seg.sh did not report APPLY_SEG_OK for egress on $($node.Name)"
                }

                return $true
            }
        }

        if ($proceed) {
            $proceed = Invoke-PairStage -Title 'backhaul-exit' -Role 'seg-exit' -Action {
                param($node)

                Copy-ToServer -IP $node.IP -Files @($backhaulExitFile) -Destination '/root/.seg-sync/'

                $result = Invoke-Remote -IP $node.IP -Command "chmod +x /root/apply-seg.sh`n/root/apply-seg.sh backhaul $backhaulInterface $backhaulMtu"

                if ($result.Output -notmatch 'APPLY_SEG_OK stage=backhaul') {
                    throw "apply-seg.sh did not report APPLY_SEG_OK for backhaul on $($node.Name)"
                }

                return $true
            }
        }

        # ----------------------------------------------------
        # Steps 11-13 (item 27): backhaul checks before sing-box (check-backhaul.sh)
        # ----------------------------------------------------

        if ($proceed) {
            $proceed = Invoke-PairStage -Title 'backhaul-check' -Role 'seg-gateway' -Action {
                param($node)

                Invoke-BackhaulCheck -Node $node
                return $true
            }
        }

        # ----------------------------------------------------
        # Steps 14-16 (item 27): sing-box with VLESS/REALITY and server-side routing (apply-seg.sh singbox)
        # ----------------------------------------------------

        if ($proceed) {
            $proceed = Invoke-PairStage -Title 'sing-box' -Role 'seg-gateway' -Action {
                param($node)

                Copy-ToServer -IP $node.IP -Files $singBoxFiles -Destination '/root/.seg-sync/'

                $arguments = "singbox $($Gateway.Port) $($SegEnv['SEG_REALITY_SERVER_NAME'])"
                $result = Invoke-Remote -IP $node.IP -Command "chmod +x /root/apply-seg.sh`n/root/apply-seg.sh $arguments"

                if ($result.Output -notmatch 'APPLY_SEG_OK stage=singbox') {
                    throw "apply-seg.sh did not report APPLY_SEG_OK for sing-box on $($node.Name)"
                }

                return $true
            }
        }

        # The installed configuration is checked once more: the selected outbound must be bound to the backhaul.
        if ($proceed) {
            $proceed = Invoke-PairStage -Title 'sing-box-check' -Role 'seg-gateway' -Action {
                param($node)

                Invoke-BackhaulCheck -Node $node -SingBoxConfig '/etc/sing-box/config.json'
                return $true
            }
        }

        if ($proceed) {
            foreach ($node in $Nodes) {
                Add-NodeResult -Node $node -Status 'PENDING' -Message 'All node stages completed (up to sing-box); the final -Check and the client commands are not implemented yet (roadmap items 21-26).'
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
