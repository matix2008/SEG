# Common functions for SEG scripts (roadmap, principle 3).
# Copies of the tested helpers from the VPN scripts: the VPN scripts are not changed to use this file.
# Keep this file ASCII-only: .ps1 files are read by Windows PowerShell 5.1.

# ============================================================
# Logging
# ============================================================

function Invoke-LogRotation {
    if (-not (Test-Path -LiteralPath $script:LogFile)) {
        return
    }

    $size = (Get-Item -LiteralPath $script:LogFile).Length

    if ($size -lt $script:LogMaxBytes) {
        return
    }

    $oldest = "$($script:LogFile).$($script:LogBackupCount)"
    Remove-Item -LiteralPath $oldest -Force -ErrorAction SilentlyContinue

    for ($i = $script:LogBackupCount - 1; $i -ge 1; $i--) {
        $source = "$($script:LogFile).$i"

        if (Test-Path -LiteralPath $source) {
            Move-Item -LiteralPath $source -Destination "$($script:LogFile).$($i + 1)" -Force
        }
    }

    Move-Item -LiteralPath $script:LogFile -Destination "$($script:LogFile).1" -Force
}

function Initialize-Logging {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$ScriptName
    )

    $script:ScriptName = $ScriptName
    $script:RunId = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $script:LogsDir = Join-Path $Root 'logs'
    $script:LogFile = Join-Path $script:LogsDir 'amnezia.log'
    $script:LogMaxBytes = 10MB
    $script:LogBackupCount = 3
    $script:LogEncoding = New-Object System.Text.UTF8Encoding($false)

    New-Item -ItemType Directory -Force -Path $script:LogsDir | Out-Null

    Invoke-LogRotation
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('START', 'INFO', 'OK', 'WARN', 'ERROR', 'DONE')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [switch]$LogOnly
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$timestamp [$($script:ScriptName)] [$($script:RunId)] [$Level] $Message"

    [System.IO.File]::AppendAllText($script:LogFile, $line + "`n", $script:LogEncoding)

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

        if ($answer -in @('y', 'yes', [string][char]0x0434, ([string][char]0x0434 + [char]0x0430))) {
            Write-Log -Level 'INFO' -Message "Confirmation: $Message -> YES"
            return $true
        }

        if ($answer -in @('n', 'no', [string][char]0x043d, ([string][char]0x043d + [char]0x0435 + [char]0x0442))) {
            Write-Log -Level 'INFO' -Message "Confirmation: $Message -> NO"
            return $false
        }
    }
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

    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-EnvFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $result = @{}
    $leaf = Split-Path -Leaf $Path

    foreach ($raw in Get-Content -LiteralPath $Path) {
        $line = $raw.Trim()

        if (-not $line -or $line.StartsWith('#')) {
            continue
        }

        $parts = @($line -split '=', 2)

        if ($parts.Count -ne 2) {
            throw "Invalid line in ${leaf}: $line"
        }

        $name = $parts[0].Trim()

        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "Invalid empty parameter name in $leaf"
        }

        $result[$name] = $parts[1].Trim()
    }

    return $result
}

# ============================================================
# Cryptography
# ============================================================

