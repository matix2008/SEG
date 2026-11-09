# SEG parameters loader and validator (config/seg.env, SEG.md section 6).
# Keep this file ASCII-only: .ps1 files are read by Windows PowerShell 5.1.

$script:SegRealityFlows = @('xtls-rprx-vision')
$script:SegRealityFingerprints = @('chrome', 'firefox', 'safari', 'ios', 'android', 'edge', '360', 'qq', 'random', 'randomized')
$script:SegUnmatchedPolicies = @('direct', 'block')

# wg-quick default fwmark (51820); SEG marks must not collide with it.
$script:SegReservedMarks = @(0xca6c)

# Secret parameters: their values are never included in messages.
$script:SegSecretKeys = @(
    'SEG_REALITY_PRIVATE_KEY',
    'SEG_BACKHAUL_PRIVATE_KEY_VPS1',
    'SEG_BACKHAUL_PRIVATE_KEY_VPS2',
    'SEG_BACKHAUL_PSK'
)

$script:SegEnvKeys = @(
    'SEG_REALITY_PRIVATE_KEY',
    'SEG_REALITY_PUBLIC_KEY',
    'SEG_REALITY_SHORT_ID',
    'SEG_REALITY_SERVER_NAME',
    'SEG_REALITY_DEST',
    'SEG_REALITY_FLOW',
    'SEG_REALITY_FINGERPRINT',
    'SEG_BACKHAUL_PRIVATE_KEY_VPS1',
    'SEG_BACKHAUL_PUBLIC_KEY_VPS1',
    'SEG_BACKHAUL_PRIVATE_KEY_VPS2',
    'SEG_BACKHAUL_PUBLIC_KEY_VPS2',
    'SEG_BACKHAUL_PSK',
    'SEG_BACKHAUL_NETWORK',
    'SEG_BACKHAUL_VPS1',
    'SEG_BACKHAUL_VPS2',
    'SEG_BACKHAUL_PORT',
    'SEG_BACKHAUL_INTERFACE',
    'SEG_BACKHAUL_MTU',
    'SEG_BACKHAUL_RANDOM_TRAILERS',
    'SEG_BACKHAUL_JC',
    'SEG_BACKHAUL_JMIN',
    'SEG_BACKHAUL_JMAX',
    'SEG_BACKHAUL_S1',
    'SEG_BACKHAUL_S2',
    'SEG_BACKHAUL_S3',
    'SEG_BACKHAUL_S4',
    'SEG_BACKHAUL_H1',
    'SEG_BACKHAUL_H2',
    'SEG_BACKHAUL_H3',
    'SEG_BACKHAUL_H4',
    'SEG_MARK',
    'SEG_UNMATCHED_MARK',
    'SEG_UNMATCHED_POLICY'
)

function Read-SegEnvFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $result = @{}

    foreach ($raw in Get-Content -LiteralPath $Path) {
        $line = $raw.Trim()

        if (-not $line -or $line.StartsWith('#')) {
            continue
        }

        $parts = @($line -split '=', 2)

        if ($parts.Count -ne 2) {
            throw "Invalid line in seg.env (expected NAME=VALUE): $($parts[0])"
        }

        $name = $parts[0].Trim()

        if ($name -notmatch '^SEG_[A-Z0-9_]+$') {
            throw "Invalid parameter name in seg.env: '$name' (names start with SEG_)."
        }

        if ($result.ContainsKey($name)) {
            throw "Duplicate parameter in seg.env: $name"
        }

        $result[$name] = $parts[1].Trim()
    }

    return $result
}

function ConvertTo-Ipv4Number {
    param([string]$Address)

    $ip = $null

    if ($Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [System.Net.IPAddress]::TryParse($Address, [ref]$ip)) {
        return $null
    }

    $b = $ip.GetAddressBytes()

    return ([uint64]$b[0] * 16777216) + ([uint64]$b[1] * 65536) + ([uint64]$b[2] * 256) + [uint64]$b[3]
}

function ConvertFrom-Ipv4Number {
    param([uint64]$Number)

    return '{0}.{1}.{2}.{3}' -f [math]::Floor($Number / 16777216), ([math]::Floor($Number / 65536) % 256), ([math]::Floor($Number / 256) % 256), ($Number % 256)
}

