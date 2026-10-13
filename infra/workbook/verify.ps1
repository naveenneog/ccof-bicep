#Requires -Version 7.0
# Read-only check of a deployed workbook: its content equals the reviewed build, and every query runs.
# Prints counts, sums and states only. Query results and deployed content pass through memory and
# standard input; nothing with person, scope or request ids is written to disk.
[CmdletBinding()]
param(
    [string]$AnswersPath,
    [string]$Period,
    [string]$Project,
    [string]$From,
    [string]$To
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'preconditions.ps1')

function Write-Audit([string]$Outcome, [string]$Reason, [hashtable]$Extra = @{}) {
    $line = [ordered]@{ schema = 'ccof.workbook.verify.v1'; outcome = $Outcome; reason = $Reason }
    foreach ($key in $Extra.Keys) { $line[$key] = $Extra[$key] }
    $line | ConvertTo-Json -Compress -Depth 6 | Write-Output
}

# A node step counts only when it prints its expected JSON outcome, never on exit code alone.
function Get-NodeOutcome([object[]]$Output, [string]$Expected) {
    $last = @($Output | Where-Object { $_ -is [string] -and $_.StartsWith('{') }) | Select-Object -Last 1
    if (-not $last) { return $null }
    $parsed = $last | ConvertFrom-Json -AsHashtable
    if (-not [string]::Equals([string]$parsed.outcome, $Expected, 'Ordinal')) { return $null }
    return $parsed
}

if ([string]::IsNullOrWhiteSpace($AnswersPath)) { Write-Audit 'refused' 'answers_required'; exit 1 }
if ($Period -cnotin @('month', 'previous', 'custom')) { Write-Audit 'refused' 'period_required'; exit 1 }
if ([string]::IsNullOrEmpty($Project)) { Write-Audit 'refused' 'project_required'; exit 1 }
$custom = [string]::Equals($Period, 'custom', 'Ordinal')
if ($custom -ne (-not [string]::IsNullOrEmpty($From) -and -not [string]::IsNullOrEmpty($To))) {
    Write-Audit 'refused' 'custom_range_required_only_for_custom'; exit 1
}
$answerFile = [IO.Path]::GetFullPath($AnswersPath)
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
# Full paths in this platform's separators: node on Linux reads \ as part of a file name.
$buildScript = Join-Path $root 'analytics' 'workbooks' 'build.ts'
$renderScript = Join-Path $root 'analytics' 'workbooks' 'render.ts'
$armToken = $null
$queryToken = $null
$queriesPath = $null
Push-Location $root
try {
    if (-not (Test-Path -LiteralPath $answerFile -PathType Leaf)) { throw 'answers_file_unavailable' }
    $build = @(& node $buildScript --answers $answerFile 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not (Get-NodeOutcome $build 'validated')) { $build | Write-Output; throw 'offline_validation_failed' }
    $answers = Get-Content -LiteralPath $answerFile -Raw | ConvertFrom-Json
    $folder = Join-Path $root $answers.outputDirectory
    Assert-WorkbookAzArguments $answers.subscriptionId @($answers.workspaceResourceId)
    $tenant = & az account show --subscription $answers.subscriptionId --query tenantId --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'azure_account_unavailable' }
    if (-not [string]::Equals($tenant, $answers.tenantId, 'Ordinal')) { throw 'tenant_mismatch' }
    $workbookId = "/subscriptions/$($answers.subscriptionId)/resourceGroups/$($answers.resourceGroupName)/providers/Microsoft.Insights/workbooks/$($answers.workbookResourceName)"
    $armToken = & az account get-access-token --subscription $answers.subscriptionId --resource https://management.azure.com --query accessToken --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($armToken)) { throw 'arm_auth_failed' }
    try {
        $deployed = Invoke-RestMethod -Method Get -Uri "https://management.azure.com$($workbookId)?api-version=2023-06-01&canFetchContent=true" `
            -Headers @{ Authorization = "Bearer $armToken" } -TimeoutSec 60
    } catch { throw 'workbook_unavailable' }
    $serialized = [string]$deployed.properties.serializedData
    $compare = @($serialized | & node $renderScript --compare (Join-Path $folder 'workbook.json') - 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not (Get-NodeOutcome $compare 'content_matches')) { throw 'deployed_content_differs' }
    $expectedTags = (Get-Content -LiteralPath (Join-Path $folder 'parameters.json') -Raw | ConvertFrom-Json).parameters.contentTags.value
    foreach ($tag in $expectedTags.PSObject.Properties) {
        if (-not [string]::Equals([string]$deployed.tags.($tag.Name), [string]$tag.Value, 'Ordinal')) { throw 'deployed_tags_differ' }
    }
    Write-Audit 'content_verified' 'matches_reviewed_build' @{ workbookId = $workbookId; revision = $deployed.properties.revision; timeModified = $deployed.properties.timeModified; contentSha256 = $deployed.tags.'ccof-content' }
    $projectBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Project))
    $queriesPath = Join-Path $folder 'verify-queries.json'
    $rangeFrom = if ($custom) { $From } else { '-' }
    $rangeTo = if ($custom) { $To } else { '-' }
    $rendered = @($serialized | & node $renderScript --render - $queriesPath $Period $projectBase64 $rangeFrom $rangeTo 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not (Get-NodeOutcome $rendered 'rendered')) { $rendered | Write-Output; throw 'render_failed' }
    $workspaceId = & az monitor log-analytics workspace show --ids $answers.workspaceResourceId --query customerId --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($workspaceId)) { throw 'workspace_unavailable' }
    $queryToken = & az account get-access-token --subscription $answers.subscriptionId --resource https://api.loganalytics.io --query accessToken --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($queryToken)) { throw 'query_auth_failed' }
    $queries = Get-Content -LiteralPath $queriesPath -Raw | ConvertFrom-Json
    $executed = 0
    foreach ($item in $queries.PSObject.Properties) {
        $body = @{ query = $item.Value } | ConvertTo-Json -Compress
        try {
            $response = Invoke-RestMethod -Method Post -Uri "https://api.loganalytics.azure.com/v1/workspaces/$workspaceId/query" `
                -Headers @{ Authorization = "Bearer $queryToken" } -ContentType 'application/json' -Body $body -TimeoutSec 120
        } catch {
            Write-Audit 'query_failed' 'engine_error' @{ query = $item.Name }
            throw 'query_engine_failed'
        }
        $summary = @(($response | ConvertTo-Json -Depth 30 -Compress) | & node $renderScript --summarize - 2>&1)
        $parsed = Get-NodeOutcome $summary 'summarized'
        if ($LASTEXITCODE -ne 0 -or -not $parsed) { throw 'query_response_invalid' }
        Write-Audit 'query_executed' 'ok' @{ query = $item.Name; summary = $parsed.summary }
        $executed++
    }
    Write-Audit 'verified' 'content_and_queries' @{ workbookId = $workbookId; period = $Period; queries = $executed }
} catch {
    $reason = if ($_.Exception.Message -match '^[a-z_]+$') { $_.Exception.Message } else { 'verification_failed' }
    Write-Audit 'refused' $reason
    exit 1
} finally {
    $armToken = $null
    $queryToken = $null
    if ($queriesPath -and (Test-Path -LiteralPath $queriesPath)) { Remove-Item -LiteralPath $queriesPath -Force }
    Pop-Location
}
