#Requires -Version 7.0
<#
Runs the offline suites: the Node suites (tests\*.test.ts), then every tests\*.ps1 in its own pwsh process.

Fails closed: a missing tests directory, no PowerShell suite, or no Node suite (unless -NoNodeSuites, used only by
the runner's own fixture tests) exits 1 before any suite runs. Every suite, Node included, runs against its own
logged-out Azure CLI profile: the operator profile's config files and the Bicep binary (from that profile's bin
or PATH), never its token cache or account list. Without a Bicep binary the run exits 1 instead of downloading one
or using the operator profile.

The PowerShell suites run in parallel, up to CCOF_TEST_THROTTLE at a time (default: half the logical processors,
at most 8; 1 runs them one at a time), each with its own TEMP/TMP. Output is printed per suite, in name order,
after all suites end. The exit code is 1 when any suite exits non-zero or its result cannot be read. A failed
suite's files are kept for inspection.
#>
param([string]$TestsDir, [string]$ScratchDir, [switch]$NoNodeSuites)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
if (-not $TestsDir) { $TestsDir = Join-Path $root 'tests' }
function Stop-Run([string]$Reason) { Write-Host "RUN FAILED: $Reason"; exit 1 }

if (-not (Test-Path -LiteralPath $TestsDir -PathType Container)) { Stop-Run "tests directory not found: $TestsDir" }
$nodeSuites = @(Get-ChildItem -LiteralPath $TestsDir -Filter '*.test.ts' -File)
$suites = @(Get-ChildItem -LiteralPath $TestsDir -Filter '*.ps1' -File | Sort-Object Name)
if (-not $NoNodeSuites -and -not $nodeSuites.Count) { Stop-Run "no Node suites (*.test.ts) in $TestsDir" }
if (-not $suites.Count) { Stop-Run "no PowerShell suites (*.ps1) in $TestsDir" }

