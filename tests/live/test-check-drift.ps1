# Drift checks of sync-servers.ps1 -Mode SEG -Check (roadmap item 26): each scenario breaks one thing on the nodes
# or in the local source of truth, runs the check, prints the report lines that matter and the exit code, and
# restores the state. Run from the project root after a successful full sync.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $Root

. (Join-Path $Root 'scripts\lib\common.ps1')
. (Join-Path $Root 'scripts\lib\servers.ps1')

$servers = (Read-ServersFile -Path (Join-Path $Root 'servers.txt')).Servers
$gateway = @($servers | Where-Object { $_.Role -eq 'seg-gateway' -and $_.IsEnabled })[0].IP
$exit = @($servers | Where-Object { $_.Role -eq 'seg-exit' -and $_.IsEnabled })[0].IP

function Invoke-Check([string]$Title, [string[]]$Keys) {
    "=== $Title"
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File scripts\sync-servers.ps1 -Mode SEG -Check all 2>&1
    $code = $LASTEXITCODE

    foreach ($line in $out) {
        $text = $line.ToString()
        $text = $text.Substring([Math]::Min(55, $text.Length - 1))

        foreach ($key in $Keys) {
            if ($text -match $key) { "  $text"; break }
        }
    }

    "  exit=$code"
}

function Invoke-Node([string]$Ip, [string]$Command) {
    & ssh -o BatchMode=yes "root@$Ip" $Command 2>&1 | Out-Null
}

$summary = 'GATEWAY=|EXIT=|BACKHAUL=|HANDSHAKE=|FAIL_CLOSED=|SECURITY=|EGRESS_IP=|BACKHAUL_DNS=|\(seg-(gateway|exit)\)'

# 1. A client added locally: the users of sing-box on VPS2 are outdated
& powershell -NoProfile -ExecutionPolicy Bypass -File scripts\add-client.ps1 -Mode SEG drifttest 2>&1 | Out-Null
'y' | & powershell -NoProfile -ExecutionPolicy Bypass -File scripts\add-client.ps1 -Mode SEG drifttest 2>&1 | Out-Null
Invoke-Check 'a client was added locally, not synchronized' $summary
'y' | & powershell -NoProfile -ExecutionPolicy Bypass -File scripts\remove-client.ps1 -Mode SEG drifttest 2>&1 | Out-Null

# 2. sing-box stopped on the gateway
Invoke-Node $gateway 'systemctl stop sing-box'
Invoke-Check 'sing-box stopped on the gateway' $summary
Invoke-Node $gateway 'systemctl start sing-box'

# 3. The fail-closed table deleted by hand
Invoke-Node $gateway 'nft delete table inet seg_failclosed'
Invoke-Check 'the fail-closed table deleted on the gateway' $summary
Invoke-Node $gateway 'systemctl reload seg-failclosed'

# 4. UFW disabled on the exit
Invoke-Node $exit 'ufw --force disable'
Invoke-Check 'UFW disabled on the exit' $summary
Invoke-Node $exit 'ufw --force enable'

# 5. The backhaul of the exit stopped
Invoke-Node $exit 'systemctl stop awg-quick@awg-backhaul'
Start-Sleep -Seconds 5
Invoke-Check 'the backhaul stopped on the exit' $summary
Invoke-Node $exit 'systemctl start awg-quick@awg-backhaul; systemctl start seg-exit-keepalive'

# 6. Everything restored
Start-Sleep -Seconds 10
Invoke-Check 'restored' $summary