function Get-Ipv4Range {
    # Returns @{ Start; End; Prefix } for 'a.b.c.d/N', or $null when invalid.
    param([string]$Cidr)

    if ($Cidr -notmatch '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') {
        return $null
    }

    $number = ConvertTo-Ipv4Number -Address $Matches[1]
    $prefix = [int]$Matches[2]

    if ($null -eq $number -or $prefix -gt 32) {
        return $null
    }

    $size = [uint64][math]::Pow(2, 32 - $prefix)
    $start = [uint64]([math]::Floor($number / $size) * $size)

    return @{ Start = $start; End = ($start + $size - 1); Prefix = $prefix }
}

function Get-SegBackhaulMtuLimit {
    # Largest inner MTU that keeps outer AmneziaWG packets below 1500 bytes:
    # 20 (IPv4) + 8 (UDP) + 32 (header) + S4 (data padding) + 480 (random trailer, measured on the prototype).
    param(
        [Parameter(Mandatory = $true)]
        [int]$S4,

        [Parameter(Mandatory = $true)]
        [string]$RandomTrailers
    )

    $limit = 1500 - 28 - 32 - $S4

    if ($RandomTrailers -eq 'on') {
        $limit -= 480
    }

    return $limit
}

function Get-SegReservedNetworks {
    # Networks the backhaul network must not overlap: the default VPN client network and,
    # when config\server.env exists, its WG_IPV4_NETWORK. Requires Read-EnvFile from common.ps1.
    param(
        [Parameter(Mandatory = $true)]
        [string]$VpnEnvFile
    )

    $networks = @('10.7.0.0/24')

    if (Test-Path -LiteralPath $VpnEnvFile) {
        $vpnNetwork = (Read-EnvFile -Path $VpnEnvFile)['WG_IPV4_NETWORK']

        if ($vpnNetwork -and $vpnNetwork -notin $networks) {
            $networks += $vpnNetwork
        }
    }

    return $networks
}

