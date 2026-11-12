$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\scripts\lib\servers.ps1')

$dir = Join-Path $env:TEMP ('servers-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $dir | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$script:fail = 0
$script:pass = 0

function Write-Case([string]$name, [string]$text) {
    $p = Join-Path $dir $name
    [System.IO.File]::WriteAllText($p, ($text -replace "`r`n", "`n"), $utf8)
    return $p
}

function Expect-Ok([string]$label, [string]$text, [scriptblock]$extra) {
    $p = Write-Case 'servers.txt' $text
    try {
        $r = Read-ServersFile -Path $p
        if ($extra) { & $extra $r }
        $script:pass++; "PASS  $label"
    }
    catch { $script:fail++; "FAIL  $label : $($_.Exception.Message)" }
}

function Expect-Error([string]$label, [string]$text, [string]$pattern) {
    $p = Write-Case 'servers.txt' $text
    try {
        [void](Read-ServersFile -Path $p)
        $script:fail++; "FAIL  $label : no error"
    }
    catch {
        if ($_.Exception.Message -match $pattern) { $script:pass++; "PASS  $label" }
        else { $script:fail++; "FAIL  $label : wrong error: $($_.Exception.Message)" }
    }
}

function Assert-True($cond, $msg) { if (-not $cond) { throw $msg } }

$H = 'Name;IP;Port;Role;Type;Enabled'
$ok = @"
$H
vpn-01;203.0.113.10;42157;vpn-server;amnezia;true
seg-ru;1.2.3.4;443;seg-gateway;amnezia;true
seg-eu;5.6.7.8;;seg-exit;amnezia;true
"@

"--- valid"
Expect-Ok 'current format, three roles' $ok { param($r) Assert-True ($r.Format -eq 'current' -and $r.Servers.Count -eq 3) 'format/count' }
Expect-Ok 'legacy format' "Name;IP;Port;Enabled`nvpn-01;1.1.1.1;42000;true`nvpn-02;2.2.2.2;42001;false" { param($r) Assert-True ($r.Format -eq 'legacy' -and $r.Servers[0].Role -eq 'vpn-server' -and $r.Servers[0].Type -eq 'amnezia' -and -not $r.Servers[1].IsEnabled) 'legacy mapping' }
Expect-Ok 'role/type case and spaces' "$H`nvpn-01;1.1.1.1;42000; VPN-Server ; Amnezia ;True" { param($r) Assert-True ($r.Servers[0].Role -eq 'vpn-server' -and $r.Servers[0].IsEnabled) 'normalization' }
Expect-Ok 'gateway with type list (single supported)' "$H`ngw;1.2.3.4;443;seg-gateway;amnezia;true" $null
Expect-Ok 'disabled seg-exit with other type ignored by cross check' "$H`ngw;1.2.3.4;443;seg-gateway;amnezia;true`nex;5.6.7.8;;seg-exit;amnezia;false" $null
Expect-Ok 'same port on different IPs' "$H`na;1.1.1.1;42000;vpn-server;amnezia;true`nb;2.2.2.2;42000;vpn-server;amnezia;true" $null
Expect-Ok 'two seg-exit with empty Port (no uniqueness check)' "$H`nga;1.2.3.4;443;seg-gateway;amnezia;true`ne1;5.5.5.5;;seg-exit;amnezia;true`ne2;5.5.5.5;;seg-exit;amnezia;false" $null

"--- invalid"
Expect-Error 'empty file' '' 'no servers'
Expect-Error 'header only' $H 'no servers'
Expect-Error 'missing Enabled column' "Name;IP;Port`na;1.1.1.1;42000" "no 'Enabled' column"
Expect-Error 'Role without Type column' "Name;IP;Port;Role;Enabled`na;1.1.1.1;42000;vpn-server;true" "both 'Role' and 'Type'"
Expect-Error 'empty Name' "$H`n;1.1.1.1;42000;vpn-server;amnezia;true" 'empty Name'
Expect-Error 'empty IP' "$H`na;;42000;vpn-server;amnezia;true" 'empty IP'
Expect-Error 'duplicate Name' "$H`na;1.1.1.1;42000;vpn-server;amnezia;true`na;2.2.2.2;42001;vpn-server;amnezia;true" 'Duplicate server Name'
Expect-Error 'bad Enabled' "$H`na;1.1.1.1;42000;vpn-server;amnezia;yes" 'Enabled must be'
Expect-Error 'unknown role' "$H`na;1.1.1.1;42000;proxy;amnezia;true" "Unknown Role 'proxy'"
Expect-Error 'empty Type' "$H`na;1.1.1.1;42000;vpn-server;;true" 'Type is required'
Expect-Error 'sing-box type rejected' "$H`ngw;1.2.3.4;443;seg-gateway;sing-box;true" "Type 'sing-box' is not supported"
Expect-Error 'openvpn not implemented yet' "$H`na;1.1.1.1;42000;vpn-server;openvpn;true" "Type 'openvpn' is not supported"
Expect-Error 'vpn-server with type list' "$H`na;1.1.1.1;42000;vpn-server;amnezia,amnezia;true" 'exactly one Type'
Expect-Error 'seg-exit with type list' "$H`ne;1.1.1.1;;seg-exit;amnezia,amnezia;true" 'exactly one Type'
Expect-Error 'gateway duplicate types' "$H`ngw;1.1.1.1;443;seg-gateway;amnezia,amnezia;true" 'Duplicate Type'
Expect-Error 'type list with trailing comma' "$H`ngw;1.1.1.1;443;seg-gateway;amnezia,;true" 'Type is required'
Expect-Error 'type list with space' "$H`ngw;1.1.1.1;443;seg-gateway;amnezia, amnezia;true" "not supported"
Expect-Error 'vpn-server empty Port' "$H`na;1.1.1.1;;vpn-server;amnezia;true" 'Invalid UDP port'
Expect-Error 'vpn-server port 0' "$H`na;1.1.1.1;0;vpn-server;amnezia;true" 'Invalid UDP port'
Expect-Error 'vpn-server port 70000' "$H`na;1.1.1.1;70000;vpn-server;amnezia;true" 'Invalid UDP port'
Expect-Error 'vpn-server huge port' "$H`na;1.1.1.1;99999999999999999999;vpn-server;amnezia;true" 'Invalid UDP port'
Expect-Error 'gateway non-numeric port' "$H`ngw;1.1.1.1;https;seg-gateway;amnezia;true" 'Invalid TCP port'
Expect-Error 'seg-exit with Port' "$H`ne;1.1.1.1;443;seg-exit;amnezia;true" 'Port must be empty for seg-exit'
Expect-Error 'duplicate IP:Port' "$H`na;1.1.1.1;42000;vpn-server;amnezia;true`nb;1.1.1.1;42000;vpn-server;amnezia;true" 'Duplicate IP:Port'
Expect-Error 'exit type not in gateway list' "$H`ngw;1.2.3.4;443;seg-gateway;amnezia;true`nex;5.6.7.8;;seg-exit;openvpn;true" "not supported"

"--- selection and topology"
$p = Write-Case 'servers.txt' $ok
$r = Read-ServersFile -Path $p
try { $vpnOnly = @(Select-ServersForMode -Servers $r.Servers -Mode VPN); Assert-True ($vpnOnly.Count -eq 1) 'VPN count'; Assert-True ($vpnOnly[0].Name -eq 'vpn-01') 'VPN name'; $script:pass++; 'PASS  VPN mode ignores seg roles' } catch { $script:fail++; "FAIL  VPN mode: $_" }
try { $s = @(Select-ServersForMode -Servers $r.Servers -Mode SEG); Assert-True ($s.Count -eq 2 -and -not ($s | Where-Object Role -eq 'vpn-server')) 'SEG set'; $script:pass++; 'PASS  SEG mode ignores vpn-server' } catch { $script:fail++; "FAIL  SEG mode: $_" }
try { Assert-SegTopology -Servers $r.Servers; $script:pass++; 'PASS  topology: one gateway, one exit' } catch { $script:fail++; "FAIL  topology: $_" }
foreach ($case in @(
    @{ n = 'no exit';        t = "$H`ngw;1.2.3.4;443;seg-gateway;amnezia;true" },
    @{ n = 'no gateway';     t = "$H`nex;5.6.7.8;;seg-exit;amnezia;true" },
    @{ n = 'two exits';      t = "$H`ngw;1.2.3.4;443;seg-gateway;amnezia;true`ne1;5.6.7.8;;seg-exit;amnezia;true`ne2;6.6.6.6;;seg-exit;amnezia;true" },
    @{ n = 'only vpn-server'; t = "$H`na;1.1.1.1;42000;vpn-server;amnezia;true" })) {
    $pp = Write-Case 'servers.txt' $case.t
    $rr = Read-ServersFile -Path $pp
    try { Assert-SegTopology -Servers $rr.Servers; $script:fail++; "FAIL  topology $($case.n): no error" }
    catch { if ($_.Exception.Message -match 'exactly one enabled seg-gateway') { $script:pass++; "PASS  topology rejected: $($case.n)" } else { $script:fail++; "FAIL  topology $($case.n): $($_.Exception.Message)" } }
}

"--- migration"
$legacy = "Name;IP;Port;Enabled`nvpn-01;1.1.1.1;42000;true`nvpn-02;2.2.2.2;42001;false`n"
$mp = Write-Case 'servers.txt' $legacy
try {
    $m = Convert-ServersFileToCurrent -Path $mp
    Assert-True ($m -and $m.Count -eq 2 -and (Test-Path $m.Backup)) 'result/backup'
    Assert-True ((Get-Content $m.Backup -Raw) -eq $legacy) 'backup differs from original'
    $after = Read-ServersFile -Path $mp
    Assert-True ($after.Format -eq 'current') 'format after'
    Assert-True ($after.Servers[0].Role -eq 'vpn-server' -and $after.Servers[0].Type -eq 'amnezia' -and $after.Servers[1].Enabled -eq 'false') 'rows after'
    $first = Get-Content $mp -First 1
    Assert-True ($first -eq 'Name;IP;Port;Role;Type;Enabled') 'header'
    $script:pass++; 'PASS  legacy migrated, backup identical to original'
} catch { $script:fail++; "FAIL  migration: $_" }
try {
    $before = (Get-Content $mp -Raw); $count = @(Get-ChildItem $dir -Filter 'servers.txt.*.bak').Count
    $again = Convert-ServersFileToCurrent -Path $mp
    Assert-True ($null -eq $again) 'second run not null'
    Assert-True ((Get-Content $mp -Raw) -eq $before) 'file changed'
    Assert-True (@(Get-ChildItem $dir -Filter 'servers.txt.*.bak').Count -eq $count) 'new backup created'
    $script:pass++; 'PASS  repeated migration is a no-op'
} catch { $script:fail++; "FAIL  idempotence: $_" }
try {
    1..5 | ForEach-Object { [System.IO.File]::WriteAllText($mp, $legacy, $utf8); Start-Sleep -Milliseconds 30; [void](Convert-ServersFileToCurrent -Path $mp) }
    Assert-True (@(Get-ChildItem $dir -Filter 'servers.txt.*.bak').Count -eq 3) "backups kept: $(@(Get-ChildItem $dir -Filter 'servers.txt.*.bak').Count)"
    $script:pass++; 'PASS  only the last 3 backups are kept'
} catch { $script:fail++; "FAIL  prune: $_" }
try {
    $bad = Write-Case 'servers.txt' "Name;IP;Port;Enabled`nvpn-01;1.1.1.1;notaport;true`n"
    $orig = Get-Content $bad -Raw
    try { [void](Convert-ServersFileToCurrent -Path $bad); throw 'no error' } catch { if ($_.Exception.Message -notmatch 'Invalid UDP port') { throw } }
    Assert-True ((Get-Content $bad -Raw) -eq $orig) 'invalid legacy file changed'
    Assert-True (-not (Test-Path "$bad.new")) 'temp file left'
    $script:pass++; 'PASS  invalid legacy file: error, original unchanged, no temp file'
} catch { $script:fail++; "FAIL  invalid legacy: $_" }

Remove-Item $dir -Recurse -Force
""
"passed=$script:pass failed=$script:fail"
if ($script:fail -gt 0) { exit 1 }
