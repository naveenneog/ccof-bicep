#Requires -Version 7.0
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path $root '.env.public-test-scratch'
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$env:TEMP = $scratch
$env:TMP = $scratch
$env:CCOF_LIVE_TESTS = '0'
$result = 0

Write-Host '=== exported Node integration and unit suites ==='
node --test (Join-Path $root 'tests\*.test.ts')
if ($LASTEXITCODE -ne 0) { $result = 1 }

Get-ChildItem (Join-Path $root 'tests') -Filter '*.ps1' |
    Sort-Object Name |
    ForEach-Object {
        Write-Host "`n=== $($_.Name) ==="
        pwsh -NoProfile -File $_.FullName
        if ($LASTEXITCODE -ne 0) { $result = 1 }
    }

exit $result
