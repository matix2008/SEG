# Offline regression tests of the project (no VPS access, no changes on the nodes).
# Run from any directory:  powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-offline.ps1
# Needs the local files of a configured project: servers.txt and config\seg.env (README, sections 5.3 and 5.4).
# The live tests that work with the nodes are in tests\live\ and are started by hand (see the header of each script).
$ErrorActionPreference = 'Stop'

$tests = @(
    'test-servers.ps1',
    'test-segenv.ps1',
    'test-seglist.ps1',
    'test-segclients.ps1',
    'test-seg-generate.ps1',
    'test-segprofile.ps1',
    'test-segprofile-status.ps1',
    'test-versions.ps1'
)

$failed = 0
$rows = @()

foreach ($test in $tests) {
    $path = Join-Path $PSScriptRoot $test
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $summary = @($output | Where-Object { $_ -match '^passed=\d+ failed=\d+' } | Select-Object -Last 1)
    $text = if ($summary.Count -gt 0) { $summary[0] } else { 'no summary line' }
    $ok = ($code -eq 0 -and $summary.Count -gt 0 -and $text -match 'failed=0\b')

    if (-not $ok) {
        $failed++
        $output | Where-Object { $_ -match '^FAIL' } | ForEach-Object { "  $_" }
    }

    $rows += '{0,-6} {1,-30} {2}' -f $(if ($ok) { 'OK' } else { 'FAILED' }), $test, $text
}

''
$rows
''
if ($failed -eq 0) { "All $($tests.Count) test scripts passed."; exit 0 }
"$failed of $($tests.Count) test scripts failed."
exit 1
