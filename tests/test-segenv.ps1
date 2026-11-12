$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\scripts\lib\segenv.ps1')

$root = Split-Path $PSScriptRoot -Parent
$script:pass = 0
$script:fail = 0

function Pass($label) { $script:pass++; "PASS  $label" }
function Fail($label, $msg) { $script:fail++; "FAIL  $label : $msg" }

# A valid environment is built from synthetic values (not real keys): MTU 800, RandomTrailers on, S1..S4 = 144.
function New-ValidEnv {
    $e = Read-SegEnvFile -Path (Join-Path $root 'config\seg.env.example')
    $e['SEG_REALITY_PRIVATE_KEY'] = 'A' * 42 + 'a'
    $e['SEG_REALITY_PUBLIC_KEY'] = 'B' * 42 + 'b'
    $e['SEG_REALITY_SHORT_ID'] = '0123456789abcdef'
    $e['SEG_BACKHAUL_PRIVATE_KEY_VPS1'] = 'C' * 43 + '='
    $e['SEG_BACKHAUL_PUBLIC_KEY_VPS1'] = 'D' * 43 + '='
    $e['SEG_BACKHAUL_PRIVATE_KEY_VPS2'] = 'E' * 43 + '='
    $e['SEG_BACKHAUL_PUBLIC_KEY_VPS2'] = 'F' * 43 + '='
    $e['SEG_BACKHAUL_PSK'] = 'G' * 43 + '='
    $awg = @{ JC = 4; JMIN = 40; JMAX = 70; S1 = 144; S2 = 144; S3 = 144; S4 = 144; H1 = 1000000001; H2 = 1000000002; H3 = 1000000003; H4 = 1000000004 }
    foreach ($k in $awg.Keys) { $e["SEG_BACKHAUL_$k"] = [string]$awg[$k] }
    return $e
}

function Expect-Valid($label, [hashtable]$env, [string[]]$reserved = @()) {
    try { Test-SegEnvironment -Env $env -ReservedNetworks $reserved; Pass $label } catch { Fail $label $_.Exception.Message }
}

function Expect-Problem($label, [hashtable]$env, [string]$pattern, [string[]]$reserved = @()) {
    try { Test-SegEnvironment -Env $env -ReservedNetworks $reserved; Fail $label 'no error' }
    catch { if ($_.Exception.Message -match $pattern) { Pass $label } else { Fail $label "wrong error: $($_.Exception.Message)" } }
}

function Mutate([hashtable]$base, [hashtable]$changes, [string[]]$remove = @()) {
    $c = @{} + $base
    foreach ($k in $changes.Keys) { $c[$k] = $changes[$k] }
    foreach ($k in $remove) { $c.Remove($k) }
    return $c
}

"--- reader"
$tmp = Join-Path $env:TEMP ('segenv-' + [guid]::NewGuid().ToString('N') + '.env')
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($tmp, "# comment`n`nSEG_MARK=0x5e90`n SEG_UNMATCHED_POLICY = direct `n", $utf8)
try { $r = Read-SegEnvFile -Path $tmp; if ($r['SEG_MARK'] -eq '0x5e90' -and $r['SEG_UNMATCHED_POLICY'] -eq 'direct' -and $r.Count -eq 2) { Pass 'comments, blanks, spaces' } else { Fail 'reader' 'wrong content' } } catch { Fail 'reader' $_ }
foreach ($case in @(@('line without =', "SEG_MARK`n", 'Invalid line'), @('name without SEG_ prefix', "MARK=1`n", 'Invalid parameter name'), @('duplicate', "SEG_MARK=1`nSEG_MARK=2`n", 'Duplicate'))) {
    [System.IO.File]::WriteAllText($tmp, $case[1], $utf8)
    try { [void](Read-SegEnvFile -Path $tmp); Fail $case[0] 'no error' } catch { if ($_.Exception.Message -match $case[2]) { Pass "reader rejects: $($case[0])" } else { Fail $case[0] $_.Exception.Message } }
}
Remove-Item $tmp -Force

