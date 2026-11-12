# Tests of the profile state functions of scripts\lib\segclients.ps1 (roadmap, item 22): Get-SegProfileStatus,
# Get-SegProfileOrphans. Works in a temporary root; reads config\seg.env, config\seg-list.json and servers.txt.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot

. (Join-Path $Root 'scripts\lib\common.ps1')
. (Join-Path $Root 'scripts\lib\servers.ps1')
. (Join-Path $Root 'scripts\lib\segenv.ps1')
. (Join-Path $Root 'scripts\lib\seglist.ps1')
. (Join-Path $Root 'scripts\lib\segclients.ps1')

Initialize-Logging -Root $Root -ScriptName 'test-segprofile-status.ps1'

$script:pass = 0
$script:fail = 0

function Check([string]$Name, [bool]$Condition) {
    if ($Condition) { $script:pass++; "PASS  $Name" } else { $script:fail++; "FAIL  $Name" }
}

$env_ = Read-SegEnvFile -Path (Join-Path $Root 'config\seg.env')
$servers = (Read-ServersFile -Path (Join-Path $Root 'servers.txt')).Servers
$gateway = @($servers | Where-Object { $_.Role -eq 'seg-gateway' -and $_.IsEnabled })[0]

$tmp = Join-Path $env:TEMP ('seg-status-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
    $listPath = Join-Path $tmp 'seg-list.json'
    Copy-Item -LiteralPath (Join-Path $Root 'config\seg-list.json') -Destination $listPath
    $list = Read-SegList -Path $listPath

    $alice = New-SegClient -Name 'alice'
    $bob = New-SegClient -Name 'bob'
    [void](Save-SegClient -Root $tmp -Client $alice)
    [void](Save-SegClient -Root $tmp -Client $bob)

    function Status($Client, $ListValue = $list, $EnvValues = $env_, $GatewayValue = $gateway) {
        return (Get-SegProfileStatus -Root $tmp -Client $Client -SegList $ListValue -Env $EnvValues -Gateway $GatewayValue)
    }

    function Write-Profile($Client, $ListValue = $list, $EnvValues = $env_, $GatewayValue = $gateway) {
        $paths = Get-SegProfilePaths -Root $tmp -Name $Client.Name
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $paths.Profile) | Out-Null
        [System.IO.File]::WriteAllText($paths.Profile, "{}`n")
        $connection = Get-SegConnectionSha256 -Vps2Ip ([string]$GatewayValue.IP) -Port ([string]$GatewayValue.Port) -Env $EnvValues
        Save-SegProfileMeta -Path $paths.Meta -SegListVersion $ListValue.Version -SegListSha256 $ListValue.Sha256 -ServerConfigSha256 $connection
    }

    # 1. No profile, then a current one
    $s = Status $alice
    Check 'no profile: MISSING' ($s.State -eq 'MISSING')

    Write-Profile $alice
    $s = Status $alice
    Check 'fresh profile: CURRENT' ($s.State -eq 'CURRENT' -and $s.Reasons.Count -eq 0)

    # 2. Changing seg-list.json makes the profile stale; reverting the file makes it current again
    $original = [System.IO.File]::ReadAllText($listPath)
    [System.IO.File]::WriteAllText($listPath, $original.Replace('"ghcr.io",', '"ghcr.io", "example-added.org",'))
    $changedList = Read-SegList -Path $listPath
    Check 'the test edit really changed the list hash' ($changedList.Sha256 -ne $list.Sha256)
    $s = Status $alice $changedList
    Check 'changed seg-list.json: STALE' ($s.State -eq 'STALE')
    Check 'the reason names seg-list.json' (($s.Reasons -join ' ') -match 'seg-list\.json changed')
    Check 'the reason mentions the versions' (($s.Reasons -join ' ') -match 'version')
    Check 'the reason asks for a version increase when only the content changed' (($s.Reasons -join ' ') -match 'increase "version"')
    Check 'the reason does not mention the connection' (($s.Reasons -join ' ') -notmatch 'connection')

    [System.IO.File]::WriteAllText($listPath, $original)
    $s = Status $alice (Read-SegList -Path $listPath)
    Check 'the list restored: CURRENT again' ($s.State -eq 'CURRENT')

    # Line endings and a BOM do not change the hash
    [System.IO.File]::WriteAllText($listPath, $original.Replace("`r`n", "`n").Replace("`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    $s = Status $alice (Read-SegList -Path $listPath)
    Check 'CRLF and BOM do not make the profile stale' ($s.State -eq 'CURRENT')

    # 3. Connection parameters
    $other = @{}
    foreach ($key in $env_.Keys) { $other[$key] = $env_[$key] }
    $other['SEG_REALITY_PUBLIC_KEY'] = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    $s = Status $alice $list $other
    Check 'another REALITY public key: STALE' ($s.State -eq 'STALE' -and ($s.Reasons -join ' ') -match 'connection parameters')

    foreach ($key in 'SEG_REALITY_SHORT_ID', 'SEG_REALITY_SERVER_NAME', 'SEG_REALITY_FLOW', 'SEG_REALITY_FINGERPRINT') {
        $other = @{}
        foreach ($k in $env_.Keys) { $other[$k] = $env_[$k] }
        $other[$key] = $env_[$key] + 'x'
        Check "another $key`: STALE" ((Status $alice $list $other).State -eq 'STALE')
    }

    $movedGateway = [pscustomobject]@{ Name = $gateway.Name; IP = $gateway.IP; Port = '8443'; Role = 'seg-gateway' }
    Check 'another gateway port: STALE' ((Status $alice $list $env_ $movedGateway).State -eq 'STALE')
    $movedGateway = [pscustomobject]@{ Name = $gateway.Name; IP = '192.0.2.77'; Port = $gateway.Port; Role = 'seg-gateway' }
    Check 'another gateway address: STALE' ((Status $alice $list $env_ $movedGateway).State -eq 'STALE')

    # A parameter that is not part of the connection does not make the profile stale
    $other = @{}
    foreach ($k in $env_.Keys) { $other[$k] = $env_[$k] }
    $other['SEG_BACKHAUL_PORT'] = '42101'
    $other['SEG_UNMATCHED_POLICY'] = 'block'
    Check 'backhaul settings and the policy do not make profiles stale' ((Status $alice $list $other).State -eq 'CURRENT')

    # Both reasons
    $other = @{}
    foreach ($k in $env_.Keys) { $other[$k] = $env_[$k] }
    $other['SEG_REALITY_SHORT_ID'] = '0123456789abcdef'
    $s = Status $alice $changedList $other
    Check 'both changes give two reasons' ($s.State -eq 'STALE' -and $s.Reasons.Count -eq 2)

    # 4. Adding and removing other clients does not touch the profile of a client
    $carol = New-SegClient -Name 'carol'
    [void](Save-SegClient -Root $tmp -Client $carol)
    Check 'a new client does not make the profile of another client stale' ((Status $alice).State -eq 'CURRENT')
    Remove-Item -LiteralPath (Join-Path $tmp 'clients\seg\bob.json')
    Check 'a removed client does not make the profile of another client stale' ((Status $alice).State -eq 'CURRENT')

    # 5. Broken states
    $paths = Get-SegProfilePaths -Root $tmp -Name 'alice'
    $metaText = [System.IO.File]::ReadAllText($paths.Meta)

    Remove-Item -LiteralPath $paths.Meta
    $s = Status $alice
    Check 'the metadata missing: BROKEN' ($s.State -eq 'BROKEN' -and ($s.Reasons -join ' ') -match 'metadata file is missing')

    [System.IO.File]::WriteAllText($paths.Meta, '{ not json')
    $s = Status $alice
    Check 'unreadable metadata: BROKEN' ($s.State -eq 'BROKEN')

    [System.IO.File]::WriteAllText($paths.Meta, $metaText.Replace('"segListSha256"', '"segListShaX"'))
    $s = Status $alice
    Check 'metadata with an unknown field: BROKEN' ($s.State -eq 'BROKEN' -and ($s.Reasons -join ' ') -match 'unknown field')
    Check 'the BROKEN reason is one line' (($s.Reasons -join ' ') -notmatch "[\r\n]")

    [System.IO.File]::WriteAllText($paths.Meta, $metaText)
    Remove-Item -LiteralPath $paths.Profile
    $s = Status $alice
    Check 'the profile missing but metadata present: BROKEN' ($s.State -eq 'BROKEN' -and ($s.Reasons -join ' ') -match 'profile file is missing')

    Remove-Item -LiteralPath $paths.Meta
    Check 'nothing left: MISSING' ((Status $alice).State -eq 'MISSING')

    # 6. Disabled client
    $dave = New-SegClient -Name 'dave'
    $dave.Enabled = $false
    Check 'a disabled client: DISABLED' ((Status $dave).State -eq 'DISABLED')

    # 7. Orphans
    Write-Profile $alice
    Write-Profile (New-SegClient -Name 'gone')
    $clients = @(Read-SegClients -Root $tmp)
    $orphans = @(Get-SegProfileOrphans -Root $tmp -Clients $clients)
    Check 'a profile without a client record is an orphan' ($orphans.Count -eq 1 -and $orphans[0] -eq 'gone')
    Check 'a profile of an existing client is not an orphan' ($orphans -notcontains 'alice')
    Check 'orphans: none for an empty directory' (@(Get-SegProfileOrphans -Root (Join-Path $tmp 'nothing-here') -Clients $clients).Count -eq 0)

    # 8. The secrets are not in the reasons
    $other = @{}
    foreach ($k in $env_.Keys) { $other[$k] = $env_[$k] }
    $other['SEG_REALITY_PUBLIC_KEY'] = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    $s = Status $alice $changedList $other
    $reasonText = $s.Reasons -join ' '
    Check 'the reasons contain neither keys nor hashes' (-not $reasonText.Contains($env_['SEG_REALITY_PUBLIC_KEY']) -and -not $reasonText.Contains($list.Sha256) -and -not $reasonText.Contains($alice.Uuid))
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

"passed=$script:pass failed=$script:fail"
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
