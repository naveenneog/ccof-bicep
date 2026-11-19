#Requires -Version 7.0
# ADR 0041 (SS-10): the npm test runner runs PowerShell suites in parallel with an isolated TEMP per
# suite, prints each suite's output in name order, and fails when any suite fails.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$runner = Join-Path $root 'scripts/run-tests.ps1'
# Without these parameters the runner would ignore the fixture and recurse into the real suite.
$declared = (Get-Command $runner).Parameters.Keys
foreach ($p in 'TestsDirectory', 'SkipNode', 'ThrottleLimit') { if ($declared -notcontains $p) { throw "run-tests.ps1 must declare -$p." } }
$work = Join-Path ([IO.Path]::GetTempPath()) "ccof-runner-$([guid]::NewGuid().ToString('N'))"
$suites = Join-Path $work 'suites'
New-Item -ItemType Directory -Path $suites -Force | Out-Null

function Write-Suite([string]$Name, [string]$Body) {
    Set-Content -LiteralPath (Join-Path $suites $Name) -Value "#Requires -Version 7.0`n$Body" -Encoding utf8NoBOM
}
function Invoke-Runner {
    $out = pwsh -NoProfile -File $runner -TestsDirectory $suites -SkipNode -ThrottleLimit 4 2>&1 | Out-String
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
}

try {
    $marks = Join-Path $work 'marks'
    New-Item -ItemType Directory -Path $marks | Out-Null
    # A and B each wait for the other's mark: a sequential runner deadlocks and A times out.
    $rendezvous = { param($self, $other) @"
Set-Content -LiteralPath '$marks/$self' -Value 1
`$deadline = (Get-Date).AddSeconds(20)
while (-not (Test-Path -LiteralPath '$marks/$other')) { if ((Get-Date) -gt `$deadline) { Write-Output 'RENDEZVOUS-TIMEOUT'; exit 9 }; Start-Sleep -Milliseconds 100 }
Write-Output "suite-$self ok"
"@ }
    Write-Suite 'Test-A.ps1' (& $rendezvous 'a' 'b')
    Write-Suite 'Test-B.ps1' (& $rendezvous 'b' 'a')
    Write-Suite 'Test-C.ps1' "Set-Content -LiteralPath '$marks/temp-c' -Value `$env:TEMP"
    Write-Suite 'Test-D.ps1' "Set-Content -LiteralPath '$marks/temp-d' -Value `$env:TEMP"

    $pass = Invoke-Runner
    if ($pass.Exit -ne 0) { throw "Passing suites must exit 0; got $($pass.Exit): $($pass.Out)" }
    if ($pass.Out -match 'RENDEZVOUS-TIMEOUT') { throw 'Suites did not run in parallel.' }
    $headers = [regex]::Matches($pass.Out, '=== (Test-[A-D]\.ps1) ===') | ForEach-Object { $_.Groups[1].Value }
    if (($headers -join ',') -ne 'Test-A.ps1,Test-B.ps1,Test-C.ps1,Test-D.ps1') { throw "Suite output must be grouped in name order; got $($headers -join ',')" }
    if ($pass.Out -notmatch '(?s)=== Test-A\.ps1 ===\s+suite-a ok\s+=== Test-B\.ps1 ===\s+suite-b ok') { throw "Each suite's output must follow its own header: $($pass.Out)" }
    $tc = (Get-Content -LiteralPath "$marks/temp-c" -Raw).Trim()
    $td = (Get-Content -LiteralPath "$marks/temp-d" -Raw).Trim()
    if (-not $tc -or $tc -eq $td) { throw "Each suite needs its own TEMP; got '$tc' and '$td'." }

    Get-ChildItem -LiteralPath $marks | Remove-Item
    Write-Suite 'Test-E.ps1' 'exit 3'
    $fail = Invoke-Runner
    if ($fail.Exit -ne 1) { throw "A suite exiting 3 must fail the runner; got $($fail.Exit)." }

    Remove-Item -LiteralPath (Join-Path $suites 'Test-E.ps1')
    Get-ChildItem -LiteralPath $marks | Remove-Item
    Write-Suite 'Test-F.ps1' "throw 'boom'"
    $thrown = Invoke-Runner
    if ($thrown.Exit -ne 1) { throw "A suite that throws must fail the runner; got $($thrown.Exit)." }
    if ($thrown.Out -notmatch 'boom') { throw 'A failing suite must keep its error output.' }

    # A typo'd or empty tests directory must not report success without running anything.
    $missing = pwsh -NoProfile -File $runner -TestsDirectory (Join-Path $work 'no-such-dir') -SkipNode 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { throw "A missing tests directory must fail the runner: $missing" }
    $empty = Join-Path $work 'empty'
    New-Item -ItemType Directory -Path $empty | Out-Null
    $none = pwsh -NoProfile -File $runner -TestsDirectory $empty -SkipNode 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { throw "A tests directory with no suites must fail the runner: $none" }
    'Test runner: parallel suites, per-suite TEMP, ordered output and failing exit codes verified.'
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
