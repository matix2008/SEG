param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('VPN', 'SEG')]
    [string]$Mode,

    [Parameter(Mandatory = $false, Position = 0)]
    [string]$ServerName,

    [Parameter(Mandatory = $false)]
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $PSBoundParameters.ContainsKey('Mode')) {
    [Console]::Error.WriteLine('ERROR: parameter -Mode is required. Use -Mode VPN or -Mode SEG.')
    exit 1
}

if ($Mode -eq 'SEG') {
    $segScript = Join-Path $PSScriptRoot 'seg\sync-seg.ps1'

    if (-not (Test-Path -LiteralPath $segScript)) {
        [Console]::Error.WriteLine("ERROR: SEG mode is not available: $segScript was not found.")
        exit 1
    }

    $segArgs = @{}
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -ne 'Mode') {
            $segArgs[$key] = $PSBoundParameters[$key]
        }
    }

    $global:LASTEXITCODE = 0

    try {
        & $segScript @segArgs
    }
    catch {
        [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
        exit 1
    }

    exit $global:LASTEXITCODE
}

# ============================================================
# Paths
# ============================================================

$Root = Split-Path -Parent $PSScriptRoot

. (Join-Path $PSScriptRoot 'lib\servers.ps1')

# ============================================================
# Logging
# ============================================================

$ScriptName = Split-Path -Leaf $PSCommandPath
$RunId      = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$LogsDir    = Join-Path $Root 'logs'
$LogFile    = Join-Path $LogsDir 'amnezia.log'

$LogMaxBytes    = 10MB
$LogBackupCount = 3
$LogEncoding    = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null

function Invoke-LogRotation {
    if (-not (Test-Path -LiteralPath $LogFile)) {
        return
    }

    $size = (Get-Item -LiteralPath $LogFile).Length

    if ($size -lt $LogMaxBytes) {
        return
    }

    $oldest = "$LogFile.$LogBackupCount"
    Remove-Item -LiteralPath $oldest -Force -ErrorAction SilentlyContinue

    for ($i = $LogBackupCount - 1; $i -ge 1; $i--) {
        $source = "$LogFile.$i"

        if (Test-Path -LiteralPath $source) {
            $destination = "$LogFile.$($i + 1)"
            Move-Item -LiteralPath $source -Destination $destination -Force
        }
    }

    Move-Item -LiteralPath $LogFile -Destination "$LogFile.1" -Force
}

Invoke-LogRotation

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('START', 'INFO', 'OK', 'WARN', 'ERROR', 'DONE', 'OUTPUT')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [switch]$LogOnly
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$timestamp [$ScriptName] [$RunId] [$Level] $Message"

    [System.IO.File]::AppendAllText(
        $LogFile,
        $line + "`n",
        $LogEncoding
    )

    if (-not $LogOnly) {
        if ($Level -eq 'ERROR') {
            Microsoft.PowerShell.Utility\Write-Host $line -ForegroundColor Red
        }
        elseif ($Level -eq 'WARN') {
            Microsoft.PowerShell.Utility\Write-Host $line -ForegroundColor Yellow
        }
        else {
            Microsoft.PowerShell.Utility\Write-Host $line
        }
    }
}

function Write-LogOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    foreach ($line in ($Text -split '\r\n|\n|\r')) {
        if ($line.Length -eq 0) {
            continue
        }

        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $record = "$timestamp [$Source] [$RunId] [OUTPUT] $line"

        [System.IO.File]::AppendAllText(
            $LogFile,
            $record + "`n",
            $LogEncoding
        )

        Microsoft.PowerShell.Utility\Write-Host $record
    }
}

function Get-ErrorDescription {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $message = [string]$ErrorRecord.Exception.Message

    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = ($ErrorRecord | Out-String).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = [string]$ErrorRecord.FullyQualifiedErrorId
    }

    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = 'Unknown PowerShell error.'
    }

    return $message
}

trap {
    $errorText = Get-ErrorDescription -ErrorRecord $_
    Write-Log -Level 'ERROR' -Message $errorText

    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Log -Level 'ERROR' -Message $_.InvocationInfo.PositionMessage -LogOnly
    }

    if ($_.ScriptStackTrace) {
        Write-Log -Level 'ERROR' -Message $_.ScriptStackTrace -LogOnly
    }

    Write-Log -Level 'DONE' -Message "FAILED. Log: $LogFile"
    exit 1
}

Write-Log -Level 'START' -Message 'Script started.'
Write-Log -Level 'INFO' -Message "PowerShell version: $($PSVersionTable.PSVersion)"


$ServersFile      = Join-Path $Root 'servers.txt'
$EnvFile          = Join-Path $Root 'config\server.env'
$TemplateFile     = Join-Path $Root 'config\awg0.conf.template'
$ClientsDir       = Join-Path $Root 'clients'

$UpgradeFile      = Join-Path $Root 'upgrade.sh'
$BootstrapFile    = Join-Path $Root 'bootstrap.sh'
$SecureFile       = Join-Path $Root 'secure.sh'
$FirewallTemplate = Join-Path $Root 'awg-iptables.service'

$AddClientFile    = Join-Path $PSScriptRoot 'add-client.ps1'

# ============================================================
# Helpers
# ============================================================

function Confirm-Action {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    while ($true) {
        $answer = (Read-Host "$Message [y/N]").Trim().ToLowerInvariant()

        if ([string]::IsNullOrWhiteSpace($answer)) {
            Write-Log -Level 'INFO' -Message "Confirmation: $Message -> NO (default)"
            return $false
        }

        if ($answer -in @('y', 'yes', 'д', 'да')) {
            Write-Log -Level 'INFO' -Message "Confirmation: $Message -> YES"
            return $true
        }

        if ($answer -in @('n', 'no', 'н', 'нет')) {
            Write-Log -Level 'INFO' -Message "Confirmation: $Message -> NO"
            return $false
        }
    }
}

function Read-EnvFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $result = @{}

    foreach ($raw in Get-Content $Path) {
        $line = $raw.Trim()

        if (-not $line -or $line.StartsWith('#')) {
            continue
        }

        $parts = @($line -split '=', 2)

        if ($parts.Count -ne 2) {
            throw "Invalid line in server.env: $line"
        }

        $name  = $parts[0].Trim()
        $value = $parts[1].Trim()

        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "Invalid empty parameter name in server.env"
        }

        $result[$name] = $value
    }

    return $result
}

function Write-Utf8Lf {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $Text = $Text -replace "`r`n", "`n"
    $Text = $Text -replace "`r", "`n"

    $utf8 = New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllText(
        $Path,
        $Text,
        $utf8
    )
}

