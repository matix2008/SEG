$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\lib\segclients.ps1')

$script:pass = 0
$script:fail = 0
function Pass($l) { $script:pass++; "PASS  $l" }
function Fail($l, $m) { $script:fail++; "FAIL  $l : $m" }
function Assert-True($c, $m) { if (-not $c) { throw $m } }
function Expect-Error($label, [scriptblock]$code, [string]$pattern) {
    try { & $code; Fail $label 'no error' }
    catch { if ($_.Exception.Message -match $pattern) { Pass $label } else { Fail $label "wrong error: $($_.Exception.Message)" } }
}

$tmpRoot = Join-Path $env:TEMP ('segclients-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmpRoot | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$cyr = [string][char]0x0442 + [char]0x0435 + [char]0x0441 + [char]0x0442

"--- names"
foreach ($ok in 'laptop', 'Phone-2', 'a.b_c', 'x', 'A1', ('a' * 64), 'com10', 'console') { if ($null -eq (Test-SegClientName -Name $ok)) { Pass "valid name '$ok'" } else { Fail "valid name '$ok'" (Test-SegClientName -Name $ok) } }
foreach ($bad in '', '-x', '.x', '_x', 'x.', 'con', 'COM1', 'nul.txt', 'Lpt9', 'x.meta', 'X.META', ('a' * 65), 'a b', 'a/b', 'a\b', '..', $cyr, 'a:b') {
    if ($null -ne (Test-SegClientName -Name $bad)) { Pass "invalid name '$bad'" } else { Fail "invalid name '$bad'" 'accepted' }
}

"--- new client, save and read"
try {
    $c = New-SegClient -Name 'laptop'
    Assert-True ($c.Uuid -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') 'uuid format (v4, lowercase)'
    Assert-True ($c.Enabled -eq $true) 'enabled by default'
    Assert-True ((New-SegClient -Name 'other').Uuid -ne $c.Uuid) 'uuids differ'
    $path = Save-SegClient -Root $tmpRoot -Client $c
    Assert-True ($path -eq (Join-Path $tmpRoot 'clients\seg\laptop.json')) "path: $path"
    $bytes = [System.IO.File]::ReadAllBytes($path)
    Assert-True ($bytes[0] -ne 239) 'no BOM'
    Assert-True (-not ([System.Text.Encoding]::UTF8.GetString($bytes)).Contains("`r")) 'LF only'
    $r = Read-SegClient -Path $path
    Assert-True ($r.Name -eq 'laptop' -and $r.Uuid -eq $c.Uuid -and $r.Enabled -eq $true) 'round trip fields'
    Assert-True ($r.Created.UtcTicks -eq $c.Created.UtcTicks) 'created round trip'
    Assert-True (@(Get-ChildItem (Join-Path $tmpRoot 'clients\seg') -Force).Count -eq 1) 'no temp files'
    Pass 'new client: random v4 UUID, saved as UTF-8 LF without BOM, round trip is exact'
} catch { Fail 'new/save/read' $_.Exception.Message }
Expect-Error 'save refuses to overwrite' { Save-SegClient -Root $tmpRoot -Client (New-SegClient -Name 'laptop') } 'already exists'
try {
    $again = New-SegClient -Name 'laptop'; $again.Enabled = $false
    [void](Save-SegClient -Root $tmpRoot -Client $again -Overwrite)
    Assert-True ((Read-SegClient -Path (Join-Path $tmpRoot 'clients\seg\laptop.json')).Enabled -eq $false) 'overwritten'
    Pass 'save with -Overwrite replaces the record'
} catch { Fail 'overwrite' $_.Exception.Message }
Expect-Error 'invalid name rejected before anything is written' { Save-SegClient -Root $tmpRoot -Client ([pscustomobject]@{ Name = 'x.meta'; Uuid = ([guid]::NewGuid().ToString()); Enabled = $true; Created = [datetimeoffset]::Now }) } 'name must be|must not end'
Expect-Error 'New-SegClient rejects an invalid name' { New-SegClient -Name 'con' } 'Invalid client name'
Assert-True (-not (Test-Path (Join-Path $tmpRoot 'clients\seg\x.meta.json'))) 'x.meta written'

"--- invalid records"
$goodUuid = [guid]::NewGuid().ToString()
$goodDate = ([datetimeoffset]::Now).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
function Record([string]$name, [string]$text) {
    $dir = Join-Path $tmpRoot 'bad'; New-Item -ItemType Directory -Force $dir | Out-Null
    $p = Join-Path $dir "$name.json"; [System.IO.File]::WriteAllText($p, $text, $utf8); return $p
}
function Json($o) { return ($o | ConvertTo-Json) }
function Base { return [ordered]@{ name = 'rec'; uuid = $goodUuid; enabled = $true; created = $goodDate } }
Expect-Error 'not JSON' { [void](Read-SegClient -Path (Record 'rec' '{ "name": ')) } 'not valid JSON'
Expect-Error 'JSON array' { [void](Read-SegClient -Path (Record 'rec' '[1]')) } 'must contain a JSON object'
foreach ($field in 'name', 'uuid', 'enabled', 'created') {
    $o = Base; $o.Remove($field)
    $f = $field; $text = Json $o
    Expect-Error "missing field $f" { [void](Read-SegClient -Path (Record 'rec' $text)) } "missing field: $f"
}
$o = Base; $o.extra = 1; $t = Json $o
Expect-Error 'unknown field' { [void](Read-SegClient -Path (Record 'rec' $t)) } 'unknown field: extra'
$o = Base; $o.name = 'other'; $t = Json $o
Expect-Error 'name differs from the file name' { [void](Read-SegClient -Path (Record 'rec' $t)) } 'does not match the file name'
$o = Base; $o.name = 5; $t = Json $o
Expect-Error 'name is not a string' { [void](Read-SegClient -Path (Record 'rec' $t)) } 'name must be a string'
foreach ($case in @(@('uppercase', $goodUuid.ToUpper()), @('too short', 'abc'), @('nil', '00000000-0000-0000-0000-000000000000'), @('no dashes', ($goodUuid -replace '-', '')))) {
    $o = Base; $o.uuid = $case[1]; $t = Json $o
    Expect-Error "uuid $($case[0])" { [void](Read-SegClient -Path (Record 'rec' $t)) } 'uuid must be'
}
$o = Base; $o.enabled = 'yes'; $t = Json $o
Expect-Error 'enabled is a string' { [void](Read-SegClient -Path (Record 'rec' $t)) } 'enabled must be true or false'
foreach ($d in '2026-11-09', '2026-11-09T14:30:00', 'yesterday') {
    $o = Base; $o.created = $d; $t = Json $o; $dd = $d
    Expect-Error "created '$dd'" { [void](Read-SegClient -Path (Record 'rec' $t)) } 'created must be'
}
try {
    $o = Base; $o.enabled = 'yes'; $t = Json $o
    try { [void](Read-SegClient -Path (Record 'rec' $t)) } catch { Assert-True (-not $_.Exception.Message.Contains($goodUuid)) 'UUID in message' }
    Pass 'the UUID is not included in error messages'
} catch { Fail 'uuid not leaked' $_.Exception.Message }

"--- all clients"
Assert-True (@(Read-SegClients -Root (Join-Path $env:TEMP 'no-such-root')).Count -eq 0) 'missing dir'
Pass 'missing clients directory: empty list'
try {
    foreach ($n in 'zeta', 'Alpha', 'beta') { [void](Save-SegClient -Root $tmpRoot -Client (New-SegClient -Name $n)) }
    $all = @(Read-SegClients -Root $tmpRoot)
    Assert-True ($all.Count -eq 4) "count $($all.Count)"
    Assert-True ((@($all | ForEach-Object { $_.Name }) -join ',') -eq 'Alpha,beta,laptop,zeta') "order: $(@($all | ForEach-Object { $_.Name }) -join ',')"
    Pass 'reads all clients, sorted by file name'
} catch { Fail 'read all' $_.Exception.Message }
try {
    $dup = [pscustomobject]@{ Name = 'copycat'; Uuid = (Read-SegClient -Path (Join-Path $tmpRoot 'clients\seg\zeta.json')).Uuid; Enabled = $true; Created = [datetimeoffset]::Now }
    [void](Save-SegClient -Root $tmpRoot -Client $dup)
    try { [void](Read-SegClients -Root $tmpRoot); Fail 'duplicate UUID' 'no error' }
    catch { if ($_.Exception.Message -match 'share a UUID' -and -not $_.Exception.Message.Contains($dup.Uuid)) { Pass 'duplicate UUID is rejected, the UUID is not in the message' } else { Fail 'duplicate UUID' $_.Exception.Message } }
    Remove-Item (Join-Path $tmpRoot 'clients\seg\copycat.json') -Force
} catch { Fail 'duplicate UUID setup' $_.Exception.Message }

"--- VLESS users for VPS2"
try {
    $clients = @(Read-SegClients -Root $tmpRoot)
    $json = ConvertTo-SegVlessUsersJson -Clients $clients -Flow 'xtls-rprx-vision'
    $users = @(("{ `"u`": [ $json ] }" | ConvertFrom-Json).u)
    Assert-True ($users.Count -eq 3) "enabled users: $($users.Count) (laptop is disabled)"
    Assert-True ((@($users | ForEach-Object { $_.name }) -join ',') -eq 'Alpha,beta,zeta') 'sorted ignoring case'
    Assert-True (@($users | Where-Object { $_.flow -ne 'xtls-rprx-vision' }).Count -eq 0) 'flow'
    Assert-True ($users[0].uuid -eq (Read-SegClient -Path (Join-Path $tmpRoot 'clients\seg\Alpha.json')).Uuid) 'uuid'
    Assert-True ((ConvertTo-SegVlessUsersJson -Clients $clients -Flow 'f') -eq (ConvertTo-SegVlessUsersJson -Clients @($clients[3], $clients[2], $clients[1], $clients[0]) -Flow 'f')) 'order independent'
    Pass 'users: enabled clients only, sorted, valid JSON, independent of input order'
} catch { Fail 'users json' $_.Exception.Message }
try { Assert-True ((ConvertTo-SegVlessUsersJson -Clients @() -Flow 'f') -eq '') 'empty'; Pass 'no clients: empty fragment (sing-box accepts "users": [])' } catch { Fail 'empty users' $_.Exception.Message }

"--- connection hash"
$envv = @{ SEG_REALITY_SERVER_NAME = 'www.microsoft.com'; SEG_REALITY_PUBLIC_KEY = ('A' * 43); SEG_REALITY_SHORT_ID = '0123456789abcdef'; SEG_REALITY_FLOW = 'xtls-rprx-vision'; SEG_REALITY_FINGERPRINT = 'chrome'; SEG_UNMATCHED_POLICY = 'direct' }
$base = Get-SegConnectionSha256 -Vps2Ip '203.0.113.20' -Port '443' -Env $envv
Assert-True ($base -cmatch '^[0-9a-f]{64}$') 'format'
Assert-True ($base -eq (Get-SegConnectionSha256 -Vps2Ip '203.0.113.20' -Port '443' -Env $envv)) 'deterministic'
Pass 'connection hash is a stable SHA-256'
foreach ($change in @(@('VPS2 address', @{ ip = '1.2.3.4' }), @('port', @{ port = '8443' }), @('server name', @{ k = 'SEG_REALITY_SERVER_NAME'; v = 'www.apple.com' }), @('public key', @{ k = 'SEG_REALITY_PUBLIC_KEY'; v = ('B' * 43) }), @('short id', @{ k = 'SEG_REALITY_SHORT_ID'; v = 'abcdef0123456789' }), @('flow', @{ k = 'SEG_REALITY_FLOW'; v = 'none' }), @('fingerprint', @{ k = 'SEG_REALITY_FINGERPRINT'; v = 'firefox' }))) {
    $e2 = @{} + $envv; $ip = '203.0.113.20'; $port = '443'
    if ($change[1].ContainsKey('ip')) { $ip = $change[1].ip } elseif ($change[1].ContainsKey('port')) { $port = $change[1].port } else { $e2[$change[1].k] = $change[1].v }
    if ((Get-SegConnectionSha256 -Vps2Ip $ip -Port $port -Env $e2) -ne $base) { Pass "hash changes with the $($change[0])" } else { Fail "hash with $($change[0])" 'unchanged' }
}
$e3 = @{} + $envv; $e3['SEG_UNMATCHED_POLICY'] = 'block'; $e3['SEG_BACKHAUL_PORT'] = '1'
if ((Get-SegConnectionSha256 -Vps2Ip '203.0.113.20' -Port '443' -Env $e3) -eq $base) { Pass 'hash ignores parameters that are not part of the connection (policy, backhaul)' } else { Fail 'hash stability' 'changed' }

"--- profile metadata"
$paths = Get-SegProfilePaths -Root $tmpRoot -Name 'laptop'
Assert-True ($paths.Profile -eq (Join-Path $tmpRoot 'clients\generated\seg\laptop.json') -and $paths.Meta -eq (Join-Path $tmpRoot 'clients\generated\seg\laptop.meta.json')) 'paths'
Pass 'profile and metadata paths follow clients\generated\seg\<name>.json and <name>.meta.json'
$sha1 = 'a' * 64; $sha2 = 'b' * 64
try {
    Save-SegProfileMeta -Path $paths.Meta -SegListVersion 3 -SegListSha256 $sha1 -ServerConfigSha256 $sha2
    $m = Read-SegProfileMeta -Path $paths.Meta
    Assert-True ($m.SegListVersion -eq 3 -and $m.SegListSha256 -eq $sha1 -and $m.ServerConfigSha256 -eq $sha2) 'fields'
    Assert-True ([math]::Abs(([datetimeoffset]::Now - $m.GeneratedAt).TotalMinutes) -lt 2) 'generatedAt'
    $bytes = [System.IO.File]::ReadAllBytes($paths.Meta)
    Assert-True ($bytes[0] -ne 239 -and -not ([System.Text.Encoding]::UTF8.GetString($bytes)).Contains("`r")) 'UTF-8 LF without BOM'
    Pass 'profile metadata: round trip, UTF-8 LF without BOM'
} catch { Fail 'meta round trip' $_.Exception.Message }
Expect-Error 'meta: bad hash rejected on save' { Save-SegProfileMeta -Path (Join-Path $tmpRoot 'm.json') -SegListVersion 1 -SegListSha256 'zz' -ServerConfigSha256 $sha2 } '64 lowercase hex'
Expect-Error 'meta: version 0 rejected on save' { Save-SegProfileMeta -Path (Join-Path $tmpRoot 'm.json') -SegListVersion 0 -SegListSha256 $sha1 -ServerConfigSha256 $sha2 } 'at least 1'
function MetaFile([string]$text) { $p = Join-Path $tmpRoot 'meta-test.json'; [System.IO.File]::WriteAllText($p, $text, $utf8); return $p }
$goodMeta = [ordered]@{ segListVersion = 1; segListSha256 = $sha1; serverConfigSha256 = $sha2; generatedAt = $goodDate }
Expect-Error 'meta: not JSON' { [void](Read-SegProfileMeta -Path (MetaFile '{')) } 'not valid JSON'
foreach ($field in 'segListVersion', 'segListSha256', 'serverConfigSha256', 'generatedAt') {
    $o = [ordered]@{} + $goodMeta; $o.Remove($field); $t = $o | ConvertTo-Json; $f = $field
    Expect-Error "meta: missing $f" { [void](Read-SegProfileMeta -Path (MetaFile $t)) } "missing field: $f"
}
$o = [ordered]@{} + $goodMeta; $o.extra = 1; $t = $o | ConvertTo-Json
Expect-Error 'meta: unknown field' { [void](Read-SegProfileMeta -Path (MetaFile $t)) } 'unknown field: extra'
$o = [ordered]@{} + $goodMeta; $o.segListSha256 = 'ABC'; $t = $o | ConvertTo-Json
Expect-Error 'meta: bad hash' { [void](Read-SegProfileMeta -Path (MetaFile $t)) } 'segListSha256 must be 64'
$o = [ordered]@{} + $goodMeta; $o.segListVersion = 0; $t = $o | ConvertTo-Json
Expect-Error 'meta: version 0' { [void](Read-SegProfileMeta -Path (MetaFile $t)) } 'segListVersion must be'
$o = [ordered]@{} + $goodMeta; $o.generatedAt = 'today'; $t = $o | ConvertTo-Json
Expect-Error 'meta: bad date' { [void](Read-SegProfileMeta -Path (MetaFile $t)) } 'generatedAt must be'

"--- git"
$ignored = @('clients/seg/laptop.json', 'clients/generated/seg/laptop.json', 'clients/generated/seg/laptop.meta.json') | Where-Object { -not (git -C $root check-ignore $_) }
if (@($ignored).Count -eq 0) { Pass 'client records and generated profiles are git-ignored (clients/)' } else { Fail 'gitignore' "not ignored: $(@($ignored) -join ', ')" }

Remove-Item $tmpRoot -Recurse -Force
""
"passed=$script:pass failed=$script:fail"
if ($script:fail -gt 0) { exit 1 }
