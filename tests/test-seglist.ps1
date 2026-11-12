$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\lib\seglist.ps1')

$script:pass = 0
$script:fail = 0
$dir = Join-Path $env:TEMP ('seglist-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $dir | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$realPath = Join-Path $root 'config\seg-list.json'

function Pass($l) { $script:pass++; "PASS  $l" }
function Fail($l, $m) { $script:fail++; "FAIL  $l : $m" }
function New-Base { return (Get-Content $realPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
function Save($obj, [string]$name = 'list.json') {
    $p = Join-Path $dir $name
    [System.IO.File]::WriteAllText($p, ($obj | ConvertTo-Json -Depth 10), $utf8)
    return $p
}
function Expect-Ok($label, $obj, [scriptblock]$extra) {
    try { $r = Read-SegList -Path (Save $obj); if ($extra) { & $extra $r }; Pass $label } catch { Fail $label $_.Exception.Message }
}
function Expect-Error($label, $obj, [string]$pattern) {
    try { [void](Read-SegList -Path (Save $obj)); Fail $label 'no error' }
    catch { if ($_.Exception.Message -match $pattern) { Pass $label } else { Fail $label "wrong error: $($_.Exception.Message)" } }
}
function Expect-RawError($label, [string]$text, [string]$pattern) {
    $p = Join-Path $dir 'raw.json'
    [System.IO.File]::WriteAllText($p, $text, $utf8)
    try { [void](Read-SegList -Path $p); Fail $label 'no error' }
    catch { if ($_.Exception.Message -match $pattern) { Pass $label } else { Fail $label "wrong error: $($_.Exception.Message)" } }
}
function Assert-True($c, $m) { if (-not $c) { throw $m } }
function With-Group($mutator) { $b = New-Base; $g = @($b.groups | Where-Object { $_.name -eq 'github' })[0]; & $mutator $g $b; return $b }

"--- real file"
try {
    $r = Read-SegList -Path $realPath
    Assert-True ($r.Version -ge 1) 'version'
    $baseCount = @((New-Base).groups).Count
    Assert-True ($r.Groups.Count -eq $baseCount -and $r.EnabledGroups.Count -ge 1 -and $r.EnabledGroups.Count -le $baseCount) 'groups'
    Assert-True ($r.Sha256 -match '^[0-9a-f]{64}$') 'sha'
    Assert-True (@('github', 'copilot', 'chatgpt', 'facebook', 'telegram', 'youtube') | Where-Object { $_ -notin $r.EnabledGroups } | Measure-Object | ForEach-Object { $_.Count -eq 0 }) 'group names'
    Assert-True ($r.Cidrs.Count -eq 9) 'telegram cidrs'
    foreach ($d in 'youtube.com', 'googlevideo.com', 'chatgpt.com', 'openai.com', 'github.com', 'githubcopilot.com', 'telegram.org', 't.me', 'googleapis.com') { Assert-True ($r.DomainSuffixes -contains $d) "missing $d" }
    Assert-True ($r.Domains -contains 'default.exp-tas.com') 'exact domain'
    Assert-True (@($r.DomainSuffixes | Where-Object { $_ -eq 'github.com' }).Count -eq 1) 'github.com de-duplicated across groups'
    Pass "shipped seg-list.json is valid ($baseCount groups, YouTube set, Telegram CIDRs, de-duplicated)"
} catch { Fail 'shipped file' $_.Exception.Message }

"--- sha256"
try {
    $lf = Join-Path $dir 'lf.json'; $crlf = Join-Path $dir 'crlf.json'; $bom = Join-Path $dir 'bom.json'
    $text = (Get-Content $realPath -Raw -Encoding UTF8) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($lf, $text, $utf8)
    [System.IO.File]::WriteAllText($crlf, ($text -replace "`n", "`r`n"), $utf8)
    [System.IO.File]::WriteAllText($bom, $text, (New-Object System.Text.UTF8Encoding($true)))
    $a = Get-SegListSha256 -Path $lf; $b = Get-SegListSha256 -Path $crlf; $c = Get-SegListSha256 -Path $bom
    Assert-True ($a -eq $b -and $a -eq $c) "LF/CRLF/BOM differ: $a $b $c"
    Assert-True ($a -eq (Read-SegList -Path $realPath).Sha256) 'sha differs from the real file'
    $expected = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($utf8.GetBytes($text))) -replace '-', '').ToLower()
    Assert-True ($a -eq $expected) 'wrong digest'
    [System.IO.File]::WriteAllText($lf, ($text + ' '), $utf8)
    Assert-True ((Get-SegListSha256 -Path $lf) -ne $a) 'content change not detected'
    Pass 'SHA-256 is independent of CRLF/LF and BOM, and changes with the content'
} catch { Fail 'sha256' $_.Exception.Message }

"--- structure"
Expect-RawError 'not JSON' '{ "version": 1, ' 'not valid JSON'
Expect-RawError 'JSON array instead of object' '[1,2]' 'must contain a JSON object'
Expect-Error 'unknown top-level field' (With-Group { param($g, $b) $b | Add-Member -NotePropertyName extra -NotePropertyValue 1 }) 'Unknown top-level field: extra'
Expect-Error 'missing version' (With-Group { param($g, $b) $b.PSObject.Properties.Remove('version') }) 'version must be'
Expect-Error 'version 0' (With-Group { param($g, $b) $b.version = 0 }) 'version must be'
Expect-Error 'version as string' (With-Group { param($g, $b) $b.version = '1' }) 'version must be'
Expect-Error 'groups empty' (With-Group { param($g, $b) $b.groups = @() }) 'groups must be a non-empty array'
Expect-Error 'groups missing' (With-Group { param($g, $b) $b.PSObject.Properties.Remove('groups') }) 'groups must be a non-empty array'
Expect-Error 'unknown group field' (With-Group { param($g, $b) $g | Add-Member -NotePropertyName colour -NotePropertyValue 'x' }) 'unknown field: colour'
Expect-Error 'duplicate group name' (With-Group { param($g, $b) $b.groups[1].name = $g.name }) 'Duplicate group name'
Expect-Error 'group name uppercase' (With-Group { param($g, $b) $g.name = 'GitHub' }) 'name must be a lowercase identifier'
Expect-Error 'group name missing' (With-Group { param($g, $b) $g.PSObject.Properties.Remove('name') }) 'name must be a lowercase identifier'
Expect-Error 'title missing' (With-Group { param($g, $b) $g.PSObject.Properties.Remove('title') }) 'title must be a non-empty string'
Expect-Error 'enabled not boolean' (With-Group { param($g, $b) $g.enabled = 'yes' }) 'enabled must be true or false'
Expect-Error 'domain_suffixes is a string' (With-Group { param($g, $b) $g.domain_suffixes = 'github.com' }) 'domain_suffixes must be an array'
Expect-Error 'empty string item' (With-Group { param($g, $b) $g.domain_suffixes = @('github.com', '') }) 'non-empty strings only'
Expect-Error 'number item' (With-Group { param($g, $b) $g.domain_suffixes = @('github.com', 5) }) 'non-empty strings only'
Expect-Error 'duplicate inside a group' (With-Group { param($g, $b) $g.domain_suffixes = @('github.com', 'github.com') }) 'contains duplicates'

"--- domains"
foreach ($bad in @('GitHub.com', '.github.com', '*.github.com', 'localhost', '1.2.3.4', 'github.com.', 'git_hub.com', 'a..b.com', '-a.com', 'a-.com', 'exa mple.com', 'github.123')) {
    Expect-Error "invalid domain '$bad'" (With-Group { param($g, $b) $g.domain_suffixes = @($bad) }) 'invalid domain'
}
foreach ($good in @('github.com', 'a.b.c.example.org', 'xn--p1ai.xn--p1ai', 'my-site.co.uk', 'a1.io')) {
    Expect-Ok "valid domain '$good'" (With-Group { param($g, $b) $g.domain_suffixes = @($good) }) $null
}
Expect-Error 'invalid exact domain' (With-Group { param($g, $b) $g.domains = @('Bad Domain') }) 'domains has an invalid domain'
Expect-Error 'domain too long' (With-Group { param($g, $b) $g.domain_suffixes = @((('a' * 60 + '.') * 5) + 'com') }) 'invalid domain'

"--- cidrs"
foreach ($case in @(
    @('IPv6', '2001:b28:f23d::/48', 'invalid IPv4 CIDR'),
    @('no prefix', '8.8.8.8', 'invalid IPv4 CIDR'),
    @('prefix 7', '8.0.0.0/7', 'invalid IPv4 CIDR'),
    @('host bits set', '8.8.8.8/24', 'host bits set'),
    @('private 10/8', '10.0.0.0/8', 'private or reserved'),
    @('private 192.168', '192.168.1.0/24', 'private or reserved'),
    @('loopback', '127.0.0.0/8', 'private or reserved'),
    @('link-local metadata', '169.254.169.254/32', 'private or reserved'),
    @('CGNAT', '100.64.1.0/24', 'private or reserved'),
    @('FakeIP range', '198.18.0.0/16', 'private or reserved'),
    @('multicast', '224.0.0.0/24', 'private or reserved'),
    @('overlaps 172.16/12', '172.20.0.0/16', 'private or reserved'))) {
    $c = $case
    Expect-Error "cidr rejected: $($c[0])" (With-Group { param($g, $b) $g.cidrs = @($c[1]) }) $c[2]
}
Expect-Ok 'public cidr accepted (/32 and /8)' (With-Group { param($g, $b) $g.cidrs = @('8.8.8.8/32', '9.0.0.0/8') }) $null
Expect-Error 'cidr string instead of array' (With-Group { param($g, $b) $g.cidrs = '8.8.8.8/32' }) 'cidrs must be an array'

"--- enabled groups and merging"
Expect-Error 'enabled group without entries' (With-Group { param($g, $b) $g.domains = @(); $g.domain_suffixes = @(); $g.cidrs = @() }) 'enabled but has no domains'
Expect-Ok 'disabled empty group is fine and excluded' (With-Group { param($g, $b) $g.enabled = $false; $g.domains = @(); $g.domain_suffixes = @(); $g.cidrs = @() }) { param($r) Assert-True ($r.EnabledGroups -notcontains 'github' -and $r.Groups.Count -eq @((New-Base).groups).Count) 'disabled group handling' }
Expect-Ok 'disabled group entries are not used' (With-Group { param($g, $b) $g.enabled = $false; $g.domain_suffixes = @('only-in-disabled.example') }) { param($r) Assert-True ($r.DomainSuffixes -notcontains 'only-in-disabled.example') 'entry from a disabled group used' }
Expect-Error 'only CIDRs enabled (DNS rules need a domain)' (With-Group { param($g, $b) foreach ($x in $b.groups) { $x.enabled = ($x.name -eq 'telegram'); if ($x.name -eq 'telegram') { $x.domain_suffixes = @() } } }) 'no domains or domain_suffixes'
Expect-Ok 'enabled omitted means enabled' (With-Group { param($g, $b) $g.PSObject.Properties.Remove('enabled') }) { param($r) Assert-True ($r.EnabledGroups -contains 'github') 'default enabled' }
Expect-Ok 'order of first occurrence is kept' (With-Group { param($g, $b) $b.groups[0].domain_suffixes = @('zeta.example', 'alpha.example') }) { param($r) Assert-True ($r.DomainSuffixes[0] -eq 'zeta.example' -and $r.DomainSuffixes[1] -eq 'alpha.example') 'order' }
try {
    $b = With-Group { param($g, $b) $cp = @($b.groups | Where-Object { $_.name -eq 'copilot' })[0]; $cp.enabled = $false; $cp.domain_suffixes = @('githubcopilot.com') }
    $r = Read-SegList -Path (Save $b)
    Assert-True ($r.DomainSuffixes -notcontains 'githubcopilot.com') 'disabled Copilot still present'
    Assert-True ($r.DomainSuffixes -contains 'github.com') 'github.com missing'
    Pass 'disabling a group removes only its own entries'
} catch { Fail 'disable group' $_.Exception.Message }
try {
    [void](Read-SegList -Path (Save (With-Group { param($g, $b) $g.domain_suffixes = @('Bad.com'); $g.cidrs = @('10.0.0.0/8'); $b.version = 0 })))
    Fail 'all problems at once' 'no error'
} catch { $n = @($_.Exception.Message -split "`n" | Where-Object { $_ -match '^\s+- ' }).Count; if ($n -eq 3) { Pass 'all problems are reported at once (3)' } else { Fail 'all problems at once' "reported $n" } }

"--- rule set fragments"
function Parse-Fragment([string]$text) { return ("{ `"x`": [ $text ] }" | ConvertFrom-Json).x }
try {
    $list = Read-SegList -Path $realPath
    $f = Get-SegRuleSetFragments -SegList $list
    $sets = @(Parse-Fragment $f.SEG_RULE_SETS_JSON)
    Assert-True ($sets.Count -eq 2 -and $sets[0].tag -eq 'seg-domains' -and $sets[1].tag -eq 'seg-cidrs') 'two rule sets'
    Assert-True ($sets[0].type -eq 'inline' -and $sets[1].type -eq 'inline') 'inline'
    $dr = @($sets[0].rules)
    Assert-True (@($dr | Where-Object { $_.PSObject.Properties.Name -contains 'domain' }).Count -eq 1) 'domain rule'
    Assert-True (@($dr | Where-Object { $_.PSObject.Properties.Name -contains 'domain_suffix' }).Count -eq 1) 'domain_suffix rule'
    Assert-True (@($dr | Where-Object { $_.PSObject.Properties.Name -contains 'ip_cidr' }).Count -eq 0) 'no IP rules in the domain set'
    Assert-True (@($sets[1].rules).Count -eq 1 -and @($sets[1].rules[0].ip_cidr).Count -eq 9) 'cidr rule'
    Assert-True ($f.SEG_DOMAIN_RULE_SETS_JSON -eq '"seg-domains"') 'domain tags'
    Assert-True ($f.SEG_ROUTE_RULE_SETS_JSON -eq '"seg-domains", "seg-cidrs"') 'route tags'
    $post = Parse-Fragment ($f.SEG_POST_RESOLVE_RULES_JSON.TrimStart(', '))
    Assert-True ($post.outbound -eq 'seg-out' -and $post.rule_set -contains 'seg-cidrs') 'post-resolve rule'
    Pass 'fragments with CIDRs: valid JSON, separate domain and CIDR sets, post-resolve rule'
} catch { Fail 'fragments (real list)' $_.Exception.Message }
try {
    $b = With-Group { param($g, $b) foreach ($x in $b.groups) { $x.cidrs = @() } }
    $list = Read-SegList -Path (Save $b)
    $f = Get-SegRuleSetFragments -SegList $list
    $sets = @(Parse-Fragment $f.SEG_RULE_SETS_JSON)
    Assert-True ($sets.Count -eq 1 -and $sets[0].tag -eq 'seg-domains') 'only the domain set'
    Assert-True ($f.SEG_ROUTE_RULE_SETS_JSON -eq '"seg-domains"') 'route tags without CIDRs'
    Assert-True ($f.SEG_POST_RESOLVE_RULES_JSON -eq '') 'no post-resolve rule without CIDRs'
    Pass 'fragments without CIDRs: no CIDR set and no post-resolve rule'
} catch { Fail 'fragments (no CIDRs)' $_.Exception.Message }
try {
    $b = With-Group { param($g, $b) foreach ($x in $b.groups) { $x.domains = @(); if ($x.name -ne 'youtube') { $x.enabled = $false } } }
    $list = Read-SegList -Path (Save $b)
    $f = Get-SegRuleSetFragments -SegList $list
    $dr = @((Parse-Fragment $f.SEG_RULE_SETS_JSON)[0].rules)
    Assert-True ($dr.Count -eq 1 -and $dr[0].PSObject.Properties.Name -contains 'domain_suffix') 'no empty domain rule'
    Pass 'empty domain list produces no empty rule'
} catch { Fail 'fragments (no exact domains)' $_.Exception.Message }

Remove-Item $dir -Recurse -Force
""
"passed=$script:pass failed=$script:fail"
if ($script:fail -gt 0) { exit 1 }