function Test-Environment {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Env
    )

    $required = @(
        'WG_IPV4_NETWORK',
        'WG_IPV4_SERVER',
        'WG_IPV6_NETWORK',
        'WG_IPV6_SERVER',
        'DNS1',
        'DNS2',
        'SERVER_PRIVATE_KEY',
        'SERVER_PUBLIC_KEY',
        'JC',
        'JMIN',
        'JMAX',
        'S1',
        'S2',
        'S3',
        'S4',
        'H1',
        'H2',
        'H3',
        'H4',
        'RANDOM_TRAILERS'
    )

    foreach ($name in $required) {
        if (
            -not $Env.ContainsKey($name) -or
            [string]::IsNullOrWhiteSpace($Env[$name])
        ) {
            throw "Missing or empty server.env parameter: $name"
        }
    }

    foreach ($keyName in @('SERVER_PRIVATE_KEY', 'SERVER_PUBLIC_KEY')) {
        if ($Env[$keyName] -notmatch '^[A-Za-z0-9+/]{43}=$') {
            throw "$keyName does not look like a valid WireGuard/AmneziaWG base64 key"
        }
    }

    $randomTrailers = $Env['RANDOM_TRAILERS'].ToLowerInvariant()

    if ($randomTrailers -notin @('on', 'off')) {
        throw "RANDOM_TRAILERS must be 'on' or 'off'"
    }

    if ($randomTrailers -eq 'on') {
        $sizes = @(
            @(
                $Env['S1'],
                $Env['S2'],
                $Env['S3'],
                $Env['S4']
            ) | Select-Object -Unique
        )

        if ($sizes.Count -ne 1) {
            throw "RandomTrailers=on requires S1=S2=S3=S4"
        }
    }

    $headers = @(
        @(
            $Env['H1'],
            $Env['H2'],
            $Env['H3'],
            $Env['H4']
        ) | Select-Object -Unique
    )

    if ($headers.Count -ne 4) {
        throw "H1, H2, H3 and H4 must be different"
    }

    $intValues = @{
        'JC'   = @(1, 128)
        'JMIN' = @(0, 1279)
        'JMAX' = @(1, 1280)
        'S1'   = @(0, 1132)
        'S2'   = @(0, 1132)
        'S3'   = @(0, 1132)
        'S4'   = @(0, 1132)
    }

    foreach ($name in $intValues.Keys) {
        $parsed = 0
        if (-not [int]::TryParse([string]$Env[$name], [ref]$parsed)) {
            throw "$name must be an integer"
        }

        $bounds = $intValues[$name]
        if ($parsed -lt $bounds[0] -or $parsed -gt $bounds[1]) {
            throw "$name is outside the supported range $($bounds[0])..$($bounds[1])"
        }
    }

    if ([int]$Env['JMIN'] -ge [int]$Env['JMAX']) {
        throw 'JMIN must be lower than JMAX'
    }

    foreach ($name in @('H1', 'H2', 'H3', 'H4')) {
        $parsedHeader = [uint64]0
        if (-not [uint64]::TryParse([string]$Env[$name], [ref]$parsedHeader) -or $parsedHeader -gt 4294967295) {
            throw "$name must be an unsigned 32-bit integer"
        }
    }

    foreach ($name in @('DNS1', 'DNS2')) {
        $parsedAddress = $null
        if (-not [System.Net.IPAddress]::TryParse([string]$Env[$name], [ref]$parsedAddress)) {
            throw "$name is not a valid IP address"
        }
    }

    if ($Env['WG_IPV4_NETWORK'] -notmatch '^(\d+)\.(\d+)\.(\d+)\.0/24$') {
        throw 'WG_IPV4_NETWORK must be an IPv4 /24 network'
    }

    $networkPrefix = "$($Matches[1]).$($Matches[2]).$($Matches[3])."
    if (-not ([string]$Env['WG_IPV4_SERVER']).StartsWith($networkPrefix)) {
        throw 'WG_IPV4_SERVER does not belong to WG_IPV4_NETWORK'
    }

    if ($Env['WG_IPV6_NETWORK'] -notmatch '/64$') {
        throw 'WG_IPV6_NETWORK must use /64 in the current template'
    }
}

function Set-SingleConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $escapedName = [regex]::Escape($Name)
    $pattern = '(?m)^\s*' + $escapedName + '\s*=\s*.*$'
    $configMatches = [regex]::Matches($Text, $pattern)

    if ($configMatches.Count -ne 1) {
        throw "Expected exactly one '$Name' in $FileName; found $($configMatches.Count)"
    }

    return [regex]::Replace(
        $Text,
        $pattern,
        "$Name = $Value",
        1
    )
}