"--- example file"
$example = Read-SegEnvFile -Path (Join-Path $root 'config\seg.env.example')
try {
    Test-SegEnvironment -Env $example
    Fail 'example must not be usable as is' 'no error'
} catch {
    $m = $_.Exception.Message
    $mustReport = @('SEG_REALITY_PRIVATE_KEY', 'SEG_REALITY_PUBLIC_KEY', 'SEG_REALITY_SHORT_ID', 'SEG_BACKHAUL_PRIVATE_KEY_VPS1', 'SEG_BACKHAUL_PSK', 'SEG_BACKHAUL_JC', 'SEG_BACKHAUL_S1', 'SEG_BACKHAUL_H1')
    $missing = @($mustReport | Where-Object { $m -notmatch [regex]::Escape($_) })
    $unexpected = @('SEG_BACKHAUL_NETWORK', 'SEG_BACKHAUL_VPS1', 'SEG_BACKHAUL_PORT', 'SEG_BACKHAUL_INTERFACE', 'SEG_MARK', 'SEG_UNMATCHED_MARK', 'SEG_UNMATCHED_POLICY', 'SEG_REALITY_FLOW', 'SEG_REALITY_DEST', 'SEG_REALITY_SERVER_NAME') | Where-Object { $m -match [regex]::Escape($_) }
    if ($missing.Count -eq 0 -and @($unexpected).Count -eq 0) { Pass 'example: only secrets and AWG parameters are reported' } else { Fail 'example' "missing: $($missing -join ','); unexpected: $(@($unexpected) -join ',')" }
}

"--- valid configuration"
$base = New-ValidEnv
Expect-Valid 'synthetic values (MTU 800, RandomTrailers on)' $base
Expect-Valid 'no overlap with VPN network' $base @('10.7.0.0/24')

"--- keys and REALITY"
Expect-Problem 'REALITY private key wrong length' (Mutate $base @{ SEG_REALITY_PRIVATE_KEY = 'short' }) 'SEG_REALITY_PRIVATE_KEY must be a 43-character'
Expect-Problem 'REALITY keys equal' (Mutate $base @{ SEG_REALITY_PUBLIC_KEY = $base['SEG_REALITY_PRIVATE_KEY'] }) 'are equal'
Expect-Problem 'short id odd length' (Mutate $base @{ SEG_REALITY_SHORT_ID = 'abc' }) 'SEG_REALITY_SHORT_ID'
Expect-Problem 'short id uppercase' (Mutate $base @{ SEG_REALITY_SHORT_ID = 'ABCDEF01' }) 'SEG_REALITY_SHORT_ID'
Expect-Problem 'server name without dot' (Mutate $base @{ SEG_REALITY_SERVER_NAME = 'localhost' }) 'SEG_REALITY_SERVER_NAME'
Expect-Problem 'dest without port' (Mutate $base @{ SEG_REALITY_DEST = 'www.microsoft.com' }) 'SEG_REALITY_DEST'
Expect-Problem 'dest port 99999' (Mutate $base @{ SEG_REALITY_DEST = 'www.microsoft.com:99999' }) 'SEG_REALITY_DEST'
Expect-Problem 'unsupported flow' (Mutate $base @{ SEG_REALITY_FLOW = 'none' }) 'SEG_REALITY_FLOW'
Expect-Problem 'unknown fingerprint' (Mutate $base @{ SEG_REALITY_FINGERPRINT = 'netscape' }) 'SEG_REALITY_FINGERPRINT'
Expect-Problem 'awg key wrong format' (Mutate $base @{ SEG_BACKHAUL_PSK = 'abc=' }) 'SEG_BACKHAUL_PSK must be a 44-character'
Expect-Problem 'psk reused as key' (Mutate $base @{ SEG_BACKHAUL_PSK = $base['SEG_BACKHAUL_PRIVATE_KEY_VPS1'] }) 'must all be different'
Expect-Problem 'same key on both sides' (Mutate $base @{ SEG_BACKHAUL_PRIVATE_KEY_VPS2 = $base['SEG_BACKHAUL_PRIVATE_KEY_VPS1'] }) 'must all be different'

