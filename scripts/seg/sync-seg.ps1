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
$CheckNodeFile = Join-Path $Root 'seg\check-node.sh'
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

$requiredFiles = @($ServersFile, $SegEnvFile, $SegListFile, $UpgradeFile, $BootstrapFile, $SecureFile, $ApplyFile, $CheckBackhaulFile, $CheckNodeFile, (Join-Path $Root 'seg\sing-box.sha256')) +
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

# Local client profiles against the current seg-list.json and connection parameters (read-only, never rewritten here).
$ProfileProblems = 0

foreach ($client in $SegClients) {
    $status = Get-SegProfileStatus -Root $Root -Client $client -SegList $SegList -Env $SegEnv -Gateway $Gateway

    switch ($status.State) {
        'CURRENT' { Write-Log -Level 'OK' -Message "Client profile $($client.Name): current (seg-list version $($SegList.Version))." }
        'DISABLED' { Write-Log -Level 'INFO' -Message "Client profile $($client.Name): the client is disabled." }
        default {
            $ProfileProblems++
            Write-Log -Level 'WARN' -Message "Client profile $($client.Name): $($status.State) - $($status.Reasons -join '; '). Recreate it with make-client-config.ps1 -Mode SEG."
        }
    }
}

foreach ($orphan in @(Get-SegProfileOrphans -Root $Root -Clients $SegClients)) {
    $ProfileProblems++
    Write-Log -Level 'WARN' -Message "Generated profile $orphan has no client record in clients\seg: delete the files or recreate the client."
}

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
            elseif ($env:SEG_TEST_FAIL_AFTER_STAGE -eq $Title) {
                # Test hook for the rollback checks (item 28): fails the stage after it was applied on the node.
                throw "SEG_TEST_FAIL_AFTER_STAGE: the stage '$Title' is made to fail on $($node.Name) after it was applied."
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

function New-SegCandidates {
    # Step 6 (item 27): renders the candidate configurations of both nodes into the directory, before any node
    # is changed (a template error stops the run early). Sets the script variables used by the stages and
    # by -Check (the hashes of the candidates are compared with the installed files).
    param(
        [Parameter(Mandatory = $true)]
        [string]$TempDirectory
    )

    $values = @{}

    foreach ($key in $SegEnv.Keys) {
        $values[$key] = $SegEnv[$key]
    }

    $values['VPS1_PUBLIC_IP'] = $Exit.IP
    $values['VPS2_PUBLIC_IP'] = $Gateway.IP
    $values['SEG_VLESS_PORT'] = [string]$Gateway.Port

    $destination = [string]$SegEnv['SEG_REALITY_DEST']
    $values['SEG_REALITY_DEST_HOST'] = $destination.Substring(0, $destination.LastIndexOf(':'))
    $values['SEG_REALITY_DEST_PORT'] = $destination.Substring($destination.LastIndexOf(':') + 1)

    $values['SEG_VLESS_USERS_JSON'] = ConvertTo-SegVlessUsersJson -Clients $SegClients -Flow $SegEnv['SEG_REALITY_FLOW']
    $values['SEG_POLICY_RULES_JSON'] = Get-SegPolicyRulesJson -Policy $SegEnv['SEG_UNMATCHED_POLICY']

    $fragments = Get-SegRuleSetFragments -SegList $SegList

    foreach ($key in $fragments.Keys) {
        $values[$key] = $fragments[$key]
    }

    $script:templateValues = $values
    $script:backhaulInterface = $SegEnv['SEG_BACKHAUL_INTERFACE']
    $script:backhaulMtu = $SegEnv['SEG_BACKHAUL_MTU']

    $script:failClosedFiles = @(
        New-RenderedFile -TemplatePath (Join-Path $TemplatesDir 'seg-failclosed.nft.template') -Values $values -Directory $TempDirectory
        New-RenderedFile -TemplatePath (Join-Path $TemplatesDir 'seg-failclosed.service.template') -Values $values -Directory $TempDirectory
    )

    # The staged name is <interface>.conf: apply-seg.sh backhaul reads it by the interface name.
    $script:backhaulGatewayFile = New-RenderedFile `
        -TemplatePath (Join-Path $TemplatesDir 'awg-backhaul-vps2.conf.template') `
        -Values $values `
        -Directory $TempDirectory `
        -Name "$($script:backhaulInterface).conf"

    # The exit candidates go to their own directory: the backhaul candidate has the same file name.
    $exitDir = Join-Path $TempDirectory 'exit'
    New-Item -ItemType Directory -Path $exitDir | Out-Null

    $script:backhaulExitFile = New-RenderedFile `
        -TemplatePath (Join-Path $TemplatesDir 'awg-backhaul-vps1.conf.template') `
        -Values $values `
        -Directory $exitDir `
        -Name "$($script:backhaulInterface).conf"

    $script:egressFiles = @(
        foreach ($template in @('seg-exit.nft', 'seg-exit-fw.service', 'seg-exit-keepalive.service', 'unbound-seg.conf')) {
            New-RenderedFile -TemplatePath (Join-Path $TemplatesDir "$template.template") -Values $values -Directory $exitDir
        }
    )

    # The server configuration must be valid JSON before it leaves the laptop; sing-box check itself runs
    # on the gateway with the Linux binary (the Windows build rejects routing_mark).
    $script:singBoxConfigFile = New-RenderedFile `
        -TemplatePath (Join-Path $TemplatesDir 'sing-box-vps2.json.template') `
        -Values $values `
        -Directory $TempDirectory `
        -Name 'sing-box-config.json'

    try {
        [void]([System.IO.File]::ReadAllText($script:singBoxConfigFile) | ConvertFrom-Json)
    }
    catch {
        throw "The rendered sing-box configuration is not valid JSON: $($_.Exception.Message)"
    }

    $script:singBoxFiles = @(
        $script:singBoxConfigFile
        New-RenderedFile -TemplatePath (Join-Path $TemplatesDir 'sing-box.service.template') -Values $values -Directory $TempDirectory
    )
}

function Get-FileSha256Lf {
    # SHA-256 of a rendered candidate (they are written with LF line endings).
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertFrom-CheckOutput {
    # Parses the "CHECK NAME=value" and "CHECK FILE path=sha256" lines of check-node.sh and check-backhaul.sh.
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $values = @{}
    $files = @{}

    foreach ($line in ($Text -split "`n")) {
        $line = $line.TrimEnd("`r")

        if ($line -match '^CHECK FILE (\S+)=(\S+)$') {
            $files[$Matches[1]] = $Matches[2]
        }
        elseif ($line -match '^CHECK ([A-Z0-9_]+)=(.*)$') {
            $values[$Matches[1]] = $Matches[2].Trim()
        }
    }

    return [pscustomobject]@{ Values = $values; Files = $files }
}

function Get-SegNodeCheck {
    # Read-only state of one node (check-node.sh through ssh, nothing is uploaded) against the candidates.
    # State: READY, CHANGES (installed files differ from the local source of truth), DEGRADED (something that
    # should work does not), NEW (nothing installed). Security is reported separately.
    param(
        [Parameter(Mandatory = $true)]
        [object]$Node,

        [Parameter(Mandatory = $true)]
        [hashtable]$Expected
    )

    if ($Node.Role -eq 'seg-gateway') {
        $arguments = @('seg-gateway', [string]$Node.Port, [string]$SegEnv['SEG_BACKHAUL_PORT'], [string]$Exit.IP, [string]$SegEnv['SEG_BACKHAUL_INTERFACE'], $SingBoxVersion)
    }
    else {
        $arguments = @('seg-exit', [string]$SegEnv['SEG_BACKHAUL_INTERFACE'], [string]$SegEnv['SEG_BACKHAUL_VPS1'], [string]$SegEnv['SEG_BACKHAUL_VPS2'])
    }

    $remote = Invoke-RemoteScript -IP $Node.IP -ScriptPath $CheckNodeFile -Arguments $arguments -AllowFailure -Quiet

    if ($remote.Code -ne 0 -or $remote.Output -notmatch 'CHECK_NODE_DONE') {
        throw "check-node.sh failed on $($Node.Name) (exit code $($remote.Code)): $((($remote.Output -split "`n") | Select-Object -Last 2) -join ' ')"
    }

    $parsed = ConvertFrom-CheckOutput -Text $remote.Output
    $values = $parsed.Values

    foreach ($name in @('OS', 'KERNEL', 'REBOOT_REQUIRED', 'PACKAGES', 'SERVICES', 'SECURITY')) {
        if (-not $values.ContainsKey($name)) {
            throw "check-node.sh on $($Node.Name) did not report $name."
        }
    }

    Write-Log -Level 'INFO' -Message "Check: $($Node.Name) ($($Node.Role)) os=$($values['OS']) kernel=$($values['KERNEL']) reboot-required=$($values['REBOOT_REQUIRED'])"

    if ($values['OS'] -ne 'ubuntu 24.04') {
        Write-Log -Level 'WARN' -Message "$($Node.Name): Ubuntu 24.04 is required; found '$($values['OS'])'."
    }

    if ($values['REBOOT_REQUIRED'] -eq 'yes') {
        Write-Log -Level 'WARN' -Message "$($Node.Name): a reboot is pending (offered by the next synchronization, after confirmation)."
    }

    $problems = @()
    $changes = @()

    foreach ($path in $Expected.Keys) {
        $actual = if ($parsed.Files.ContainsKey($path)) { $parsed.Files[$path] } else { 'MISSING' }

        if ($actual -ne $Expected[$path]) {
            $changes += "$path $(if ($actual -eq 'MISSING') { 'is missing' } else { 'differs from the local source' })"
        }
    }

    $nothingInstalled = ($values['PACKAGES'] -ne 'OK') -and (@($parsed.Files.Values | Where-Object { $_ -ne 'MISSING' }).Count -eq 0)

    if ($values['PACKAGES'] -ne 'OK') { $problems += "packages: $($values['PACKAGES'])" }
    if ($values['SERVICES'] -ne 'OK') { $problems += "services: $($values['SERVICES'])" }

    foreach ($name in @('FAIL_CLOSED', 'EXIT_FIREWALL', 'BACKHAUL_IF')) {
        if ($values.ContainsKey($name) -and $values[$name] -notin @('OK', 'UP')) { $problems += "$($name.ToLowerInvariant()): $($values[$name])" }
    }

    if ($values.ContainsKey('HANDSHAKE_EXIT') -and $values['HANDSHAKE_EXIT'] -notlike 'FRESH*') { $problems += "handshake (exit side): $($values['HANDSHAKE_EXIT'])" }

    $state = if ($nothingInstalled) { 'NEW' } elseif ($problems.Count -gt 0) { 'DEGRADED' } elseif ($changes.Count -gt 0) { 'CHANGES' } else { 'READY' }

    return [pscustomobject]@{
        Node     = $Node
        State    = $state
        Problems = $problems
        Changes  = $changes
        Security = $values['SECURITY']
        Values   = $values
        Files    = $parsed.Files
    }
}

function Get-SegBackhaulState {
    # Read-only checks of the backhaul seen from the gateway (check-backhaul.sh; it only sends DNS queries).
    param(
        [Parameter(Mandatory = $true)]
        [object]$Node,

        [Parameter(Mandatory = $true)]
        [bool]$HasSingBoxConfig
    )

    $arguments = @($backhaulInterface, [string]$SegEnv['SEG_BACKHAUL_VPS1'], [string]$SegEnv['SEG_BACKHAUL_VPS2'], [string]$Exit.IP, [string]$SegEnv['SEG_MARK'])

    if ($HasSingBoxConfig) {
        $arguments += '/etc/sing-box/config.json'
    }

    $remote = Invoke-RemoteScript -IP $Node.IP -ScriptPath $CheckBackhaulFile -Arguments $arguments -AllowFailure -Quiet

    return (ConvertFrom-CheckOutput -Text $remote.Output).Values
}

function Invoke-PairRollback {
    # Item 28: a stage failed after the first change of the run. Both nodes are restored to the snapshot taken
    # before the run (apply-seg.sh restore): the previous working configuration comes back, fail-closed is not
    # weakened, a node that had no sing-box keeps it stopped. The results of the nodes get the outcome.
    Write-Log -Level 'WARN' -Message 'A stage failed after the first change: restoring both nodes to the state before this run.'

    foreach ($node in $Nodes) {
        $restored = $false
        $problem = ''

        try {
            $result = Invoke-Remote -IP $node.IP -Command "chmod +x /root/apply-seg.sh`n/root/apply-seg.sh restore $($node.Role) $backhaulInterface" -AllowFailure

            if ($result.Code -eq 0 -and $result.Output -match 'APPLY_SEG_OK stage=restore') {
                $restored = $true
            }
            else {
                $problem = "apply-seg.sh restore failed (exit code $($result.Code))"
            }
        }
        catch {
            $problem = Get-ErrorDescription -ErrorRecord $_
        }

        foreach ($entry in @($Results | Where-Object { $_.Name -eq $node.Name })) {
            if ($restored) {
                Write-Log -Level 'OK' -Message "$($node.Name): restored to the state before this run."

                if ($entry.Status -eq 'SKIPPED') {
                    $entry.Status = 'ROLLED_BACK'
                    $entry.Message = "$($entry.Message) The node was restored to the state before this run."
                }
                else {
                    $entry.Message = "$($entry.Message) The node was restored to the state before this run."
                }
            }
            else {
                Write-Log -Level 'ERROR' -Message "$($node.Name): the rollback failed: $problem. The snapshot stays in /root/.seg-snapshot on the node; the node needs manual attention."
                $entry.Status = 'ERROR'
                $entry.Message = "$($entry.Message) ROLLBACK FAILED ($problem): the node needs manual attention, the snapshot stays in /root/.seg-snapshot."
            }
        }
    }
}

function Invoke-SnapshotDrop {
    # Best effort: the snapshot holds secrets and is not needed any more.
    foreach ($node in $Nodes) {
        try {
            Invoke-Remote -IP $node.IP -Command '/root/apply-seg.sh snapshot-drop' -AllowFailure -Quiet | Out-Null
        }
        catch {
            Write-Log -Level 'WARN' -Message "$($node.Name): the snapshot could not be removed: $(Get-ErrorDescription -ErrorRecord $_)"
        }
    }
}

function Get-ReportValue {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Table,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Table.ContainsKey($Name)) { return $Table[$Name] } else { return 'NOT_CHECKED' }
}

