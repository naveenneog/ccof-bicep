#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
python (Join-Path $PSScriptRoot 'test_architecture_assets.py')
if ($LASTEXITCODE -ne 0) { throw 'Architecture assets failed validation.' }
