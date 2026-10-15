#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$guide = Get-Content (Join-Path $root 'docs/runbooks/PUBLIC-ACCESS-WORKBOOK.md') -Raw
$count = 0
foreach ($block in [regex]::Matches($guide, '(?s)```powershell\s*\r?\n(.*?)```')) {
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($block.Groups[1].Value, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw "Manual copy/paste block $count does not parse: $($errors.Message -join '; ')" }
    $count++
}
if ($count -lt 80) { throw 'Manual command coverage unexpectedly missing.' }
foreach ($file in Get-ChildItem (Join-Path $root 'scripts/manual') -Filter '*.example.json') {
    Get-Content $file.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 100 | Out-Null
}
"Public completion workbook: $count PowerShell command blocks and all example JSON parse; no commands executed."
