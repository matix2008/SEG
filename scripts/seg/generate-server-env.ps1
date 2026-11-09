param(
    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$NoBackup,

    [Parameter(Mandatory = $false)]
    [switch]$Restore
)

# SEG mode of generate-server-env.ps1: creates or restores config\seg.env only.
# config\server.env (VPN mode) is never read for secrets and never changed.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ============================================================
# Paths and libraries
# ============================================================

$Root       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$EnvFile    = Join-Path $Root 'config\seg.env'
$VpnEnvFile = Join-Path $Root 'config\server.env'

$BackupKeepCount        = 3

# Margin below the computed no-fragmentation MTU limit (SEG.md, section 13).
$MtuMargin = 16

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $PSScriptRoot '..\lib\segenv.ps1')

$RequiredSingBoxVersion = $script:SegSingBoxVersion

Initialize-Logging -Root $Root -ScriptName (Split-Path -Leaf $PSCommandPath)

trap {
    Write-Log -Level 'ERROR' -Message $_.Exception.Message

    if ($_.ScriptStackTrace) {
        Write-Log -Level 'ERROR' -Message $_.ScriptStackTrace -LogOnly
    }

    Write-Log -Level 'DONE' -Message "FAILED. Log: $LogFile"
    exit 1
}

Write-Log -Level 'START' -Message $(if ($Restore) { 'SEG: restoring seg.env from backup.' } else { 'SEG: generating complete seg.env.' })
Write-Log -Level 'INFO' -Message "PowerShell version: $($PSVersionTable.PSVersion)"

# ============================================================
# Validation helpers
# ============================================================

# The backhaul network must not overlap the VPN client network.
$ReservedNetworks = @(Get-SegReservedNetworks -VpnEnvFile $VpnEnvFile)

function Test-SegEnvFile {
    # Returns $null when the file is a valid seg.env, otherwise the problem text.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        Test-SegEnvironment -Env (Read-SegEnvFile -Path $Path) -ReservedNetworks $ReservedNetworks
        return $null
    }
    catch {
        return $_.Exception.Message
    }
}

# ============================================================
# Restore mode
# ============================================================

if ($Restore) {
    $backups = @(Get-EnvBackups -EnvFile $EnvFile)

    if ($backups.Count -eq 0) {
        throw "No seg.env backups found in $(Split-Path -Parent $EnvFile)"
    }

    $source = $backups[0]
    $problem = Test-SegEnvFile -Path $source.FullName

    if ($problem) {
        throw "Backup $($source.Name) is not a valid seg.env: $problem"
    }

    Write-Log -Level 'WARN' -Message "seg.env will be restored from the newest backup: $($source.Name)"

    if (-not $NoBackup -and (Test-Path -LiteralPath $EnvFile)) {
        Write-Log -Level 'INFO' -Message 'The current seg.env will be saved as a new backup first (a second -Restore undoes this one).'
    }
    elseif (Test-Path -LiteralPath $EnvFile) {
        Write-Log -Level 'WARN' -Message 'No backup of the current seg.env will be created because -NoBackup was specified.'
    }

    if (-not $Force) {
        if (-not (Confirm-Action 'Replace the current seg.env with the backup?')) {
            Write-Log -Level 'DONE' -Message 'CANCELLED.'
            exit 0
        }
    }

    if (-not $NoBackup -and (Test-Path -LiteralPath $EnvFile)) {
        [void](New-EnvBackup -EnvFile $EnvFile -KeepCount $BackupKeepCount)
    }

    Copy-Item -LiteralPath $source.FullName -Destination $EnvFile -Force

    Write-Log -Level 'OK' -Message "seg.env restored from $($source.Name)"
    Write-Log -Level 'WARN' -Message 'SEG servers and client profiles still use the previous keys until sync-servers.ps1 -Mode SEG is applied.'
    Write-Log -Level 'DONE' -Message "SUCCESS. Log: $LogFile"
    exit 0
}

# ============================================================
# Tools (checked before any prompt)
# ============================================================

$SingBox = Resolve-SingBoxExecutable -Root $Root -RequiredVersion $RequiredSingBoxVersion
Write-Log -Level 'INFO' -Message "Using sing-box ${RequiredSingBoxVersion}: $SingBox"

$Awg = Resolve-AwgExecutable
Write-Log -Level 'INFO' -Message "Using AWG executable: $Awg"

# ============================================================
# Non-secret settings (defaults; kept from an existing seg.env)
# ============================================================

