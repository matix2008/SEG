# SEG mode of status-servers.ps1: read-only status of the seg-gateway / seg-exit pair (README, section 9.7).
# Runs seg\status-node.sh on each node through ssh without uploading anything and prints a table. Nothing is changed
# locally or on the nodes, no confirmations are asked. The client addresses are shown on the console only
# and are not written to the log file.
# Exit codes: 0 everything within the thresholds, 2 at least one WARN, 1 an error (a node is unreachable).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $PSScriptRoot '..\lib\servers.ps1')
. (Join-Path $PSScriptRoot '..\lib\segenv.ps1')

Initialize-Logging -Root $Root -ScriptName (Split-Path -Leaf $PSCommandPath)

trap {
    Write-Log -Level 'ERROR' -Message (Get-ErrorDescription -ErrorRecord $_)

    if ($_.ScriptStackTrace) {
        Write-Log -Level 'ERROR' -Message $_.ScriptStackTrace -LogOnly
    }

    Write-Log -Level 'DONE' -Message "FAILED. Log: $($script:LogFile)"
    exit 1
}

Write-Log -Level 'START' -Message 'SEG: status of the pair (read-only).'

$ServersFile = Join-Path $Root 'servers.txt'
$SegEnvFile = Join-Path $Root 'config\seg.env'
$VpnEnvFile = Join-Path $Root 'config\server.env'
$StatusNodeFile = Join-Path $Root 'seg\status-node.sh'

foreach ($file in @($ServersFile, $SegEnvFile, $StatusNodeFile)) {
    if (-not (Test-Path -LiteralPath $file)) {
        throw "Required file not found: $file"
    }
}

$SegEnv = Read-SegEnvFile -Path $SegEnvFile
Test-SegEnvironment -Env $SegEnv -ReservedNetworks @(Get-SegReservedNetworks -VpnEnvFile $VpnEnvFile)

$ServersLoaded = Read-ServersFile -Path $ServersFile

if ($ServersLoaded.Format -eq 'legacy') {
    throw 'servers.txt uses the legacy format and has no SEG servers.'
}

$SegServers = @(Select-ServersForMode -Servers @($ServersLoaded.Servers) -Mode SEG)
Assert-SegTopology -Servers $SegServers

$Gateway = @($SegServers | Where-Object { $_.Role -eq 'seg-gateway' -and $_.IsEnabled })[0]
$Exit = @($SegServers | Where-Object { $_.Role -eq 'seg-exit' -and $_.IsEnabled })[0]
$Interface = [string]$SegEnv['SEG_BACKHAUL_INTERFACE']

$Labels = [ordered]@{
    OS              = 'System'
    KERNEL          = 'Kernel'
    UPTIME          = 'Uptime'
    LOAD            = 'Load (1/5/15 min)'
    REBOOT_REQUIRED = 'Reboot required'
    DISK            = 'Disk /'
    MEMORY          = 'Memory'
    JOURNAL         = 'Logs'
    PACKAGES        = 'Packages'
    SERVICES        = 'Services'
    BACKHAUL        = 'Backhaul'
    SING_BOX        = 'sing-box'
}

$Warnings = 0
$Unreachable = 0

foreach ($node in @($Gateway, $Exit)) {
    Write-Host ''
    Write-Host "== $($node.Role)  $($node.Name)  $($node.IP) =="

    if (-not (Test-Ssh -IP $node.IP)) {
        Write-Log -Level 'ERROR' -Message "$($node.Name): SSH connection failed."
        $Unreachable++
        continue
    }

    if ($node.Role -eq 'seg-gateway') {
        $arguments = @('seg-gateway', [string]$node.Port, $Interface)
    }
    else {
        $arguments = @('seg-exit', $Interface)
    }

    $remote = Invoke-RemoteScript -IP $node.IP -ScriptPath $StatusNodeFile -Arguments $arguments -AllowFailure -Quiet

    if ($remote.Code -ne 0 -or $remote.Output -notmatch 'STATUS_NODE_DONE') {
        Write-Log -Level 'ERROR' -Message "$($node.Name): status-node.sh failed (exit code $($remote.Code)): $((($remote.Output -split "`n") | Select-Object -Last 2) -join ' ')"
        $Unreachable++
        continue
    }

    $values = @{}
    $clientIps = @()

    foreach ($line in ($remote.Output -split "`n")) {
        $line = $line.TrimEnd("`r")

        if ($line -match '^STATUS CLIENT_IP=(.+)$') {
            $clientIps += $Matches[1].Trim()
        }
        elseif ($line -match '^STATUS ([A-Z_]+)=(.*)$') {
            $values[$Matches[1]] = $Matches[2].Trim()
        }
    }

    foreach ($key in $Labels.Keys) {
        if (-not $values.ContainsKey($key)) { continue }

        $text = $values[$key]
        $isWarn = $text -like 'WARN*'
        $isOk = $text -like 'OK *'

        if ($isWarn -or $isOk) {
            $text = $text -replace '^(OK|WARN) ', ''
        }

        if ($isWarn) {
            $Warnings++
            Write-Host ('  {0,-18} {1}   [over the threshold]' -f $Labels[$key], $text) -ForegroundColor Yellow
            Write-Log -Level 'WARN' -Message "$($node.Name): $($Labels[$key]): $text" -LogOnly
        }
        else {
            Write-Host ('  {0,-18} {1}' -f $Labels[$key], $text)
        }
    }

    if ($node.Role -eq 'seg-gateway') {
        $count = if ($values.ContainsKey('CLIENTS')) { $values['CLIENTS'] } else { '?' }
        $list = if ($clientIps.Count -gt 0) { ' ' + ($clientIps -join ', ') } else { '' }
        Write-Host ('  {0,-18} {1}{2}' -f 'Client addresses', $count, $(if ($list) { ":$list" } else { '' }))
    }

    if ($values['REBOOT_REQUIRED'] -eq 'yes') {
        Write-Host '  A reboot is pending: the next sync-servers.ps1 -Mode SEG all offers it.' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host 'Thresholds: disk and inodes below 75%, available memory at least 15%, journald below 180 MB, /var/log below 300 MB.'
Write-Host 'Client addresses: distinct external addresses with an established connection to the VLESS port (no names: sing-box keeps no per-user counters).'

if ($Unreachable -gt 0) {
    Write-Log -Level 'DONE' -Message "Status incomplete: $Unreachable node(s) could not be read. Log: $($script:LogFile)"
    exit 1
}

if ($Warnings -gt 0) {
    Write-Log -Level 'DONE' -Message "Status read: $Warnings value(s) over the thresholds. Log: $($script:LogFile)"
    exit 2
}

Write-Log -Level 'DONE' -Message "Status read: everything within the thresholds. Log: $($script:LogFile)"
exit 0