function Sync-LocalClientConfigs {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Env,

        # Report differences without rewriting profiles or deleting derived ones.
        [switch]$CheckOnly
    )

    if (-not (Test-Path $ClientsDir)) {
        Write-Log -Level 'INFO' -Message 'clients directory does not exist; no local client configs to synchronize.'
        return
    }

    $clientFiles = @(
        Get-ChildItem `
            -LiteralPath $ClientsDir `
            -Filter '*.conf' `
            -File `
            -ErrorAction SilentlyContinue
    )

    if ($clientFiles.Count -eq 0) {
        Write-Log -Level 'INFO' -Message 'No persistent client configs found.'
        return
    }

    $values = [ordered]@{
        'DNS'            = "$($Env['DNS1']), $($Env['DNS2'])"
        'Jc'             = $Env['JC']
        'Jmin'           = $Env['JMIN']
        'Jmax'           = $Env['JMAX']
        'S1'             = $Env['S1']
        'S2'             = $Env['S2']
        'S3'             = $Env['S3']
        'S4'             = $Env['S4']
        'H1'             = $Env['H1']
        'H2'             = $Env['H2']
        'H3'             = $Env['H3']
        'H4'             = $Env['H4']
        'RandomTrailers' = $Env['RANDOM_TRAILERS']
        'PublicKey'      = $Env['SERVER_PUBLIC_KEY']
    }

    $updatedCount = 0

    foreach ($file in $clientFiles) {
        $original = Get-Content $file.FullName -Raw
        $updated = $original

        foreach ($name in $values.Keys) {
            $updated = Set-SingleConfigValue `
                -Text $updated `
                -Name $name `
                -Value ([string]$values[$name]) `
                -FileName $file.Name
        }

        if ($updated -ne $original) {
            if ($CheckOnly) {
                Write-Log -Level 'WARN' -Message "Local client config differs from server.env and would be updated: $($file.Name)"
                $script:LocalConfigDrift = $true
                $updatedCount++
                continue
            }

            Write-Utf8Lf `
                -Path $file.FullName `
                -Text $updated

            $updatedCount++
            Write-Log -Level 'OK' -Message "Updated local client config: $($file.Name)"
        }
    }

    if ($updatedCount -eq 0) {
        Write-Log -Level 'OK' -Message "Local client configs already match server.env ($($clientFiles.Count) checked)."
    }
    elseif ($CheckOnly) {
        Write-Log -Level 'WARN' -Message "$updatedCount of $($clientFiles.Count) local client config(s) differ from server.env. A normal run updates them and removes derived profiles (check only: nothing changed)."
    }
    else {
        Write-Log -Level 'OK' -Message "Local client config synchronization complete: $updatedCount updated, $($clientFiles.Count) checked."

        $generatedDir = Join-Path $ClientsDir 'generated'

        if (Test-Path -LiteralPath $generatedDir) {
            $staleGenerated = @(
                Get-ChildItem `
                    -LiteralPath $generatedDir `
                    -Filter '*.conf' `
                    -File `
                    -Recurse `
                    -ErrorAction SilentlyContinue
            )

            if ($staleGenerated.Count -gt 0) {
                $staleGenerated | Remove-Item -Force
                Write-Log -Level 'WARN' -Message "Removed $($staleGenerated.Count) derived client profile(s) because global server parameters changed. Regenerate them with make-client-config.ps1."
            }
        }
    }
}

function Test-ClientEndpoints {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Servers
    )

    # Sync never rewrites Endpoint, so after an IP/port change of a VPS the
    # profiles keep the old address. Only warn; reissuing profiles is a manual step.
    $profiles = @()

    if (Test-Path -LiteralPath $ClientsDir) {
        $profiles += @(
            Get-ChildItem -LiteralPath $ClientsDir -Filter '*.conf' -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                [PSCustomObject]@{ Path = $_.FullName; Label = $_.Name; Server = $null }
            }
        )

        $generatedDir = Join-Path $ClientsDir 'generated'

        if (Test-Path -LiteralPath $generatedDir) {
            $profiles += @(
                Get-ChildItem -LiteralPath $generatedDir -Filter '*.conf' -File -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object {
                    [PSCustomObject]@{
                        Path   = $_.FullName
                        Label  = "generated\$($_.Directory.Name)\$($_.Name)"
                        Server = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                    }
                }
            )
        }
    }

    $problems = 0

    foreach ($item in $profiles) {
        $match = [regex]::Match(
            (Get-Content -LiteralPath $item.Path -Raw),
            '(?m)^\s*Endpoint\s*=\s*(\S+)\s*$'
        )

        if (-not $match.Success) {
            continue
        }

        $endpoint = $match.Groups[1].Value
        $matchesAny = @($Servers | Where-Object { "$($_.IP):$($_.Port)" -eq $endpoint })

        if ($item.Server) {
            # A derived profile must point exactly to its own server.
            $own = @($Servers | Where-Object { $_.Name -eq $item.Server })

            if ($own.Count -eq 0) {
                Write-Log -Level 'WARN' -Message "Derived profile $($item.Label) belongs to server '$($item.Server)', which is not in servers.txt; remove it."
                $problems++
            }
            elseif ("$($own[0].IP):$($own[0].Port)" -ne $endpoint) {
                Write-Log -Level 'WARN' -Message "Derived profile $($item.Label) has Endpoint $endpoint, but servers.txt has $($own[0].IP):$($own[0].Port); recreate it with make-client-config.ps1."
                $problems++
            }

            continue
        }

        if ($matchesAny.Count -eq 0) {
            Write-Log -Level 'WARN' -Message "Client profile $($item.Label) has Endpoint $endpoint, which matches no server in servers.txt; the profile will not connect. Edit Endpoint or issue a new profile with make-client-config.ps1."
            $problems++
            continue
        }

        $enabled = @($matchesAny | Where-Object { ([string]$_.Enabled).Trim().ToLowerInvariant() -eq 'true' })

        if ($enabled.Count -eq 0) {
            Write-Log -Level 'WARN' -Message "Client profile $($item.Label) points to disabled server '$($matchesAny[0].Name)' ($endpoint)."
            $problems++
        }
    }

    if ($problems -eq 0 -and $profiles.Count -gt 0) {
        Write-Log -Level 'OK' -Message "Client profile endpoints match servers.txt ($($profiles.Count) checked)."
    }
}

function Convert-Template {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Template,

        [Parameter(Mandatory = $true)]
        [hashtable]$Env,

        [Parameter(Mandatory = $true)]
        [string]$Port
    )

    $result = $Template

    foreach ($key in $Env.Keys) {
        $result = $result.Replace(
            "{{$key}}",
            [string]$Env[$key]
        )
    }

    $result = $result.Replace(
        '{{AWG_PORT}}',
        $Port
    )

    $unresolved = @(
        [regex]::Matches(
            $result,
            '\{\{[^}]+\}\}'
        ) |
        ForEach-Object { $_.Value } |
        Sort-Object -Unique
    )

    if ($unresolved.Count -gt 0) {
        throw "Unresolved template variables: $($unresolved -join ', ')"
    }

    return $result
}

function Test-Ssh {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP,

        [switch]$Quiet
    )

    $TimeoutMs = 15000

    if (-not $Quiet) {
        Write-Log -Level 'INFO' -Message "Testing SSH connection: root@$IP (hard timeout $($TimeoutMs / 1000)s)"
    }

    $sshCommand = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $sshCommand) {
        $sshCommand = Get-Command ssh -ErrorAction SilentlyContinue
    }

    if (-not $sshCommand) {
        if (-not $Quiet) {
            Write-Log -Level 'ERROR' -Message 'ssh.exe was not found in PATH.'
        }
        return $false
    }

    $process = $null

    try {
        # Use System.Diagnostics.Process directly. Windows PowerShell 5.1 can
        # return an empty ExitCode from Start-Process -PassThru with redirected
        # native-process streams on some systems.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $sshCommand.Source
        $psi.Arguments = "-n -o BatchMode=yes -o ConnectionAttempts=1 -o ConnectTimeout=7 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=yes root@$IP true"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi

        if (-not $process.Start()) {
            if (-not $Quiet) {
                Write-Log -Level 'ERROR' -Message "SSH probe process could not be started: root@$IP"
            }
            return $false
        }

        if (-not $process.WaitForExit($TimeoutMs)) {
            try {
                $process.Kill()
                $process.WaitForExit()
            }
            catch {
                # Best effort only; timeout is already the primary result.
            }

            $stdoutText = $process.StandardOutput.ReadToEnd()
            $stderrText = $process.StandardError.ReadToEnd()

            if (-not $Quiet) {
                if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
                    Write-LogOutput -Source "ssh:$IP" -Text $stdoutText
                }
                if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
                    Write-LogOutput -Source "ssh:$IP" -Text $stderrText
                }
                Write-Log -Level 'WARN' -Message "SSH probe timed out after $($TimeoutMs / 1000)s: root@$IP"
            }

            return $false
        }

        # Ensure all redirected data is flushed before reading streams/ExitCode.
        $process.WaitForExit()
        $stdoutText = $process.StandardOutput.ReadToEnd()
        $stderrText = $process.StandardError.ReadToEnd()
        $code = [int]$process.ExitCode

        if (-not $Quiet) {
            if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
                Write-LogOutput -Source "ssh:$IP" -Text $stdoutText
            }
            if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
                Write-LogOutput -Source "ssh:$IP" -Text $stderrText
            }
        }

        if ($code -eq 0) {
            if (-not $Quiet) {
                Write-Log -Level 'OK' -Message "SSH connection established: root@$IP (exit 0)"
            }
            return $true
        }

        if (-not $Quiet) {
            Write-Log -Level 'WARN' -Message "SSH connection failed: root@$IP (exit $code)"
        }

        return $false
    }
    catch {
        if (-not $Quiet) {
            Write-Log -Level 'ERROR' -Message "SSH probe failed to execute for root@${IP}: $($_.Exception.Message)"
        }
        return $false
    }
    finally {
        if ($process) {
            $process.Dispose()
        }
    }
}

function Invoke-Remote {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [switch]$AllowFailure,

        [switch]$Quiet
    )

    if (-not $Quiet) {
        Write-Log -Level 'INFO' -Message "Executing remote command on root@$IP"
    }

    # Normalize embedded shell blocks so CRLF cannot leak into remote bash.
    $Command = $Command -replace "`r`n", "`n"
    $Command = $Command -replace "`r", "`n"

    $lines = New-Object System.Collections.Generic.List[string]

    $previousErrorActionPreference = $ErrorActionPreference

    try {
        # See Test-Ssh: stderr from ssh.exe is diagnostic output, not a
        # PowerShell exception.  Use ssh.exe exit code as the authority.
        $ErrorActionPreference = 'Continue'

        & ssh `
            -n `
            -o BatchMode=yes `
            -o ConnectionAttempts=1 `
            -o ConnectTimeout=15 `
            -o ServerAliveInterval=15 `
            -o ServerAliveCountMax=3 `
            -o StrictHostKeyChecking=yes `
            "root@$IP" `
            $Command `
            2>&1 |
        ForEach-Object {
            $line = [string]$_
            [void]$lines.Add($line)

            if (-not $Quiet) {
                Write-LogOutput -Source "remote:$IP" -Text $line
            }
        }

        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $text = ($lines -join "`n")

    if ($code -eq 0) {
        if (-not $Quiet) {
            Write-Log -Level 'OK' -Message "Remote command completed on $IP"
        }
    }
    elseif ($AllowFailure) {
        if (-not $Quiet) {
            Write-Log -Level 'WARN' -Message "Remote command returned exit code $code on $IP"
        }
    }
    else {
        Write-Log -Level 'ERROR' -Message "Remote command failed on $IP with exit code $code"
        throw "Remote command failed on $IP with exit code $code"
    }

    return [PSCustomObject]@{
        Code   = $code
        Output = $text
    }
}

function Copy-ToServer {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP,

        [Parameter(Mandatory = $true)]
        [string[]]$Files,

        [Parameter(Mandatory = $false)]
        [string]$Destination = '/root/'
    )

    $fileNames = @($Files | ForEach-Object { [System.IO.Path]::GetFileName($_) })
    Write-Log -Level 'INFO' -Message "Copying to root@${IP}:${Destination}: $($fileNames -join ', ')"

    $scpArgs = @(
        '-o', 'BatchMode=yes',
        '-o', 'ConnectionAttempts=1',
        '-o', 'ConnectTimeout=15',
        '-o', 'ServerAliveInterval=15',
        '-o', 'ServerAliveCountMax=3',
        '-o', 'StrictHostKeyChecking=yes'
    )

    $scpArgs += $Files
    $scpArgs += "root@${IP}:${Destination}"

    $lines = New-Object System.Collections.Generic.List[string]
    $previousErrorActionPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = 'Continue'

        & scp @scpArgs 2>&1 |
        ForEach-Object {
            $line = [string]$_
            [void]$lines.Add($line)
            Write-LogOutput -Source "scp:$IP" -Text $line
        }

        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($code -ne 0) {
        Write-Log -Level 'ERROR' -Message "SCP failed: $IP (exit $code)"
        throw "SCP failed: $IP (exit $code)"
    }

    Write-Log -Level 'OK' -Message "Files copied successfully to ${IP}:$Destination"
}

function Initialize-RemoteStaging {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP
    )

    Invoke-Remote -IP $IP -Command 'install -d -o root -g root -m 700 /root/.amnezia-sync' -Quiet | Out-Null
}

function Clear-RemoteStaging {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP
    )

    Invoke-Remote `
        -IP $IP `
        -Command 'rm -f /root/.amnezia-sync/awg0.conf /root/.amnezia-sync/awg-iptables.service' `
        -AllowFailure `
        -Quiet | Out-Null
}

