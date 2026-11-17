#Requires -Version 7.0
# Offline checks for scripts/run-tests.ps1 (the `npm test` runner) with fixture suites: failure and exit-code
# semantics, output order, per-suite TEMP and Azure CLI profile isolation, parallel and sequential throttles.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$runner = Join-Path $repo 'scripts/run-tests.ps1'
$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++; Write-Host "ok   $Name" } else { $script:fail++; Write-Host "FAIL $Name" } }

$base = Join-Path ([IO.Path]::GetTempPath()) ("run-tests-" + [guid]::NewGuid().ToString('n'))
$out = Join-Path $base 'out'
New-Item -ItemType Directory -Path $out | Out-Null

# Each fixture suite records its environment, writes a fixed-name file in TEMP, waits, and fails if another
# suite overwrote that file (shared TEMP).
$probe = @'
$name = Split-Path $PSCommandPath -LeafBase
$start = [DateTime]::UtcNow.Ticks
$file = Join-Path $env:TEMP 'same-name.txt'
Set-Content -LiteralPath $file -Value $name
Start-Sleep -Seconds 3
$seen = (Get-Content -LiteralPath $file -Raw).Trim()
[ordered]@{ name = $name; temp = $env:TEMP; cli = $env:AZURE_CONFIG_DIR; start = $start; end = [DateTime]::UtcNow.Ticks; seen = $seen;
    files = @(if ($env:AZURE_CONFIG_DIR -and (Test-Path $env:AZURE_CONFIG_DIR)) { Get-ChildItem -LiteralPath $env:AZURE_CONFIG_DIR -Recurse -File -Name }) } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:CCOF_RT_OUT "$name.json")
Write-Host "probe output from $name"
if ($seen -ne $name) { Write-Host "TEMP shared: $name saw $seen"; exit 1 }
'@

function New-Fixture([string]$Name, [hashtable]$Suites, [switch]$Bicep) {
    $dir = Join-Path $base $Name
    $tests = Join-Path $dir 'tests'; $cli = Join-Path $dir 'azure'
    New-Item -ItemType Directory -Path $tests, (Join-Path $cli 'bin') -Force | Out-Null
    foreach ($k in $Suites.Keys) { Set-Content -LiteralPath (Join-Path $tests "$k.ps1") -Value $Suites[$k] }
    Set-Content -LiteralPath (Join-Path $cli 'config') -Value "[core]`ncollect_telemetry = no"
    Set-Content -LiteralPath (Join-Path $cli 'msal_token_cache.json') -Value '{"fake":"not a token"}'
    Set-Content -LiteralPath (Join-Path $cli 'azureProfile.json') -Value '{"subscriptions":[]}'
    if ($Bicep) { Set-Content -LiteralPath (Join-Path $cli 'bin/bicep.exe') -Value 'fake'; Set-Content -LiteralPath (Join-Path $cli 'bin/bicep') -Value 'fake' }
    @{ tests = $tests; cli = $cli; scratch = (Join-Path $dir 'scratch') }
}
function Invoke-Runner($Fx, [string]$Throttle) {
    Get-ChildItem -LiteralPath $out -File | Remove-Item -Force
    $saved = @{ t = $env:CCOF_TEST_THROTTLE; c = $env:AZURE_CONFIG_DIR; o = $env:CCOF_RT_OUT }
    $env:CCOF_TEST_THROTTLE = $Throttle; $env:AZURE_CONFIG_DIR = $Fx.cli; $env:CCOF_RT_OUT = $out
    try { $text = (& pwsh -NoProfile -File $runner -TestsDir $Fx.tests -ScratchDir $Fx.scratch *>&1 | Out-String); $code = $LASTEXITCODE }
    finally { $env:CCOF_TEST_THROTTLE = $saved.t; $env:AZURE_CONFIG_DIR = $saved.c; $env:CCOF_RT_OUT = $saved.o }
    $rec = @{}; Get-ChildItem -LiteralPath $out -Filter '*.json' | ForEach-Object { $j = Get-Content -Raw $_.FullName | ConvertFrom-Json; $rec[$j.name] = $j }
    @{ code = $code; text = $text; rec = $rec }
}
function Test-Overlap($Rec, [string[]]$Names) {
    $r = @($Names | ForEach-Object { $Rec[$_] })
    for ($i = 0; $i -lt $r.Count; $i++) { for ($j = $i + 1; $j -lt $r.Count; $j++) { if ($r[$i].start -lt $r[$j].end -and $r[$j].start -lt $r[$i].end) { return $true } } }
    $false
}

