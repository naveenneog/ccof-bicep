#Requires -Version 7.0
<#
.SYNOPSIS
Generates settings, policy, registry seed and chargeback content for manual Portal configuration.
.DESCRIPTION
Offline except az bicep build-params (local compilation). No Azure reads, writes or deployment state.
Reuses pure configuration/schema helpers; never dispatches the quickstart steps.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ParametersPath,
    [Parameter(Mandatory)] [string]$EvidencePath,
    [string]$OutputDirectory = '.env.portal-artifacts'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'infra/quickstart/Deploy-Quickstart.ps1') -ParametersPath $ParametersPath -DotSourceOnly
Import-Module (Join-Path $PSScriptRoot 'Portal.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'scripts/Core.D2Steps.psm1') -DisableNameChecking
$parameterFile = Resolve-QsParametersPath $ParametersPath
if (@((Get-Content -LiteralPath $parameterFile) | Where-Object { $_ -match 'REPLACE-' -and $_ -notmatch '^\s*//' }).Count) { throw 'portal_placeholders_left: complete the private form first.' }
$p = Read-QsParameters $parameterFile
$e = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
Assert-PortalEvidence -P $p -Evidence $e
if ($p.sync.mode -cne 'application-permission') { throw 'portal_sync_mode: this workbook documents application-permission mode; see docs/SYNC.md for separately approved snapshot mode.' }
if ($p.reconciler.timerEnabled -or $p.syncTimerEnabled) { throw 'portal_timers_must_start_disabled: enable in the UI only after grants, seed and telemetry are verified.' }
$documents = New-QsSeedDocuments $p
$out = Resolve-QsParametersPath $OutputDirectory
New-Item -ItemType Directory -Path $out -Force | Out-Null
$answers = @{
    names = $p.names; target = @{ tenantId = $p.tenantId }; resolver = $p.resolver
    sync = $p.sync; reconciler = $p.reconciler
    availability = @{ sync = $p.sync; budgetState = $p.budgetState }
}
$connections = @{}
foreach ($app in @('resolver', 'sync')) {
    if (-not $e.apps[$app].connectionString -or $e.apps[$app].connectionString -match 'REPLACE') { throw "portal_insights_connection_missing: copy $app Application Insights connection string from Overview into the private evidence file." }
    $connections[$app] = $e.apps[$app].connectionString
}
$settings = Get-CoreAppSettings -Answers $answers -D1 $e -Connections $connections
$settings.sync.'AzureWebJobs.registrySeed.Disabled' = 'true'
foreach ($app in $settings.Keys) {
    $settings[$app].GetEnumerator() | ForEach-Object { [ordered]@{ name = $_.Key; value = $_.Value; slotSetting = $false } } |
        ConvertTo-Json -AsArray -Depth 10 | Set-Content -LiteralPath (Join-Path $out "$app-settings.json") -Encoding utf8NoBOM
}
$checks = @{ gatewayBaseUrl = $e.apim.gatewayUrl; gatewayIdentifierUri = $e.apim.gatewayIdentifierUri }
if (-not $checks.gatewayIdentifierUri -or $checks.gatewayIdentifierUri -match 'REPLACE') { throw 'portal_gateway_identifier_missing: copy the actual Gateway Application ID URI from Expose an API.' }
$config = New-QsGatewayConfig -P $p -Checks $checks
$config.resolver.url = "https://$($e.apps.resolver.defaultHostName)/api/resolve"
$configPath = Join-Path $out 'gateway-config.json'
$config | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
node (Join-Path $root 'infra/gateway/render.ts') --config $configPath --out (Join-Path $out 'gateway') | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'portal_policy_render_failed: check gateway-config.json and the renderer error.' }
$seedId = [guid]::NewGuid().ToString('N')
$payload = New-QsSeedPayload -Documents $documents -SeedId $seedId
$payload | Set-Content -LiteralPath (Join-Path $out 'seed-payload.txt') -Encoding utf8NoBOM -NoNewline
$documents | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $out 'registry-documents.json') -Encoding utf8NoBOM
$seedId | Set-Content -LiteralPath (Join-Path $out 'seed-id.txt') -Encoding utf8NoBOM
$workbookAnswers = New-QsWorkbookAnswers -P $p -ApimId $e.apim.id -Directory $out
$groupsPath = Join-Path $out 'workbook.groups.json'
@($p.groups | ForEach-Object { @{ projectId = $_.projectId; classification = $_.classification; groupId = $_.groupId; displayName = $_.classificationGroupDisplayName } }) |
    ConvertTo-Json -AsArray -Depth 20 | Set-Content -LiteralPath $groupsPath -Encoding utf8NoBOM
$workbook = Invoke-QsWorkbookBuild -AnswersPath $workbookAnswers -GroupsPath $groupsPath -Directory $out
$workbookParameters = Get-Content -LiteralPath $workbook.parametersPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
$workbookParameters.parameters.workbookContent.value | ConvertTo-Json -Depth 100 |
    Set-Content -LiteralPath (Join-Path $out 'chargeback.workbook.json') -Encoding utf8NoBOM
Write-Host "Generated private artifacts at $out; seed ID $seedId. Nothing was deployed. Review and import each artifact as the Portal workbook directs."