$Settings = [ordered]@{
    SEG_REALITY_SERVER_NAME      = 'www.microsoft.com'
    SEG_REALITY_DEST             = 'www.microsoft.com:443'
    SEG_REALITY_FLOW             = 'xtls-rprx-vision'
    SEG_REALITY_FINGERPRINT      = 'chrome'
    SEG_BACKHAUL_NETWORK         = '10.77.0.0/30'
    SEG_BACKHAUL_VPS1            = '10.77.0.2'
    SEG_BACKHAUL_VPS2            = '10.77.0.1'
    SEG_BACKHAUL_PORT            = '42100'
    SEG_BACKHAUL_INTERFACE       = 'awg-backhaul'
    SEG_BACKHAUL_RANDOM_TRAILERS = 'on'
    SEG_MARK                     = '0x5e90'
    SEG_UNMATCHED_MARK           = '0x5e91'
    SEG_UNMATCHED_POLICY         = 'direct'
}

if (Test-Path -LiteralPath $EnvFile) {
    try {
        $existing = Read-SegEnvFile -Path $EnvFile

        foreach ($key in @($Settings.Keys)) {
            if ($existing.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($existing[$key])) {
                $Settings[$key] = $existing[$key]
            }
        }

        Write-Log -Level 'INFO' -Message 'Non-secret settings (REALITY server name and dest, backhaul network, port, interface, RandomTrailers, marks, policy) are kept from the existing seg.env. Secrets and AmneziaWG parameters are regenerated.'
    }
    catch {
        Write-Log -Level 'WARN' -Message "The existing seg.env cannot be read ($($_.Exception.Message)); default settings are used."
    }
}

if ($Settings['SEG_BACKHAUL_RANDOM_TRAILERS'] -notin @('on', 'off')) {
    throw "SEG_BACKHAUL_RANDOM_TRAILERS must be on or off (found '$($Settings['SEG_BACKHAUL_RANDOM_TRAILERS'])')."
}

# ============================================================
# Confirmation
# ============================================================

if (Test-Path -LiteralPath $EnvFile) {
    Write-Log -Level 'WARN' -Message "Existing seg.env will be replaced: $EnvFile"

    if ($NoBackup) {
        Write-Log -Level 'WARN' -Message 'No backup will be created (-NoBackup), so the old private keys are not retained.'
    }
    else {
        Write-Log -Level 'WARN' -Message "The current seg.env will be saved as config\seg.env.<time>.bak (unencrypted; the last $BackupKeepCount copies are kept). Use -NoBackup if the old private keys are compromised."
    }

    if (-not $Force) {
        if (-not (Confirm-Action 'Generate a new seg.env and replace the existing one?')) {
            Write-Log -Level 'DONE' -Message 'CANCELLED.'
            exit 0
        }
    }
    else {
        Write-Log -Level 'INFO' -Message 'Overwrite confirmation skipped because -Force was specified.'
    }
}

# ============================================================
# Generate secrets
# ============================================================

$previousErrorActionPreference = $ErrorActionPreference

try {
    $ErrorActionPreference = 'Continue'
    $keypairLines = @(& $SingBox generate reality-keypair 2>&1 | ForEach-Object { [string]$_ })
    $keypairCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}

if ($keypairCode -ne 0) {
    throw "sing-box generate reality-keypair failed with exit code $keypairCode"
}

$RealityPrivate = (($keypairLines | Where-Object { $_ -match '^PrivateKey:' }) -replace '^PrivateKey:\s*', '' | Select-Object -First 1)
$RealityPublic  = (($keypairLines | Where-Object { $_ -match '^PublicKey:' }) -replace '^PublicKey:\s*', '' | Select-Object -First 1)

if (-not $RealityPrivate -or -not $RealityPublic) {
    throw 'sing-box generate reality-keypair returned an unexpected result.'
}

$RealityPrivate = $RealityPrivate.Trim()
$RealityPublic  = $RealityPublic.Trim()
$RealityShortId = New-RandomHexString -Bytes 8

Write-Log -Level 'OK' -Message 'REALITY key pair and short id generated. Values are not written to the log.'

$ExitKeys    = New-AwgKeyPair -Awg $Awg
$GatewayKeys = New-AwgKeyPair -Awg $Awg
$Psk         = Invoke-AwgSecretCommand -Awg $Awg -Command 'genpsk'

if ($Psk -notmatch '^[A-Za-z0-9+/]{43}=$') {
    throw 'Generated PSK has an unexpected format.'
}

Write-Log -Level 'OK' -Message 'Backhaul key pairs (exit and gateway) and PSK generated. Values are not written to the log.'

# ============================================================
# Generate AmneziaWG parameters
# ============================================================

$JC   = Get-CryptoRandomInt -Min 4 -Max 12
$JMIN = Get-CryptoRandomInt -Min 20 -Max 60
$JMAX = Get-CryptoRandomInt -Min ($JMIN + 20) -Max 120

# S1..S4 are equal, as in VPN mode with RandomTrailers.
$SCommon = Get-CryptoRandomInt -Min 15 -Max 150
$S1 = $SCommon
$S2 = $SCommon
$S3 = $SCommon
$S4 = $SCommon

$Headers = New-AwgHeaderValues