function Test-SegEnvironment {
    <#
        Validates the parsed seg.env. Collects all problems and throws one error listing them.
        Secret values are never included in the message.
        ReservedNetworks: networks the backhaul network must not overlap (for example the VPN client network).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Env,

        [Parameter(Mandatory = $false)]
        [string[]]$ReservedNetworks = @()
    )

    $problems = New-Object System.Collections.Generic.List[string]

    foreach ($name in $Env.Keys) {
        if ($name -notin $script:SegEnvKeys) {
            $problems.Add("Unknown parameter: $name")
        }
    }

    $present = @{}

    foreach ($name in $script:SegEnvKeys) {
        if (-not $Env.ContainsKey($name) -or [string]::IsNullOrWhiteSpace([string]$Env[$name])) {
            $problems.Add("$name is missing or empty")
        }
        else {
            $present[$name] = [string]$Env[$name]
        }
    }

    function Add-Problem([string]$name, [string]$text) {
        $shown = if ($name -in $script:SegSecretKeys) { '' } else { " (value: '$($present[$name])')" }
        $problems.Add("$name $text$shown")
    }

    function Get-IntValue([string]$name, [int]$min, [int]$max) {
        if (-not $present.ContainsKey($name)) { return $null }

        if ($present[$name] -notmatch '^\d{1,10}$' -or [int64]$present[$name] -lt $min -or [int64]$present[$name] -gt $max) {
            Add-Problem $name "must be an integer from $min to $max"
            return $null
        }

        return [int64]$present[$name]
    }

    # REALITY
    foreach ($name in @('SEG_REALITY_PRIVATE_KEY', 'SEG_REALITY_PUBLIC_KEY')) {
        if ($present.ContainsKey($name) -and $present[$name] -notmatch '^[A-Za-z0-9_-]{43}$') {
            Add-Problem $name 'must be a 43-character base64url key'
        }
    }

    if ($present.ContainsKey('SEG_REALITY_PRIVATE_KEY') -and $present.ContainsKey('SEG_REALITY_PUBLIC_KEY') -and $present['SEG_REALITY_PRIVATE_KEY'] -ceq $present['SEG_REALITY_PUBLIC_KEY']) {
        $problems.Add('SEG_REALITY_PRIVATE_KEY and SEG_REALITY_PUBLIC_KEY are equal')
    }

    if ($present.ContainsKey('SEG_REALITY_SHORT_ID') -and $present['SEG_REALITY_SHORT_ID'] -cnotmatch '^([0-9a-f]{2}){1,8}$') {
        Add-Problem 'SEG_REALITY_SHORT_ID' 'must be 2 to 16 lowercase hex digits (even count)'
    }

    if ($present.ContainsKey('SEG_REALITY_SERVER_NAME') -and $present['SEG_REALITY_SERVER_NAME'] -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$') {
        Add-Problem 'SEG_REALITY_SERVER_NAME' 'must be a domain name'
    }

    if ($present.ContainsKey('SEG_REALITY_DEST')) {
        if ($present['SEG_REALITY_DEST'] -notmatch '^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+):(\d{1,5})$' -or [int]$Matches[5] -lt 1 -or [int]$Matches[5] -gt 65535) {
            Add-Problem 'SEG_REALITY_DEST' 'must be host:port'
        }
    }

    if ($present.ContainsKey('SEG_REALITY_FLOW') -and $present['SEG_REALITY_FLOW'] -notin $script:SegRealityFlows) {
        Add-Problem 'SEG_REALITY_FLOW' "must be one of: $($script:SegRealityFlows -join ', ')"
    }

    if ($present.ContainsKey('SEG_REALITY_FINGERPRINT') -and $present['SEG_REALITY_FINGERPRINT'] -notin $script:SegRealityFingerprints) {
        Add-Problem 'SEG_REALITY_FINGERPRINT' "must be one of: $($script:SegRealityFingerprints -join ', ')"
    }

    # Backhaul keys
    $awgKeyNames = @('SEG_BACKHAUL_PRIVATE_KEY_VPS1', 'SEG_BACKHAUL_PUBLIC_KEY_VPS1', 'SEG_BACKHAUL_PRIVATE_KEY_VPS2', 'SEG_BACKHAUL_PUBLIC_KEY_VPS2', 'SEG_BACKHAUL_PSK')

    foreach ($name in $awgKeyNames) {
        if ($present.ContainsKey($name) -and $present[$name] -notmatch '^[A-Za-z0-9+/]{43}=$') {
            Add-Problem $name 'must be a 44-character base64 key'
        }
    }

    $awgValues = @($awgKeyNames | Where-Object { $present.ContainsKey($_) } | ForEach-Object { $present[$_] })

    if (@($awgValues | Select-Object -Unique).Count -ne $awgValues.Count) {
        $problems.Add('Backhaul keys and PSK must all be different from each other (do not reuse keys between the two sides or as PSK)')
    }

    # Backhaul network
    $range = $null

    if ($present.ContainsKey('SEG_BACKHAUL_NETWORK')) {
        $range = Get-Ipv4Range -Cidr $present['SEG_BACKHAUL_NETWORK']

        if ($null -eq $range -or $range.Prefix -ne 30) {
            Add-Problem 'SEG_BACKHAUL_NETWORK' 'must be an IPv4 /30 network (first version: one gateway and one exit)'
            $range = $null
        }
        elseif ($present['SEG_BACKHAUL_NETWORK'].Split('/')[0] -ne (ConvertFrom-Ipv4Number -Number $range.Start)) {
            Add-Problem 'SEG_BACKHAUL_NETWORK' 'must be written with the network address (host bits zero)'
            $range = $null
        }
        else {
            foreach ($reserved in $ReservedNetworks) {
                $other = Get-Ipv4Range -Cidr $reserved

                if ($null -ne $other -and $range.Start -le $other.End -and $other.Start -le $range.End) {
                    Add-Problem 'SEG_BACKHAUL_NETWORK' "overlaps the reserved network $reserved"
                }
            }
        }
    }

    $addresses = @{}

    foreach ($name in @('SEG_BACKHAUL_VPS1', 'SEG_BACKHAUL_VPS2')) {
        if (-not $present.ContainsKey($name)) { continue }

        $number = ConvertTo-Ipv4Number -Address $present[$name]

        if ($null -eq $number) {
            Add-Problem $name 'must be an IPv4 address'
        }
        elseif ($null -ne $range) {
            if ($number -le $range.Start -or $number -ge $range.End) {
                Add-Problem $name 'must be a host address inside SEG_BACKHAUL_NETWORK (not the network or broadcast address)'
            }
            else {
                $addresses[$name] = $number
            }
        }
    }

    if ($addresses.Count -eq 2 -and $addresses['SEG_BACKHAUL_VPS1'] -eq $addresses['SEG_BACKHAUL_VPS2']) {
        $problems.Add('SEG_BACKHAUL_VPS1 and SEG_BACKHAUL_VPS2 must be different')
    }

    [void](Get-IntValue 'SEG_BACKHAUL_PORT' 1 65535)

    if ($present.ContainsKey('SEG_BACKHAUL_INTERFACE')) {
        if ($present['SEG_BACKHAUL_INTERFACE'] -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,14}$') {
            Add-Problem 'SEG_BACKHAUL_INTERFACE' 'must be a valid interface name (up to 15 characters)'
        }
        elseif ($present['SEG_BACKHAUL_INTERFACE'] -in @('awg0', 'lo')) {
            Add-Problem 'SEG_BACKHAUL_INTERFACE' 'must not be awg0 (VPN mode) or lo'
        }
    }

    # AmneziaWG parameters (ranges follow generate-server-env.ps1)
    $randomTrailers = if ($present.ContainsKey('SEG_BACKHAUL_RANDOM_TRAILERS')) { $present['SEG_BACKHAUL_RANDOM_TRAILERS'] } else { $null }

    if ($null -ne $randomTrailers -and $randomTrailers -notin @('on', 'off')) {
        Add-Problem 'SEG_BACKHAUL_RANDOM_TRAILERS' 'must be on or off'
        $randomTrailers = $null
    }

    $jc = Get-IntValue 'SEG_BACKHAUL_JC' 1 128
    $jmin = Get-IntValue 'SEG_BACKHAUL_JMIN' 1 1280
    $jmax = Get-IntValue 'SEG_BACKHAUL_JMAX' 1 1280

    if ($null -ne $jmin -and $null -ne $jmax -and $jmin -gt $jmax) {
        $problems.Add('SEG_BACKHAUL_JMIN must not be greater than SEG_BACKHAUL_JMAX')
    }

    $s = @{}

    foreach ($i in 1..4) {
        $s[$i] = Get-IntValue "SEG_BACKHAUL_S$i" 15 150
    }

    $h = @()

    foreach ($i in 1..4) {
        $value = Get-IntValue "SEG_BACKHAUL_H$i" 5 2147483647

        if ($null -ne $value) { $h += $value }
    }

    if (@($h | Select-Object -Unique).Count -ne $h.Count) {
        $problems.Add('SEG_BACKHAUL_H1..H4 must be unique')
    }

    $mtu = Get-IntValue 'SEG_BACKHAUL_MTU' 576 1420

    if ($null -ne $mtu -and $null -ne $s[4] -and $null -ne $randomTrailers) {
        $limit = Get-SegBackhaulMtuLimit -S4 ([int]$s[4]) -RandomTrailers $randomTrailers

        if ($mtu -gt $limit) {
            $problems.Add("SEG_BACKHAUL_MTU $mtu exceeds $limit (S4=$($s[4]), RandomTrailers=$randomTrailers): outer packets would be fragmented (SEG.md, section 13)")
        }
    }

    # Marks
    $marks = @{}

    foreach ($name in @('SEG_MARK', 'SEG_UNMATCHED_MARK')) {
        if (-not $present.ContainsKey($name)) { continue }

        if ($present[$name] -notmatch '^0x[0-9a-fA-F]{1,8}$') {
            Add-Problem $name 'must be a hex number such as 0x5e90'
            continue
        }

        $value = [Convert]::ToInt64($present[$name].Substring(2), 16)

        if ($value -lt 0x1000 -or $value -in $script:SegReservedMarks) {
            Add-Problem $name 'must be at least 0x1000 and must not equal a reserved mark (AmneziaWG default 0xca6c)'
            continue
        }

        $marks[$name] = $value
    }

    if ($marks.Count -eq 2 -and $marks['SEG_MARK'] -eq $marks['SEG_UNMATCHED_MARK']) {
        $problems.Add('SEG_MARK and SEG_UNMATCHED_MARK must be different')
    }

    if ($present.ContainsKey('SEG_UNMATCHED_POLICY') -and $present['SEG_UNMATCHED_POLICY'] -notin $script:SegUnmatchedPolicies) {
        Add-Problem 'SEG_UNMATCHED_POLICY' "must be one of: $($script:SegUnmatchedPolicies -join ', ')"
    }

    if ($problems.Count -gt 0) {
        throw ("seg.env is invalid:`n  - " + ($problems -join "`n  - "))
    }
}