"--- network"
Expect-Problem 'network not /30' (Mutate $base @{ SEG_BACKHAUL_NETWORK = '10.77.0.0/29' }) 'must be an IPv4 /30'
Expect-Problem 'network host bits set' (Mutate $base @{ SEG_BACKHAUL_NETWORK = '10.77.0.1/30' }) 'network address'
Expect-Problem 'network invalid' (Mutate $base @{ SEG_BACKHAUL_NETWORK = 'abc' }) 'must be an IPv4 /30'
Expect-Problem 'overlap with VPN network' (Mutate $base @{ SEG_BACKHAUL_NETWORK = '10.7.0.0/30'; SEG_BACKHAUL_VPS1 = '10.7.0.2'; SEG_BACKHAUL_VPS2 = '10.7.0.1' }) 'overlaps the reserved network' @('10.7.0.0/24')
Expect-Problem 'address outside network' (Mutate $base @{ SEG_BACKHAUL_VPS1 = '10.78.0.2' }) 'inside SEG_BACKHAUL_NETWORK'
Expect-Problem 'address is network address' (Mutate $base @{ SEG_BACKHAUL_VPS1 = '10.77.0.0' }) 'inside SEG_BACKHAUL_NETWORK'
Expect-Problem 'address is broadcast' (Mutate $base @{ SEG_BACKHAUL_VPS2 = '10.77.0.3' }) 'inside SEG_BACKHAUL_NETWORK'
Expect-Problem 'addresses equal' (Mutate $base @{ SEG_BACKHAUL_VPS2 = $base['SEG_BACKHAUL_VPS1'] }) 'must be different'
Expect-Problem 'address not IPv4' (Mutate $base @{ SEG_BACKHAUL_VPS1 = '10.77.0.x' }) 'must be an IPv4 address'
Expect-Problem 'port 0' (Mutate $base @{ SEG_BACKHAUL_PORT = '0' }) 'SEG_BACKHAUL_PORT must be an integer'
Expect-Problem 'port 70000' (Mutate $base @{ SEG_BACKHAUL_PORT = '70000' }) 'SEG_BACKHAUL_PORT must be an integer'
Expect-Problem 'interface awg0' (Mutate $base @{ SEG_BACKHAUL_INTERFACE = 'awg0' }) 'must not be awg0'
Expect-Problem 'interface too long' (Mutate $base @{ SEG_BACKHAUL_INTERFACE = 'awg-backhaul-interface' }) 'SEG_BACKHAUL_INTERFACE'

