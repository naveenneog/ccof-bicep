#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$text = (Get-Content (Join-Path $root 'docs/runbooks/PUBLIC-ACCESS-WORKBOOK.md') -Raw).Replace("`r`n", "`n")
$boundary = $text.IndexOf("`n---`n`n<!-- ADMIN-HAND-CONFIG-APPENDIX-START -->", [StringComparison]::Ordinal)
if ($boundary -lt 0) { throw 'Append-only admin boundary is missing.' }
$original = $text.Substring(0, $boundary)
$digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($original))).ToLowerInvariant()
# Changed 2026-10-28 only by the hand-copy client sources (src/config.mjs, src/token-service.mjs: browserSignIn),
# which tests/manual-guide.test.ts keeps equal to client/.
if ($digest -cne 'd89c2dda6e168b3a6942a9d5e6239d4542dfbf406685e782360f24bc744d4290') {
    throw 'Original workbook changed. Modules 00-16 and the existing Step 13 must remain untouched.'
}
$appendix = $text.Substring($boundary)
$steps = [regex]::Matches($appendix, '(?m)^### Step (\d+\.[\da-z]+) - .+$')
if ($steps.Count -lt 75) { throw 'Granular step coverage is missing.' }
$ids = @($steps | ForEach-Object { $_.Groups[1].Value })
if (@($ids | Select-Object -Unique).Count -ne $ids.Count) { throw 'Duplicate appendix step number.' }
for ($i = 0; $i -lt $steps.Count; $i++) {
    $start = $steps[$i].Index
    $end = if ($i + 1 -lt $steps.Count) { $steps[$i + 1].Index } else { $appendix.Length }
    $body = $appendix.Substring($start, $end - $start)
    foreach ($label in '**Path A', '**Path B', '**Check') {
        if (-not $body.Contains($label)) { throw "Step $($ids[$i]) is missing $label." }
    }
}
foreach ($block in [regex]::Matches($appendix, '(?s)```json\s*\n(.*?)```')) {
    $block.Groups[1].Value | ConvertFrom-Json -AsHashtable -Depth 100 | Out-Null
}
foreach ($required in @(
    'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/readChangeFeed',
    '/dbs/$($Admin.database)/colls/$($Admin.container)',
    'privatelink.documents.azure.com', 'privatelink.blob.core.windows.net',
    'privatelink.azurewebsites.net', 'Microsoft.App/environments',
    'CCOF.Projects.Read', 'CCOF.Projects.Write', 'Projects.Manage',
    'STD', 'PRM', 'CYB', 'If-Match', 'inferenceGatewayOidc',
    'ipSecurityRestrictionsDefaultAction=Deny', 'properties.publicNetworkAccess=Disabled'
)) {
    if (-not $appendix.Contains($required)) { throw "Missing admin deployment requirement: $required" }
}
if ($appendix -match 'az deployment group create|Deploy-Quickstart\.ps1') {
    throw 'The hand-config appendix must not require an infrastructure deployment runner.'
}
if ($appendix -match "'functionapp','deploy'|az functionapp deploy -g|WEBSITE_RUN_FROM_PACKAGE\s*=") {
    throw 'Use the documented Flex-aware config-zip command, not the generic deploy preview command or run-from-package settings.'
}
if ($appendix -notmatch "'functionapp','deployment','source','config-zip',.*'--src',") {
    throw 'Admin publish must use the Azure CLI command that detects the Flex package endpoint.'
}
$quick = Get-Content (Join-Path $root 'docs/ADMIN-QUICK-STAGES.md') -Raw
$quickCount = 0
foreach ($block in [regex]::Matches($quick, '(?s)```powershell\s*\r?\n(.*?)```')) {
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($block.Groups[1].Value, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw "Quick admin block does not parse: $($errors.Message -join '; ')" }
    $quickCount++
}
if ($quickCount -lt 7 -or -not $quick.Contains('deployment source config-zip') -or -not $quick.Contains('Network gate')) {
    throw 'Quick modular deployment needs checked publish syntax and an explicit network-policy gate.'
}
"Quick admin stages: $quickCount PowerShell blocks parsed; no commands executed."
"Admin workbook: original content hash preserved, $($steps.Count) numbered Portal/CLI/check steps and appendix JSON verified. No commands executed."