if (@($Headers | Select-Object -Unique).Count -ne 4) {
    throw 'Generated H1-H4 values are not unique.'
}

$MtuLimit = Get-SegBackhaulMtuLimit -S4 $S4 -RandomTrailers $Settings['SEG_BACKHAUL_RANDOM_TRAILERS']
$Mtu = [int][math]::Min(1420, [math]::Max(576, $MtuLimit - $MtuMargin))

Write-Log -Level 'OK' -Message "AmneziaWG parameters generated: JC=$JC JMIN=$JMIN JMAX=$JMAX S1-S4=$S1 RandomTrailers=$($Settings['SEG_BACKHAUL_RANDOM_TRAILERS']) MTU=$Mtu (limit without fragmentation $MtuLimit). H1-H4 are not written to the log."

# ============================================================
# Build complete seg.env
# ============================================================

$Content = @"
SEG_REALITY_PRIVATE_KEY=$RealityPrivate
SEG_REALITY_PUBLIC_KEY=$RealityPublic
SEG_REALITY_SHORT_ID=$RealityShortId
SEG_REALITY_SERVER_NAME=$($Settings['SEG_REALITY_SERVER_NAME'])
SEG_REALITY_DEST=$($Settings['SEG_REALITY_DEST'])
SEG_REALITY_FLOW=$($Settings['SEG_REALITY_FLOW'])
SEG_REALITY_FINGERPRINT=$($Settings['SEG_REALITY_FINGERPRINT'])

SEG_BACKHAUL_PRIVATE_KEY_VPS1=$($ExitKeys.Private)
SEG_BACKHAUL_PUBLIC_KEY_VPS1=$($ExitKeys.Public)
SEG_BACKHAUL_PRIVATE_KEY_VPS2=$($GatewayKeys.Private)
SEG_BACKHAUL_PUBLIC_KEY_VPS2=$($GatewayKeys.Public)
SEG_BACKHAUL_PSK=$Psk
SEG_BACKHAUL_NETWORK=$($Settings['SEG_BACKHAUL_NETWORK'])
SEG_BACKHAUL_VPS1=$($Settings['SEG_BACKHAUL_VPS1'])
SEG_BACKHAUL_VPS2=$($Settings['SEG_BACKHAUL_VPS2'])
SEG_BACKHAUL_PORT=$($Settings['SEG_BACKHAUL_PORT'])
SEG_BACKHAUL_INTERFACE=$($Settings['SEG_BACKHAUL_INTERFACE'])
SEG_BACKHAUL_MTU=$Mtu
SEG_BACKHAUL_RANDOM_TRAILERS=$($Settings['SEG_BACKHAUL_RANDOM_TRAILERS'])

SEG_BACKHAUL_JC=$JC
SEG_BACKHAUL_JMIN=$JMIN
SEG_BACKHAUL_JMAX=$JMAX

SEG_BACKHAUL_S1=$S1
SEG_BACKHAUL_S2=$S2
SEG_BACKHAUL_S3=$S3
SEG_BACKHAUL_S4=$S4

SEG_BACKHAUL_H1=$($Headers[0])
SEG_BACKHAUL_H2=$($Headers[1])
SEG_BACKHAUL_H3=$($Headers[2])
SEG_BACKHAUL_H4=$($Headers[3])

SEG_MARK=$($Settings['SEG_MARK'])
SEG_UNMATCHED_MARK=$($Settings['SEG_UNMATCHED_MARK'])

SEG_UNMATCHED_POLICY=$($Settings['SEG_UNMATCHED_POLICY'])
"@

$ConfigDir = Split-Path -Parent $EnvFile
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

$TempFile = Join-Path $ConfigDir ('.seg.env.' + [Guid]::NewGuid().ToString('N') + '.tmp')

try {
    Write-Utf8Lf -Path $TempFile -Text $Content

    $problem = Test-SegEnvFile -Path $TempFile

    if ($problem) {
        throw "Generated seg.env is invalid, nothing was changed: $problem"
    }

    # Back up only after a successful generation, right before the replacement.
    if ((Test-Path -LiteralPath $EnvFile) -and -not $NoBackup) {
        [void](New-EnvBackup -EnvFile $EnvFile -KeepCount $BackupKeepCount)
    }

    Copy-Item -LiteralPath $TempFile -Destination $EnvFile -Force
}
finally {
    Remove-Item -LiteralPath $TempFile -Force -ErrorAction SilentlyContinue
}

Write-Log -Level 'OK' -Message "seg.env created: $EnvFile"
Write-Log -Level 'WARN' -Message 'SEG servers still use the previous keys until sync-servers.ps1 -Mode SEG is applied.'
Write-Log -Level 'WARN' -Message 'SEG client profiles must be recreated after sync: the REALITY key pair and short id changed. Client UUIDs are not affected.'
Write-Log -Level 'DONE' -Message "SUCCESS. Log: $LogFile"
