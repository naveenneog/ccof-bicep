#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$ValuesPath,
    [Parameter(Mandatory)][string]$RegistryPath,
    [Parameter(Mandatory)][string]$RoutingPath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
function Read-PrivateJson([string]$Path) {
    $text = Get-Content -LiteralPath $Path -Raw
    if ($text -match 'REPLACE-') { throw "Unfilled placeholder in $Path." }
    return ($text | ConvertFrom-Json -AsHashtable -Depth 100)
}
function Save-PrivateJson($Value, [string]$Path) {
    ConvertTo-Json -InputObject $Value -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}
$root = (Resolve-Path $Repository).Path
$c = Read-PrivateJson $ValuesPath
$docs = Read-PrivateJson $RegistryPath
$routing = Read-PrivateJson $RoutingPath
foreach ($field in 'subscriptionId','tenantId','cosmosResourceId','workspaceResourceId','apimResourceId') {
    if (-not $c[$field]) { throw "manual_values_incomplete: $field is absent. Use verified customer-values.json, not customer-inputs.json." }
}
if ([string]$c.apps.resolver.location -cnotmatch '^[a-z][a-z0-9]+$') {
    throw 'manual_location_short_name_required: rerun Discovery to resolve the Function App display location to the approved short region name before building artifacts.'
}
$out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $out | Out-Null
$seedFile = Join-Path $out 'seed-payload.txt'
$seedIdFile = Join-Path $out 'seed-id.txt'
# Check an earlier seed before overwriting any other artifacts.
if ((Test-Path $seedFile) -or (Test-Path $seedIdFile)) {
    if (-not ((Test-Path $seedFile) -and (Test-Path $seedIdFile))) { throw 'Incomplete earlier seed artifacts. Review them before regenerating.' }
    $old = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((Get-Content $seedFile -Raw).Trim())) | ConvertFrom-Json -AsHashtable -Depth 100
    $oldId = (Get-Content $seedIdFile -Raw).Trim()
    if ($old.seedId -cne $oldId -or $oldId -cnotmatch '^[0-9a-f]{32}$') { throw 'Earlier payload and seed ID are invalid or differ. Stop.' }
    $oldDocuments = [ordered]@{projects=$old.projects;backends=$old.backends} | ConvertTo-Json -Depth 100 -Compress
    $newDocuments = [ordered]@{projects=$docs.projects;backends=$docs.backends} | ConvertTo-Json -Depth 100 -Compress
    if ($oldDocuments -cne $newDocuments) { throw 'An earlier seed exists with different documents. Do not regenerate over an unresolved seed.' }
}
$settingsPath = Join-Path $out 'sync-settings.object.json'
node (Join-Path $PSScriptRoot 'Validate-Registry.mjs') $root $RegistryPath $settingsPath
if ($LASTEXITCODE -ne 0) { throw 'Offline registry validation failed; no artifacts should be applied.' }
$registered = @($docs.backends | ForEach-Object { $_.backendId } | Sort-Object)
$routed = @($routing.backends | ForEach-Object { $_.backendId } | Sort-Object)
if (@(Compare-Object $registered $routed).Count -or @($routed | Select-Object -Unique).Count -ne $routed.Count) {
    throw 'Registry and routing backend IDs must match exactly and be unique.'
}
$inference = [ordered]@{}
foreach ($b in $routing.backends) {
    $u = [uri]$b.url
    if ($u.Scheme -cne 'https' -or $u.UserInfo -or $u.Query -or $u.Fragment -or $u.AbsolutePath -cne '/anthropic') {
        throw "Backend URL must be the approved HTTPS /anthropic endpoint: $($b.backendId)."
    }
    if ($b.foundryResourceId -notmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft.CognitiveServices/accounts/[^/]+$') {
        throw 'Foundry must be an account resource ID, not a project ID.'
    }
    if (-not $b.deploymentInferenceGeo.Count -or @($b.deploymentInferenceGeo.Values | Where-Object { $_ -cnotin @('global','us') }).Count) {
        throw 'Each exact deployment needs an approved global or us inference geography.'
    }
    $inference[$b.backendId] = $b.deploymentInferenceGeo
    foreach ($p in @($docs.projects | Where-Object backendId -CEQ $b.backendId)) {
        if (($b.foundryResourceId -split '/')[2] -ine $p.designatedSubscriptionId) {
            throw 'Project designated subscription differs from its Foundry account subscription.'
        }
        foreach ($cl in $p.classifications.Values) {
            foreach ($family in $cl.familyPolicy.families.Values) {
                foreach ($model in $family.models) {
                    if (-not $b.deploymentInferenceGeo.Contains($model)) { throw "Missing exact deployment geography: $model" }
                }
            }
        }
    }
}
$gateway = [ordered]@{
    schemaVersion=1; configurationId='public-path-gateway-1'
    apim=@{subscriptionId=($c.apimResourceId -split '/')[2];resourceGroup=$c.apimResourceGroup;serviceName=$c.apimName;apiId=$c.apiId;gatewayBaseUrl=$c.apimGatewayUrl;apiPath=$c.apiPath}
    entra=@{
        tenantId=$c.tenantId;authorityHost='https://login.microsoftonline.com';v1IssuerHost='https://sts.windows.net'
        audiences=@($c.gatewayIdentifierUri,$c.gatewayAppId) | Select-Object -Unique
        delegatedScope='access_as_user';delegatedClientAppIds=@($c.gatewayAppId.ToLowerInvariant())
        testIdentities=@{allowAppOnlyTokens=$false;clientAppIds=@();appRole=$null}
    }
    admission=@{perPerson=@{calls=120;renewalPeriodSeconds=60};resolverMisses=@{calls=200;renewalPeriodSeconds=1;maxConcurrent=100}}
    resolver=@{url="https://$($c.apps.resolver.defaultHostName)/api/resolve";tokenAudience=$c.resolverApiAppId;timeoutSeconds=10;projectHeaderName='x-ccof-project'}
    entitlementCache=@{keyVersion=1;cachingType='internal';allowTtlSeconds=120;refusalTtlSeconds=30;lastKnownGoodGraceSeconds=3600;refreshBackoffSeconds=30;unavailableRetryAfterSeconds=5}
    tokenLimits=@{
        estimatePromptTokens=$false
        headers=@{personRemainingQuota='x-ccof-person-quota-remaining';personRemainingTokens='x-ccof-person-tokens-remaining';groupRemainingQuota='x-ccof-group-quota-remaining';groupRemainingTokens='x-ccof-group-tokens-remaining';tokensConsumed='x-ccof-tokens-consumed'}
    }
    backends=@();inferenceGeo=$inference;forwarding=@{defaultAnthropicVersion='2023-06-01'}
}
$gateway.entra.audiences = @($gateway.entra.audiences)
Save-PrivateJson $gateway (Join-Path $out 'gateway-config.json')
node (Join-Path $root 'infra/gateway/render.ts') --config (Join-Path $out 'gateway-config.json') --out (Join-Path $out 'gateway')
if ($LASTEXITCODE -ne 0) { throw 'Gateway renderer refused the configuration. Do not publish partial output.' }
if ((Test-Path $seedFile) -or (Test-Path $seedIdFile)) {
    $seedId = $oldId
} else {
    $seedId = [guid]::NewGuid().ToString('N')
    $payload = @{seedId=$seedId;projects=@($docs.projects);backends=@($docs.backends)} | ConvertTo-Json -Depth 100 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    if ($encoded.Length -gt 98304) { throw 'Seed payload exceeds 96 KiB; do not truncate it.' }
    Set-Content -LiteralPath $seedFile -Value $encoded -Encoding utf8NoBOM -NoNewline
    Set-Content -LiteralPath $seedIdFile -Value $seedId -Encoding utf8NoBOM -NoNewline
}
$itemDirectory = Join-Path $out 'seed-documents'
New-Item -ItemType Directory -Force -Path $itemDirectory | Out-Null
foreach ($container in 'projects','backends') {
    foreach ($doc in $docs[$container]) {
        Save-PrivateJson $doc (Join-Path $itemDirectory "$container-$($doc.id).json")
    }
}
$groups = @()
foreach ($p in $docs.projects) {
    foreach ($code in $p.classifications.Keys) {
        $cl = $p.classifications[$code]
        $groups += @{projectId=$p.projectId;classification=$code;groupId=$cl.groupId;displayName=$cl.classificationGroupDisplayName}
    }
}
Save-PrivateJson $groups (Join-Path $out 'workbook.groups.json')
$answers = @{
    schemaVersion=1;subscriptionId=$c.subscriptionId;tenantId=$c.tenantId;resourceGroupName=$c.resourceGroup
    location=$c.apps.resolver.location;deploymentName='public-path-workbook';workbookResourceName='00000000-0000-0000-0000-000000000001'
    workbookDisplayName='Claude gateway chargeback';workspaceResourceId=$c.workspaceResourceId;gatewayResourceId=$c.apimResourceId;reconcilerResourceId=$c.apps.reconciler.id
    rateCardPath=(Join-Path $root 'config/rate-card.json');ledgerPath=(Join-Path $root 'analytics/ledger.kql')
    outputDirectory='.env.public-workbook';defaultProjectId='*';maxRows=1000;topUsers=25;maxQueryDays=62;budgetLookbackDays=31;retentionDays=$c.retentionDays
}
# This candidate GUID is metadata for the offline builder only. The Portal allocates
# the actual saved workbook ID; CLI save uses a separately recorded GUID.
Save-PrivateJson $answers (Join-Path $out 'workbook.answers.json')
Push-Location $out
try {
    node (Join-Path $root 'analytics/workbooks/chargeback.ts') --answers (Join-Path $out 'workbook.answers.json') --groups (Join-Path $out 'workbook.groups.json')
    if ($LASTEXITCODE -ne 0) { throw 'Chargeback workbook build failed.' }
    Copy-Item (Join-Path $out '.env.public-workbook/workbook.json') (Join-Path $out 'chargeback.workbook.json')
} finally { Pop-Location }
Write-Host "Local artifacts complete. Seed ID: $seedId. No Azure command or Bicep compilation was run."
