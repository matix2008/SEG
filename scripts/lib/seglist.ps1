# seg-list.json loader, validator and sing-box rule_set generator (SEG.md, section 7).
# Keep this file ASCII-only: .ps1 files are read by Windows PowerShell 5.1.

. (Join-Path $PSScriptRoot 'segenv.ps1')

$script:SegListTopFields = @('version', 'groups')
$script:SegListGroupFields = @('name', 'title', 'enabled', 'domains', 'domain_suffixes', 'cidrs', 'sources')

# Selected CIDRs must not cover private or reserved space (VPS2 and VPS1 block it) or the client FakeIP range.
$script:SegListReservedCidrs = @(
    '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
    '172.16.0.0/12', '192.0.0.0/24', '192.168.0.0/16', '198.18.0.0/15', '224.0.0.0/3'
)

$script:DomainPattern = '^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z][a-z0-9-]{0,61}[a-z0-9]|[a-z])$'

function Get-SegListSha256 {
    # SHA-256 of the content with a BOM removed and line endings normalized to LF,
    # so the value does not depend on how git checked the file out.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $text = [System.IO.File]::ReadAllText($Path)
    $text = $text -replace "`r`n", "`n" -replace "`r", "`n"
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($text)

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha.Dispose()
    }
}

function Read-SegList {
    <#
        Reads and validates config/seg-list.json. Collects all problems and throws one error.
        Returns Version, Sha256, Groups, the lists of the enabled groups (Domains, DomainSuffixes, Cidrs,
        de-duplicated, in file order) and the names of the enabled groups.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $json = $null

    try {
        $json = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    }
    catch {
        throw "seg-list.json is not valid JSON: $($_.Exception.Message)"
    }

    $problems = New-Object System.Collections.Generic.List[string]

    if ($null -eq $json -or $json -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'seg-list.json must contain a JSON object.'
    }

    $topNames = @($json.PSObject.Properties.Name)

    foreach ($name in $topNames) {
        if ($name -cnotin $script:SegListTopFields) {
            $problems.Add("Unknown top-level field: $name")
        }
    }

    $version = $null

    if ($topNames -cnotcontains 'version' -or ($json.version -isnot [int] -and $json.version -isnot [long]) -or $json.version -lt 1) {
        $problems.Add('version must be an integer not less than 1')
    }
    else {
        $version = [int64]$json.version
    }

    $groups = @()

    if ($topNames -cnotcontains 'groups' -or $json.groups -isnot [System.Array] -or @($json.groups).Count -eq 0) {
        $problems.Add('groups must be a non-empty array')
    }
    else {
        $groups = @($json.groups)
    }

    $reserved = @($script:SegListReservedCidrs | ForEach-Object { Get-Ipv4Range -Cidr $_ })
    $seenNames = @{}
    $parsedGroups = @()

    $index = 0

    foreach ($group in $groups) {
        $index++
        $label = "groups[$index]"

        if ($group -isnot [System.Management.Automation.PSCustomObject]) {
            $problems.Add("$label must be an object")
            continue
        }

        $fields = @($group.PSObject.Properties.Name)

        foreach ($field in $fields) {
            if ($field -cnotin $script:SegListGroupFields) {
                $problems.Add("$label has an unknown field: $field")
            }
        }

        $name = $null

        if ($fields -cnotcontains 'name' -or $group.name -isnot [string] -or $group.name -cnotmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$') {
            $problems.Add("$label name must be a lowercase identifier (letters, digits, hyphen)")
        }
        else {
            $name = $group.name
            $label = "group '$name'"

            if ($seenNames.ContainsKey($name)) {
                $problems.Add("Duplicate group name: $name")
            }

            $seenNames[$name] = $true
        }

        if ($fields -cnotcontains 'title' -or $group.title -isnot [string] -or [string]::IsNullOrWhiteSpace($group.title)) {
            $problems.Add("$label title must be a non-empty string")
        }

        $enabled = $true

        if ($fields -ccontains 'enabled') {
            if ($group.enabled -isnot [bool]) {
                $problems.Add("$label enabled must be true or false")
            }
            else {
                $enabled = [bool]$group.enabled
            }
        }

        $lists = @{}

        foreach ($field in @('domains', 'domain_suffixes', 'cidrs', 'sources')) {
            $lists[$field] = @()

            if ($fields -cnotcontains $field) {
                continue
            }

            $value = $group.$field

            if ($null -eq $value) {
                $value = @()
            }

            if ($value -isnot [System.Array] -and @($value).Count -gt 0) {
                $problems.Add("$label $field must be an array of strings")
                continue
            }

            $items = @($value)
            $bad = @($items | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) })

            if ($bad.Count -gt 0) {
                $problems.Add("$label $field must contain non-empty strings only")
                continue
            }

            if (@($items | Select-Object -Unique).Count -ne $items.Count) {
                $problems.Add("$label $field contains duplicates")
            }

            $lists[$field] = $items
        }

        foreach ($field in @('domains', 'domain_suffixes')) {
            foreach ($item in $lists[$field]) {
                if ($item -cnotmatch $script:DomainPattern) {
                    $problems.Add("$label $field has an invalid domain: '$item' (lowercase host name, no leading dot, no wildcard)")
                }
            }
        }

        foreach ($item in $lists['cidrs']) {
            $range = Get-Ipv4Range -Cidr $item

            if ($null -eq $range -or $range.Prefix -lt 8) {
                $problems.Add("$label cidrs has an invalid IPv4 CIDR: '$item' (prefix 8 to 32; IPv6 is not supported in the first version)")
                continue
            }

            if ($item.Split('/')[0] -ne (ConvertFrom-Ipv4Number -Number $range.Start)) {
                $problems.Add("$label cidrs: '$item' has host bits set (use the network address)")
                continue
            }

            foreach ($block in $reserved) {
                if ($range.Start -le $block.End -and $block.Start -le $range.End) {
                    $problems.Add("$label cidrs: '$item' overlaps private or reserved address space")
                    break
                }
            }
        }

        if ($enabled -and ($lists['domains'].Count + $lists['domain_suffixes'].Count + $lists['cidrs'].Count) -eq 0) {
            $problems.Add("$label is enabled but has no domains, domain_suffixes or cidrs")
        }

        $parsedGroups += [pscustomobject]@{
            Name           = $name
            Title          = $(if ($fields -ccontains 'title') { [string]$group.title } else { '' })
            Enabled        = $enabled
            Domains        = $lists['domains']
            DomainSuffixes = $lists['domain_suffixes']
            Cidrs          = $lists['cidrs']
            Sources        = $lists['sources']
        }
    }

    $enabledGroups = @($parsedGroups | Where-Object { $_.Enabled })

    function Merge-Unique([string]$field) {
        $seen = @{}
        $result = New-Object System.Collections.Generic.List[string]

        foreach ($g in $enabledGroups) {
            foreach ($item in $g.$field) {
                if (-not $seen.ContainsKey($item)) {
                    $seen[$item] = $true
                    $result.Add($item)
                }
            }
        }

        return @($result)
    }

    $domains = @(Merge-Unique 'Domains')
    $suffixes = @(Merge-Unique 'DomainSuffixes')
    $cidrs = @(Merge-Unique 'Cidrs')

    if ($problems.Count -eq 0 -and ($domains.Count + $suffixes.Count) -eq 0) {
        $problems.Add('Enabled groups contain no domains or domain_suffixes: DNS rules need at least one')
    }

    if ($problems.Count -gt 0) {
        throw ("seg-list.json is invalid:`n  - " + ($problems -join "`n  - "))
    }

    return [pscustomobject]@{
        Version        = $version
        Sha256         = (Get-SegListSha256 -Path $Path)
        Groups         = $parsedGroups
        EnabledGroups  = @($enabledGroups | ForEach-Object { $_.Name })
        Domains        = $domains
        DomainSuffixes = $suffixes
        Cidrs          = $cidrs
    }
}

