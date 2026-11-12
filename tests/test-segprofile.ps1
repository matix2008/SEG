# Tests of scripts\lib\segprofile.ps1: rendering, structural verification and sing-box check of the client profile.
# Uses config\seg.env, config\seg-list.json, clients\seg\unit-test.json and servers.txt (read-only).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot

. (Join-Path $Root 'scripts\lib\common.ps1')
. (Join-Path $Root 'scripts\lib\servers.ps1')
. (Join-Path $Root 'scripts\lib\segenv.ps1')
. (Join-Path $Root 'scripts\lib\seglist.ps1')
. (Join-Path $Root 'scripts\lib\segclients.ps1')
. (Join-Path $Root 'scripts\lib\segprofile.ps1')

Initialize-Logging -Root $Root -ScriptName 'test-segprofile.ps1'

$script:pass = 0
$script:fail = 0

function Check([string]$Name, [bool]$Condition) {
    if ($Condition) { $script:pass++; "PASS  $Name" } else { $script:fail++; "FAIL  $Name" }
}

function Get-Problem([scriptblock]$Action) {
    try { & $Action; return $null } catch { return $_.Exception.Message }
}

$env_ = Read-SegEnvFile -Path (Join-Path $Root 'config\seg.env')
$list = Read-SegList -Path (Join-Path $Root 'config\seg-list.json')
$client = New-SegClient -Name 'unit-test'
$servers = (Read-ServersFile -Path (Join-Path $Root 'servers.txt')).Servers
$gateway = @($servers | Where-Object { $_.Role -eq 'seg-gateway' -and $_.IsEnabled })[0]
$exit = @($servers | Where-Object { $_.Role -eq 'seg-exit' -and $_.IsEnabled })[0]

function New-Text($EnvValues = $env_, $ListValue = $list) {
    return (New-SegClientProfileText -Root $Root -Env $EnvValues -SegList $ListValue -Client $client -Gateway $gateway)
}

function Test-Text([string]$Text, $EnvValues = $env_, $ListValue = $list) {
    Test-SegClientProfile -Text $Text -Env $EnvValues -SegList $ListValue -Client $client -Gateway $gateway -Exit $exit
}

# 1. The profile rendered from the real values is correct
$text = New-Text
Check 'rendered profile has no unresolved variables' ($text -notmatch '\{\{')
Check 'rendered profile has LF endings only' ($text -notmatch "`r")
Check 'rendered profile is valid JSON' ($null -ne ($text | ConvertFrom-Json))
Check 'rendered profile passes the structural check' ($null -eq (Get-Problem { Test-Text $text }))
Check 'rendered profile passes sing-box check' ($null -eq (Get-Problem { Invoke-SingBoxClientCheck -Root $Root -Text $text }))
Check 'the client uuid is in the profile' ($text.Contains($client.Uuid))
Check 'the gateway address and port are in the profile' ($text.Contains("`"server`": `"$($gateway.IP)`"") -and $text.Contains("`"server_port`": $($gateway.Port)"))

# 2. Values come from seg.env, not from the template
$other = @{}
foreach ($key in $env_.Keys) { $other[$key] = $env_[$key] }
$other['SEG_REALITY_FINGERPRINT'] = 'firefox'
$changed = New-Text -EnvValues $other
Check 'the fingerprint comes from seg.env' ($changed.Contains('"fingerprint": "firefox"'))
Check 'the profile with another fingerprint is correct for those values' ($null -eq (Get-Problem { Test-Text $changed $other }))
Check 'the profile with another fingerprint does not match the original seg.env' ($null -ne (Get-Problem { Test-Text $changed $env_ }))

# 3. A seg-list without CIDRs gives a profile without the seg-cidrs set
$noCidrs = $list.PSObject.Copy()
$noCidrs.Cidrs = @()
$textNoCidrs = New-Text -ListValue $noCidrs
Check 'no seg-cidrs set without CIDRs' (-not $textNoCidrs.Contains('seg-cidrs'))
Check 'the profile without CIDRs is correct' ($null -eq (Get-Problem { Test-Text $textNoCidrs $env_ $noCidrs }))
Check 'the profile without CIDRs sing-box check' ($null -eq (Get-Problem { Invoke-SingBoxClientCheck -Root $Root -Text $textNoCidrs }))
Check 'a profile without CIDRs does not satisfy a list with CIDRs' ($null -ne (Get-Problem { Test-Text $textNoCidrs $env_ $list }))

