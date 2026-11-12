# Rollback checks of sync-servers.ps1 -Mode SEG (roadmap item 28). One scenario per run:
#   -Scenario KeyRotationExit   a new seg.env is applied, the stage backhaul-exit fails after it was applied
#   -Scenario KeyRotationSingBox a new seg.env is applied, the stage sing-box fails after it was applied
#   -Scenario FirstSingBox      the gateway has no sing-box, the stage sing-box fails after it was applied
# The failure is made by the test hook SEG_TEST_FAIL_AFTER_STAGE. After the rollback every managed file of both
# nodes must be identical to the state before the run (SHA-256), and the pair must still work.
# Restores the local and remote state at the end.
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('KeyRotationExit', 'KeyRotationSingBox', 'FirstSingBox')]
    [string]$Scenario
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $Root

. (Join-Path $Root 'scripts\lib\common.ps1')
. (Join-Path $Root 'scripts\lib\servers.ps1')
. (Join-Path $Root 'scripts\lib\segenv.ps1')

Initialize-Logging -Root $Root -ScriptName 'test-rollback.ps1'

$env_ = Read-SegEnvFile -Path (Join-Path $Root 'config\seg.env')
$servers = (Read-ServersFile -Path (Join-Path $Root 'servers.txt')).Servers
$gateway = @($servers | Where-Object { $_.Role -eq 'seg-gateway' -and $_.IsEnabled })[0]
$exit = @($servers | Where-Object { $_.Role -eq 'seg-exit' -and $_.IsEnabled })[0]
$iface = $env_['SEG_BACKHAUL_INTERFACE']

$script:pass = 0
$script:fail = 0

function Check([string]$Name, [bool]$Condition) {
    if ($Condition) { $script:pass++; "PASS  $Name" } else { $script:fail++; "FAIL  $Name" }
}

function Get-NodeState([object]$Node) {
    if ($Node.Role -eq 'seg-gateway') {
        $arguments = @('seg-gateway', [string]$Node.Port, $env_['SEG_BACKHAUL_PORT'], [string]$exit.IP, $iface, '1.14.4')
    }
    else {
        $arguments = @('seg-exit', $iface, $env_['SEG_BACKHAUL_VPS1'], $env_['SEG_BACKHAUL_VPS2'])
    }

    $output = (Invoke-RemoteScript -IP $Node.IP -ScriptPath (Join-Path $Root 'seg\check-node.sh') -Arguments $arguments -AllowFailure -Quiet).Output
    $files = @{}
    $values = @{}

    foreach ($line in ($output -split "`n")) {
        if ($line -match '^CHECK FILE (\S+)=(\S+)') { $files[$Matches[1]] = $Matches[2] }
        elseif ($line -match '^CHECK ([A-Z0-9_]+)=(.*)$') { $values[$Matches[1]] = $Matches[2].Trim() }
    }

    return [pscustomobject]@{ Files = $files; Values = $values }
}

function Compare-State($Before, $After) {
    $differences = @()

    foreach ($path in $Before.Files.Keys) {
        if (-not $After.Files.ContainsKey($path) -or $After.Files[$path] -ne $Before.Files[$path]) {
            $differences += $path
        }
    }

    return $differences
}

function Invoke-Sync {
    $log = Join-Path $env:TEMP ('seg-rollback-sync-' + [guid]::NewGuid().ToString('N') + '.log')
    'n' | & powershell -NoProfile -ExecutionPolicy Bypass -File scripts\sync-servers.ps1 -Mode SEG all *> $log
    $code = $LASTEXITCODE
    return [pscustomobject]@{ Code = $code; Log = $log; Text = (Get-Content -LiteralPath $log -Raw) }
}

