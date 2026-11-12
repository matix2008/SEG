# Items 33 and 38 end to end: the real issued client profile (SOCKS inbound instead of TUN) -> VPS2 -> backhaul -> VPS1.
# Disrupts the backhaul in several ways and checks that selected traffic never leaves with the address of VPS2.
# Everything that is changed on the nodes is restored. Needs a SEG client (-ClientName) known to VPS2.
param(
    [Parameter(Mandatory = $true)][string]$ClientName,
    [int]$Port = 20810,
    [string[]]$Scenarios = @('Baseline', 'StopInterface', 'DeleteRoute', 'StopPeer', 'UfwReload', 'RebootExit', 'RebootGateway')
)

$ErrorActionPreference = 'Continue'
$Scenarios = @($Scenarios | ForEach-Object { $_ -split ',' })
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

. (Join-Path $Root 'scripts\lib\common.ps1')
. (Join-Path $Root 'scripts\lib\servers.ps1')

$servers = (Read-ServersFile -Path (Join-Path $Root 'servers.txt')).Servers
$gw = @($servers | Where-Object { $_.Role -eq 'seg-gateway' -and $_.IsEnabled })[0].IP
$ex = @($servers | Where-Object { $_.Role -eq 'seg-exit' -and $_.IsEnabled })[0].IP
$mark = ((Get-Content (Join-Path $Root 'config\seg.env') | Where-Object { $_ -match '^SEG_MARK=' }) -split '=')[1].Trim()
$iface = ((Get-Content (Join-Path $Root 'config\seg.env') | Where-Object { $_ -match '^SEG_BACKHAUL_INTERFACE=' }) -split '=')[1].Trim()
$bhNet = ((Get-Content (Join-Path $Root 'config\seg.env') | Where-Object { $_ -match '^SEG_BACKHAUL_NETWORK=' }) -split '=')[1].Trim()
$bhGw = ((Get-Content (Join-Path $Root 'config\seg.env') | Where-Object { $_ -match '^SEG_BACKHAUL_VPS2=' }) -split '=')[1].Trim()

$singBox = Join-Path $Root 'tools\sing-box.exe'
$work = Join-Path $env:TEMP ('seg-e2e-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$sshOpt = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=6')
$script:results = @()
$script:clientPid = $null

function Add-Result([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $script:results += [pscustomobject]@{ Name = $Name; Ok = $Ok }
    '{0}  {1}{2}' -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $(if ($Detail) { " ($Detail)" } else { '' })
}

function Invoke-Node([string]$Ip, [string]$Script) {
    $s = ($Script -replace "`r", '') + "`n# end"
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = $s | & ssh @sshOpt root@$Ip 'bash -s' 2>&1
    $ErrorActionPreference = $prev
    @($out | ForEach-Object { "$_" } | Where-Object { $_ -notmatch '^ssh\.exe : |^At C:|^\+ |CategoryInfo|FullyQualifiedErrorId|^\s*$' })
}

function Get-Selected {
    $text = & curl.exe -s --max-time 12 --socks5-hostname "127.0.0.1:$Port" 'https://chatgpt.com/cdn-cgi/trace' 2>$null
    if ($LASTEXITCODE -eq 0 -and (($text -join "`n") -match '(?m)^ip=(\S+)')) { return $Matches[1] }
    return ''
}

function Test-Outage([string]$Name, [int]$Probes = 3) {
    $seen = @(1..$Probes | ForEach-Object { Get-Selected })
    $leak = @($seen | Where-Object { $_ -eq $gw })
    $any = @($seen | Where-Object { $_ })
    Add-Result "$Name`: selected resource does not open" ($any.Count -eq 0) "answers: $(($seen | ForEach-Object { if ($_) { $_ } else { 'fail' } }) -join ',')"
    Add-Result "$Name`: the address of VPS2 is never used" ($leak.Count -eq 0)
}

function Wait-Selected([string]$Name, [int]$TimeoutSec = 120) {
    $t0 = Get-Date
    $seen = ''
    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
        $seen = Get-Selected
        if ($seen -eq $ex) { break }
        Start-Sleep -Seconds 2
    }
    Add-Result "$Name`: selected resource is served again through VPS1" ($seen -eq $ex) "after $([int](((Get-Date) - $t0).TotalSeconds))s, ip=$seen"
}