function ConvertTo-JsonStringList {
    # The validator guarantees that items contain no characters that need JSON escaping.
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Items
    )

    return (($Items | ForEach-Object { '"' + $_ + '"' }) -join ', ')
}

function Get-SegRuleSetFragments {
    <#
        Builds the JSON fragments substituted into the sing-box templates:
          SEG_RULE_SETS_JSON           inline rule_set objects (seg-domains, and seg-cidrs when there are CIDRs)
          SEG_DOMAIN_RULE_SETS_JSON    tags used by DNS rules and the client QUIC rule (domains only)
          SEG_ROUTE_RULE_SETS_JSON     tags used by routing rules (domains and CIDRs)
          SEG_POST_RESOLVE_RULES_JSON  server only: CIDR rule after the resolve action (empty without CIDRs)
        Domains and CIDRs are kept in separate rule sets: IP rules do not belong in DNS rules.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $SegList
    )

    $domainRules = @()

    if ($SegList.Domains.Count -gt 0) {
        $domainRules += '{ "domain": [' + (ConvertTo-JsonStringList -Items $SegList.Domains) + '] }'
    }

    if ($SegList.DomainSuffixes.Count -gt 0) {
        $domainRules += '{ "domain_suffix": [' + (ConvertTo-JsonStringList -Items $SegList.DomainSuffixes) + '] }'
    }

    $ruleSets = @('{ "type": "inline", "tag": "seg-domains", "rules": [ ' + ($domainRules -join ', ') + ' ] }')
    $routeTags = @('"seg-domains"')
    $postResolve = ''

    if ($SegList.Cidrs.Count -gt 0) {
        $ruleSets += '{ "type": "inline", "tag": "seg-cidrs", "rules": [ { "ip_cidr": [' + (ConvertTo-JsonStringList -Items $SegList.Cidrs) + '] } ] }'
        $routeTags += '"seg-cidrs"'
        $postResolve = ', { "rule_set": ["seg-cidrs"], "outbound": "seg-out" }'
    }

    return @{
        SEG_RULE_SETS_JSON          = ($ruleSets -join ', ')
        SEG_DOMAIN_RULE_SETS_JSON   = '"seg-domains"'
        SEG_ROUTE_RULE_SETS_JSON    = ($routeTags -join ', ')
        SEG_POST_RESOLVE_RULES_JSON = $postResolve
    }
}
