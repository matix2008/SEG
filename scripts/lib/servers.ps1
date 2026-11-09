# Shared servers.txt loader for VPN and SEG modes (SEG.md, section 4).
# Keep this file ASCII-only: .ps1 files are read by Windows PowerShell 5.1.

$script:ServerRoles = @('vpn-server', 'seg-gateway', 'seg-exit')

# Types implemented per role. Extend a list when a new VPN or backhaul type is supported.
$script:ServerTypesByRole = @{
    'vpn-server'  = @('amnezia')
    'seg-gateway' = @('amnezia')
    'seg-exit'    = @('amnezia')
}

# Roles that accept exactly one Type value; seg-gateway accepts a comma-separated list.
$script:SingleTypeRoles = @('vpn-server', 'seg-exit')

function Test-ServerPortValue {
    param(
        [AllowEmptyString()]
        [string]$Port
    )

    return ($Port -match '^\d{1,5}$' -and [int]$Port -ge 1 -and [int]$Port -le 65535)
}

function Read-ServersFile {
    <#
        Reads and validates servers.txt.
        Returns an object with Format ('current' or 'legacy') and Servers.
        The legacy format (Name;IP;Port;Enabled) is read as Role = vpn-server, Type = amnezia.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $rows = @(Import-Csv -LiteralPath $Path -Delimiter ';')

    if ($rows.Count -eq 0) {
        throw 'servers.txt contains no servers.'
    }

    $columns = @($rows[0].PSObject.Properties.Name)

    foreach ($required in @('Name', 'IP', 'Port', 'Enabled')) {
        if ($columns -notcontains $required) {
            throw "servers.txt has no '$required' column. Expected 'Name;IP;Port;Role;Type;Enabled' or the legacy 'Name;IP;Port;Enabled'."
        }
    }

    $hasRole = $columns -contains 'Role'
    $hasType = $columns -contains 'Type'

    if ($hasRole -ne $hasType) {
        throw "servers.txt must have both 'Role' and 'Type' columns, or neither (legacy format)."
    }

    $format = if ($hasRole) { 'current' } else { 'legacy' }

    $servers = @(
        foreach ($row in $rows) {
            if ($format -eq 'current') {
                $role = ([string]$row.Role).Trim().ToLowerInvariant()
                $typeText = ([string]$row.Type).Trim().ToLowerInvariant()
            }
            else {
                $role = 'vpn-server'
                $typeText = 'amnezia'
            }

            $enabledText = ([string]$row.Enabled).Trim().ToLowerInvariant()

            [pscustomobject]@{
                Name      = [string]$row.Name
                IP        = [string]$row.IP
                Port      = [string]$row.Port
                Role      = $role
                Type      = $typeText
                Types     = @(if ($typeText) { $typeText -split ',' } else { @() })
                Enabled   = [string]$row.Enabled
                IsEnabled = ($enabledText -eq 'true')
            }
        }
    )

    foreach ($item in $servers) {
        if ([string]::IsNullOrWhiteSpace($item.Name)) {
            throw 'servers.txt contains a server with an empty Name.'
        }

        if ([string]::IsNullOrWhiteSpace($item.IP)) {
            throw "servers.txt contains an empty IP for server $($item.Name)."
        }
    }

    $duplicateNames = @($servers | Group-Object Name | Where-Object { $_.Count -gt 1 })

    if ($duplicateNames.Count -gt 0) {
        throw "Duplicate server Name values in servers.txt: $($duplicateNames.Name -join ', ')"
    }

    foreach ($item in $servers) {
        $enabledValue = $item.Enabled.Trim().ToLowerInvariant()

        if ($enabledValue -notin @('true', 'false')) {
            throw "Enabled must be true or false for server $($item.Name); found '$($item.Enabled)'"
        }
    }

    foreach ($item in $servers) {
        if ($item.Role -notin $script:ServerRoles) {
            throw "Unknown Role '$($item.Role)' for server $($item.Name). Allowed: $($script:ServerRoles -join ', ')"
        }

        if ($item.Types.Count -eq 0 -or @($item.Types | Where-Object { [string]::IsNullOrEmpty($_) }).Count -gt 0) {
            throw "Type is required for server $($item.Name) (role $($item.Role)); list values separated by a comma without spaces."
        }

        if ($item.Role -in $script:SingleTypeRoles -and $item.Types.Count -ne 1) {
            throw "Role $($item.Role) allows exactly one Type; server $($item.Name) has '$($item.Type)'."
        }

        if (@($item.Types | Select-Object -Unique).Count -ne $item.Types.Count) {
            throw "Duplicate Type values for server $($item.Name): '$($item.Type)'"
        }

        foreach ($type in $item.Types) {
            if ($type -notin $script:ServerTypesByRole[$item.Role]) {
                throw "Type '$type' is not supported for role $($item.Role) (server $($item.Name)). Supported: $($script:ServerTypesByRole[$item.Role] -join ', ')"
            }
        }

        if ($item.Role -eq 'seg-exit') {
            if (-not [string]::IsNullOrWhiteSpace($item.Port)) {
                throw "Port must be empty for seg-exit server $($item.Name): it has no public service port."
            }
        }
        elseif (-not (Test-ServerPortValue -Port $item.Port)) {
            $protocol = if ($item.Role -eq 'seg-gateway') { 'TCP' } else { 'UDP' }
            throw "Invalid $protocol port for server $($item.Name): $($item.Port)"
        }
    }

    # seg-exit has no port and is excluded from the check; the same IP:Port pair cannot serve two roles.
    $duplicateEndpoints = @(
        $servers |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Port) } |
        Group-Object { "$($_.IP):$($_.Port)" } |
        Where-Object { $_.Count -gt 1 }
    )

    if ($duplicateEndpoints.Count -gt 0) {
        throw "Duplicate IP:Port in servers.txt: $($duplicateEndpoints.Name -join ', ')"
    }

    $gatewayTypes = @(
        $servers |
        Where-Object { $_.Role -eq 'seg-gateway' -and $_.IsEnabled } |
        ForEach-Object { $_.Types }
    )

    if ($gatewayTypes.Count -gt 0) {
        foreach ($exit in @($servers | Where-Object { $_.Role -eq 'seg-exit' -and $_.IsEnabled })) {
            if ($exit.Types[0] -notin $gatewayTypes) {
                throw "Type '$($exit.Type)' of seg-exit $($exit.Name) is not in the Type list of the enabled seg-gateway ($($gatewayTypes -join ', '))."
            }
        }
    }

    return [pscustomobject]@{
        Format  = $format
        Servers = $servers
    }
}