"--- AmneziaWG parameters and MTU"
Expect-Problem 'RandomTrailers invalid' (Mutate $base @{ SEG_BACKHAUL_RANDOM_TRAILERS = 'yes' }) 'must be on or off'
Expect-Problem 'JMIN greater than JMAX' (Mutate $base @{ SEG_BACKHAUL_JMIN = '100'; SEG_BACKHAUL_JMAX = '50' }) 'JMIN must not be greater'
Expect-Problem 'JC zero' (Mutate $base @{ SEG_BACKHAUL_JC = '0' }) 'SEG_BACKHAUL_JC must be an integer'
Expect-Problem 'S4 out of range' (Mutate $base @{ SEG_BACKHAUL_S4 = '5' }) 'SEG_BACKHAUL_S4 must be an integer'
Expect-Problem 'H values not unique' (Mutate $base @{ SEG_BACKHAUL_H2 = $base['SEG_BACKHAUL_H1'] }) 'H1..H4 must be unique'
Expect-Problem 'H value too small' (Mutate $base @{ SEG_BACKHAUL_H1 = '3' }) 'SEG_BACKHAUL_H1 must be an integer'
Expect-Problem 'MTU above 1420' (Mutate $base @{ SEG_BACKHAUL_MTU = '1500' }) 'SEG_BACKHAUL_MTU must be an integer'
Expect-Problem 'MTU fragments with RandomTrailers on' (Mutate $base @{ SEG_BACKHAUL_MTU = '1280' }) 'would be fragmented'
Expect-Valid 'MTU 1280 is fine with RandomTrailers off' (Mutate $base @{ SEG_BACKHAUL_MTU = '1280'; SEG_BACKHAUL_RANDOM_TRAILERS = 'off' })
Expect-Problem 'MTU 1300 still too big with RandomTrailers off' (Mutate $base @{ SEG_BACKHAUL_MTU = '1300'; SEG_BACKHAUL_RANDOM_TRAILERS = 'off' }) 'would be fragmented'
try { if ((Get-SegBackhaulMtuLimit -S4 144 -RandomTrailers 'on') -eq 816 -and (Get-SegBackhaulMtuLimit -S4 144 -RandomTrailers 'off') -eq 1296) { Pass 'MTU limits 816 (on) and 1296 (off) for S4=144' } else { Fail 'MTU limit' 'unexpected value' } } catch { Fail 'MTU limit' $_ }

"--- marks and policy"
Expect-Problem 'mark not hex' (Mutate $base @{ SEG_MARK = '24208' }) 'SEG_MARK must be a hex'
Expect-Problem 'mark too small' (Mutate $base @{ SEG_MARK = '0x1' }) 'SEG_MARK must be at least'
Expect-Problem 'mark equals AmneziaWG fwmark' (Mutate $base @{ SEG_MARK = '0xca6c' }) 'reserved mark'
Expect-Problem 'marks equal' (Mutate $base @{ SEG_UNMATCHED_MARK = $base['SEG_MARK'] }) 'must be different'
Expect-Problem 'policy invalid' (Mutate $base @{ SEG_UNMATCHED_POLICY = 'allow' }) 'SEG_UNMATCHED_POLICY'
Expect-Valid 'policy block' (Mutate $base @{ SEG_UNMATCHED_POLICY = 'block' })

"--- completeness"
Expect-Problem 'missing parameter' (Mutate $base @{} @('SEG_MARK')) 'SEG_MARK is missing'
Expect-Problem 'empty parameter' (Mutate $base @{ SEG_BACKHAUL_PORT = '' }) 'SEG_BACKHAUL_PORT is missing or empty'
Expect-Problem 'unknown parameter (typo)' (Mutate $base @{ SEG_BACKHAUL_PROT = '1' }) 'Unknown parameter: SEG_BACKHAUL_PROT'
try {
    $bad = Mutate $base @{ SEG_REALITY_PRIVATE_KEY = 'SECRETVALUE-SHOULD-NOT-LEAK'; SEG_BACKHAUL_PSK = 'SECRETPSK-SHOULD-NOT-LEAK' }
    try { Test-SegEnvironment -Env $bad; Fail 'secrets not leaked' 'no error' }
    catch { if ($_.Exception.Message -match 'SHOULD-NOT-LEAK') { Fail 'secrets not leaked' 'secret value present in message' } else { Pass 'secret values are not included in messages' } }
} catch { Fail 'secrets not leaked' $_ }
try {
    $multi = Mutate $base @{ SEG_BACKHAUL_PORT = '0'; SEG_MARK = '1'; SEG_UNMATCHED_POLICY = 'x' }
    try { Test-SegEnvironment -Env $multi } catch { $count = @($_.Exception.Message -split "`n" | Where-Object { $_ -match '^\s+- ' }).Count; if ($count -eq 3) { Pass 'all problems are reported at once (3)' } else { Fail 'multiple problems' "reported $count" } }
} catch { Fail 'multiple problems' $_ }

""
"passed=$script:pass failed=$script:fail"
if ($script:fail -gt 0) { exit 1 }
