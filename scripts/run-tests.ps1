#Requires -Version 7.0
# Suites run in parallel (ADR 0041, SS-10), each with its own TEMP. Each suite's output is printed in
# name order after it finishes, and any failing suite fails the run.
[CmdletBinding()]
param(
    [string]$TestsDirectory,
    [switch]$SkipNode,
    [ValidateRange(1, 64)][int]$ThrottleLimit = [Math]::Min(8, [Math]::Max(1, [Environment]::ProcessorCount - 2))
)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
if (-not $TestsDirectory) { $TestsDirectory = Join-Path $root 'tests' }
$scratch = Join-Path $root '.env.public-test-scratch'
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$env:TEMP = $scratch
$env:TMP = $scratch
$env:CCOF_LIVE_TESTS = '0'
$result = 0

if (-not $SkipNode) {
    Write-Host '=== exported Node integration and unit suites ==='
    node --test (Join-Path $root 'tests\*.test.ts')
    if ($LASTEXITCODE -ne 0) { $result = 1 }
}

$suiteFiles = @(Get-ChildItem -LiteralPath $TestsDirectory -Filter '*.ps1' -ErrorAction Stop | Sort-Object Name)
if ($suiteFiles.Count -eq 0) { Write-Error "No PowerShell suites found in $TestsDirectory." -ErrorAction Continue; exit 1 }
$runs = $suiteFiles | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $name = $_.Name
    $temp = Join-Path $using:scratch "suite-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $psi = [Diagnostics.ProcessStartInfo]::new('pwsh')
    foreach ($a in '-NoProfile', '-File', $_.FullName) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = (Get-Location).Path
    $psi.Environment['TEMP'] = $temp
    $psi.Environment['TMP'] = $temp
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    try {
        $p = [Diagnostics.Process]::Start($psi)
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $stderr = $p.StandardError.ReadToEndAsync()
        $p.WaitForExit()
        [pscustomobject]@{ Name = $name; Exit = $p.ExitCode; Output = $stdout.Result + $stderr.Result }
    }
    catch { [pscustomobject]@{ Name = $name; Exit = -1; Output = "runner_error: $_" } }
    finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

foreach ($run in $runs | Sort-Object Name) {
    Write-Host "`n=== $($run.Name) ==="
    Write-Host $run.Output.TrimEnd()
    if ($run.Exit -ne 0) { Write-Host "FAILED: $($run.Name) exited $($run.Exit)"; $result = 1 }
}

exit $result