function Invoke-Node([string]$Ip, [string]$Command) {
    # ssh writes diagnostics to stderr: not a failure of the test
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        return (& ssh -o BatchMode=yes "root@$Ip" $Command 2>&1 | ForEach-Object { [string]$_ })
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

$failedStage = if ($Scenario -eq 'KeyRotationExit') { 'backhaul-exit' } else { 'sing-box' }
$rotated = $Scenario -ne 'FirstSingBox'

# The state before the run, taken from the nodes
$beforeGateway = Get-NodeState $gateway
$beforeExit = Get-NodeState $exit
Check 'the nodes are healthy before the scenario' ($beforeGateway.Values['SERVICES'] -eq 'OK' -and $beforeExit.Values['SERVICES'] -eq 'OK')

try {
    if ($rotated) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File scripts\generate-server-env.ps1 -Mode SEG -Force *> $null
        Check 'a new seg.env was generated' ($LASTEXITCODE -eq 0)
    }
    else {
        # The gateway has no sing-box: it is stopped, disabled and its files are moved aside
        Invoke-Node $gateway.IP 'mkdir -p /root/aside; systemctl disable --now sing-box; mv /etc/sing-box/config.json /root/aside/; mv /etc/systemd/system/sing-box.service /root/aside/; systemctl daemon-reload' | Out-Null
        Check 'the gateway has no sing-box before the run' ((Invoke-Node $gateway.IP 'test ! -e /etc/sing-box/config.json && test ! -e /etc/systemd/system/sing-box.service && echo ok') -match 'ok')
        $beforeGateway = Get-NodeState $gateway
    }

    $env:SEG_TEST_FAIL_AFTER_STAGE = $failedStage
    $run = Invoke-Sync
    Remove-Item Env:SEG_TEST_FAIL_AFTER_STAGE -ErrorAction SilentlyContinue

    Check "the run fails (exit code 1) after the stage $failedStage was applied" ($run.Code -eq 1)
    Check 'the failure comes from the test hook' ($run.Text -match 'SEG_TEST_FAIL_AFTER_STAGE')
    Check 'a snapshot was taken before the first change' ($run.Text -match 'Snapshot of \d+ file')
    Check 'the rollback was started' ($run.Text -match 'restoring both nodes to the state before this run')
    Check 'both nodes report the restore' (([regex]::Matches($run.Text, 'The node is restored to the state before the run')).Count -eq 2)
    Check 'no rollback failure is reported' ($run.Text -notmatch 'ROLLBACK FAILED|the rollback failed')

    $afterGateway = Get-NodeState $gateway
    $afterExit = Get-NodeState $exit
    $diffGateway = @(Compare-State $beforeGateway $afterGateway)
    $diffExit = @(Compare-State $beforeExit $afterExit)

    Check 'every managed file of the gateway is identical to the state before the run' ($diffGateway.Count -eq 0)
    Check 'every managed file of the exit is identical to the state before the run' ($diffExit.Count -eq 0)

    if ($diffGateway.Count -gt 0) { "  gateway differs: $($diffGateway -join ', ')" }
    if ($diffExit.Count -gt 0) { "  exit differs: $($diffExit -join ', ')" }

    Check 'the snapshot is removed from the gateway after the restore' ((Invoke-Node $gateway.IP 'test -e /root/.seg-snapshot && echo yes || echo no') -match 'no')
    Check 'the snapshot is removed from the exit after the restore' ((Invoke-Node $exit.IP 'test -e /root/.seg-snapshot && echo yes || echo no') -match 'no')

    # Fail-closed is intact and never weakened
    Check 'the fail-closed table is present on the gateway' ($afterGateway.Values['FAIL_CLOSED'] -eq 'OK')

    if ($Scenario -eq 'FirstSingBox') {
        Check 'sing-box stays stopped on the gateway' ((Invoke-Node $gateway.IP 'systemctl is-active sing-box; true') -match 'inactive')
        Check 'sing-box stays disabled on the gateway' ((Invoke-Node $gateway.IP 'systemctl is-enabled sing-box 2>&1; true') -notmatch '^enabled')
        Check 'no sing-box configuration is left' ((Invoke-Node $gateway.IP 'test ! -e /etc/sing-box/config.json && echo ok') -match 'ok')
        Check 'nothing listens on the VLESS port' ((Invoke-Node $gateway.IP "ss -H -lnt 'sport = :$($gateway.Port)' | wc -l") -match '^0')
    }
    else {
        Check 'the services of the gateway work' ($afterGateway.Values['SERVICES'] -eq 'OK')
        Check 'the sing-box configuration keeps its mode and owner' ((Invoke-Node $gateway.IP "stat -c '%a %U:%G' /etc/sing-box/config.json") -match '^640 root:sing-box')
        Check 'the backhaul configuration keeps its mode and owner' ((Invoke-Node $gateway.IP "stat -c '%a %U:%G' /etc/amnezia/amneziawg/$iface.conf") -match '^600 root:root')
        Check 'the services of the exit work' ($afterExit.Values['SERVICES'] -eq 'OK')

        # The pair works with the previous configuration: the backhaul check passes
        $backhaul = (Invoke-RemoteScript -IP $gateway.IP -ScriptPath (Join-Path $Root 'seg\check-backhaul.sh') -Arguments @($iface, $env_['SEG_BACKHAUL_VPS1'], $env_['SEG_BACKHAUL_VPS2'], [string]$exit.IP, $env_['SEG_MARK'], '/etc/sing-box/config.json') -AllowFailure -Quiet).Output
        Check 'the backhaul works with the previous configuration (check-backhaul passes)' ($backhaul -match 'BACKHAUL_CHECK_OK')
        Check 'the selected outbound is still bound to the backhaul' ($backhaul -match 'CHECK SELECTED_ROUTING=OK')
        Check 'the unmatched policy was not switched by the failed run' ($afterGateway.Files['/etc/sing-box/config.json'] -eq $beforeGateway.Files['/etc/sing-box/config.json'])
    }
}
finally {
    Remove-Item Env:SEG_TEST_FAIL_AFTER_STAGE -ErrorAction SilentlyContinue

    if ($rotated) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File scripts\generate-server-env.ps1 -Mode SEG -Restore -Force *> $null
        Check 'the previous seg.env was restored' ($LASTEXITCODE -eq 0)
    }
    else {
        Invoke-Node $gateway.IP 'test -f /root/aside/config.json && mv /root/aside/config.json /etc/sing-box/config.json; test -f /root/aside/sing-box.service && mv /root/aside/sing-box.service /etc/systemd/system/; rmdir /root/aside 2>/dev/null; systemctl daemon-reload; systemctl enable --now sing-box' | Out-Null
    }
}

# The pair is current again with the restored local state
$check = & powershell -NoProfile -ExecutionPolicy Bypass -File scripts\sync-servers.ps1 -Mode SEG -Check all *> $null
Check 'after the restore of the local state the check of the pair passes (exit code 0)' ($LASTEXITCODE -eq 0)

"passed=$script:pass failed=$script:fail"
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