function Invoke-SegCheckReport {
    # The read-only check of the pair (item 26), used by -Check and as the final step of the apply order
    # (item 27, step 17). Needs the candidates rendered by New-SegCandidates. Logs the report and returns
    # one result per node (Node, Status OK or CHANGES, Message).
    $expectedGateway = @{
        '/etc/seg/seg-failclosed.nft'                    = (Get-FileSha256Lf $failClosedFiles[0])
        '/etc/systemd/system/seg-failclosed.service'     = (Get-FileSha256Lf $failClosedFiles[1])
        "/etc/amnezia/amneziawg/$backhaulInterface.conf" = (Get-FileSha256Lf $backhaulGatewayFile)
        '/etc/sing-box/config.json'                      = (Get-FileSha256Lf $singBoxFiles[0])
        '/etc/systemd/system/sing-box.service'           = (Get-FileSha256Lf $singBoxFiles[1])
    }

    $expectedExit = @{
        '/etc/seg/seg-exit.nft'                          = (Get-FileSha256Lf $egressFiles[0])
        '/etc/systemd/system/seg-exit-fw.service'        = (Get-FileSha256Lf $egressFiles[1])
        '/etc/systemd/system/seg-exit-keepalive.service' = (Get-FileSha256Lf $egressFiles[2])
        '/etc/unbound/unbound.conf.d/seg.conf'           = (Get-FileSha256Lf $egressFiles[3])
        "/etc/amnezia/amneziawg/$backhaulInterface.conf" = (Get-FileSha256Lf $backhaulExitFile)
    }

    $gatewayCheck = Get-SegNodeCheck -Node $Gateway -Expected $expectedGateway
    $exitCheck = Get-SegNodeCheck -Node $Exit -Expected $expectedExit

    $backhaul = @{}

    if ($gatewayCheck.State -ne 'NEW') {
        $hasConfig = $gatewayCheck.Files.ContainsKey('/etc/sing-box/config.json') -and $gatewayCheck.Files['/etc/sing-box/config.json'] -ne 'MISSING'
        $backhaul = Get-SegBackhaulState -Node $Gateway -HasSingBoxConfig $hasConfig
    }

    $backhaulUp = ((Get-ReportValue $backhaul 'INTERFACE') -eq 'UP') -and ((Get-ReportValue $backhaul 'BACKHAUL_ADDRESS') -eq 'OK') -and ((Get-ReportValue $exitCheck.Values 'BACKHAUL_IF') -eq 'UP')

    $report = [ordered]@{
        GATEWAY          = $gatewayCheck.State
        EXIT             = $exitCheck.State
        BACKHAUL         = $(if ($backhaulUp) { 'UP' } else { 'DOWN' })
        HANDSHAKE        = (Get-ReportValue $backhaul 'HANDSHAKE')
        SELECTED_ROUTING = (Get-ReportValue $backhaul 'SELECTED_ROUTING')
        BACKHAUL_DNS     = (Get-ReportValue $backhaul 'BACKHAUL_DNS')
        EGRESS_IP        = (Get-ReportValue $backhaul 'EGRESS_IP')
        FAIL_CLOSED      = (Get-ReportValue $gatewayCheck.Values 'FAIL_CLOSED')
        UNMATCHED_DIRECT = (Get-ReportValue $backhaul 'UNMATCHED_DIRECT')
        SEG_LIST_VERSION = [string]$SegList.Version
        SEG_LIST_HASH    = $SegList.Sha256
        SECURITY         = $(if ($gatewayCheck.Security -eq 'OK' -and $exitCheck.Security -eq 'OK') { 'OK' } else { "FAIL (gateway: $($gatewayCheck.Security); exit: $($exitCheck.Security))" })
    }

    # What a healthy pair looks like (roadmap, item 26); anything else is a problem of the pair.
    $pairProblems = @()

    if ($report['BACKHAUL'] -ne 'UP') { $pairProblems += 'the backhaul is down' }
    if ($report['HANDSHAKE'] -notlike 'FRESH*') { $pairProblems += "handshake: $($report['HANDSHAKE'])" }
    if ($report['SELECTED_ROUTING'] -ne 'OK') { $pairProblems += "selected routing: $($report['SELECTED_ROUTING'])" }
    if ($report['BACKHAUL_DNS'] -ne 'OK') { $pairProblems += "backhaul DNS: $($report['BACKHAUL_DNS'])" }
    if ($report['EGRESS_IP'] -ne [string]$Exit.IP) { $pairProblems += "external address through the backhaul is $($report['EGRESS_IP']), expected $($Exit.IP)" }

    Write-Log -Level 'INFO' -Message 'SEG check report:'

    foreach ($key in $report.Keys) {
        $value = [string]$report[$key]
        $level = if ($value -in @('READY', 'UP', 'OK') -or $value -like 'FRESH*' -or $key -in @('SEG_LIST_VERSION', 'SEG_LIST_HASH')) { 'OK' } elseif ($key -eq 'UNMATCHED_DIRECT') { 'INFO' } elseif ($key -eq 'EGRESS_IP' -and $value -eq [string]$Exit.IP) { 'OK' } else { 'WARN' }

        Write-Log -Level $level -Message "$key=$value"
    }

    if ($report['UNMATCHED_DIRECT'] -match '^\d+$' -and [int]$report['UNMATCHED_DIRECT'] -gt 0) {
        Write-Log -Level 'WARN' -Message "UNMATCHED_DIRECT=$($report['UNMATCHED_DIRECT']): clients send traffic outside seg-list to the gateway (an outdated profile, resources missing from seg-list, application DoH); a warning, not an error."
    }

    $nodeResults = @()

    foreach ($checked in @($gatewayCheck, $exitCheck)) {
        $parts = @()

        if ($checked.State -ne 'READY') { $parts += "state $($checked.State)" }
        $parts += $checked.Problems
        $parts += $checked.Changes

        if ($checked.Security -ne 'OK') { $parts += "security: $($checked.Security)" }

        if ($checked.Node.Role -eq 'seg-gateway') { $parts += $pairProblems }

        $nodeResults += [pscustomobject]@{
            Node    = $checked.Node
            Status  = $(if ($parts.Count -eq 0) { 'OK' } else { 'CHANGES' })
            Message = $(if ($parts.Count -eq 0) { 'Configuration and state are current.' } else { "Not current: $($parts -join '; ')." })
        }
    }

    return $nodeResults
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
        # Read-only: candidates are rendered locally only to compare their hashes with the installed files;
        # the node checks run through ssh without uploading anything.
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('seg-check-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temp | Out-Null
        New-SegCandidates -TempDirectory $temp

        foreach ($checkResult in @(Invoke-SegCheckReport)) {
            $message = if ($checkResult.Status -eq 'OK') { "$($checkResult.Message) (check only)" } else { $checkResult.Message }
            Add-NodeResult -Node $checkResult.Node -Status $checkResult.Status -Message $message
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

        New-SegCandidates -TempDirectory $temp

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
        # Snapshot (item 28): the configuration of both nodes before the first change of this run
        # ----------------------------------------------------

        $SnapshotTaken = $false

        if ($proceed) {
            $proceed = Invoke-PairStage -Title 'snapshot' -Action {
                param($node)

                Copy-ToServer -IP $node.IP -Files @($applyCopy)
                Invoke-Remote -IP $node.IP -Command 'install -d -o root -g root -m 700 /root/.seg-sync' -Quiet | Out-Null

                $result = Invoke-Remote -IP $node.IP -Command "chmod +x /root/apply-seg.sh`n/root/apply-seg.sh snapshot $($node.Role) $backhaulInterface"

                if ($result.Output -notmatch 'APPLY_SEG_OK stage=snapshot') {
                    throw "apply-seg.sh did not report APPLY_SEG_OK for the snapshot on $($node.Name)"
                }

                return $true
            }

            if ($proceed) {
                $SnapshotTaken = $true
            }
            else {
                # Nothing was changed yet; remove what has been taken on the other node.
                Invoke-SnapshotDrop
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

        # ----------------------------------------------------
        # Rollback (item 28): a stage after the snapshot failed
        # ----------------------------------------------------

        if (-not $proceed -and $SnapshotTaken) {
            Invoke-PairRollback
        }

        # ----------------------------------------------------
        # Step 17 (item 27): the final check of the pair (the same read-only check as -Check)
        # ----------------------------------------------------

        if ($proceed) {
            Write-Log -Level 'START' -Message 'Stage: final check'
            $finalOk = $false

            try {
                $finalResults = @(Invoke-SegCheckReport)
                $finalOk = (@($finalResults | Where-Object { $_.Status -ne 'OK' }).Count -eq 0)

                foreach ($finalResult in $finalResults) {
                    if ($finalResult.Status -eq 'OK') {
                        Add-NodeResult -Node $finalResult.Node -Status 'OK' -Message 'Configured; the final check passed.'
                    }
                    else {
                        Add-NodeResult -Node $finalResult.Node -Status 'ERROR' -Message "The final check found problems. $($finalResult.Message)"
                    }
                }
            }
            catch {
                $description = Get-ErrorDescription -ErrorRecord $_
                Write-Log -Level 'ERROR' -Message "The final check failed: $description"

                foreach ($node in $Nodes) {
                    Add-NodeResult -Node $node -Status 'ERROR' -Message "The final check could not be completed: $description"
                }
            }

            if ($finalOk) {
                Invoke-SnapshotDrop
            }
            else {
                # The configuration was applied but the pair is not healthy (the cause may be outside the
                # configuration, for example a service on the Internet): it is not rolled back automatically.
                Write-Log -Level 'WARN' -Message 'The snapshot of the state before this run stays in /root/.seg-snapshot on the nodes (restore: /root/apply-seg.sh restore <role> <interface>). It is replaced by the next run.'
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

    if ($open.Count -gt 0 -or $ProfileProblems -gt 0) {
        Write-Log -Level 'DONE' -Message "Check completed: the SEG pair is not confirmed as current ($($open.Count) node(s)); client profiles needing attention: $ProfileProblems. Nothing was changed. Log: $($script:LogFile)"
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
