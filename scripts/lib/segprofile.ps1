# Client profile of SEG mode: rendering, structural verification and sing-box check (roadmap, items 21 and 25).
# Keep this file ASCII-only: .ps1 files are read by Windows PowerShell 5.1.
# Requires common.ps1, segenv.ps1, seglist.ps1 (dot-sourced by the caller).

function Get-SegClientProfileValues {
    # Template values of the client profile for one client. Secrets stay in the values only; they are
    # never logged. Gateway and Exit are the seg-gateway and seg-exit rows of servers.txt.
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Env,

        [Parameter(Mandatory = $true)]
        $SegList,

        [Parameter(Mandatory = $true)]
        $Client,

        [Parameter(Mandatory = $true)]
        $Gateway
    )

    $values = @{}

    foreach ($key in $Env.Keys) {
        $values[$key] = $Env[$key]
    }

    $fragments = Get-SegRuleSetFragments -SegList $SegList

    foreach ($key in $fragments.Keys) {
        $values[$key] = $fragments[$key]
    }

    $values['VPS2_PUBLIC_IP'] = [string]$Gateway.IP
    $values['SEG_VLESS_PORT'] = [string]$Gateway.Port
    $values['SEG_CLIENT_UUID'] = [string]$Client.Uuid

    return $values
}

function New-SegClientProfileText {
    # Renders seg\templates\sing-box-client-tun.json.template (LF line endings) and checks that it is valid JSON.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [hashtable]$Env,

        [Parameter(Mandatory = $true)]
        $SegList,

        [Parameter(Mandatory = $true)]
        $Client,

        [Parameter(Mandatory = $true)]
        $Gateway
    )

    $template = [System.IO.File]::ReadAllText((Join-Path $Root 'seg\templates\sing-box-client-tun.json.template'))
    $values = Get-SegClientProfileValues -Env $Env -SegList $SegList -Client $Client -Gateway $Gateway
    $text = (Convert-Template -Template $template -Values $values) -replace "`r`n", "`n" -replace "`r", "`n"

    try {
        [void]($text | ConvertFrom-Json)
    }
    catch {
        throw "The rendered client profile is not valid JSON: $($_.Exception.Message)"
    }

    return $text
}

function Test-SegAddressInCidrs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Cidrs
    )

    $number = ConvertTo-Ipv4Number -Address $Address

    if ($null -eq $number) {
        return $false
    }

    foreach ($cidr in $Cidrs) {
        $range = Get-Ipv4Range -Cidr $cidr

        if ($range -and $number -ge $range.Start -and $number -le $range.End) {
            return $true
        }
    }

    return $false
}