function Wait-SshAfterReboot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP
    )

    Write-Log -Level 'INFO' -Message "Waiting for reboot cycle: $IP"
    Start-Sleep -Seconds 3

    # Сначала ждём исчезновения старой SSH-сессии.
    for ($i = 0; $i -lt 20; $i++) {
        if (-not (Test-Ssh -IP $IP -Quiet)) {
            Write-Log -Level 'INFO' -Message "SSH went down during reboot: $IP"
            break
        }

        Start-Sleep -Seconds 2
    }

    # Затем ждём возвращения SSH.
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-Ssh -IP $IP -Quiet) {
            Write-Log -Level 'OK' -Message "SSH restored after reboot: $IP"
            return
        }

        Start-Sleep -Seconds 5
    }

    throw "SSH did not return after reboot: $IP"
}

# ============================================================
# Server state
# ============================================================

function Get-ServerBootstrapState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP
    )

    $command = @'
failed=0
installed=0

check()
{
    name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "CHECK $name=OK"
        return 0
    else
        echo "CHECK $name=FAIL"
        failed=1
        return 1
    fi
}

if command -v awg >/dev/null 2>&1 ||
   command -v awg-quick >/dev/null 2>&1 ||
   [[ -f /etc/amnezia/amneziawg/awg0.conf ]] ||
   [[ -f /etc/systemd/system/awg-iptables.service ]]; then
    installed=1
fi

check AWG command -v awg || true
check AWG_QUICK command -v awg-quick || true
check AWG_CONFIG test -f /etc/amnezia/amneziawg/awg0.conf || true
check IPTABLES_SERVICE_FILE test -f /etc/systemd/system/awg-iptables.service || true
check AWG_MODULE modinfo amneziawg || true
check AWG_SERVICE systemctl is-active --quiet awg-quick@awg0.service || true
check IPTABLES_SERVICE systemctl is-active --quiet awg-iptables.service || true

if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" == "1" ]]; then
    echo "CHECK IPV4_FORWARDING=OK"
else
    echo "CHECK IPV4_FORWARDING=FAIL"
    failed=1
fi

if [[ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || true)" == "1" ]]; then
    echo "CHECK IPV6_FORWARDING=OK"
else
    echo "CHECK IPV6_FORWARDING=FAIL"
    failed=1
fi

latest_kernel="$(find /lib/modules -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -V | tail -n1)"
if [[ -n "$latest_kernel" && -e "/lib/modules/$latest_kernel/build" ]]; then
    echo "CHECK LATEST_KERNEL_HEADERS=OK"
else
    echo "CHECK LATEST_KERNEL_HEADERS=FAIL"
    failed=1
fi

if command -v dkms >/dev/null 2>&1 &&
   [[ -n "$latest_kernel" ]] &&
   dkms status 2>/dev/null | grep -F 'amneziawg/' | grep -F "$latest_kernel" | grep -q 'installed'; then
    echo "CHECK AWG_DKMS_LATEST_KERNEL=OK"
else
    echo "CHECK AWG_DKMS_LATEST_KERNEL=FAIL"
    failed=1
fi

if [[ "$failed" == "0" ]]; then
    echo 'STATE=READY'
elif [[ "$installed" == "0" ]]; then
    echo 'STATE=NEW'
else
    echo 'STATE=DEGRADED'
fi
'@

    $result = Invoke-Remote -IP $IP -Command $command -AllowFailure

    foreach ($line in ($result.Output -split "`n")) {
        if ($line -match '^STATE=(READY|NEW|DEGRADED)$') {
            return $Matches[1]
        }
    }

    throw "Unable to determine bootstrap state for $IP"
}

function Test-Secured {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP,

        [Parameter(Mandatory = $true)]
        [string]$Port
    )

    $command = @'
failed=0

if ufw status | grep -q '^Status: active'; then
    echo 'CHECK UFW_ACTIVE=OK'
else
    echo 'CHECK UFW_ACTIVE=FAIL'
    failed=1
fi

if ufw status | grep -Eq '(^|[[:space:]])__PORT__/udp([[:space:]]|$)'; then
    echo 'CHECK UFW_AWG_PORT=OK'
else
    echo 'CHECK UFW_AWG_PORT=FAIL'
    failed=1
fi

if systemctl is-active --quiet fail2ban; then
    echo 'CHECK FAIL2BAN=OK'
else
    echo 'CHECK FAIL2BAN=FAIL'
    failed=1
fi

EFFECTIVE="$(sshd -T 2>/dev/null || true)"

if grep -q '^passwordauthentication no$' <<<"$EFFECTIVE"; then
    echo 'CHECK SSH_PASSWORD_AUTH=OK'
else
    echo 'CHECK SSH_PASSWORD_AUTH=FAIL'
    failed=1
fi

if grep -q '^kbdinteractiveauthentication no$' <<<"$EFFECTIVE"; then
    echo 'CHECK SSH_KBD_INTERACTIVE=OK'
else
    echo 'CHECK SSH_KBD_INTERACTIVE=FAIL'
    failed=1
fi

if grep -Eq '^permitrootlogin (prohibit-password|without-password)$' <<<"$EFFECTIVE"; then
    echo 'CHECK SSH_ROOT_POLICY=OK'
else
    echo 'CHECK SSH_ROOT_POLICY=FAIL'
    failed=1
fi

