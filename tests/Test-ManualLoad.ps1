#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$path = Join-Path $root 'infra\manual\Test-ManualLoad.ps1'
if (-not (Test-Path $path)) { Write-Host 'FAIL: bounded manual load entrypoint missing'; exit 1 }
. $path -DotSourceOnly
function Check([string]$Name, [bool]$Condition) {
    if (-not $Condition) { throw "FAIL: $Name" }
    Write-Host "PASS: $Name"
}
$pass = Get-ManualLoadSummary -Samples @(
    @{ status = 200; elapsedMs = 10 }, @{ status = 200; elapsedMs = 20 }
) -ExpectedRequests 2 -P95BudgetMilliseconds 25
Check 'all successful requests within explicit budget pass' $pass.passed
Check 'nearest rank p95 is correctly calculated' ($pass.p95Milliseconds -eq 20)
$failed = Get-ManualLoadSummary -Samples @(@{ status = 429; elapsedMs = 10 }) -ExpectedRequests 1 -P95BudgetMilliseconds 25
Check '429 is a failed load gate, not successful availability' (-not $failed.passed)
$slow = Get-ManualLoadSummary -Samples @(@{ status = 200; elapsedMs = 100 }) -ExpectedRequests 1 -P95BudgetMilliseconds 25
Check 'explicit latency budget enforced' (-not $slow.passed)
$incomplete = Get-ManualLoadSummary -Samples @(@{ status = 200; elapsedMs = 10 }) -ExpectedRequests 2 -P95BudgetMilliseconds 25
Check 'partial request set cannot pass' (-not $incomplete.passed)
$empty = Get-ManualLoadSummary -Samples @() -ExpectedRequests 2 -P95BudgetMilliseconds 25
Check 'empty load cannot pass' (-not $empty.passed)
$source = Get-Content $path -Raw
Check 'load never logs response bodies, credentials or request headers' (
    $source -notmatch 'Write-(Host|Output).*Token|\.Content|\.Headers|Exception\.Message')
Check 'load limits wall time and requires confirmation' ($source -match '-TimeoutSeconds \$MaximumDurationSeconds' -and $source -match 'if \(-not \$Confirmed\)')
