$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\lib\common.ps1')

$script:pass = 0
$script:fail = 0
function Pass($l) { $script:pass++; "PASS  $l" }
function Fail($l, $m) { $script:fail++; "FAIL  $l : $m" }
function Assert-True($c, $m) { if (-not $c) { throw $m } }
function Expect-Error($label, [scriptblock]$code, [string]$pattern) {
    try { & $code; Fail $label 'no error' }
    catch { if ($_.Exception.Message -match $pattern) { Pass $label } else { Fail $label "wrong error: $($_.Exception.Message)" } }
}

$dir = Join-Path $env:TEMP ('versions-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $dir | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Write-Hashes([string]$text) { $p = Join-Path $dir 'h.sha256'; [System.IO.File]::WriteAllText($p, $text, $utf8); return $p }

$hashFile = Join-Path $root 'seg\sing-box.sha256'

"--- hash file format"
try {
    $h = Read-HashFile -Path $hashFile
    Assert-True ($h.Count -eq 4) "entries: $($h.Count)"
    foreach ($n in 'sing-box-1.14.4-linux-amd64.tar.gz', 'sing-box-1.14.4-windows-amd64.zip', 'sing-box.exe', 'libcronet.dll') { Assert-True ($h.ContainsKey($n) -and $h[$n] -cmatch '^[0-9a-f]{64}$') "entry $n" }
    Pass 'shipped seg\sing-box.sha256: 4 entries, lowercase sha256'
} catch { Fail 'shipped hash file' $_.Exception.Message }

$good = 'a' * 64
Expect-Error 'missing file' { [void](Read-HashFile -Path (Join-Path $dir 'none.sha256')) } 'Hash file not found'
Expect-Error 'hash too short' { [void](Read-HashFile -Path (Write-Hashes "abc  file.bin`n")) } 'Invalid line'
Expect-Error 'name missing' { [void](Read-HashFile -Path (Write-Hashes "$good`n")) } 'Invalid line'
Expect-Error 'non-hex hash' { [void](Read-HashFile -Path (Write-Hashes (('z' * 64) + "  f`n"))) } 'Invalid line'
Expect-Error 'duplicate name' { [void](Read-HashFile -Path (Write-Hashes "$good  f`n$good  f`n")) } 'Duplicate entry'
try {
    $h = Read-HashFile -Path (Write-Hashes "# comment`n`n$(('A' * 64))  *bin.exe`n")
    Assert-True ($h['bin.exe'] -eq ('a' * 64)) 'binary marker or case'
    Pass 'comments, blank lines, binary marker and uppercase hash are accepted'
} catch { Fail 'tolerant parsing' $_.Exception.Message }

"--- Assert-FileSha256"
$hashes = Read-HashFile -Path $hashFile
try { Assert-FileSha256 -Path (Join-Path $root 'tools\sing-box.exe') -Hashes $hashes; Pass 'tools\sing-box.exe matches the recorded hash' } catch { Fail 'exe hash' $_.Exception.Message }
try { Assert-FileSha256 -Path (Join-Path $root 'tools\libcronet.dll') -Hashes $hashes; Pass 'tools\libcronet.dll matches the recorded hash' } catch { Fail 'dll hash' $_.Exception.Message }
try { Assert-FileSha256 -Path (Join-Path $root 'tools\sing-box-1.14.4-linux-amd64.tar.gz') -Hashes $hashes; Pass 'Linux package matches the recorded hash' } catch { Fail 'tar hash' $_.Exception.Message }
$small = Join-Path $dir 'sing-box.exe'
[System.IO.File]::WriteAllBytes($small, [byte[]](1, 2, 3))
Expect-Error 'tampered file is rejected' { Assert-FileSha256 -Path $small -Hashes $hashes } 'does not match the recorded value'
Expect-Error 'file without recorded hash' { Assert-FileSha256 -Path $small -Hashes $hashes -Name 'other.bin' } 'No recorded SHA-256'
Expect-Error 'file not found' { Assert-FileSha256 -Path (Join-Path $dir 'absent.exe') -Hashes $hashes } 'File not found'

"--- Resolve-SingBoxExecutable and Linux package"
try { $exe = Resolve-SingBoxExecutable -Root $root -RequiredVersion '1.14.4'; Assert-True ($exe -eq (Join-Path $root 'tools\sing-box.exe')) 'path'; Pass 'real tools\sing-box.exe: hash and version 1.14.4 accepted' } catch { Fail 'resolve real' $_.Exception.Message }
Expect-Error 'other required version is rejected' { [void](Resolve-SingBoxExecutable -Root $root -RequiredVersion '1.13.0') } 'is required'
try { $p = Get-VerifiedSingBoxLinuxPackage -Root $root -Version '1.14.4'; Assert-True ($p -eq (Join-Path $root 'tools\sing-box-1.14.4-linux-amd64.tar.gz')) 'path'; Pass 'Linux package verified and returned' } catch { Fail 'linux package' $_.Exception.Message }

$fake = Join-Path $dir 'root'
New-Item -ItemType Directory "$fake\seg", "$fake\tools" | Out-Null
Copy-Item $hashFile "$fake\seg\"
Expect-Error 'no package in tools' { [void](Get-VerifiedSingBoxLinuxPackage -Root $fake -Version '1.14.4') } 'Linux package not found'
[System.IO.File]::WriteAllBytes("$fake\tools\sing-box-1.14.4-linux-amd64.tar.gz", [byte[]](1, 2, 3))
Expect-Error 'tampered Linux package is rejected' { [void](Get-VerifiedSingBoxLinuxPackage -Root $fake -Version '1.14.4') } 'does not match the recorded value'
[System.IO.File]::WriteAllBytes("$fake\tools\sing-box.exe", [byte[]](1, 2, 3))
Expect-Error 'tampered sing-box.exe is rejected before it is run' { [void](Resolve-SingBoxExecutable -Root $fake -RequiredVersion '1.14.4') } 'does not match the recorded value'
Remove-Item "$fake\tools\sing-box.exe" -Force
Expect-Error 'no sing-box anywhere' { [void](Resolve-SingBoxExecutable -Root $fake -RequiredVersion '1.14.4') } 'was not found'
Remove-Item "$fake\seg\sing-box.sha256" -Force
[System.IO.File]::WriteAllBytes("$fake\tools\sing-box.exe", [byte[]](1, 2, 3))
Expect-Error 'missing hash file is an error' { [void](Resolve-SingBoxExecutable -Root $fake -RequiredVersion '1.14.4') } 'Hash file not found'

Remove-Item $dir -Recurse -Force
""
"passed=$script:pass failed=$script:fail"
if ($script:fail -gt 0) { exit 1 }