exit "$failed"
'@

    $command = $command.Replace('__PORT__', $Port)

    $result = Invoke-Remote `
        -IP $IP `
        -Command $command `
        -AllowFailure

    return ($result.Code -eq 0)
}

# ============================================================
# Peer validation
# ============================================================

function Initialize-Peers {

    $template = Get-Content $TemplateFile -Raw

    if ($template -match '(?m)^# BEGIN_PEER\s+\S+') {
        Write-Log -Level 'OK' -Message 'At least one peer is present in awg0.conf.template.'
        return $true
    }

    Write-Log -Level 'WARN' -Message 'awg0.conf.template contains no peers.'

    if (-not (Confirm-Action 'Создать первого клиента?')) {
        Write-Log -Level 'WARN' -Message 'No client was created. Bootstrap will be postponed; completed upgrade work is preserved.'
        return $false
    }

    if (-not (Test-Path $AddClientFile)) {
        throw "No peers configured and add-client.ps1 was not found: $AddClientFile"
    }

    $powerShellExe = (Get-Process -Id $PID).Path

    Write-Log -Level 'INFO' -Message 'Starting add-client.ps1 in a child PowerShell process.'
    & $powerShellExe -NoProfile -ExecutionPolicy Bypass -File $AddClientFile -Mode VPN
    $childCode = $LASTEXITCODE

    if ($childCode -ne 0) {
        throw "add-client.ps1 failed with exit code $childCode"
    }

    $template = Get-Content $TemplateFile -Raw

    if ($template -notmatch '(?m)^# BEGIN_PEER\s+\S+') {
        throw "add-client.ps1 completed, but no peer appeared in awg0.conf.template"
    }

    Write-Log -Level 'OK' -Message 'First peer created successfully.'
    return $true
}

# ============================================================
# Upgrade stage
# ============================================================

function Invoke-UpgradeStage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP
    )

    for ($attempt = 1; $attempt -le 4; $attempt++) {

        Write-Log -Level 'START' -Message "UPGRADE stage on $IP (attempt $attempt/4)"

        $command = @'
chmod +x /root/upgrade.sh
/root/upgrade.sh
'@

        $result = Invoke-Remote `
            -IP $IP `
            -Command $command `
            -AllowFailure

        if ($result.Code -eq 0) {
            Write-Log -Level 'OK' -Message "Upgrade completed successfully on $IP"
            return $true
        }

        if ($result.Code -eq 255) {
            # ssh.exe itself failed or the connection dropped mid-upgrade.
            # upgrade.sh is idempotent and repairs an interrupted dpkg state,
            # so wait for SSH and run it again.
            Write-Log -Level 'WARN' -Message "SSH connection lost during upgrade on $IP; waiting for SSH to retry."

            $restored = $false
            for ($i = 0; $i -lt 30; $i++) {
                if (Test-Ssh -IP $IP -Quiet) {
                    $restored = $true
                    break
                }

                Start-Sleep -Seconds 10
            }

            if (-not $restored) {
                throw "SSH did not return after connection loss during upgrade on $IP"
            }

            Write-Log -Level 'OK' -Message "SSH restored on $IP; retrying upgrade."
            continue
        }

        if ($result.Code -ne 10) {
            throw "upgrade.sh failed with code $($result.Code) on $IP"
        }

        Write-Log -Level 'WARN' -Message "upgrade.sh requires reboot on $IP"

        if (-not (Confirm-Action 'Перезагрузить VPS и продолжить upgrade?')) {
            Write-Log -Level 'WARN' -Message "Configuration stopped after upgrade stage on $IP"
            return $false
        }

        $rebootCommand = @'
nohup bash -c 'sleep 1; reboot' >/dev/null 2>&1 &
exit 0
'@

        Invoke-Remote `
            -IP $IP `
            -Command $rebootCommand `
            -AllowFailure |
            Out-Null

        Wait-SshAfterReboot -IP $IP
    }

    throw "upgrade.sh did not reach UPGRADE_OK after repeated runs on $IP"
}

# ============================================================
# Candidate files
# ============================================================

function New-CandidateConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Server,

        [Parameter(Mandatory = $true)]
        [hashtable]$Env,

        [Parameter(Mandatory = $true)]
        [string]$TempDirectory
    )

    $template = Get-Content $TemplateFile -Raw

    $rendered = Convert-Template `
        -Template $template `
        -Env $Env `
        -Port ([string]$Server.Port)

    $path = Join-Path $TempDirectory 'awg0.conf'

    Write-Utf8Lf `
        -Path $path `
        -Text $rendered

    Write-Log -Level 'OK' -Message "Rendered candidate awg0.conf for $($Server.Name)"
    return $path
}

function New-CandidateFirewall {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Server,

        [Parameter(Mandatory = $true)]
        [hashtable]$Env,

        [Parameter(Mandatory = $true)]
        [string]$TempDirectory
    )

    $template = Get-Content $FirewallTemplate -Raw

    $rendered = Convert-Template `
        -Template $template `
        -Env $Env `
        -Port ([string]$Server.Port)

    $path = Join-Path $TempDirectory 'awg-iptables.service'

    Write-Utf8Lf `
        -Path $path `
        -Text $rendered

    Write-Log -Level 'OK' -Message "Rendered candidate awg-iptables.service for $($Server.Name)"
    return $path
}

function New-LinuxCopy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$TempDirectory
    )

    $destination = Join-Path `
        $TempDirectory `
        ([System.IO.Path]::GetFileName($Source))

    Write-Utf8Lf `
        -Path $destination `
        -Text (Get-Content $Source -Raw)

    Write-Log -Level 'INFO' -Message "Prepared LF copy: $([System.IO.Path]::GetFileName($Source))"
    return $destination
}

# ============================================================
# Sync status
# ============================================================

function Get-SyncStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP
    )

    $command = @'
if [[ ! -f /etc/amnezia/amneziawg/awg0.conf ]]; then
    echo "CONFIG=MISSING"
elif cmp -s /root/.amnezia-sync/awg0.conf /etc/amnezia/amneziawg/awg0.conf; then
    echo "CONFIG=SAME"
else
    echo "CONFIG=DIFF"
fi

if [[ ! -f /etc/systemd/system/awg-iptables.service ]]; then
    echo "FIREWALL=MISSING"
elif cmp -s /root/.amnezia-sync/awg-iptables.service /etc/systemd/system/awg-iptables.service; then
    echo "FIREWALL=SAME"
else
    echo "FIREWALL=DIFF"
fi
'@

    $result = Invoke-Remote `
        -IP $IP `
        -Command $command

    $status = @{}

    foreach ($line in ($result.Output -split "`n")) {
        if ($line -match '^([A-Z]+)=(.+)$') {
            $status[$matches[1]] = $matches[2].Trim()
        }
    }

    if (-not $status.ContainsKey('CONFIG') -or -not $status.ContainsKey('FIREWALL')) {
        throw "Unable to parse remote synchronization status from $IP"
    }

    return $status
}

# Read-only variant for -Check: nothing is uploaded; the VPS files are hashed
# on the server and compared with hashes of the local candidates.
function Get-SyncStatusByHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP,

        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$FirewallPath
    )

    $configHash = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $firewallHash = (Get-FileHash -LiteralPath $FirewallPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $command = @'
compare()
{
    local label="$1" file="$2" expected="$3"

    if [[ ! -f "$file" ]]; then
        echo "${label}=MISSING"
    elif [[ "$(sha256sum "$file" | cut -d' ' -f1)" == "$expected" ]]; then
        echo "${label}=SAME"
    else
        echo "${label}=DIFF"
    fi
}

compare CONFIG /etc/amnezia/amneziawg/awg0.conf __CONFIG_HASH__
compare FIREWALL /etc/systemd/system/awg-iptables.service __FIREWALL_HASH__
'@

    $command = $command.Replace('__CONFIG_HASH__', $configHash).Replace('__FIREWALL_HASH__', $firewallHash)

    $result = Invoke-Remote `
        -IP $IP `
        -Command $command

    $status = @{}

    foreach ($line in ($result.Output -split "`n")) {
        if ($line -match '^([A-Z]+)=(.+)$') {
            $status[$matches[1]] = $matches[2].Trim()
        }
    }

    if (-not $status.ContainsKey('CONFIG') -or -not $status.ContainsKey('FIREWALL')) {
        throw "Unable to parse remote synchronization status from $IP"
    }

    return $status
}

# ============================================================
# Apply sync
# ============================================================

function Invoke-Sync {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP
    )

    $command = @'
set -Eeuo pipefail

CONF=/etc/amnezia/amneziawg/awg0.conf
SERVICE=/etc/systemd/system/awg-iptables.service
NEW_CONF=/root/.amnezia-sync/awg0.conf
NEW_SERVICE=/root/.amnezia-sync/awg-iptables.service

CONF_BAK=$(mktemp)
SERVICE_BAK=$(mktemp)
SERVICE_EXISTED=0
NEW_PORT_ADDED=0
UFW_ACTIVE=0
PORT_CHANGED=0

cp -a "$CONF" "$CONF_BAK"

if [[ -f "$SERVICE" ]]; then
    cp -a "$SERVICE" "$SERVICE_BAK"
    SERVICE_EXISTED=1