# 4. Management traffic must not enter the tunnel: the addresses of both VPS are outside seg-list
$withGateway = $list.PSObject.Copy()
$withGateway.Cidrs = @($list.Cidrs) + @("$($gateway.IP)/32")
$problem = Get-Problem { Test-Text $text $env_ $withGateway }
Check 'the gateway address inside a seg-list CIDR is rejected' ($problem -and $problem -match 'inside a seg-list CIDR')

$withExit = $list.PSObject.Copy()
$withExit.Cidrs = @($list.Cidrs) + @("$($exit.IP)/24")
$problem = Get-Problem { Test-Text $text $env_ $withExit }
Check 'the exit address inside a seg-list CIDR is rejected' ($problem -and $problem -match 'inside a seg-list CIDR')

# 5. Each rule of the client is enforced
$cases = [ordered]@{
    'strict_route off'                = @{ Replace = '"strict_route": true'; With = '"strict_route": false'; Expect = 'strict_route' }
    'auto_route off'                  = @{ Replace = '"auto_route": true'; With = '"auto_route": false'; Expect = 'auto_route' }
    'auto_detect_interface off'       = @{ Replace = '"auto_detect_interface": true'; With = '"auto_detect_interface": false'; Expect = 'auto_detect_interface' }
    'final is the seg outbound'       = @{ Replace = '"final": "direct",' + "`n" + '    "auto_detect_interface"'; With = '"final": "seg",' + "`n" + '    "auto_detect_interface"'; Expect = 'route.final' }
    'no hijack-dns'                   = @{ Replace = '"action": "hijack-dns"'; With = '"action": "route"'; Expect = 'hijack-dns' }
    'QUIC is not rejected'            = @{ Replace = '"port": 443, "action": "reject"'; With = '"port": 443, "action": "route"'; Expect = 'QUIC' }
    'direct DNS over udp'             = @{ Replace = '"type": "https", "tag": "dns-direct", "server": "8.8.8.8", "tls": { "server_name": "dns.google" }'; With = '"type": "udp", "tag": "dns-direct", "server": "8.8.8.8"'; Expect = 'DNS server dns-direct' }
    'FakeIP range changed'            = @{ Replace = '198.18.0.0/15'; With = '198.19.0.0/16'; Expect = 'FakeIP' }
    'another uuid'                    = @{ Replace = $client.Uuid; With = [guid]::NewGuid().ToString(); Expect = 'uuid' }
    'another REALITY public key'      = @{ Replace = $env_['SEG_REALITY_PUBLIC_KEY']; With = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; Expect = 'public key' }
    'another gateway port'            = @{ Replace = "`"server_port`": $($gateway.Port)"; With = '"server_port": 8443'; Expect = 'port' }
    'private addresses are proxied'   = @{ Replace = '"ip_is_private": true, "outbound": "direct"'; With = '"ip_is_private": true, "outbound": "seg"'; Expect = 'Private addresses' }
}

foreach ($name in $cases.Keys) {
    $case = $cases[$name]
    $broken = $text.Replace($case.Replace, $case.With)

    if ($broken -eq $text) {
        Check "case '$name' changes the profile" $false
        continue
    }

    $problem = Get-Problem { Test-Text $broken }
    Check "violation is detected: $name" ($problem -and $problem -match [regex]::Escape($case.Expect))
    Check "the message does not contain secrets: $name" ($problem -and -not $problem.Contains($client.Uuid) -and -not $problem.Contains($env_['SEG_REALITY_PUBLIC_KEY']))
}

# 6. sing-box check rejects an invalid profile and its message names the reason
$invalid = $text.Replace('"type": "tun"', '"type": "no-such-inbound"')
$problem = Get-Problem { Invoke-SingBoxClientCheck -Root $Root -Text $invalid }
Check 'sing-box check rejects an unknown inbound type' ($problem -and $problem -match 'sing-box check rejected')

# 7. Rendering fails on a missing value
$partial = @{}
foreach ($key in $env_.Keys) { if ($key -ne 'SEG_REALITY_FLOW') { $partial[$key] = $env_[$key] } }
$problem = Get-Problem { New-Text -EnvValues $partial }
Check 'a missing value is reported as an unresolved variable' ($problem -and $problem -match 'Unresolved template variables: \{\{SEG_REALITY_FLOW\}\}')

"passed=$script:pass failed=$script:fail"
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