$cliSource = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $HOME '.azure' }
$bicep = @((Join-Path $cliSource 'bin/bicep.exe'), (Join-Path $cliSource 'bin/bicep') | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
if (-not $bicep.Count) { $bicep = @(Get-Command bicep -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object Source) }
if (-not $bicep.Count) { Stop-Run "no Bicep binary in $cliSource\bin or on PATH; install it (az bicep install) and run again. The suites never use the operator profile itself." }

$scratch = if ($ScratchDir) { $ScratchDir } else { Join-Path $root '.env.public-test-scratch' }
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$env:TEMP = $scratch
$env:TMP = $scratch
$env:CCOF_LIVE_TESTS = '0'
$run = Join-Path $scratch ('run-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $run | Out-Null

# A logged-out Azure CLI profile: config files and the Bicep binary only.
function New-SuiteProfile([string]$Dir) {
    $cli = Join-Path $Dir 'azure'
    New-Item -ItemType Directory -Path (Join-Path $Dir 'tmp'), (Join-Path $cli 'bin') -ErrorAction Stop | Out-Null
    foreach ($f in 'config', 'bicepVersionCheck.json', 'versionCheck.json') {
        $s = Join-Path $cliSource $f
        if (Test-Path -LiteralPath $s -PathType Leaf) { Copy-Item -LiteralPath $s -Destination (Join-Path $cli $f) -ErrorAction Stop }
    }
    foreach ($s in $bicep) {
        $d = Join-Path $cli "bin/$(Split-Path $s -Leaf)"
        try { New-Item -ItemType HardLink -Path $d -Target $s -ErrorAction Stop | Out-Null } catch { Copy-Item -LiteralPath $s -Destination $d -ErrorAction Stop }
    }
    $cli
}

$result = 0
if ($nodeSuites.Count) {
    Write-Host '=== exported Node integration and unit suites ==='
    $nodeDir = Join-Path $run 'node'
    $saved = $env:AZURE_CONFIG_DIR
    try {
        $env:AZURE_CONFIG_DIR = New-SuiteProfile $nodeDir
        node --test (Join-Path $TestsDir '*.test.ts')
        $nodeCode = $LASTEXITCODE
    } catch { Write-Host "$_"; $nodeCode = $null }
    finally { $env:AZURE_CONFIG_DIR = $saved }
    if ($nodeCode -isnot [int] -or $nodeCode -ne 0) { $result = 1; Write-Host "NODE SUITES FAILED (exit code $nodeCode)" }
    else { Remove-Item -LiteralPath $nodeDir -Recurse -Force -ErrorAction SilentlyContinue }
}

$throttle = 0
if (-not [int]::TryParse("$env:CCOF_TEST_THROTTLE", [ref]$throttle) -or $throttle -lt 1) { $throttle = [Math]::Max(1, [Math]::Min(8, [int][Math]::Floor([Environment]::ProcessorCount / 2))) }
$pwshExe = (Get-Process -Id $PID).Path
$here = (Get-Location).Path
$jobs = foreach ($s in $suites) {
    $dir = Join-Path $run $s.BaseName
    $cli = $null; $failure = ''
    try { $cli = New-SuiteProfile $dir } catch { $failure = "profile setup: $_" }
    [pscustomobject]@{ suite = $s; dir = $dir; cli = $cli; failure = $failure }
}
$clock = [Diagnostics.Stopwatch]::StartNew()
$done = @($jobs | ForEach-Object -ThrottleLimit $throttle -Parallel {
    $job = $_; $pwshExe = $using:pwshExe
    Set-Location -LiteralPath $using:here
    $temp = Join-Path $job.dir 'tmp'; $log = Join-Path $job.dir 'output.log'
    $code = $null; $failure = $job.failure; $watch = [Diagnostics.Stopwatch]::StartNew()
    if (-not $failure) {
        try {
            $q = { param($v) "'" + ($v -replace "'", "''") + "'" }
            # The suite environment is set inside a wrapper process: $env is shared by all runspaces of this process.
            $cmd = "`$env:TEMP = $(& $q $temp); `$env:TMP = `$env:TEMP; `$env:AZURE_CONFIG_DIR = $(& $q $job.cli); & $(& $q $pwshExe) -NoProfile -File $(& $q $job.suite.FullName) *> $(& $q $log); exit `$LASTEXITCODE"
            $wrapper = & $pwshExe -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-String
            $code = $LASTEXITCODE
            if ($wrapper.Trim()) { $failure = "runner wrapper output: $($wrapper.Trim())" }
        } catch { $failure = "$_" }
    }
    [pscustomobject]@{ name = $job.suite.Name; code = $code; seconds = [int]$watch.Elapsed.TotalSeconds; log = $log; dir = $job.dir; failure = $failure }
} | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['code'] })

$failed = @()
foreach ($s in $suites) {
    $r = @($done | Where-Object name -ceq $s.Name)
    Write-Host "`n=== $($s.Name) ==="
    if ($r.Count -eq 1 -and (Test-Path -LiteralPath $r[0].log)) { Get-Content -LiteralPath $r[0].log | ForEach-Object { Write-Host $_ } }
    $ok = $r.Count -eq 1 -and $r[0].code -is [int] -and $r[0].code -eq 0 -and -not $r[0].failure
    if (-not $ok) {
        $failed += $s.Name
        $why = if ($r.Count -ne 1) { 'no result' } elseif ($r[0].code -isnot [int]) { "no exit code; $($r[0].failure)" } elseif ($r[0].code -ne 0) { "exit code $($r[0].code)" } else { $r[0].failure }
        Write-Host "SUITE FAILED: $($s.Name) ($why); files kept in $(if ($r.Count -eq 1) { $r[0].dir } else { $run })"
    } else {
        Write-Host "--- $($s.Name): exit 0 in $($r[0].seconds)s"
        Remove-Item -LiteralPath $r[0].dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($failed.Count) { $result = 1 }
if (-not $result) { Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "`n$($suites.Count) PowerShell suite(s) in $([int]$clock.Elapsed.TotalSeconds)s, up to $throttle at a time; failed: $(if ($failed.Count) { $failed -join ', ' } else { 'none' })"
exit $result