function Resolve-AwgExecutable {
    $command = Get-Command awg.exe -ErrorAction SilentlyContinue

    if ($command) {
        return $command.Source
    }

    $command = Get-Command awg -ErrorAction SilentlyContinue

    if ($command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'AmneziaWG\awg.exe'),
        (Join-Path $env:ProgramFiles 'AmneziaVPN\awg.exe'),
        (Join-Path $env:LOCALAPPDATA 'AmneziaWG\awg.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw 'awg.exe was not found. Install AmneziaWG tools or add awg.exe to PATH.'
}

function Invoke-AwgSecretCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Awg,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$InputText
    )

    $previousErrorActionPreference = $ErrorActionPreference

    try {
        # Windows PowerShell 5.1 can turn stderr from a native executable
        # into a terminating PowerShell error when ErrorActionPreference is Stop.
        # awg.exe success/failure is determined by its exit code.
        $ErrorActionPreference = 'Continue'

        $output = if ($PSBoundParameters.ContainsKey('InputText')) {
            # Piping from PowerShell prepends a UTF-8 BOM when the console
            # code page is 65001, and awg.exe rejects it. Feed stdin through
            # cmd.exe; the secret travels via the environment, not argv.
            $env:AWG_SECRET_INPUT = $InputText
            $env:AWG_SECRET_EXE   = $Awg
            try {
                cmd.exe /d /c "echo %AWG_SECRET_INPUT%| `"%AWG_SECRET_EXE%`" $Command 2>&1"
            }
            finally {
                Remove-Item Env:AWG_SECRET_INPUT, Env:AWG_SECRET_EXE -ErrorAction SilentlyContinue
            }
        }
        else {
            & $Awg $Command 2>&1
        }

        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $lines = @($output | ForEach-Object { [string]$_ })

    if ($code -ne 0) {
        foreach ($line in $lines) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Log -Level 'ERROR' -Message "awg ${Command}: $line"
            }
        }

        throw "awg $Command failed with exit code $code"
    }

    $value = @(
        $lines |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    ) | Select-Object -Last 1

    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "awg $Command returned an empty result"
    }

    return $value.Trim()
}

function New-AwgKeyPair {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Awg
    )

    $private = Invoke-AwgSecretCommand -Awg $Awg -Command 'genkey'
    $public = Invoke-AwgSecretCommand -Awg $Awg -Command 'pubkey' -InputText $private

    if ($private -notmatch '^[A-Za-z0-9+/]{43}=$' -or $public -notmatch '^[A-Za-z0-9+/]{43}=$') {
        throw 'Generated AmneziaWG key pair has an unexpected format.'
    }

    return [pscustomobject]@{ Private = $private; Public = $public }
}

function Get-CryptoRandomInt {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Min,

        [Parameter(Mandatory = $true)]
        [int]$Max
    )

    if ($Min -gt $Max) {
        throw "Invalid random range: $Min..$Max"
    }

    [uint64]$range = ([uint64]$Max - [uint64]$Min) + 1
    [uint64]$sampleSpace = 4294967296
    [uint64]$limit = $sampleSpace - ($sampleSpace % $range)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    try {
        $bytes = New-Object byte[] 4
        do {
            $rng.GetBytes($bytes)
            [uint64]$sample = [System.BitConverter]::ToUInt32($bytes, 0)
        } while ($sample -ge $limit)

        return [int]([uint64]$Min + ($sample % $range))
    }
    finally {
        $rng.Dispose()
    }
}

function New-RandomHexString {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Bytes
    )

    $buffer = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    try {
        $rng.GetBytes($buffer)
    }
    finally {
        $rng.Dispose()
    }

    return (($buffer | ForEach-Object { $_.ToString('x2') }) -join '')
}

function New-AwgHeaderValues {
    $values = @()

    while ($values.Count -lt 4) {
        [uint32]$value = Get-CryptoRandomInt -Min 5 -Max 2147483647

        # 0 and compatibility values 1..4 are intentionally excluded.
        if ($value -le 4 -or $values -contains $value) {
            continue
        }

        $values += $value
    }

    return $values
}

function Read-HashFile {
    # Parses a sha256sum-style file ("<sha256>  <name>"); returns a hashtable name -> lowercase hash.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Hash file not found: $Path"
    }

    $result = @{}

    foreach ($raw in Get-Content -LiteralPath $Path) {
        $line = $raw.Trim()

        if (-not $line -or $line.StartsWith('#')) {
            continue
        }

        if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(\S+)$') {
            throw "Invalid line in $(Split-Path -Leaf $Path): $line"
        }

        $name = $Matches[2]

        if ($result.ContainsKey($name)) {
            throw "Duplicate entry in $(Split-Path -Leaf $Path): $name"
        }

        $result[$name] = $Matches[1].ToLowerInvariant()
    }

    return $result
}

function Assert-FileSha256 {
    # Throws when the file does not exist, has no recorded hash, or does not match it.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [hashtable]$Hashes,

        [Parameter(Mandatory = $false)]
        [string]$Name
    )

    if (-not $Name) {
        $Name = Split-Path -Leaf $Path
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path"
    }

    if (-not $Hashes.ContainsKey($Name)) {
        throw "No recorded SHA-256 for $Name"
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($actual -ne $Hashes[$Name]) {
        throw "SHA-256 of $Path does not match the recorded value for $Name (expected $($Hashes[$Name]), actual $actual). Download the official package again."
    }
}

function Get-VerifiedSingBoxLinuxPackage {
    # Returns the path of the Linux package for VPS2 after checking it against seg\sing-box.sha256.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $name = "sing-box-$Version-linux-amd64.tar.gz"
    $path = Join-Path $Root "tools\$name"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "Linux package not found: $path. Download it from the official sing-box release v$Version into tools\."
    }

    Assert-FileSha256 -Path $path -Hashes (Read-HashFile -Path (Join-Path $Root 'seg\sing-box.sha256')) -Name $name

    return $path
}

function Resolve-SingBoxExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$RequiredVersion
    )

    $local = Join-Path $Root 'tools\sing-box.exe'
    $exe = $null

    if (Test-Path -LiteralPath $local) {
        $exe = $local

        # The bundled executable must be the official one recorded in seg\sing-box.sha256.
        Assert-FileSha256 -Path $local -Hashes (Read-HashFile -Path (Join-Path $Root 'seg\sing-box.sha256')) -Name 'sing-box.exe'
    }
    else {
        $command = Get-Command sing-box.exe -ErrorAction SilentlyContinue

        if ($command) {
            $exe = $command.Source
        }
    }

    if (-not $exe) {
        throw "sing-box $RequiredVersion was not found. Put sing-box.exe into $(Join-Path $Root 'tools') or add it to PATH."
    }

    $previousErrorActionPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = 'Continue'
        $first = @(& $exe version 2>&1 | ForEach-Object { [string]$_ } | Select-Object -First 1)
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($first.Count -eq 0 -or $first[0] -notmatch "^sing-box version $([regex]::Escape($RequiredVersion))\s*$") {
        throw "sing-box $RequiredVersion is required; $exe reports: $($first -join ' ')"
    }

    return $exe
}

# ============================================================
# Remote nodes: SSH, copy, reboot, upgrade
# Every connection uses BatchMode and StrictHostKeyChecking=yes: the host key of a node must be
# verified and stored in known_hosts by the user beforehand (README, section 5).
# ============================================================

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
        $record = "$timestamp [$Source] [$($script:RunId)] [OUTPUT] $line"

        [System.IO.File]::AppendAllText($script:LogFile, $record + "`n", $script:LogEncoding)

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
        # System.Diagnostics.Process is used directly: Windows PowerShell 5.1 can return an empty
        # ExitCode from Start-Process -PassThru with redirected native-process streams.
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
                # Best effort only; the timeout is already the primary result.
            }

            $stdoutText = $process.StandardOutput.ReadToEnd()
            $stderrText = $process.StandardError.ReadToEnd()

            if (-not $Quiet) {
                Write-LogOutput -Source "ssh:$IP" -Text $stdoutText
                Write-LogOutput -Source "ssh:$IP" -Text $stderrText
                Write-Log -Level 'WARN' -Message "SSH probe timed out after $($TimeoutMs / 1000)s: root@$IP"
            }

            return $false
        }

        # Flush the redirected streams before reading them and ExitCode.
        $process.WaitForExit()
        $stdoutText = $process.StandardOutput.ReadToEnd()
        $stderrText = $process.StandardError.ReadToEnd()
        $code = [int]$process.ExitCode

        if (-not $Quiet) {
            Write-LogOutput -Source "ssh:$IP" -Text $stdoutText
            Write-LogOutput -Source "ssh:$IP" -Text $stderrText
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

    # CRLF must not leak into the remote bash.
    $Command = $Command -replace "`r`n", "`n"
    $Command = $Command -replace "`r", "`n"

    $lines = New-Object System.Collections.Generic.List[string]
    $previousErrorActionPreference = $ErrorActionPreference

    try {
        # stderr of ssh.exe is diagnostic output, not a PowerShell exception: the exit code decides.
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

    $previousErrorActionPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = 'Continue'

        & scp @scpArgs 2>&1 |
        ForEach-Object {
            Write-LogOutput -Source "scp:$IP" -Text ([string]$_)
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

function New-LinuxCopy {
    # Writes an LF-only copy of a script or template into the temporary directory.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$TempDirectory
    )

    $destination = Join-Path $TempDirectory ([System.IO.Path]::GetFileName($Source))

    Write-Utf8Lf -Path $destination -Text (Get-Content -LiteralPath $Source -Raw)

    Write-Log -Level 'INFO' -Message "Prepared LF copy: $([System.IO.Path]::GetFileName($Source))"
    return $destination
}

function Wait-SshAfterReboot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IP
    )

    Write-Log -Level 'INFO' -Message "Waiting for reboot cycle: $IP"
    Start-Sleep -Seconds 3

    # First wait until the old SSH session goes away.
    for ($i = 0; $i -lt 20; $i++) {
        if (-not (Test-Ssh -IP $IP -Quiet)) {
            Write-Log -Level 'INFO' -Message "SSH went down during reboot: $IP"
            break
        }

        Start-Sleep -Seconds 2
    }

    # Then wait until SSH returns.
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-Ssh -IP $IP -Quiet) {
            Write-Log -Level 'OK' -Message "SSH restored after reboot: $IP"
            return
        }

        Start-Sleep -Seconds 5
    }

    throw "SSH did not return after reboot: $IP"
}

