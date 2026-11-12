# LIVE test: changes servers.txt temporarily (restored at the end). Needs servers.txt with a vpn-test row (Role vpn-server)
# and the SEG pair; makes SSH checks (-Check) against the nodes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$sync = Join-Path $root 'scripts\sync-servers.ps1'
$sf = Join-Path $root 'servers.txt'
$orig = Join-Path $env:TEMP 'servers.txt.e2e-orig'
Copy-Item -LiteralPath $sf -Destination $orig -Force
$origBaks = @(Get-ChildItem $root -Filter 'servers.txt.*.bak' | ForEach-Object { $_.Name })

$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Info = '') {
    if ($Ok) { $script:pass++; "PASS  $Name" } else { $script:fail++; "FAIL  $Name $Info" }
}
function Norm([string[]]$Lines) {
    @($Lines | ForEach-Object { ($_ -replace '^\S+ \S+ \[[^\]]+\] \[[^\]]+\] ', '') } |
        Where-Object { $_ -notmatch 'legacy format|Temporary directory|Temporary files|Log: |SSH connection|Testing SSH' })
}
function Run([string]$Stdin, [string[]]$ScriptArgs) {
    $out = if ($Stdin) { $Stdin | & powershell -NoProfile -ExecutionPolicy Bypass -File $sync @ScriptArgs 2>&1 } else { & powershell -NoProfile -ExecutionPolicy Bypass -File $sync @ScriptArgs 2>&1 }
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = @($out | ForEach-Object { "$_" }) }
}
function NewBaks { @(Get-ChildItem $root -Filter 'servers.txt.*.bak' | Where-Object { $origBaks -notcontains $_.Name }) }

try {
    $vpnRow = (Get-Content $orig | Where-Object { $_ -match '^vpn-test;' } | Select-Object -First 1)
    $segNames = @(Get-Content $orig | Where-Object { $_ -match ';seg-(gateway|exit);' } | ForEach-Object { ($_ -split ';')[0] })
    $segPattern = ($segNames | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $parts = $vpnRow -split ';'
    $newText = "Name;IP;Port;Role;Type;Enabled`r`n$vpnRow`r`n"
    $legacyText = "Name;IP;Port;Enabled`r`n$($parts[0]);$($parts[1]);$($parts[2]);$($parts[5])`r`n"

    # A: current format -Check
    [IO.File]::WriteAllText($sf, $newText)
    $a = Run $null @('-Mode', 'VPN', '-Check', 'vpn-test')
    Check 'A current -Check exit 0' ($a.Code -eq 0)

    # B: legacy -Check
    [IO.File]::WriteAllText($sf, $legacyText)
    $h1 = (Get-FileHash $sf).Hash
    $b = Run $null @('-Mode', 'VPN', '-Check', 'vpn-test')
    Check 'B legacy -Check exit 0' ($b.Code -eq 0)
    Check 'B legacy -Check file unchanged' ($h1 -eq (Get-FileHash $sf).Hash)
    Check 'B legacy -Check no backup created' (@(NewBaks).Count -eq 0)
    Check 'B legacy -Check says migration is required' (@($b.Out | Where-Object { $_ -match 'legacy format.*migration is required' }).Count -eq 1)
    $na = Norm $a.Out; $nb = Norm $b.Out
    Check 'B legacy output equals current output (same lines)' ((($na -join "`n") -replace '\d','#') -eq (($nb -join "`n") -replace '\d','#')) ("A=$($na.Count) B=$($nb.Count)")

    # C: real migration through sync (one 'y' for the sync prompt)
    $c = Run 'y' @('-Mode', 'VPN', 'vpn-test')
    Check 'C migration run exit 0' ($c.Code -eq 0)
    Check 'C migration message' (@($c.Out | Where-Object { $_ -match 'servers.txt migrated to the current format' }).Count -eq 1)
    $baks = @(NewBaks)
    Check 'C one backup created' ($baks.Count -eq 1)
    if ($baks.Count -eq 1) { Check 'C backup equals legacy content' ((Get-Content $baks[0].FullName -Raw) -eq $legacyText) }
    $lines = @(Get-Content $sf)
    Check 'C header current' ($lines[0] -eq 'Name;IP;Port;Role;Type;Enabled')
    Check 'C row Role=vpn-server Type=amnezia' ($lines[1] -eq "$($parts[0]);$($parts[1]);$($parts[2]);vpn-server;amnezia;$($parts[5])") ($lines[1] -replace '\d+\.\d+\.\d+\.\d+', 'IP')
    Check 'C confirmations only for expected prompt' (@($c.Out | Where-Object { $_ -match 'Confirmation:' }).Count -eq 1)

    # D: repeat
    $h2 = (Get-FileHash $sf).Hash
    $d = Run 'y' @('-Mode', 'VPN', 'vpn-test')
    Check 'D repeat exit 0' ($d.Code -eq 0)
    Check 'D repeat no migration message' (@($d.Out | Where-Object { $_ -match 'migrated|legacy format' }).Count -eq 0)
    Check 'D repeat file unchanged' ($h2 -eq (Get-FileHash $sf).Hash)
    Check 'D repeat no new backup' (@(NewBaks).Count -eq 1)

    # E: all with SEG servers present
    Copy-Item $orig $sf -Force
    $e = Run $null @('-Mode', 'VPN', '-Check', 'all')
    Check 'E VPN all -Check exit 0' ($e.Code -eq 0)
    Check 'E VPN all selects only vpn-test' (@($e.Out | Where-Object { $_ -match 'Selected targets: vpn-test$' }).Count -eq 1)
    Check 'E VPN all does not touch seg servers' (@($e.Out | Where-Object { $_ -match $segPattern }).Count -eq 0)
    Check 'E no new backup for current format' (@(NewBaks).Count -eq 1)

    # F: seg-exit with empty Port is accepted in SEG mode
    $exitRow = @(Get-Content $orig | Where-Object { $_ -match ';seg-exit;' })
    Check 'F servers.txt has seg-exit with empty Port' ($exitRow.Count -eq 1 -and ($exitRow[0] -split ';')[2] -eq '')
    $f = Run $null @('-Mode', 'SEG', '-Check', 'all')
    Check 'F SEG all -Check exit 0' ($f.Code -eq 0)
    Check 'F SEG -Check does not touch vpn-test' (@($f.Out | Where-Object { $_ -match 'vpn-test' }).Count -eq 0)

    # G: a seg server cannot be selected in VPN mode
    $g = Run $null @('-Mode', 'VPN', '-Check', $segNames[0])
    Check "G VPN mode rejects $($segNames[0])" ($g.Code -ne 0)
}
finally {
    Copy-Item $orig $sf -Force
    NewBaks | Remove-Item -Force
    Remove-Item $orig -Force
}

"`npassed=$pass failed=$fail"