fi

OLD_PORT="$(sed -nE 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*([0-9]+).*$/\1/p' "$CONF" | head -n1)"
NEW_PORT="$(sed -nE 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*([0-9]+).*$/\1/p' "$NEW_CONF" | head -n1)"

rollback()
{
    echo "Synchronization failed. Rolling back..." >&2

    install -o root -g root -m 600 "$CONF_BAK" "$CONF" || true

    if [[ "$SERVICE_EXISTED" == "1" ]]; then
        install -o root -g root -m 644 "$SERVICE_BAK" "$SERVICE" || true
    else
        rm -f "$SERVICE"
    fi

    systemctl daemon-reload || true
    systemctl restart awg-quick@awg0.service || true
    systemctl restart awg-iptables.service || true

    if [[ "$NEW_PORT_ADDED" == "1" ]] && command -v ufw >/dev/null 2>&1; then
        ufw --force delete allow "${NEW_PORT}/udp" >/dev/null 2>&1 || true
    fi

    echo "Rollback completed." >&2
}

on_error()
{
    rc=$?
    echo "SYNC_ERROR line=$LINENO command=$BASH_COMMAND code=$rc" >&2
    trap - ERR
    rollback
    exit "$rc"
}

trap on_error ERR

CONF_CHANGED=0
SERVICE_CHANGED=0
cmp -s "$NEW_CONF" "$CONF" || CONF_CHANGED=1

if [[ -f "$SERVICE" ]]; then
    cmp -s "$NEW_SERVICE" "$SERVICE" || SERVICE_CHANGED=1
else
    SERVICE_CHANGED=1
fi

if [[ "$CONF_CHANGED" == "1" ]]; then
    if [[ -n "$NEW_PORT" && "$NEW_PORT" != "$OLD_PORT" ]]; then
        PORT_CHANGED=1
    fi

    if [[ "$PORT_CHANGED" == "1" ]] && command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
        UFW_ACTIVE=1
        if ! ufw status | grep -Eq '(^|[[:space:]])'"${NEW_PORT}"'/udp([[:space:]]|$)'; then
            ufw allow "${NEW_PORT}/udp"
            NEW_PORT_ADDED=1
        fi
    fi

    install -o root -g root -m 600 "$NEW_CONF" "$CONF"

    # Deliberately restart the interface so every Interface-level AWG setting
    # (J/S/H/RandomTrailers/private key/listen port) is applied reliably.
    systemctl restart awg-quick@awg0.service
fi

if [[ "$SERVICE_CHANGED" == "1" ]]; then
    install -o root -g root -m 644 "$NEW_SERVICE" "$SERVICE"
    systemctl daemon-reload
    systemctl enable awg-iptables.service >/dev/null
    systemctl restart awg-iptables.service
fi

# Restarting awg-quick@awg0 cascades a restart to awg-iptables.service
# (Requires=), which finishes asynchronously; wait for it instead of
# checking immediately.
wait_active()
{
    local unit="$1"
    local i

    for i in $(seq 1 30); do
        systemctl is-active --quiet "$unit" && return 0
        sleep 0.5
    done

    return 1
}

wait_active awg-quick@awg0.service
wait_active awg-iptables.service

if [[ "$CONF_CHANGED" == "1" && "$PORT_CHANGED" == "1" && "$UFW_ACTIVE" == "1" && -n "$OLD_PORT" ]]; then
    if ufw status | grep -Eq '(^|[[:space:]])'"${OLD_PORT}"'/udp([[:space:]]|$)'; then
        ufw --force delete allow "${OLD_PORT}/udp" >/dev/null
    fi
fi

trap - ERR
rm -f "$CONF_BAK" "$SERVICE_BAK"
echo "SYNC_OK"
'@

    Invoke-Remote -IP $IP -Command $command | Out-Null
    Write-Log -Level 'OK' -Message "Server configuration applied successfully on $IP"
}

# ============================================================
# Bootstrap stage
# ============================================================

function Invoke-BootstrapStage {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Server
    )

    Write-Log -Level 'START' -Message "BOOTSTRAP stage: $($Server.Name) $($Server.IP):$($Server.Port)"

    $command = @"
chmod +x /root/bootstrap.sh
/root/bootstrap.sh $($Server.Port)
"@

    Invoke-Remote `
        -IP $Server.IP `
        -Command $command |
        Out-Null

    $state = Get-ServerBootstrapState -IP $Server.IP
    if ($state -ne 'READY') {
        throw "Bootstrap verification failed: $($Server.Name) state=$state"
    }

    Write-Log -Level 'OK' -Message "Bootstrap completed and verified: $($Server.Name)"
}

# ============================================================
# Security stage
# ============================================================

function Invoke-SecurityStage {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Server
    )

    Write-Log -Level 'START' -Message "SECURITY stage: $($Server.Name) $($Server.IP):$($Server.Port)"

    $command = @"
chmod +x /root/secure.sh
/root/secure.sh $($Server.Port)
"@

    Invoke-Remote `
        -IP $Server.IP `
        -Command $command |
        Out-Null

    if (-not (Test-Ssh -IP $Server.IP)) {
        throw "SSH verification failed after secure.sh: $($Server.Name)"
    }

    if (-not (Test-Secured `
        -IP $Server.IP `
        -Port ([string]$Server.Port))) {

        throw "Security verification failed: $($Server.Name)"
    }

    Write-Log -Level 'OK' -Message "Security hardening completed and verified: $($Server.Name)"
}

# ============================================================
# Validation
# ============================================================

foreach ($file in @(
    $ServersFile,
    $EnvFile,
    $TemplateFile,
    $UpgradeFile,
    $BootstrapFile,
    $SecureFile,
    $FirewallTemplate
)) {
    if (-not (Test-Path $file)) {
        throw "Required file not found: $file"
    }
}

Write-Log -Level 'OK' -Message 'Required local files verified.'

$Env = Read-EnvFile $EnvFile
Test-Environment -Env $Env
Write-Log -Level 'OK' -Message 'server.env validated. Secret values are not logged.'

$ServersLoaded = Read-ServersFile -Path $ServersFile

if ($ServersLoaded.Format -eq 'legacy') {
    if ($Check) {
        Write-Log -Level 'WARN' -Message 'servers.txt uses the legacy format (Name;IP;Port;Enabled): migration is required. Run sync-servers.ps1 -Mode VPN without -Check. It is read here as Role=vpn-server, Type=amnezia.'
    }
    else {
        $migration = Convert-ServersFileToCurrent -Path $ServersFile
        Write-Log -Level 'OK' -Message "servers.txt migrated to the current format (Name;IP;Port;Role;Type;Enabled): $($migration.Count) server(s) as vpn-server/amnezia. Backup: $($migration.Backup)"
        $ServersLoaded = Read-ServersFile -Path $ServersFile
    }
}

# This mode handles only Role = vpn-server; seg-gateway and seg-exit belong to -Mode SEG.
$Servers = @(Select-ServersForMode -Servers @($ServersLoaded.Servers) -Mode VPN)

if ($Servers.Count -eq 0) {
    throw 'servers.txt contains no servers with Role = vpn-server.'
}

Write-Log -Level 'OK' -Message "servers.txt loaded: $($Servers.Count) server(s)."

if (-not $ServerName) {
    $ServerName = (Read-Host 'Server name (or "all")').Trim()
}

if ($ServerName -eq 'all') {

    $Targets = @(
        $Servers |
        Where-Object {
            (-not [string]::IsNullOrWhiteSpace([string]$_.Enabled)) -and ([string]$_.Enabled).Trim().ToLowerInvariant() -eq 'true'
        }
    )

}
else {

    $Targets = @(
        $Servers |
        Where-Object {
            $_.Name -eq $ServerName -and
            (-not [string]::IsNullOrWhiteSpace([string]$_.Enabled)) -and ([string]$_.Enabled).Trim().ToLowerInvariant() -eq 'true'
        }
    )
}

