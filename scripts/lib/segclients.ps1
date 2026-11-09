# SEG clients storage (SEG.md, section 20): clients\seg\<name>.json and generated profile metadata.
# Keep this file ASCII-only: .ps1 files are read by Windows PowerShell 5.1.

$script:SegClientFields = @('name', 'uuid', 'enabled', 'created')
$script:SegProfileMetaFields = @('segListVersion', 'segListSha256', 'serverConfigSha256', 'generatedAt')

# Names are used as file names (case-insensitive on Windows) and as sing-box user names.
$script:SegClientNamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
$script:WindowsReservedNames = @('con', 'prn', 'aux', 'nul', 'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9', 'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9')

function Test-SegClientName {
    # Returns $null when the name is acceptable, otherwise the reason.
    param(
        [AllowEmptyString()]
        [string]$Name
    )

    if ($Name -cnotmatch $script:SegClientNamePattern) {
        return 'must be 1 to 64 characters: letters, digits, dot, underscore, hyphen, starting with a letter or digit'
    }

    if ($Name.EndsWith('.')) {
        return 'must not end with a dot'
    }

    if ($Name -imatch '\.meta$') {
        return "must not end with '.meta' (it would collide with the profile metadata file of another client)"
    }

    if ($Name.Split('.')[0].ToLowerInvariant() -in $script:WindowsReservedNames) {
        return 'is a reserved Windows device name'
    }

    return $null
}

function Get-SegClientsDir {
    param([Parameter(Mandatory = $true)][string]$Root)

    return (Join-Path $Root 'clients\seg')
}

function Get-SegGeneratedDir {
    param([Parameter(Mandatory = $true)][string]$Root)

    return (Join-Path $Root 'clients\generated\seg')
}

function ConvertFrom-SegClientJson {
    <#
        Validates the text of one client record stored under the given file name.
        The UUID is a credential: it is never put into messages.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $false)]
        [string]$Path = ''
    )

    $leaf = $FileName
    $json = $null

    try {
        $json = $Text | ConvertFrom-Json
    }
    catch {
        throw "$leaf is not valid JSON: $($_.Exception.Message)"
    }

    if ($null -eq $json -or $json -isnot [System.Management.Automation.PSCustomObject]) {
        throw "$leaf must contain a JSON object."
    }

    $problems = New-Object System.Collections.Generic.List[string]
    $names = @($json.PSObject.Properties.Name)

    foreach ($field in $names) {
        if ($field -cnotin $script:SegClientFields) {
            $problems.Add("unknown field: $field")
        }
    }

    foreach ($field in $script:SegClientFields) {
        if ($names -cnotcontains $field) {
            $problems.Add("missing field: $field")
        }
    }

    $name = $null
    $uuid = $null
    $enabled = $null
    $created = $null

    if ($names -ccontains 'name') {
        $name = $json.name
        $reason = if ($name -is [string]) { Test-SegClientName -Name $name } else { 'must be a string' }

        if ($reason) {
            $problems.Add("name $reason")
        }
        elseif ($leaf -ine "$name.json") {
            $problems.Add("name '$name' does not match the file name $leaf")
        }
    }

    if ($names -ccontains 'uuid') {
        $uuid = $json.uuid

        if ($uuid -isnot [string] -or $uuid -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or $uuid -eq '00000000-0000-0000-0000-000000000000') {
            $problems.Add('uuid must be a lowercase UUID (8-4-4-4-12 hex digits) and not the nil UUID')
        }
    }

    if ($names -ccontains 'enabled') {
        if ($json.enabled -isnot [bool]) {
            $problems.Add('enabled must be true or false')
        }
        else {
            $enabled = [bool]$json.enabled
        }
    }

    if ($names -ccontains 'created') {
        $parsed = [datetimeoffset]::MinValue

        if ($json.created -isnot [string] -or -not [datetimeoffset]::TryParseExact($json.created, 'o', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            $problems.Add("created must be an ISO 8601 date with offset, for example 2026-11-09T14:30:00.0000000+03:00")
        }
        else {
            $created = $parsed
        }
    }

    if ($problems.Count -gt 0) {
        throw ("$leaf is invalid:`n  - " + ($problems -join "`n  - "))
    }

    return [pscustomobject]@{
        Name    = $name
        Uuid    = $uuid
        Enabled = $enabled
        Created = $created
        Path    = $Path
    }
}