function Select-ServersForMode {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Servers,

        [Parameter(Mandatory = $true)]
        [ValidateSet('VPN', 'SEG')]
        [string]$Mode
    )

    if ($Mode -eq 'VPN') {
        return @($Servers | Where-Object { $_.Role -eq 'vpn-server' })
    }

    return @($Servers | Where-Object { $_.Role -in @('seg-gateway', 'seg-exit') })
}

function Assert-SegTopology {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Servers
    )

    $gateways = @($Servers | Where-Object { $_.Role -eq 'seg-gateway' -and $_.IsEnabled })
    $exits = @($Servers | Where-Object { $_.Role -eq 'seg-exit' -and $_.IsEnabled })

    if ($gateways.Count -ne 1 -or $exits.Count -ne 1) {
        throw "SEG mode requires exactly one enabled seg-gateway and one enabled seg-exit; found $($gateways.Count) and $($exits.Count)."
    }
}

function Convert-ServersFileToCurrent {
    <#
        Migrates the legacy servers.txt to the current format (Role = vpn-server, Type = amnezia).
        Returns $null when the file already uses the current format, otherwise an object
        with the backup path and the number of migrated servers. Idempotent.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [int]$BackupKeepCount = 3
    )

    $loaded = Read-ServersFile -Path $Path

    if ($loaded.Format -eq 'current') {
        return $null
    }

    $backup = "$Path.$(Get-Date -Format 'yyyyMMdd-HHmmssfff').bak"
    Copy-Item -LiteralPath $Path -Destination $backup

    $lines = @('Name;IP;Port;Role;Type;Enabled')

    foreach ($item in $loaded.Servers) {
        $lines += ('{0};{1};{2};{3};{4};{5}' -f $item.Name, $item.IP, $item.Port, 'vpn-server', 'amnezia', $item.Enabled)
    }

    $temp = "$Path.new"
    [System.IO.File]::WriteAllText($temp, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

    try {
        $migrated = Read-ServersFile -Path $temp

        if ($migrated.Format -ne 'current' -or $migrated.Servers.Count -ne $loaded.Servers.Count) {
            throw 'migrated file has a different structure.'
        }

        for ($i = 0; $i -lt $loaded.Servers.Count; $i++) {
            $before = $loaded.Servers[$i]
            $after = $migrated.Servers[$i]

            if ($before.Name -ne $after.Name -or $before.IP -ne $after.IP -or $before.Port -ne $after.Port -or $before.IsEnabled -ne $after.IsEnabled) {
                throw "migrated row $($i + 1) differs from the original."
            }
        }
    }
    catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw "Migrated servers.txt failed validation, the original is unchanged: $($_.Exception.Message)"
    }

    Move-Item -LiteralPath $temp -Destination $Path -Force

    $directory = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path

    Get-ChildItem -LiteralPath $directory -Filter "$leaf.*.bak" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $BackupKeepCount |
        Remove-Item -Force

    return [pscustomobject]@{
        Backup = $backup
        Count  = $loaded.Servers.Count
    }
}
