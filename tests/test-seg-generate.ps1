$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sb   = Join-Path $env:TEMP 'seg-sandbox6'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$script:pass = 0; $script:fail = 0

function Check([string]$label, [bool]$ok, [string]$detail = '') { if ($ok) { $script:pass++; "PASS  $label" } else { $script:fail++; "FAIL  $label $detail" } }

if (Test-Path $sb) { Remove-Item $sb -Recurse -Force }
New-Item -ItemType Directory $sb, "$sb\config", "$sb\tools" | Out-Null
Copy-Item (Join-Path $root 'scripts') "$sb\scripts" -Recurse
Copy-Item (Join-Path $root 'seg') "$sb\seg" -Recurse
Copy-Item (Join-Path $root 'tools\sing-box.exe') "$sb\tools\"
Copy-Item (Join-Path $root 'tools\libcronet.dll') "$sb\tools\" -ErrorAction SilentlyContinue

$gen = Join-Path $sb 'scripts\generate-server-env.ps1'
function Run-Gen([string[]]$argsList) {
    $o = ($null | powershell -NoProfile -ExecutionPolicy Bypass -File $gen @argsList 2>&1 | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o }
}
$envFile = Join-Path $sb 'config\seg.env'
function Read-Kv([string]$p) { $h = @{}; Get-Content $p | ForEach-Object { if ($_ -match '^([A-Z0-9_]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] } }; $h }
function Backups { @(Get-ChildItem "$sb\config" -Filter 'seg.env.*.bak' -ErrorAction SilentlyContinue) }

. (Join-Path $root 'scripts\lib\segenv.ps1')
function Valid([string]$p) { try { Test-SegEnvironment -Env (Read-SegEnvFile -Path $p) -ReservedNetworks @('10.7.0.0/24'); $true } catch { $false } }

# A VPN-mode server.env for the sandbox (new test keys, no real secrets).
$o = ($null | powershell -NoProfile -ExecutionPolicy Bypass -File $gen -Mode VPN -Force 2>&1 | Out-String)
$vpnFile = Join-Path $sb 'config\server.env'
"server.env created in sandbox: $(Test-Path $vpnFile)"
$vpnHash = (Get-FileHash $vpnFile).Hash

"--- first generation"
$r = Run-Gen @('-Mode', 'SEG')
Check 'exit code 0' ($r.Code -eq 0) $r.Out
Check 'seg.env exists and passes the validator' ((Test-Path $envFile) -and (Valid $envFile))
Check 'no backup on first generation' ((Backups).Count -eq 0)
Check 'no temp files left' (@(Get-ChildItem "$sb\config" -Filter '.seg.env.*.tmp' -Force).Count -eq 0)
Check 'server.env (VPN) untouched' ((Get-FileHash $vpnFile).Hash -eq $vpnHash)
$v1 = Read-Kv $envFile
$mtuExpected = [math]::Min(1420, [math]::Max(576, (1500 - 28 - 32 - [int]$v1['SEG_BACKHAUL_S4'] - 480) - 16))
Check "MTU is computed from S4 (S4=$($v1['SEG_BACKHAUL_S4']), MTU=$($v1['SEG_BACKHAUL_MTU']))" ([int]$v1['SEG_BACKHAUL_MTU'] -eq $mtuExpected)
Check 'S1..S4 equal' (($v1['SEG_BACKHAUL_S1'], $v1['SEG_BACKHAUL_S2'], $v1['SEG_BACKHAUL_S3'], $v1['SEG_BACKHAUL_S4'] | Select-Object -Unique).Count -eq 1)
Check 'defaults: policy direct, port 42100' ($v1['SEG_UNMATCHED_POLICY'] -eq 'direct' -and $v1['SEG_BACKHAUL_PORT'] -eq '42100')
$log = Get-Content (Join-Path $sb 'logs\amnezia.log') -Raw
$leak = @('SEG_REALITY_PRIVATE_KEY', 'SEG_REALITY_PUBLIC_KEY', 'SEG_REALITY_SHORT_ID', 'SEG_BACKHAUL_PRIVATE_KEY_VPS1', 'SEG_BACKHAUL_PRIVATE_KEY_VPS2', 'SEG_BACKHAUL_PSK', 'SEG_BACKHAUL_H1', 'SEG_BACKHAUL_H2') | Where-Object { $log.Contains($v1[$_]) }
Check 'secret values are not in the log' (@($leak).Count -eq 0) ("leaked: " + (@($leak) -join ','))

"--- regeneration keeps settings, rotates secrets"
$text = (Get-Content $envFile -Raw) -replace 'SEG_UNMATCHED_POLICY=direct', 'SEG_UNMATCHED_POLICY=block' -replace 'SEG_BACKHAUL_PORT=42100', 'SEG_BACKHAUL_PORT=42200' -replace 'SEG_BACKHAUL_RANDOM_TRAILERS=on', 'SEG_BACKHAUL_RANDOM_TRAILERS=off'
[System.IO.File]::WriteAllText($envFile, $text, $utf8)
$edited = Read-Kv $envFile
$r = Run-Gen @('-Mode', 'SEG', '-Force')
Check 'exit code 0' ($r.Code -eq 0) $r.Out
$v2 = Read-Kv $envFile
Check 'one backup created' ((Backups).Count -eq 1)
Check 'backup equals the previous (edited) file' ((Get-Content (Backups)[0].FullName -Raw) -eq $text)
Check 'settings kept (policy block, port 42200, RandomTrailers off)' ($v2['SEG_UNMATCHED_POLICY'] -eq 'block' -and $v2['SEG_BACKHAUL_PORT'] -eq '42200' -and $v2['SEG_BACKHAUL_RANDOM_TRAILERS'] -eq 'off')
Check 'all secrets rotated' (((@('SEG_REALITY_PRIVATE_KEY', 'SEG_REALITY_PUBLIC_KEY', 'SEG_REALITY_SHORT_ID', 'SEG_BACKHAUL_PRIVATE_KEY_VPS1', 'SEG_BACKHAUL_PRIVATE_KEY_VPS2', 'SEG_BACKHAUL_PSK') | Where-Object { $v2[$_] -eq $edited[$_] }) | Measure-Object).Count -eq 0)
$mtu2 = [math]::Min(1420, [math]::Max(576, (1500 - 60 - [int]$v2['SEG_BACKHAUL_S4']) - 16))
Check "MTU recomputed for RandomTrailers off (S4=$($v2['SEG_BACKHAUL_S4']), MTU=$($v2['SEG_BACKHAUL_MTU']))" ([int]$v2['SEG_BACKHAUL_MTU'] -eq $mtu2)
Check 'new file passes the validator' (Valid $envFile)

"--- -NoBackup"
$before = (Backups).Count
$r = Run-Gen @('-Mode', 'SEG', '-Force', '-NoBackup')
Check 'exit 0, no new backup' ($r.Code -eq 0 -and (Backups).Count -eq $before) $r.Out

"--- restore"
$current = Get-Content $envFile -Raw
Start-Sleep -Milliseconds 50
$newest = (Backups | Sort-Object Name -Descending)[0]
$r = Run-Gen @('-Mode', 'SEG', '-Restore', '-Force')
Check 'restore exit 0' ($r.Code -eq 0) $r.Out
Check 'seg.env equals the newest backup' ((Get-Content $envFile -Raw) -eq (Get-Content $newest.FullName -Raw))
Check 'current file saved as a new backup' (@(Backups | Where-Object { (Get-Content $_.FullName -Raw) -eq $current }).Count -ge 1)
Check 'at most 3 backups kept' ((Backups).Count -le 3)
$r = Run-Gen @('-Mode', 'SEG', '-Restore', '-Force', '-NoBackup')
Check 'restore -NoBackup works' ($r.Code -eq 0) $r.Out

"--- existing file unusable or invalid"
[System.IO.File]::WriteAllText($envFile, "this is not a valid file`n", $utf8)
$r = Run-Gen @('-Mode', 'SEG', '-Force')
Check 'corrupt existing: defaults used, success' ($r.Code -eq 0 -and (Valid $envFile) -and $r.Out -match 'cannot be read') $r.Out
$bad = (Get-Content $envFile -Raw) -replace 'SEG_BACKHAUL_PORT=\d+', 'SEG_BACKHAUL_PORT=0'
[System.IO.File]::WriteAllText($envFile, $bad, $utf8)
$r = Run-Gen @('-Mode', 'SEG', '-Force')
Check 'invalid kept setting: error, file unchanged' ($r.Code -eq 1 -and $r.Out -match 'invalid, nothing was changed' -and (Get-Content $envFile -Raw) -eq $bad) $r.Out
Check 'no temp files left after error' (@(Get-ChildItem "$sb\config" -Filter '.seg.env.*.tmp' -Force).Count -eq 0)
[System.IO.File]::WriteAllText($envFile, ((Get-Content $envFile -Raw) -replace 'SEG_BACKHAUL_RANDOM_TRAILERS=\w+', 'SEG_BACKHAUL_RANDOM_TRAILERS=maybe'), $utf8)
$r = Run-Gen @('-Mode', 'SEG', '-Force')
Check 'invalid RandomTrailers: clear error' ($r.Code -eq 1 -and $r.Out -match 'must be on or off') $r.Out

"--- no sing-box"
Rename-Item "$sb\tools\sing-box.exe" 'sing-box.exe.off'
$h = (Get-FileHash $envFile).Hash
$r = Run-Gen @('-Mode', 'SEG', '-Force')
Check 'missing sing-box: error before any change' ($r.Code -eq 1 -and $r.Out -match 'was not found' -and (Get-FileHash $envFile).Hash -eq $h) $r.Out
Rename-Item "$sb\tools\sing-box.exe.off" 'sing-box.exe'

"--- tampered sing-box.exe"
$fs = [System.IO.File]::Open("$sb\tools\sing-box.exe", 'Append'); $fs.WriteByte(0); $fs.Close()
$h = (Get-FileHash $envFile).Hash
$r = Run-Gen @('-Mode', 'SEG', '-Force')
Check 'tampered exe: rejected before it is run, file unchanged' ($r.Code -eq 1 -and $r.Out -match 'does not match the recorded value' -and (Get-FileHash $envFile).Hash -eq $h) $r.Out
Copy-Item (Join-Path $root 'tools\sing-box.exe') "$sb\tools\sing-box.exe" -Force

"--- no existing file and no confirmation"
Remove-Item $envFile -Force
$r = Run-Gen @('-Mode', 'SEG')
Check 'fresh generation needs no confirmation' ($r.Code -eq 0 -and (Valid $envFile)) $r.Out
$hashBefore = (Get-FileHash $envFile).Hash
$r = Run-Gen @('-Mode', 'SEG')
Check 'existing file without -Force and without input: nothing replaced' ((Get-FileHash $envFile).Hash -eq $hashBefore -and (Backups).Count -le 3) "exit=$($r.Code)"

""
"passed=$script:pass failed=$script:fail"
Remove-Item $sb -Recurse -Force
if ($script:fail -gt 0) { exit 1 }