function Read-SegClient {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (ConvertFrom-SegClientJson -Text ([System.IO.File]::ReadAllText($Path)) -FileName (Split-Path -Leaf $Path) -Path $Path)
}

function Read-SegClients {
    # Reads all clients; names are unique ignoring case, UUIDs are unique.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $dir = Get-SegClientsDir -Root $Root

    if (-not (Test-Path -LiteralPath $dir)) {
        return @()
    }

    $clients = @(
        Get-ChildItem -LiteralPath $dir -Filter '*.json' -File |
        Sort-Object Name |
        ForEach-Object { Read-SegClient -Path $_.FullName }
    )

    $duplicateUuids = @($clients | Group-Object Uuid | Where-Object { $_.Count -gt 1 })

    if ($duplicateUuids.Count -gt 0) {
        $names = @($duplicateUuids | ForEach-Object { ($_.Group | ForEach-Object { $_.Name }) -join ' and ' })
        throw "Clients share a UUID (each client needs its own): $($names -join '; ')"
    }

    $duplicateNames = @($clients | Group-Object { $_.Name.ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })

    if ($duplicateNames.Count -gt 0) {
        throw "Client names must differ ignoring case: $(($duplicateNames | ForEach-Object { $_.Name }) -join ', ')"
    }

    return $clients
}

function New-SegClient {
    # Builds a new enabled client record with a random UUID; the file is written by Save-SegClient.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $reason = Test-SegClientName -Name $Name

    if ($reason) {
        throw "Invalid client name '$Name': $reason"
    }

    return [pscustomobject]@{
        Name    = $Name
        Uuid    = [guid]::NewGuid().ToString().ToLowerInvariant()
        Enabled = $true
        Created = [datetimeoffset]::Now
        Path    = $null
    }
}

function Save-SegClient {
    # Writes clients\seg\<name>.json (UTF-8 without BOM, LF). Refuses to overwrite unless -Overwrite is given.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        $Client,

        [switch]$Overwrite
    )

    $dir = Get-SegClientsDir -Root $Root
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $path = Join-Path $dir "$($Client.Name).json"

    if ((Test-Path -LiteralPath $path) -and -not $Overwrite) {
        throw "SEG client already exists: $path"
    }

    $text = @(
        '{',
        ('  "name": "{0}",' -f $Client.Name),
        ('  "uuid": "{0}",' -f $Client.Uuid),
        ('  "enabled": {0},' -f $(if ($Client.Enabled) { 'true' } else { 'false' })),
        ('  "created": "{0}"' -f $Client.Created.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)),
        '}'
    ) -join "`n"

    $temp = "$path.$([guid]::NewGuid().ToString('N')).tmp"

    try {
        # The record is validated against its final file name before anything is written.
        [void](ConvertFrom-SegClientJson -Text $text -FileName "$($Client.Name).json")

        [System.IO.File]::WriteAllText($temp, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $path -Force
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }

    return $path
}

function ConvertTo-SegVlessUsersJson {
    # sing-box VLESS users for VPS2: enabled clients only, sorted by name (stable output).
    # An empty result is valid: sing-box starts and nobody can connect.
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Clients,

        [Parameter(Mandatory = $true)]
        [string]$Flow
    )

    $users = @(
        $Clients |
        Where-Object { $_.Enabled } |
        Sort-Object { $_.Name.ToLowerInvariant() } |
        ForEach-Object { '{ "name": "' + $_.Name + '", "uuid": "' + $_.Uuid + '", "flow": "' + $Flow + '" }' }
    )

    return ($users -join ', ')
}