function Get-DropCount {
    $o = Invoke-Node $gw "nft list chain inet seg_failclosed output | grep -E 'meta mark 0x0*$($mark -replace '^0x','') ' | sed -E 's/.*packets ([0-9]+) bytes.*/\1/' | head -1"
    [int64]("$($o | Select-Object -First 1)".Trim())
}

function Wait-Node([string]$Ip, [string]$OldBoot, [int]$TimeoutSec = 240) {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
        $b = & ssh @sshOpt root@$Ip 'cat /proc/sys/kernel/random/boot_id' 2>$null
        if ($LASTEXITCODE -eq 0 -and "$b".Trim() -ne $OldBoot) { return [int](((Get-Date) - $t0).TotalSeconds) }
        Start-Sleep -Seconds 3
    }
    return -1
}

function Start-Reboot([string]$Ip) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & ssh @sshOpt root@$Ip 'systemd-run --on-active=2 systemctl reboot' 2>&1 | Out-Null
    $ErrorActionPreference = $prev
}

function Wait-Down([string]$Ip, [int]$TimeoutSec = 60) {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
        & ssh @sshOpt root@$Ip 'true' 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Get-BootId([string]$Ip) { "$(& ssh @sshOpt root@$Ip 'cat /proc/sys/kernel/random/boot_id' 2>$null)".Trim() }

try {
    $profile = Get-Content -LiteralPath (Join-Path $Root "clients\generated\seg\$ClientName.json") -Raw | ConvertFrom-Json
    $profile.inbounds = @([pscustomobject]@{ type = 'mixed'; tag = 'mixed-in'; listen = '127.0.0.1'; listen_port = $Port })
    $profile.log = [pscustomobject]@{ level = 'warn'; timestamp = $true }
    $profile.route.PSObject.Properties.Remove('auto_detect_interface')
    $path = Join-Path $work 'profile-socks.json'
    [System.IO.File]::WriteAllText($path, ($profile | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    $process = Start-Process -FilePath $singBox -ArgumentList @('run', '-c', $path) -WorkingDirectory (Split-Path $singBox) -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $work 'client.err') -RedirectStandardOutput (Join-Path $work 'client.out')
    $script:clientPid = $process.Id
    Start-Sleep -Seconds 4

    if ($Scenarios -contains 'Baseline') {
        '== Baseline (item 33)'
        Add-Result 'backhaul UP: selected resource leaves with the address of VPS1' ((Get-Selected) -eq $ex)

        $o = Invoke-Node $gw @"
ip -4 route get 1.1.1.1 | head -1
echo "--- fwmark of ${iface}: `$(awg show $iface fwmark)"
echo "--- ip rules:"; ip rule
echo "--- rules that set or match any mark (nft + iptables):"
(nft list ruleset; iptables-save 2>/dev/null) | grep -iE 'mark' | sed 's/^[[:space:]]*/    /'
echo "--- awg-iptables on this host:"
systemctl is-enabled awg-iptables.service 2>&1 | head -1
"@
        $o | ForEach-Object { "      $_" }
        $defaultDev = if (($o | Select-Object -First 1) -match ' dev (\S+)') { $Matches[1] } else { '' }
        $markHex = $mark -replace '^0x', ''
        $markLines = @($o | Where-Object { $_ -match '^\s{4}\S' -and $_ -match '(?i)mark' })
        Add-Result 'main default route goes through the public interface of VPS2 (not the backhaul)' ($defaultDev -and $defaultDev -ne $iface) $defaultDev
        Add-Result 'awg-backhaul has no fwmark' (($o -join "`n") -match 'fwmark of [^:]+: off')
        Add-Result 'no ip rule uses SEG_MARK' (@($o | Where-Object { $_ -match 'fwmark' -and $_ -match $markHex }).Count -eq 0)
        Add-Result 'SEG_MARK is matched only by the fail-closed drop rule' (@($markLines | Where-Object { $_ -match "0x0*$markHex\b" }).Count -eq 1)
        Add-Result 'no other mark rules (UFW, awg-iptables) exist on VPS2' (@($markLines | Where-Object { $_ -notmatch '0x0*5e9[01]\b' }).Count -eq 0) "$(@($markLines | Where-Object { $_ -notmatch '0x0*5e9[01]\b' }).Count) other"
    }

    if ($Scenarios -contains 'StopInterface') {
        '== Stop the backhaul interface on VPS2 (item 38)'
        $d0 = Get-DropCount
        Invoke-Node $gw "systemctl stop awg-quick@$iface.service; ip link show $iface >/dev/null 2>&1 && echo still-present || echo interface-gone" | ForEach-Object { "      $_" }
        Test-Outage 'interface stopped'

        # A marked socket that is not bound to the backhaul (what sing-box would do without the bind) must be dropped
        $py = @"
python3 - <<'PY'
import socket
def probe(mark, label):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(4)
    if mark:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, mark)
    try:
        s.connect(('1.1.1.1', 443)); print(label, 'OK')
    except Exception as e:
        print(label, 'FAIL')
probe($mark, 'marked-unbound')
probe(0, 'unmarked-direct')
PY
"@
        $o = Invoke-Node $gw $py
        $o | ForEach-Object { "      $_" }
        Add-Result 'a SEG_MARK socket without the backhaul is dropped by the fail-closed table' (($o -join ' ') -match 'marked-unbound FAIL')
        Add-Result 'unmarked traffic of VPS2 itself still works (the table is not a general block)' (($o -join ' ') -match 'unmarked-direct OK')
        $d1 = Get-DropCount
        Add-Result 'the fail-closed drop counter grew' ($d1 -gt $d0) "$d0 -> $d1"

        Invoke-Node $gw "systemctl start awg-quick@$iface.service; systemctl is-active awg-quick@$iface.service" | ForEach-Object { "      restored: $_" }
        Wait-Selected 'interface restored'
    }

    if ($Scenarios -contains 'DeleteRoute') {
        '== Delete the connected route of the backhaul on VPS2 (item 38)'
        Invoke-Node $gw "ip route del $bhNet dev $iface; ip route show dev $iface | wc -l" | ForEach-Object { "      routes left on $iface`: $_" }
        $seen = @(1..3 | ForEach-Object { Get-Selected })
        Add-Result 'no route: selected traffic does not leave with the address of VPS2' (@($seen | Where-Object { $_ -eq $gw }).Count -eq 0) "answers: $(($seen | ForEach-Object { if ($_) { $_ } else { 'fail' } }) -join ',')"
        "      info: with the route removed selected answers were: $(($seen | ForEach-Object { if ($_) { $_ } else { 'fail' } }) -join ',')"
        Invoke-Node $gw "ip route replace $bhNet dev $iface proto kernel scope link src $bhGw; ip route show dev $iface" | ForEach-Object { "      restored: $_" }
        Wait-Selected 'route restored' 60
    }

    if ($Scenarios -contains 'StopPeer') {
        '== Stop the backhaul on VPS1 (VPS1 does not answer) (item 38)'
        Invoke-Node $ex "systemctl stop awg-quick@$iface.service; systemctl is-active seg-exit-keepalive.service" | ForEach-Object { "      after stop, keepalive unit: $_" }
        Test-Outage 'VPS1 backhaul stopped'
        Invoke-Node $ex "systemctl start awg-quick@$iface.service; sleep 1; echo keepalive after the start of awg-quick: `$(systemctl is-active seg-exit-keepalive.service)" | ForEach-Object { "      $_" }
        Wait-Selected 'VPS1 backhaul restored'
        $o = Invoke-Node $ex "systemctl is-active seg-exit-keepalive.service"
        Add-Result 'seg-exit-keepalive is active after a manual stop and start of awg-quick' (($o | Select-Object -First 1) -eq 'active') "$($o | Select-Object -First 1)"
        if (($o | Select-Object -First 1) -ne 'active') {
            Invoke-Node $ex "systemctl start seg-exit-keepalive.service; systemctl is-active seg-exit-keepalive.service" | ForEach-Object { "      keepalive started manually: $_" }
        }
    }

    if ($Scenarios -contains 'UfwReload') {
        '== ufw reload on VPS2 under load (item 38)'
        $before = Invoke-Node $gw "nft list table inet seg_failclosed >/dev/null && echo present"
        Add-Result 'fail-closed table present before ufw reload' (($before | Select-Object -First 1) -eq 'present')
        $job = Start-Job -ScriptBlock { param($o, $ip) 'ufw reload >/dev/null 2>&1; sleep 1; ufw reload >/dev/null 2>&1; nft list table inet seg_failclosed >/dev/null && echo present-after' | & ssh @o root@$ip 'bash -s' 2>&1 } -ArgumentList (, $sshOpt), $gw
        $seen = @(1..8 | ForEach-Object { Get-Selected })
        $after = Receive-Job -Job $job -Wait; Remove-Job $job
        Add-Result 'selected traffic never uses the address of VPS2 during ufw reload' (@($seen | Where-Object { $_ -eq $gw }).Count -eq 0) "answers: $(($seen | ForEach-Object { if ($_) { $_ } else { 'fail' } }) -join ',')"
        Add-Result 'selected traffic keeps working through VPS1 during ufw reload' (@($seen | Where-Object { $_ -eq $ex }).Count -ge 6) "$(@($seen | Where-Object { $_ -eq $ex }).Count) of 8"
        Add-Result 'fail-closed table present after ufw reload' (($after -join ' ') -match 'present-after')
        Wait-Selected 'after ufw reload' 30
    }

    if ($Scenarios -contains 'RebootExit') {
        '== Reboot of VPS1 (item 38)'
        $b = Get-BootId $ex
        Start-Reboot $ex
        Add-Result 'VPS1 went down' (Wait-Down $ex)
        Test-Outage 'VPS1 rebooting' 2
        $up = Wait-Node $ex $b
        "      VPS1 back after ${up}s"
        Wait-Selected 'VPS1 rebooted' 150
    }

    if ($Scenarios -contains 'RebootGateway') {
        '== Reboot of VPS2 (item 38)'
        $b = Get-BootId $gw
        Start-Reboot $gw
        Add-Result 'VPS2 went down' (Wait-Down $gw)
        Test-Outage 'VPS2 rebooting' 2
        $up = Wait-Node $gw $b
        "      VPS2 back after ${up}s"
        Wait-Selected 'VPS2 rebooted' 150
        $o = Invoke-Node $gw "nft list table inet seg_failclosed >/dev/null && echo table-present; echo order: failclosed=`$(systemctl show seg-failclosed -p ActiveEnterTimestampMonotonic --value) backhaul=`$(systemctl show awg-quick@$iface -p ActiveEnterTimestampMonotonic --value) singbox=`$(systemctl show sing-box -p ActiveEnterTimestampMonotonic --value)"
        $o | ForEach-Object { "      $_" }
        Add-Result 'fail-closed table is loaded after the reboot' (($o -join ' ') -match 'table-present')
        if (($o -join ' ') -match 'failclosed=(\d+) backhaul=(\d+) singbox=(\d+)') {
            Add-Result 'fail-closed was loaded before the backhaul and sing-box' (([int64]$Matches[1] -lt [int64]$Matches[2]) -and ([int64]$Matches[1] -lt [int64]$Matches[3]))
        }
    }
}
finally {
    if ($script:clientPid) { Stop-Process -Id $script:clientPid -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($script:results | Where-Object { -not $_.Ok }).Count
"passed=$(@($script:results | Where-Object { $_.Ok }).Count) failed=$failed"
exit $(if ($failed -gt 0) { 1 } else { 0 })
