#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $root 'infra\manual\Invoke-ManualConfiguration.ps1'
$refused = $false
try { & $scriptPath -Step 1 -ParametersPath '' -DotSourceOnly:$false }
catch { $refused = $_.Exception.Message -match 'manual_usage' }
if (-not $refused) { throw 'FAIL: normal manual CLI must reach its required argument validation, not silently return' }
Write-Host 'PASS: normal manual CLI reaches its argument guard'
& $scriptPath -DotSourceOnly
Write-Host 'PASS: explicit helper-only invocation does not dispatch a stage'
$refused = $false
try { & $scriptPath -Step 1 -ParametersPath 'synthetic-no-such-input.bicepparam' -WhatIfOnly }
catch { $refused = $_.Exception.Message -match 'manual_what_if_step' }
if (-not $refused) { throw 'FAIL: normal manual CLI must preserve WhatIfOnly and refuse a nonconfiguration stage' }
Write-Host 'PASS: manual CLI preserves WhatIfOnly and enforces stage restriction'