function Get-SegConnectionSha256 {
    <#
        SHA-256 of the parameters a client profile needs to connect: VPS2 address and port, REALITY server name,
        public key and short id, flow and fingerprint. It changes when the profile must be recreated and does not
        change when a client is added or removed (the user list is not part of it).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Vps2Ip,

        [Parameter(Mandatory = $true)]
        [string]$Port,

        [Parameter(Mandatory = $true)]
        [hashtable]$Env
    )

    $text = @(
        "host=$Vps2Ip",
        "port=$Port",
        "server_name=$($Env['SEG_REALITY_SERVER_NAME'])",
        "public_key=$($Env['SEG_REALITY_PUBLIC_KEY'])",
        "short_id=$($Env['SEG_REALITY_SHORT_ID'])",
        "flow=$($Env['SEG_REALITY_FLOW'])",
        "fingerprint=$($Env['SEG_REALITY_FINGERPRINT'])"
    ) -join "`n"

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        return (($sha.ComputeHash((New-Object System.Text.UTF8Encoding($false)).GetBytes($text + "`n")) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha.Dispose()
    }
}

function Get-SegProfilePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $dir = Get-SegGeneratedDir -Root $Root

    return [pscustomobject]@{
        Profile = (Join-Path $dir "$Name.json")
        Meta    = (Join-Path $dir "$Name.meta.json")
    }
}