if ($Targets.Count -eq 0) {
    throw "Enabled server not found: $ServerName"
}

Write-Log -Level 'INFO' -Message "Selected targets: $($Targets.Name -join ', ')"

# ============================================================
# Main
# ============================================================

# Prepare existing local client configs once per run.
# An empty peer list is valid for READY/DEGRADED servers and when the last client was removed.
$script:LocalConfigDrift = $false

if ($Check) {
    Write-Log -Level 'INFO' -Message 'CHECK mode: nothing is changed locally or on the VPS, no confirmations are asked.'
}

Sync-LocalClientConfigs -Env $Env -CheckOnly:$Check
Test-ClientEndpoints -Servers $Servers

$Results = @()

foreach ($Server in $Targets) {

    $temp = $null
    $ServerStatus = 'ERROR'
    $ServerMessage = 'Unexpected failure.'
    $Endpoint = "$($Server.IP):$($Server.Port)"

    Write-Log -Level 'START' -Message "Server processing started: $($Server.Name) $Endpoint"

    try {

        if (-not (Test-Ssh -IP $Server.IP)) {
            $ServerStatus = 'UNREACHABLE'
            $ServerMessage = 'SSH connection failed.'
            continue
        }

        $temp = Join-Path `
            ([System.IO.Path]::GetTempPath()) `
            ("amnezia-" + [Guid]::NewGuid().ToString('N'))

        New-Item `
            -ItemType Directory `
            -Path $temp |
            Out-Null

        Write-Log -Level 'INFO' -Message "Temporary directory created for $($Server.Name): $temp"

        # ----------------------------------------------------
        # CHECK mode: read-only comparison, then next server.
        # ----------------------------------------------------

        if ($Check) {

            $checkState = Get-ServerBootstrapState -IP $Server.IP
            Write-Log -Level 'INFO' -Message "Check: $($Server.Name) state=$checkState"

            if ($checkState -eq 'NEW') {
                $ServerStatus = 'CHANGES'
                $ServerMessage = 'New VPS: upgrade and bootstrap are required.'
                continue
            }

            $checkConfig = New-CandidateConfig `
                -Server $Server `
                -Env $Env `
                -TempDirectory $temp

            $checkFirewall = New-CandidateFirewall `
                -Server $Server `
                -Env $Env `
                -TempDirectory $temp

            $checkStatus = Get-SyncStatusByHash `
                -IP $Server.IP `
                -ConfigPath $checkConfig `
                -FirewallPath $checkFirewall

            Write-Log -Level 'INFO' -Message "Comparison result for $($Server.Name): AWG=$($checkStatus['CONFIG']); iptables-service=$($checkStatus['FIREWALL'])"

            $checkProblems = @()

            if ($checkState -eq 'DEGRADED') {
                $checkProblems += 'AmneziaWG is degraded (repair bootstrap required)'
            }

            if ($checkStatus['CONFIG'] -ne 'SAME') {
                $checkProblems += "awg0.conf: $($checkStatus['CONFIG'])"
            }

            if ($checkStatus['FIREWALL'] -ne 'SAME') {
                $checkProblems += "awg-iptables.service: $($checkStatus['FIREWALL'])"
            }

            $checkSecured = Test-Secured -IP $Server.IP -Port ([string]$Server.Port)

            if (-not $checkSecured) {
                $checkProblems += 'security hardening is incomplete'
            }

            # Baseline of a healthy VPN server (roadmap, item 26): STATE=READY, VPN=UP, SECURITY=OK.
            # READY means that awg0 and the firewall service are active, i.e. the VPN is up.
            Write-Log -Level 'INFO' -Message "Check baseline: $($Server.Name) STATE=$checkState VPN=$(if ($checkState -eq 'READY') { 'UP' } else { 'NOT_READY' }) SECURITY=$(if ($checkSecured) { 'OK' } else { 'FAIL' })"

            if ($checkProblems.Count -eq 0) {
                $ServerStatus = 'OK'
                $ServerMessage = 'Configuration and security state are current (check only).'
            }
            else {
                $ServerStatus = 'CHANGES'
                $ServerMessage = "Changes required: $($checkProblems -join '; ')."
            }

            continue
        }

        # ----------------------------------------------------
        # Always prepare and copy current Linux artifacts.
        # This also guarantees LF line endings.
        # ----------------------------------------------------

        $TempUpgrade = New-LinuxCopy `
            -Source $UpgradeFile `
            -TempDirectory $temp

        $TempBootstrap = New-LinuxCopy `
            -Source $BootstrapFile `
            -TempDirectory $temp

        $TempSecure = New-LinuxCopy `
            -Source $SecureFile `
            -TempDirectory $temp

        $TempFirewall = New-CandidateFirewall `
            -Server $Server `
            -Env $Env `
            -TempDirectory $temp

        Copy-ToServer `
            -IP $Server.IP `
            -Files @(
                $TempUpgrade,
                $TempBootstrap,
                $TempSecure
            )

        $BootstrapState = Get-ServerBootstrapState -IP $Server.IP

        # ====================================================
        # NEW / NOT FULLY CONFIGURED SERVER
        # ====================================================

        if ($BootstrapState -eq 'NEW') {

            Write-Log -Level 'INFO' -Message "$($Server.Name): VPS is new; full upgrade/bootstrap path selected."

            $upgradeCompleted = Invoke-UpgradeStage -IP $Server.IP

            if (-not $upgradeCompleted) {
                $ServerStatus = 'PENDING'
                $ServerMessage = 'Upgrade stage stopped by user.'
                continue
            }

            if (-not (Confirm-Action `
                'Upgrade завершён. Перейти к настройке AmneziaWG?')) {

                $ServerStatus = 'PENDING'
                $ServerMessage = 'Upgrade complete; bootstrap postponed by user.'
                continue
            }

            # A new VPS is upgraded before we require a client. This preserves
            # completed OS maintenance even when first-client creation is postponed.
            if (-not (Initialize-Peers)) {
                $ServerStatus = 'PENDING'
                $ServerMessage = 'Upgrade complete; bootstrap postponed because no clients are configured.'
                continue
            }

            # add-client.ps1 already writes current values, but synchronize again
            # so all persistent client profiles are guaranteed to match server.env.
            Sync-LocalClientConfigs -Env $Env

            $TempConfig = New-CandidateConfig `
                -Server $Server `
                -Env $Env `
                -TempDirectory $temp

            Initialize-RemoteStaging -IP $Server.IP

            Copy-ToServer `
                -IP $Server.IP `
                -Files @(
                    $TempConfig,
                    $TempFirewall
                ) `
                -Destination '/root/.amnezia-sync/'

            Invoke-Remote -IP $Server.IP -Command 'chmod 600 /root/.amnezia-sync/awg0.conf; chmod 644 /root/.amnezia-sync/awg-iptables.service' -Quiet | Out-Null

            Invoke-BootstrapStage -Server $Server

            Write-Log -Level 'INFO' -Message 'AmneziaWG is configured. Verify VPN from a client device before security hardening.'

            if (-not (Confirm-Action `
                'VPN проверен и работает. Перейти к security hardening?')) {

                $ServerStatus = 'PENDING'
                $ServerMessage = 'Bootstrap complete; security hardening postponed pending VPN verification.'
                continue
            }

            Invoke-SecurityStage -Server $Server

            $ServerStatus = 'OK'
            $ServerMessage = 'New VPS configured, secured and verified.'
            continue
        }

        # ====================================================
        # DEGRADED / PARTIALLY CONFIGURED SERVER
        # ====================================================

        if ($BootstrapState -eq 'DEGRADED') {
            Write-Log -Level 'WARN' -Message "$($Server.Name): AmneziaWG is installed but the server is degraded or partially configured. dist-upgrade will not be run automatically."

            if (-not (Confirm-Action 'Запустить восстановительный bootstrap.sh без dist-upgrade?')) {
                $ServerStatus = 'PENDING'
                $ServerMessage = 'Degraded server detected; repair postponed by user.'
                continue
            }

            $TempConfig = New-CandidateConfig -Server $Server -Env $Env -TempDirectory $temp
            Initialize-RemoteStaging -IP $Server.IP
            Copy-ToServer -IP $Server.IP -Files @($TempConfig, $TempFirewall) -Destination '/root/.amnezia-sync/'
            Invoke-Remote -IP $Server.IP -Command 'chmod 600 /root/.amnezia-sync/awg0.conf; chmod 644 /root/.amnezia-sync/awg-iptables.service' -Quiet | Out-Null
            Invoke-BootstrapStage -Server $Server

            $ServerStatus = 'PENDING'
            $ServerMessage = 'Repair bootstrap completed; verify VPN and rerun sync to continue.'
            continue
        }

        # ====================================================
        # CONFIGURED SERVER
        # ====================================================

        Write-Log -Level 'OK' -Message "$($Server.Name): VPS is already bootstrapped."

        if (-not (Confirm-Action `
            'Выполнить синхронизацию с локальной конфигурацией?')) {

            $ServerStatus = 'SKIPPED'
            $ServerMessage = 'Synchronization skipped by user.'
            continue
        }

        $TempConfig = New-CandidateConfig `
            -Server $Server `
            -Env $Env `
            -TempDirectory $temp

        $TempFirewall = New-CandidateFirewall `
            -Server $Server `
            -Env $Env `
            -TempDirectory $temp

        Initialize-RemoteStaging -IP $Server.IP

        Copy-ToServer `
            -IP $Server.IP `
            -Files @(
                $TempConfig,
                $TempFirewall
            ) `
            -Destination '/root/.amnezia-sync/'

        Invoke-Remote -IP $Server.IP -Command 'chmod 600 /root/.amnezia-sync/awg0.conf; chmod 644 /root/.amnezia-sync/awg-iptables.service' -Quiet | Out-Null

        $status = Get-SyncStatus -IP $Server.IP

        $configState = $status['CONFIG']
        $firewallState = $status['FIREWALL']

        Write-Log -Level 'INFO' -Message "Comparison result for $($Server.Name): AWG=$configState; iptables-service=$firewallState"

        $NeedsSync = (
            $configState -ne 'SAME' -or
            $firewallState -ne 'SAME'
        )

        $ConfigurationCurrent = $false

        if (-not $NeedsSync) {
            Write-Log -Level 'OK' -Message 'Server configuration already matches the local source of truth.'
            $ConfigurationCurrent = $true
        }
        else {
            Write-Log -Level 'WARN' -Message 'Server configuration differs from the local source of truth.'

            if (Confirm-Action 'Применить изменения?') {

                Invoke-Sync -IP $Server.IP

                $postSyncStatus = Get-SyncStatus -IP $Server.IP

                if (
                    $postSyncStatus['CONFIG'] -ne 'SAME' -or
                    $postSyncStatus['FIREWALL'] -ne 'SAME'
                ) {
                    throw "Post-sync verification failed: $($Server.Name)"
                }

                Write-Log -Level 'OK' -Message "Synchronization completed and verified: $($Server.Name)"
                $ConfigurationCurrent = $true
            }
            else {
                $ServerStatus = 'SKIPPED'
                $ServerMessage = 'Differences detected but changes were not applied by user.'
                continue
            }
        }

        # ====================================================
        # Resume unfinished security stage if necessary
        # ====================================================

        if ($ConfigurationCurrent) {

            $Secured = Test-Secured `
                -IP $Server.IP `
                -Port ([string]$Server.Port)

            if (-not $Secured) {

                Write-Log -Level 'WARN' -Message "Security hardening is incomplete: $($Server.Name)"

                if (Confirm-Action 'Запустить secure.sh?') {
                    Invoke-SecurityStage -Server $Server
                }
                else {
                    $ServerStatus = 'PENDING'
                    $ServerMessage = 'Configuration current; security hardening postponed by user.'
                    continue
                }
            }
            else {
                Write-Log -Level 'OK' -Message "Security state verified: $($Server.Name)"
            }
        }

        $ServerStatus = 'OK'
        $ServerMessage = 'Configuration and security state are current.'
    }
    catch {
        $ServerStatus = 'ERROR'
        $ServerMessage = Get-ErrorDescription -ErrorRecord $_

        Write-Log -Level 'ERROR' -Message "$($Server.Name): $ServerMessage"

        if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
            Write-Log -Level 'ERROR' -Message $_.InvocationInfo.PositionMessage -LogOnly
        }

        if ($_.ScriptStackTrace) {
            Write-Log -Level 'ERROR' -Message $_.ScriptStackTrace -LogOnly
        }
    }
    finally {

        # CHECK mode never writes to the VPS, so there is nothing to clear.
        if (-not $Check) {
            try {
                if (Test-Ssh -IP $Server.IP -Quiet) {
                    Clear-RemoteStaging -IP $Server.IP
                }
            }
            catch {
                Write-Log -Level 'WARN' -Message "Unable to clear remote staging files on $($Server.IP)."
            }
        }

        if ($temp -and (Test-Path $temp)) {
            Remove-Item `
                -Recurse `
                -Force `
                $temp `
                -ErrorAction SilentlyContinue

            Write-Log -Level 'INFO' -Message "Temporary files removed for $($Server.Name)."
        }

        $Results += [PSCustomObject]@{
            Name     = $Server.Name
            Endpoint = $Endpoint
            Status   = $ServerStatus
            Message  = $ServerMessage
        }

        if ($ServerStatus -eq 'OK') {
            Write-Log -Level 'OK' -Message "$($Server.Name): $ServerStatus - $ServerMessage"
        }
        elseif ($ServerStatus -eq 'ERROR' -or $ServerStatus -eq 'UNREACHABLE') {
            Write-Log -Level 'ERROR' -Message "$($Server.Name): $ServerStatus - $ServerMessage"
        }
        else {
            Write-Log -Level 'WARN' -Message "$($Server.Name): $ServerStatus - $ServerMessage"
        }
    }
}

# ============================================================
# Summary
# ============================================================

Write-Log -Level 'INFO' -Message 'Final server summary:'

foreach ($result in $Results) {
    $level = if ($result.Status -eq 'OK') {
        'OK'
    }
    elseif ($result.Status -eq 'ERROR' -or $result.Status -eq 'UNREACHABLE') {
        'ERROR'
    }
    else {
        'WARN'
    }

    Write-Log `
        -Level $level `
        -Message "$($result.Name) $($result.Endpoint) $($result.Status) - $($result.Message)"
}

$Failed = @(
    $Results |
    Where-Object {
        $_.Status -in @('ERROR', 'UNREACHABLE')
    }
)

if ($Failed.Count -gt 0) {
    Write-Log -Level 'DONE' -Message "Completed with errors: $($Failed.Count) server(s) failed. Log: $LogFile"
    exit 1
}

if ($Check) {
    $NeedChanges = @($Results | Where-Object { $_.Status -eq 'CHANGES' })

    if ($NeedChanges.Count -gt 0 -or $script:LocalConfigDrift) {
        Write-Log -Level 'DONE' -Message "Check completed: $($NeedChanges.Count) server(s) need changes; local client configs differ from server.env: $($script:LocalConfigDrift). Nothing was changed. Log: $LogFile"
        exit 2
    }

    Write-Log -Level 'DONE' -Message "Check completed: all selected servers and local configs are current. Nothing was changed. Log: $LogFile"
    exit 0
}

$Pending = @(
    $Results |
    Where-Object {
        $_.Status -in @('PENDING', 'SKIPPED')
    }
)

if ($Pending.Count -gt 0) {
    Write-Log -Level 'DONE' -Message "Completed without technical errors; $($Pending.Count) server(s) pending/skipped. Log: $LogFile"
    exit 0
}

Write-Log -Level 'DONE' -Message "All selected servers completed successfully. Log: $LogFile"
exit 0
