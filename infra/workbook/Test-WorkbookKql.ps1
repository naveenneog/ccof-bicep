#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$WorkspaceId,
    [string]$OutputDirectory,
    [string]$CheckId
)
$ErrorActionPreference = 'Stop'
if ($env:CCOF_LIVE_TESTS -cne '1') {
    '{"schema":"ccof.workbook.kql.v1","outcome":"refused","reason":"live_opt_in_required"}'
    exit 1
}
$guid = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
if ($SubscriptionId -notmatch $guid -or $WorkspaceId -notmatch $guid -or $OutputDirectory -notmatch '^\.env\.[a-z0-9._-]+$') {
    '{"schema":"ccof.workbook.kql.v1","outcome":"refused","reason":"configuration_required"}'
    exit 1
}
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
# A full path in this platform's separators: node on Linux reads \ as part of a file name.
$kql = Join-Path $root 'tests' 'helpers' 'workbook-kql.ts'
Push-Location $root
$token = $null
try {
    $manifest = Join-Path $OutputDirectory 'checks.json'
    # Never run an older manifest: a silent generator failure must not leave stale checks behind.
    if (Test-Path -LiteralPath $manifest) { Remove-Item -LiteralPath $manifest -Force }
    $written = @(& node $kql --write $OutputDirectory 2>&1)
    $writtenLine = @($written | Where-Object { $_ -is [string] -and $_.StartsWith('{') }) | Select-Object -Last 1
    $ready = if ($writtenLine) { $writtenLine | ConvertFrom-Json } else { $null }
    if ($LASTEXITCODE -ne 0 -or -not $ready -or $ready.outcome -cne 'fixtures_ready' -or -not (Test-Path -LiteralPath $manifest)) { throw 'fixture_generation_failed' }
    $checks = @(Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json)
    if ($checks.Count -ne $ready.checks) { throw 'fixture_generation_failed' }
    if ($CheckId) { $checks = @($checks | Where-Object { $_.id -ceq $CheckId }) }
    if ($checks.Count -eq 0) { throw 'check_not_found' }
    $token = & az account get-access-token --subscription $SubscriptionId --resource https://api.loganalytics.io --query accessToken --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) { throw 'query_auth_failed' }
    $results = @()
    foreach ($check in $checks) {
        $body = @{ query = $check.query } | ConvertTo-Json -Depth 10 -Compress
        try {
            $response = Invoke-RestMethod -Method Post -Uri "https://api.loganalytics.azure.com/v1/workspaces/$WorkspaceId/query" `
                -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body $body -TimeoutSec 120
        } catch {
            [ordered]@{ id = $check.id; outcome = 'engine_error'; reason = $_.ErrorDetails.Message } | ConvertTo-Json -Compress | Write-Output
            throw 'query_engine_failed'
        }
        $responseFile = Join-Path $OutputDirectory "$($check.id).response.json"
        $response | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $responseFile -Encoding utf8NoBOM
        $result = @(& node $kql --verify $manifest $check.id $responseFile 2>&1)
        $result | Write-Output
        $resultLine = @($result | Where-Object { $_ -is [string] -and $_.StartsWith('{') }) | Select-Object -Last 1
        $parsed = if ($resultLine) { $resultLine | ConvertFrom-Json } else { $null }
        $wanted = if ($check.shouldPass) { 'passed' } else { 'mutation_caught' }
        if ($LASTEXITCODE -ne 0 -or -not $parsed -or $parsed.outcome -cne $wanted -or $parsed.id -cne $check.id) { throw 'kql_verification_failed' }
        $results += $parsed
    }
    if ($results.Count -ne $checks.Count) { throw 'kql_results_incomplete' }
    $results | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'results.json') -Encoding utf8NoBOM
    [ordered]@{ schema = 'ccof.workbook.kql.v1'; outcome = 'passed'; queries = $results.Count } | ConvertTo-Json -Compress
} catch {
    [ordered]@{ schema = 'ccof.workbook.kql.v1'; outcome = 'failed'; reason = $_.Exception.Message } | ConvertTo-Json -Compress
    exit 1
} finally {
    $token = $null
    Pop-Location
}