try {
    # 1. Passing, failing, throwing and silently-crashing suites run together.
    $fx = New-Fixture 'mixed' @{
        'Test-A' = $probe; 'Test-B' = $probe; 'Test-C' = $probe
        'Test-Fail' = "Write-Host 'fail suite output'; exit 3"
        'Test-Throw' = "`$ErrorActionPreference = 'Stop'; throw 'fixture throw'"
    } -Bicep
    $r = Invoke-Runner $fx '4'
    Check 'a failing suite makes the run exit 1' ($r.code -eq 1)
    Check 'the exit-3 and throwing suites are both reported as failed' ($r.text -match 'SUITE FAILED: Test-Fail\.ps1 \(exit code 3\)' -and $r.text -match 'SUITE FAILED: Test-Throw\.ps1 \(exit code 1\)')
    Check 'the summary lists exactly the failed suites' ($r.text -match 'failed: Test-Fail\.ps1, Test-Throw\.ps1')
    $order = @([regex]::Matches($r.text, '=== (Test-\w+\.ps1) ===') | ForEach-Object { $_.Groups[1].Value })
    Check 'each suite is printed once, in name order' (($order -join ',') -ceq 'Test-A.ps1,Test-B.ps1,Test-C.ps1,Test-Fail.ps1,Test-Throw.ps1')
    Check 'suite output appears under its own header' ($r.text -match '(?s)=== Test-Fail\.ps1 ===\s+fail suite output' -and $r.text -match '(?s)=== Test-B\.ps1 ===\s+probe output from Test-B')
    Check 'all three probe suites ran and passed' ($r.rec.Count -eq 3 -and $r.text -notmatch 'SUITE FAILED: Test-[ABC]\.ps1')
    $temps = @($r.rec.Values | ForEach-Object temp | Sort-Object -Unique)
    Check 'each suite has its own TEMP' ($temps.Count -eq 3 -and -not ($r.rec.Values | Where-Object { $_.seen -ne $_.name }))
    $clis = @($r.rec.Values | ForEach-Object cli | Sort-Object -Unique)
    Check 'each suite has its own Azure CLI profile, not the operator profile' ($clis.Count -eq 3 -and $clis -notcontains $fx.cli)
    $files = @($r.rec['Test-A'].files)
    Check 'the suite profile has the config and the Bicep binary' ($files -contains 'config' -and ($files -contains 'bin\bicep.exe' -or $files -contains 'bin/bicep.exe'))
    Check 'the suite profile has no token cache or account list' ($files -notcontains 'msal_token_cache.json' -and $files -notcontains 'azureProfile.json')
    Check 'suites ran in parallel with throttle 4' (Test-Overlap $r.rec 'Test-A', 'Test-B', 'Test-C')
    Check 'passing suites leave no scratch; the failed suites keep theirs' (-not (Get-ChildItem -LiteralPath $fx.scratch -Recurse -Directory -Filter 'Test-A') -and (Get-ChildItem -LiteralPath $fx.scratch -Recurse -Directory -Filter 'Test-Fail'))
    Check 'the operator profile is unchanged' (@(Get-ChildItem -LiteralPath $fx.cli -Recurse -File).Count -eq 5)

    # 2. All passing; throttle 1 runs one suite at a time.
    $fx = New-Fixture 'sequential' @{ 'Test-A' = $probe; 'Test-B' = $probe } -Bicep
    $r = Invoke-Runner $fx '1'
    Check 'all suites passing exits 0' ($r.code -eq 0 -and $r.text -match 'failed: none')
    Check 'throttle 1 runs the suites one at a time' ($r.rec.Count -eq 2 -and -not (Test-Overlap $r.rec 'Test-A', 'Test-B'))
    Check 'a clean run removes its scratch' (-not (Get-ChildItem -LiteralPath $fx.scratch -Directory -Filter 'run-*'))

    # 3. No Bicep binary in the operator profile: keep that profile and run one suite at a time, as before.
    $fx = New-Fixture 'nobicep' @{ 'Test-A' = $probe; 'Test-B' = $probe }
    $r = Invoke-Runner $fx '4'
    Check 'without a Bicep binary the suites use the operator profile' ($r.code -eq 0 -and @($r.rec.Values | Where-Object cli -ne $fx.cli).Count -eq 0)
    Check 'without a Bicep binary the suites run one at a time' ($r.rec.Count -eq 2 -and -not (Test-Overlap $r.rec 'Test-A', 'Test-B'))
} finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Run-tests runner: $pass checks passed, $fail failed."
if ($fail) { exit 1 }
