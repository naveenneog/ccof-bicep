#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts/manual/Session-Helpers.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Refuses([scriptblock]$Call, [string]$Pattern) {
    $message=$null
    try { & $Call | Out-Null } catch { $message=$_.Exception.Message }
    Assert ($message -like $Pattern) "Expected $Pattern; received $message"
}
function global:az { throw 'Offline artifact generation must not call Azure CLI.' }
$scratch=Join-Path $root ".env.manual-artifacts-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch | Out-Null
$sub='11111111-1111-4111-8111-111111111111'
$base="/subscriptions/$sub/resourceGroups/sample-platform/providers"
$C=@{
    subscriptionId=$sub;tenantId='22222222-2222-4222-8222-222222222222';resourceGroup='sample-platform'
    cosmosResourceId="$base/Microsoft.DocumentDB/databaseAccounts/sample-cosmos";cosmosEndpoint='https://sample-cosmos.documents.azure.com/'
    database='registry';workspaceResourceId="$base/Microsoft.OperationalInsights/workspaces/sample-law"
    apimResourceId="$base/Microsoft.ApiManagement/service/sample-apim";apimResourceGroup='sample-platform';apimName='sample-apim'
    apimGatewayUrl='https://sample-apim.azure-api.net';apimPrincipalId='44444444-4444-4444-8444-444444444444'
    workspaceCustomerId='33333333-3333-4333-8333-333333333333';retentionDays=30
    apiId='claude-messages';apiPath='anthropic'
    gatewayAppId='88888888-8888-4888-8888-888888888888';gatewayIdentifierUri='api://88888888-8888-4888-8888-888888888888'
    resolverApiAppId='99999999-9999-4999-8999-999999999999';apps=@{}
}
foreach($app in 'resolver','sync','reconciler'){
    $C.apps[$app]=@{name="sample-$app";id="$base/Microsoft.Web/sites/sample-$app";location='eastus2'
        defaultHostName="sample-$app.azurewebsites.net";storageAccount="sample${app}storage"
        clientId='77777777-7777-4777-8777-777777777777';principalId='66666666-6666-4666-8666-666666666666'
        connectionString='InstrumentationKey=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'}
}
try {
    $docs=Get-Content (Join-Path $root 'scripts/manual/registry.example.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $p=$docs.projects[0];$p.id='PROJECT01';$p.projectId='PROJECT01';$p.displayName='Synthetic project';$p.backendId='foundry-primary';$p.designatedSubscriptionId=$sub
    $cl=$p.classifications['REPLACE-classification-code'];$p.classifications.Remove('REPLACE-classification-code');$p.classifications.STD=$cl
    $cl.groupId='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';$cl.classificationGroupDisplayName='PROJECT01STD';$cl.familyPolicy.families.sonnet.models=@('claude-sonnet-5')
    $docs.backends[0].id='foundry-primary';$docs.backends[0].backendId='foundry-primary'
    $routing=@{backends=@(@{backendId='foundry-primary';foundryResourceId="$base/Microsoft.CognitiveServices/accounts/sample-foundry"
        url='https://sample-foundry.services.ai.azure.com/anthropic';deploymentInferenceGeo=@{'claude-sonnet-5'='global'}})}
    $values=Join-Path $scratch 'values.json';$registry=Join-Path $scratch 'registry.json';$route=Join-Path $scratch 'routing.json'
    Save-CcofJson $C $values;Save-CcofJson $docs $registry;Save-CcofJson $routing $route
    New-CcofAppSettings -C $C -App sync -Directory $scratch
    $builder=Join-Path $root 'scripts/manual/Build-LocalArtifacts.ps1'
    & $builder -Repository $root -ValuesPath $values -RegistryPath $registry -RoutingPath $route -OutputDirectory $scratch | Out-Null
    $id=(Get-Content (Join-Path $scratch 'seed-id.txt') -Raw).Trim()
    $seedHash=(Get-FileHash (Join-Path $scratch 'seed-payload.txt')).Hash
    $groups=Get-Content (Join-Path $scratch 'workbook.groups.json') -Raw | ConvertFrom-Json -NoEnumerate
    Assert ($groups -is [array] -and $groups.Count -eq 1) 'One group was unwrapped to a JSON object.'
    $report=Get-Content (Join-Path $scratch 'chargeback.workbook.json') -Raw | ConvertFrom-Json -Depth 100
    Assert ($report.version -ceq 'Notebook/1.0' -and $report.items.Count -ge 10) 'Report is an incomplete shell.'
    Assert (Test-Path (Join-Path $scratch 'gateway/claude-messages.policy.xml')) 'Policy not rendered.'
    & $builder -Repository $root -ValuesPath $values -RegistryPath $registry -RoutingPath $route -OutputDirectory $scratch | Out-Null
    Assert ((Get-Content (Join-Path $scratch 'seed-id.txt') -Raw).Trim() -ceq $id) 'A no-change rebuild replaced the seed ID.'
    Assert ((Get-FileHash (Join-Path $scratch 'seed-payload.txt')).Hash -ceq $seedHash) 'A no-change rebuild changed the seed payload.'
    $C.apps.resolver.location='East US 2';Save-CcofJson $C $values
    Refuses { & $builder -Repository $root -ValuesPath $values -RegistryPath $registry -RoutingPath $route -OutputDirectory $scratch } 'manual_location_short_name_required*'
    $C.apps.resolver.location='eastus2';$C.cosmosResourceId=$null;Save-CcofJson $C $values
    Refuses { & $builder -Repository $root -ValuesPath $values -RegistryPath $registry -RoutingPath $route -OutputDirectory $scratch } 'manual_values_incomplete*'
    $C.cosmosResourceId="$base/Microsoft.DocumentDB/databaseAccounts/sample-cosmos";Save-CcofJson $C $values
    $p.displayName='Changed synthetic project';Save-CcofJson $docs $registry
    Refuses { & $builder -Repository $root -ValuesPath $values -RegistryPath $registry -RoutingPath $route -OutputDirectory $scratch } '*earlier seed exists with different documents*'
    'Offline manual artifacts: complete report, singleton group array, stable seed rebuild and fail-closed old/incomplete inputs: PASS'
} finally {
    Remove-Item Function:\global:az
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