function Invoke-UpgradeStage {
    # Runs /root/upgrade.sh (already copied) until UPGRADE_OK, rebooting after confirmation when it asks to.
    # Returns $false when the user declined the reboot.
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

        $result = Invoke-Remote -IP $IP -Command $command -AllowFailure

        if ($result.Code -eq 0) {
            Write-Log -Level 'OK' -Message "Upgrade completed successfully on $IP"
            return $true
        }

        if ($result.Code -eq 255) {
            # ssh.exe failed or the connection dropped mid-upgrade. upgrade.sh is idempotent and repairs
            # an interrupted dpkg state, so wait for SSH and run it again.
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

        if (-not (Confirm-Action "Reboot $IP and continue the upgrade?")) {
            Write-Log -Level 'WARN' -Message "Configuration stopped after upgrade stage on $IP"
            return $false
        }

        $rebootCommand = @'
nohup bash -c 'sleep 1; reboot' >/dev/null 2>&1 &
exit 0
'@

        Invoke-Remote -IP $IP -Command $rebootCommand -AllowFailure | Out-Null

        Wait-SshAfterReboot -IP $IP
    }

    throw "upgrade.sh did not reach UPGRADE_OK after repeated runs on $IP"
}

# ============================================================
# Env file backups (parameterized by file)
# ============================================================

function Get-EnvBackups {
    # The timestamp in the name sorts chronologically; newest first.
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvFile
    )

    $dir = Split-Path -Parent $EnvFile
    $leaf = Split-Path -Leaf $EnvFile

    if (-not (Test-Path -LiteralPath $dir)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $dir -Filter "$leaf.*.bak" -File |
        Sort-Object Name -Descending
    )
}

function New-EnvBackup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvFile,

        [Parameter(Mandatory = $false)]
        [int]$KeepCount = 3
    )

    $leaf = Split-Path -Leaf $EnvFile
    $path = Join-Path (Split-Path -Parent $EnvFile) ("$leaf." + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '.bak')

    Copy-Item -LiteralPath $EnvFile -Destination $path

    Write-Log -Level 'OK' -Message "Backup of the current $leaf created: $path"

    @(Get-EnvBackups -EnvFile $EnvFile | Select-Object -Skip $KeepCount) | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force
        Write-Log -Level 'INFO' -Message "Old backup removed (keeping the last $KeepCount): $($_.Name)"
    }

    return $path
}