function Save-SegProfileMeta {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$SegListVersion,

        [Parameter(Mandatory = $true)]
        [string]$SegListSha256,

        [Parameter(Mandatory = $true)]
        [string]$ServerConfigSha256
    )

    foreach ($value in @($SegListSha256, $ServerConfigSha256)) {
        if ($value -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Profile metadata hashes must be 64 lowercase hex digits.'
        }
    }

    if ($SegListVersion -lt 1) {
        throw 'segListVersion must be at least 1.'
    }

    $dir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $text = @(
        '{',
        ('  "segListVersion": {0},' -f $SegListVersion),
        ('  "segListSha256": "{0}",' -f $SegListSha256),
        ('  "serverConfigSha256": "{0}",' -f $ServerConfigSha256),
        ('  "generatedAt": "{0}"' -f ([datetimeoffset]::Now).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)),
        '}'
    ) -join "`n"

    [System.IO.File]::WriteAllText($Path, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Read-SegProfileMeta {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $leaf = Split-Path -Leaf $Path
    $json = $null

    try {
        $json = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    }
    catch {
        throw "$leaf is not valid JSON: $($_.Exception.Message)"
    }

    if ($null -eq $json -or $json -isnot [System.Management.Automation.PSCustomObject]) {
        throw "$leaf must contain a JSON object."
    }

    $problems = New-Object System.Collections.Generic.List[string]
    $names = @($json.PSObject.Properties.Name)

    foreach ($field in $names) {
        if ($field -cnotin $script:SegProfileMetaFields) {
            $problems.Add("unknown field: $field")
        }
    }

    foreach ($field in $script:SegProfileMetaFields) {
        if ($names -cnotcontains $field) {
            $problems.Add("missing field: $field")
        }
    }

    if ($names -ccontains 'segListVersion' -and ($json.segListVersion -isnot [int] -or $json.segListVersion -lt 1)) {
        $problems.Add('segListVersion must be an integer not less than 1')
    }

    foreach ($field in @('segListSha256', 'serverConfigSha256')) {
        if ($names -ccontains $field -and ($json.$field -isnot [string] -or $json.$field -cnotmatch '^[0-9a-f]{64}$')) {
            $problems.Add("$field must be 64 lowercase hex digits")
        }
    }

    $generated = [datetimeoffset]::MinValue

    if ($names -ccontains 'generatedAt' -and ($json.generatedAt -isnot [string] -or -not [datetimeoffset]::TryParseExact($json.generatedAt, 'o', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$generated))) {
        $problems.Add('generatedAt must be an ISO 8601 date with offset')
    }

    if ($problems.Count -gt 0) {
        throw ("$leaf is invalid:`n  - " + ($problems -join "`n  - "))
    }

    return [pscustomobject]@{
        SegListVersion     = [int]$json.segListVersion
        SegListSha256      = [string]$json.segListSha256
        ServerConfigSha256 = [string]$json.serverConfigSha256
        GeneratedAt        = $generated
    }
}

function Get-SegProfileStatus {
    <#
        State of the generated profile of one client against the current seg-list.json and the connection
        parameters of seg.env / servers.txt:
          CURRENT   the profile was built from the current list and connection parameters
          STALE     built from another list version or other connection parameters (Reasons tells which)
          MISSING   no profile has been generated yet
          BROKEN    the profile or its metadata is missing or unreadable
          DISABLED  the client is disabled: no profile is needed
        A stale list does not break a client: VPS2 applies the current seg-list on its own; a changed
        connection parameter (address, port, REALITY keys, flow, fingerprint) does.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        $Client,

        [Parameter(Mandatory = $true)]
        $SegList,

        [Parameter(Mandatory = $true)]
        [hashtable]$Env,

        [Parameter(Mandatory = $true)]
        $Gateway
    )

    $paths = Get-SegProfilePaths -Root $Root -Name $Client.Name
    $result = [pscustomobject]@{ Name = $Client.Name; State = 'CURRENT'; Reasons = @(); Profile = $paths.Profile; Meta = $paths.Meta }

    if (-not $Client.Enabled) {
        $result.State = 'DISABLED'
        return $result
    }

    $hasProfile = Test-Path -LiteralPath $paths.Profile
    $hasMeta = Test-Path -LiteralPath $paths.Meta

    if (-not $hasProfile -and -not $hasMeta) {
        $result.State = 'MISSING'
        $result.Reasons = @('the profile has not been generated')
        return $result
    }

    if (-not $hasProfile) {
        $result.State = 'BROKEN'
        $result.Reasons = @('the profile file is missing, only its metadata exists')
        return $result
    }

    if (-not $hasMeta) {
        $result.State = 'BROKEN'
        $result.Reasons = @('the metadata file is missing: the version of the profile is unknown')
        return $result
    }

    $meta = $null

    try {
        $meta = Read-SegProfileMeta -Path $paths.Meta
    }
    catch {
        $result.State = 'BROKEN'
        $result.Reasons = @($_.Exception.Message -replace '\s*\r?\n\s*', ' ')
        return $result
    }

    $reasons = @()

    if ($meta.SegListSha256 -ne $SegList.Sha256) {
        $text = "seg-list.json changed (profile: version $($meta.SegListVersion), current: version $($SegList.Version))"

        if ($meta.SegListVersion -eq $SegList.Version) {
            $text += '; the content changed but the version did not: increase "version" in seg-list.json when you change the list'
        }

        $reasons += $text
    }

    $connection = Get-SegConnectionSha256 -Vps2Ip ([string]$Gateway.IP) -Port ([string]$Gateway.Port) -Env $Env

    if ($meta.ServerConfigSha256 -ne $connection) {
        $reasons += 'the connection parameters changed (address, port or REALITY/flow/fingerprint settings)'
    }

    if ($reasons.Count -gt 0) {
        $result.State = 'STALE'
        $result.Reasons = $reasons
    }

    return $result
}

function Get-SegProfileOrphans {
    # Names of generated profiles (and metadata files) that no client record belongs to.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Clients
    )

    $dir = Get-SegGeneratedDir -Root $Root

    if (-not (Test-Path -LiteralPath $dir)) {
        return @()
    }

    $known = @($Clients | ForEach-Object { $_.Name.ToLowerInvariant() })

    $names = @(
        Get-ChildItem -LiteralPath $dir -Filter '*.json' -File |
        ForEach-Object { $_.Name -replace '\.meta\.json$', '' -replace '\.json$', '' } |
        Sort-Object -Unique |
        Where-Object { $known -notcontains $_.ToLowerInvariant() }
    )

    return $names
}