function Test-SegClientProfile {
    <#
        Structural check of a rendered profile against the client rules (roadmap, item 21). Collects all problems
        and throws one error; returns nothing when the profile is correct. The addresses of both VPS must not be
        in seg-list: the client would send the management traffic (SSH) to the gateway through its own tunnel.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [hashtable]$Env,

        [Parameter(Mandatory = $true)]
        $SegList,

        [Parameter(Mandatory = $true)]
        $Client,

        [Parameter(Mandatory = $true)]
        $Gateway,

        [Parameter(Mandatory = $true)]
        $Exit
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $parsed = $Text | ConvertFrom-Json

    # Optional JSON properties are absent in many rules: reading a missing property must give $null.
    Set-StrictMode -Version 1
    foreach ($server in @($Gateway, $Exit)) {
        if (Test-SegAddressInCidrs -Address ([string]$server.IP) -Cidrs @($SegList.Cidrs)) {
            $problems.Add("The address $($server.IP) of $($server.Name) is inside a seg-list CIDR: management traffic would enter the tunnel.")
        }
    }

    # Inbound: one TUN with strict routing
    $tun = @($parsed.inbounds | Where-Object { $_.type -eq 'tun' })

    if ($tun.Count -ne 1) {
        $problems.Add('Exactly one tun inbound is required.')
    }
    else {
        if (-not $tun[0].auto_route) { $problems.Add('The tun inbound must use auto_route.') }
        if (-not $tun[0].strict_route) { $problems.Add('The tun inbound must use strict_route.') }
    }

    # Outbounds: VLESS/REALITY to the gateway with the client values, and direct
    $vless = @($parsed.outbounds | Where-Object { $_.type -eq 'vless' })

    if ($vless.Count -ne 1 -or $vless[0].tag -ne 'seg') {
        $problems.Add('Exactly one vless outbound with the tag seg is required.')
    }
    else {
        $out = $vless[0]

        if ($out.server -ne [string]$Gateway.IP) { $problems.Add('The vless server is not the seg-gateway address.') }
        if ([string]$out.server_port -ne [string]$Gateway.Port) { $problems.Add('The vless port is not the seg-gateway port.') }
        if ($out.uuid -ne [string]$Client.Uuid) { $problems.Add('The vless uuid is not the client uuid.') }
        if ($out.flow -ne $Env['SEG_REALITY_FLOW']) { $problems.Add('The vless flow differs from seg.env.') }
        if (-not $out.tls.enabled -or -not $out.tls.reality.enabled) { $problems.Add('TLS with REALITY must be enabled.') }
        if ($out.tls.server_name -ne $Env['SEG_REALITY_SERVER_NAME']) { $problems.Add('The REALITY server_name differs from seg.env.') }
        if ($out.tls.reality.public_key -ne $Env['SEG_REALITY_PUBLIC_KEY']) { $problems.Add('The REALITY public key differs from seg.env.') }
        if ($out.tls.reality.short_id -ne $Env['SEG_REALITY_SHORT_ID']) { $problems.Add('The REALITY short id differs from seg.env.') }
        if (-not $out.tls.utls.enabled -or $out.tls.utls.fingerprint -ne $Env['SEG_REALITY_FINGERPRINT']) { $problems.Add('The uTLS fingerprint differs from seg.env.') }
    }

    if (@($parsed.outbounds | Where-Object { $_.type -eq 'direct' -and $_.tag -eq 'direct' }).Count -ne 1) {
        $problems.Add('Exactly one direct outbound with the tag direct is required.')
    }

    # Route
    $route = $parsed.route

    if ($route.final -ne 'direct') { $problems.Add('route.final must be direct (traffic outside seg-list goes directly).') }
    if (-not $route.auto_detect_interface) { $problems.Add('route.auto_detect_interface must be on: the connection to the gateway must not enter the own TUN.') }

    $rules = @($route.rules)

    if ($rules.Count -lt 5) {
        $problems.Add('The route rules are incomplete.')
    }
    else {
        if ($rules[0].action -ne 'sniff') { $problems.Add('The first route rule must be sniff.') }

        $hijack = @($rules | Where-Object { $_.action -eq 'hijack-dns' -and $_.protocol -eq 'dns' })
        if ($hijack.Count -ne 1) { $problems.Add('A hijack-dns rule for the dns protocol is required.') }

        $privateIndex = -1
        $quicIndex = -1
        $selectedIndex = -1

        for ($i = 0; $i -lt $rules.Count; $i++) {
            if ($rules[$i].ip_is_private -and $rules[$i].outbound -eq 'direct') { $privateIndex = $i }
            if ($rules[$i].action -eq 'reject' -and $rules[$i].network -eq 'udp' -and [string]$rules[$i].port -eq '443') { $quicIndex = $i }
            if ($rules[$i].outbound -eq 'seg' -and $rules[$i].rule_set) { $selectedIndex = $i }
        }

        if ($privateIndex -lt 0) { $problems.Add('Private addresses must go directly.') }
        if ($quicIndex -lt 0) { $problems.Add('QUIC (udp/443) to seg-list must be rejected.') }
        if ($selectedIndex -lt 0) { $problems.Add('A rule that sends seg-list to the seg outbound is required.') }

        if ($quicIndex -ge 0 -and $selectedIndex -ge 0 -and $quicIndex -gt $selectedIndex) { $problems.Add('The QUIC reject rule must precede the selected rule.') }
        if ($privateIndex -ge 0 -and $selectedIndex -ge 0 -and $privateIndex -gt $selectedIndex) { $problems.Add('The private-address rule must precede the selected rule.') }

        if ($selectedIndex -ge 0) {
            $expected = @('seg-domains')
            if (@($SegList.Cidrs).Count -gt 0) { $expected += 'seg-cidrs' }

            if ((@($rules[$selectedIndex].rule_set) -join ',') -ne ($expected -join ',')) {
                $problems.Add('The selected rule must use exactly the seg-list rule sets.')
            }
        }
    }

    $setTags = @($route.rule_set | ForEach-Object { $_.tag })

    if ($setTags -notcontains 'seg-domains') { $problems.Add('The rule set seg-domains is missing.') }
    if (@($SegList.Cidrs).Count -gt 0 -and $setTags -notcontains 'seg-cidrs') { $problems.Add('The rule set seg-cidrs is missing.') }

    # DNS: selected domains get FakeIP, direct DNS is DoH/DoT only (port 53 is blocked by strict_route)
    $dns = $parsed.dns
    $fake = @($dns.servers | Where-Object { $_.type -eq 'fakeip' })

    if ($fake.Count -ne 1 -or $fake[0].inet4_range -ne '198.18.0.0/15') { $problems.Add('One FakeIP server with the range 198.18.0.0/15 is required.') }

    foreach ($server in @($dns.servers)) {
        if ($server.type -notin @('fakeip', 'https', 'tls', 'quic', 'h3')) {
            $problems.Add("DNS server $($server.tag) has the type $($server.type): only FakeIP and encrypted DNS (DoH, DoT) work with strict_route.")
        }
    }

    $directDns = @($dns.servers | Where-Object { $_.tag -eq $dns.final })

    if ($directDns.Count -ne 1 -or $directDns[0].type -notin @('https', 'tls', 'quic', 'h3')) { $problems.Add('dns.final must be an encrypted direct DNS server.') }

    $fakeRule = @($dns.rules | Where-Object { $_.server -eq 'dns-fakeip' })

    if ($fakeRule.Count -ne 1 -or (@($fakeRule[0].rule_set) -join ',') -ne 'seg-domains') { $problems.Add('Selected domains must be routed to FakeIP by the seg-domains rule set only.') }

    if ($problems.Count -gt 0) {
        throw "Client profile problems:`n  - $($problems -join "`n  - ")"
    }
}

function Invoke-SingBoxClientCheck {
    # Runs "sing-box check" (the local, verified Windows binary) on the profile text; throws with its output on failure.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $exe = Resolve-SingBoxExecutable -Root $Root -RequiredVersion $script:SegSingBoxVersion
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('seg-profile-' + [guid]::NewGuid().ToString('N') + '.json')

    try {
        [System.IO.File]::WriteAllText($path, $Text, (New-Object System.Text.UTF8Encoding($false)))

        $previousErrorActionPreference = $ErrorActionPreference

        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& $exe check -c $path 2>&1 | ForEach-Object { [string]$_ })
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($code -ne 0) {
            throw "sing-box check rejected the client profile: $($output -join ' ')"
        }
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}
