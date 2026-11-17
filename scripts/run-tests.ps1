#Requires -Version 7.0
<#
Runs the offline suites: the Node suites, then every tests\*.ps1 in its own pwsh process.

The PowerShell suites run in parallel, up to CCOF_TEST_THROTTLE at a time (default: half the logical processors,
at most 8; 1 runs them one at a time). Each suite gets its own TEMP/TMP and its own Azure CLI profile directory
holding only the operator profile's config files and Bicep binary (no token cache, no account list), so suites
share no scratch files or CLI state. Without a Bicep binary in the operator profile the suites keep that profile
and run one at a time, as before. Output is printed per suite, in name order, after all suites end. The exit code
is 1 when any suite exits non-zero or its result cannot be read. A failed suite's TEMP is kept for inspection.
#>
param([string]$TestsDir, [string]$ScratchDir)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
if (-not $TestsDir) { $TestsDir = Join-Path $root 'tests' }
$scratch = if ($ScratchDir) { $ScratchDir } else { Join-Path $root '.env.public-test-scratch' }
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$env:TEMP = $scratch
$env:TMP = $scratch
$env:CCOF_LIVE_TESTS = '0'
$result = 0

if (Get-ChildItem -Path $TestsDir -Filter '*.test.ts' -ErrorAction SilentlyContinue) {
    Write-Host '=== exported Node integration and unit suites ==='
    node --test (Join-Path $TestsDir '*.test.ts')
    if ($LASTEXITCODE -ne 0) { $result = 1 }
}

$cliSource = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $HOME '.azure' }
$bicepFiles = @('bicep.exe', 'bicep' | Where-Object { Test-Path -LiteralPath (Join-Path $cliSource "bin/$_") -PathType Leaf })
$throttle = 0
if (-not [int]::TryParse("$env:CCOF_TEST_THROTTLE", [ref]$throttle) -or $throttle -lt 1) { $throttle = [Math]::Max(1, [Math]::Min(8, [int][Math]::Floor([Environment]::ProcessorCount / 2))) }
# Without a Bicep binary each suite profile would download its own; keep the shared profile and run one at a time.
$ownProfile = $bicepFiles.Count -gt 0
if (-not $ownProfile) { $throttle = 1 }

$run = Join-Path $scratch ('run-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $run | Out-Null
$pwshExe = (Get-Process -Id $PID).Path
$here = (Get-Location).Path
$suites = @(Get-ChildItem -Path $TestsDir -Filter '*.ps1' | Sort-Object Name)
$clock = [Diagnostics.Stopwatch]::StartNew()
$done = @($suites | ForEach-Object -ThrottleLimit $throttle -Parallel {
    $suite = $_; $cliSource = $using:cliSource; $pwshExe = $using:pwshExe
    Set-Location -LiteralPath $using:here
    $dir = Join-Path $using:run $suite.BaseName
    $temp = Join-Path $dir 'tmp'; $log = Join-Path $dir 'output.log'
    $cli = if ($using:ownProfile) { Join-Path $dir 'azure' } else { $cliSource }
    $code = $null; $failure = ''; $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        New-Item -ItemType Directory -Path $temp -ErrorAction Stop | Out-Null
        if ($using:ownProfile) {
            New-Item -ItemType Directory -Path (Join-Path $cli 'bin') -ErrorAction Stop | Out-Null
            foreach ($f in 'config', 'bicepVersionCheck.json', 'versionCheck.json') {
                $s = Join-Path $cliSource $f
                if (Test-Path -LiteralPath $s -PathType Leaf) { Copy-Item -LiteralPath $s -Destination (Join-Path $cli $f) -ErrorAction Stop }
            }
            foreach ($b in $using:bicepFiles) {
                $s = Join-Path $cliSource "bin/$b"; $d = Join-Path $cli "bin/$b"
                try { New-Item -ItemType HardLink -Path $d -Target $s -ErrorAction Stop | Out-Null } catch { Copy-Item -LiteralPath $s -Destination $d -ErrorAction Stop }
            }
        }
        $q = { param($v) "'" + ($v -replace "'", "''") + "'" }
        # The suite environment is set inside a wrapper process: $env is shared by all runspaces of this process.
        $cmd = "`$env:TEMP = $(& $q $temp); `$env:TMP = `$env:TEMP; `$env:AZURE_CONFIG_DIR = $(& $q $cli); & $(& $q $pwshExe) -NoProfile -File $(& $q $suite.FullName) *> $(& $q $log); exit `$LASTEXITCODE"
        $wrapper = & $pwshExe -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-String
        $code = $LASTEXITCODE
        if ($wrapper.Trim()) { $failure = "runner wrapper output: $($wrapper.Trim())" }
    } catch { $failure = "$_" }
    [pscustomobject]@{ name = $suite.Name; code = $code; seconds = [int]$watch.Elapsed.TotalSeconds; log = $log; dir = $dir; failure = $failure }
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
if ($failed.Count) { $result = 1 } else { Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "`n$($suites.Count) PowerShell suite(s) in $([int]$clock.Elapsed.TotalSeconds)s, up to $throttle at a time; failed: $(if ($failed.Count) { $failed -join ', ' } else { 'none' })"
exit $result
