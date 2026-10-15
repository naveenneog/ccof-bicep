#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts/portal/Portal.psm1') -Force
$sub = '11111111-1111-4111-8111-111111111111'
$rg = 'sample-platform'
$base = "/subscriptions/$sub/resourceGroups/$rg/providers"
$p = @{
    tenantId = '22222222-2222-4222-8222-222222222222'
    names = @{
        subscriptionId = $sub; resourceGroup = $rg; cosmosAccount = 'sample-cosmos'
        cosmosDatabase = 'registry'; logAnalyticsWorkspace = 'sample-law'
        cosmosRoles = @{ syncWriter = 'sample-sync-writer'; reconcilerWriter = 'sample-budget-writer'; projectWriter = 'sample-seed-writer' }
        apps = @{}
    }
    apim = @{ subscriptionId = $sub; resourceGroup = $rg; name = 'sample-apim' }
}
$d1 = @{
    target = @{ subscriptionId = $sub }
    cosmos = @{ id = "$base/Microsoft.DocumentDB/databaseAccounts/sample-cosmos"; endpoint = 'https://sample-cosmos.documents.azure.com:443/' }
    workspace = @{ id = "$base/Microsoft.OperationalInsights/workspaces/sample-law"; customerId = '33333333-3333-4333-8333-333333333333' }
    apim = @{ id = "$base/Microsoft.ApiManagement/service/sample-apim"; principalId = '44444444-4444-4444-8444-444444444444'; appId = '55555555-5555-4555-8555-555555555555'; gatewayUrl = 'https://sample-apim.azure-api.net' }
    apps = @{}
}
foreach ($app in @('resolver', 'sync', 'reconciler')) {
    $p.names.apps[$app] = @{ functionApp = "sample-$app"; storageAccount = "sample${app}storage"; appInsights = "sample-$app-ai" }
    $d1.apps[$app] = @{
        functionAppId = "$base/Microsoft.Web/sites/sample-$app"
        storageAccountId = "$base/Microsoft.Storage/storageAccounts/sample${app}storage"
        appInsightsId = "$base/Microsoft.Insights/components/sample-$app-ai"
        principalId = '66666666-6666-4666-8666-666666666666'
        clientId = if ($app -eq 'resolver') { '' } else { '77777777-7777-4777-8777-777777777777' }
        defaultHostName = "sample-$app.azurewebsites.net"
    }
}
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Refuses([scriptblock]$Call) {
    $refused = $false
    try { & $Call | Out-Null } catch { $refused = $true }
    Assert $refused 'Expected invalid evidence to be refused.'
}
foreach ($app in @('resolver', 'sync', 'reconciler')) {
    $plan = New-PortalAccessPlan -P $p -Evidence $d1 -App $app
    Assert ($plan.Problems.Count -eq 0) "$app plan has unresolved inputs."
    Assert (@($plan.Items | Where-Object plane -eq 'graph-app-role').Count -eq 0) 'Graph consent must remain separate.'
    Assert (@($plan.Items | Where-Object { $_.principalId -ne $d1.apps[$app].principalId }).Count -eq 0) 'Grant targets another principal.'
    Assert (@($plan.Items | Where-Object role -in @('Owner', 'Contributor', 'Cosmos DB Built-in Data Contributor')).Count -eq 0) 'Application got administrator access.'
    Assert (@($plan.Items | Where-Object role -eq 'Storage Blob Data Owner').Count -eq 1) 'Host storage grant missing.'
    if ($app -eq 'sync') {
        foreach ($container in @('projects', 'backends')) {
            Assert (@($plan.Items | Where-Object { $_.scope -eq "/dbs/registry/colls/$container" -and $_.roleDefinitionId -eq 'custom:onbProjectWriter' }).Count -eq 1) 'Create-only seed grant missing.'
        }
        $writer = @($plan.RoleDefinitions | Where-Object key -eq 'onbProjectWriter')[0]
        Assert (@($writer.dataActions | Where-Object { $_ -match 'replace|upsert|delete|\*' }).Count -eq 0) 'Seed writer is too broad.'
    }
}
$d1.apps.sync.principalId = 'REPLACE-object-id'
Refuses { New-PortalAccessPlan -P $p -Evidence $d1 -App sync }
$d1.apps.sync.principalId = '66666666-6666-4666-8666-666666666666'
$d1.apps.sync.storageAccountId = "$base/Microsoft.Storage/storageAccounts/another-storage"
Refuses { New-PortalAccessPlan -P $p -Evidence $d1 -App sync }
$d1.apps.sync.storageAccountId = "$base/Microsoft.Storage/storageAccounts/samplesyncstorage"
$d1.apps.sync.clientId = ''
Refuses { New-PortalAccessPlan -P $p -Evidence $d1 -App sync }
$d1.apps.sync.clientId = '77777777-7777-4777-8777-777777777777'
$d1.apps.sync.principalId += "`n"
Refuses { New-PortalAccessPlan -P $p -Evidence $d1 -App sync }
$d1.apps.sync.principalId = '66666666-6666-4666-8666-666666666666'
$d1.cosmos.id = '/subscriptions/wrong/resourceGroups/other/providers/Microsoft.DocumentDB/databaseAccounts/sample-cosmos'
Refuses { New-PortalAccessPlan -P $p -Evidence $d1 -App resolver }
$d1.cosmos.id = "$base/Microsoft.DocumentDB/databaseAccounts/sample-cosmos"
Write-Host 'Portal access plans and invalid-evidence refusal: PASS'

Import-Module (Join-Path $root 'scripts/Core.PermissionsApply.psm1') -DisableNameChecking
$resources = @{}
$writes = [System.Collections.Generic.List[string]]::new()
$send = {
    param($Method, $Url, $Body)
    $id = $Url.Split('?')[0].Replace('https://management.azure.com', '')
    if ($Method -eq 'PUT') {
        $writes.Add($id)
        $resources[$id] = @{ id = $id; name = $id.Split('/')[-1]; properties = $Body.properties }
        return @{ Status = 200; Content = $resources[$id]; ErrorCode = $null }
    }
    if ($id.EndsWith('/sqlRoleDefinitions') -or $id.EndsWith('/sqlRoleAssignments') -or $id.EndsWith('/roleAssignments')) {
        $values = @($resources.Values | Where-Object { $_.id.StartsWith("$id/") })
        return @{ Status = 200; Content = @{ value = $values }; ErrorCode = $null }
    }
    if ($resources.ContainsKey($id)) { return @{ Status = 200; Content = $resources[$id]; ErrorCode = $null } }
    return @{ Status = 404; Content = $null; ErrorCode = 'NotFound' }
}.GetNewClosure()
foreach ($app in @('resolver', 'sync', 'reconciler')) {
    $plan = New-PortalAccessPlan -P $p -Evidence $d1 -App $app
    $definitions = Get-CoreCosmosDefinitionWrites -Plan $plan -D1 $d1 -Send $send
    $first = @(Invoke-CoreD3Apply -Plan $plan -D1 $d1 -Send $send -Sleep {} -DefinitionWrites $definitions.Writes -OnWrite {})
    Assert (@($first | Where-Object state -notin @('created', 'existing', 'inherited')).Count -eq 0) "Mock runtime access apply failed for $app."
    $before = $writes.Count
    $again = @(Invoke-CoreD3Apply -Plan $plan -D1 $d1 -Send $send -Sleep {} -DefinitionWrites $definitions.Writes -OnWrite {})
    Assert (@($again | Where-Object state -notin @('existing', 'inherited')).Count -eq 0 -and $writes.Count -eq $before) 'Rerun must find existing grants without new writes.'
}
Write-Host 'Shared runtime grant engine: per-app apply and no-write rerun: PASS'

# Exercise the real exporter with local Bicep compilation and only synthetic inputs.
$scratch = Join-Path $root ".env.portal-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $formText = Get-Content (Join-Path $root 'infra/quickstart/main.bicepparam') -Raw
    $formText = $formText.Replace("using 'main.bicep'", "using '../infra/quickstart/main.bicep'")
    $formText = $formText.Replace('REPLACE-developer-gateway-app-id', '88888888-8888-4888-8888-888888888888')
    $formText = $formText.Replace('REPLACE-workbook-resource-guid', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
    $formText = $formText.Replace('REPLACE-resolver-api-app-id', '99999999-9999-4999-8999-999999999999').Replace('REPLACE-', '')
    $formPath = Join-Path $scratch 'form.bicepparam'
    $formText | Set-Content -LiteralPath $formPath -Encoding utf8NoBOM
    . (Join-Path $root 'infra/quickstart/Deploy-Quickstart.ps1') -DotSourceOnly
    $fixture = Read-QsParameters $formPath
    $fixtureBase = "/subscriptions/$($fixture.names.subscriptionId)/resourceGroups/$($fixture.names.resourceGroup)/providers"
    $record = @{
        target = @{ subscriptionId = $fixture.names.subscriptionId }
        cosmos = @{ id = "$fixtureBase/Microsoft.DocumentDB/databaseAccounts/$($fixture.names.cosmosAccount)"; endpoint = "https://$($fixture.names.cosmosAccount).documents.azure.com:443/" }
        workspace = @{ id = "$fixtureBase/Microsoft.OperationalInsights/workspaces/$($fixture.names.logAnalyticsWorkspace)"; customerId = '33333333-3333-4333-8333-333333333333' }
        apim = @{
            id = "/subscriptions/$($fixture.apim.subscriptionId)/resourceGroups/$($fixture.apim.resourceGroup)/providers/Microsoft.ApiManagement/service/$($fixture.apim.name)"
            principalId = '44444444-4444-4444-8444-444444444444'; appId = '55555555-5555-4555-8555-555555555555'
            gatewayUrl = "https://$($fixture.apim.name).azure-api.net"
            gatewayIdentifierUri = "api://$($fixture.registrations.gatewayApi.appId)"
        }
        apps = @{}
    }
    foreach ($app in @('resolver', 'sync', 'reconciler')) {
        $names = $fixture.names.apps[$app]
        $record.apps[$app] = @{
            functionAppId = "$fixtureBase/Microsoft.Web/sites/$($names.functionApp)"
            storageAccountId = "$fixtureBase/Microsoft.Storage/storageAccounts/$($names.storageAccount)"
            appInsightsId = if ($names.appInsights) { "$fixtureBase/Microsoft.Insights/components/$($names.appInsights)" } else { '' }
            principalId = '66666666-6666-4666-8666-666666666666'
            clientId = if ($app -eq 'resolver') { '' } else { '77777777-7777-4777-8777-777777777777' }
            connectionString = 'InstrumentationKey=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa;IngestionEndpoint=https://eastus2.in.applicationinsights.azure.com/'
            defaultHostName = "$($names.functionApp)-unique.azurewebsites.net"
        }
    }
    $evidencePath = Join-Path $scratch 'evidence.json'
    $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $evidencePath -Encoding utf8NoBOM
    $out = Join-Path $scratch 'artifacts'
    pwsh -NoProfile -File (Join-Path $root 'scripts/portal/Export-PortalArtifacts.ps1') -ParametersPath $formPath -EvidencePath $evidencePath -OutputDirectory $out
    Assert ($LASTEXITCODE -eq 0) 'Real portal artifact exporter failed.'
    foreach ($app in @('resolver', 'sync', 'reconciler')) {
        $settings = Get-Content (Join-Path $out "$app-settings.json") -Raw | ConvertFrom-Json
        Assert (@($settings | Where-Object name -eq 'CCOF_APP_ROLE')[0].value -ceq $app) 'Settings belong to the wrong app.'
        Assert (@($settings | Where-Object { $_.name -eq 'AzureWebJobsStorage' }).Count -eq 0) 'Key-based host setting was generated.'
    }
    $gateway = Get-Content (Join-Path $out 'gateway-config.json') -Raw | ConvertFrom-Json
    Assert ($gateway.resolver.url -ceq "https://$($record.apps.resolver.defaultHostName)/api/resolve") 'Actual resolver hostname was ignored.'
    $policy = Get-Content (Join-Path $out "gateway/$($fixture.apim.apiId).policy.xml") -Raw
    Assert ($policy.Contains($record.apps.resolver.defaultHostName)) 'Rendered policy lost actual hostname.'
    $seedPayload = Get-Content (Join-Path $out 'seed-payload.txt') -Raw
    $seed = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($seedPayload)) | ConvertFrom-Json
    Assert ($seed.projects.Count -eq 2 -and $seed.backends.Count -eq 1) 'Registry document shape/count wrong.'
    $workbook = Get-Content (Join-Path $out 'chargeback.workbook.json') -Raw | ConvertFrom-Json -Depth 100
    Assert ($workbook.version -ceq 'Notebook/1.0' -and $workbook.items.Count -gt 0) 'Workbook is an empty shell.'
    $guidePath = Join-Path $root 'docs/runbooks/AZURE-PORTAL-DEPLOYMENT.md'
    $guide = Get-Content -LiteralPath $guidePath -Raw
    foreach ($block in [regex]::Matches($guide, '(?s)```powershell\s*\r?\n(.*?)```')) {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($block.Groups[1].Value, [ref]$tokens, [ref]$errors)
        Assert ($errors.Count -eq 0) "Workbook PowerShell block failed parsing: $errors"
    }
    foreach ($link in [regex]::Matches($guide, '\[[^\]]*\]\(([^)]+)\)')) {
        $target = $link.Groups[1].Value
        if ($target -match '^https?://' -or $target.StartsWith('#')) { continue }
        Assert (Test-Path -LiteralPath (Join-Path (Split-Path $guidePath -Parent) $target.Split('#')[0])) "Broken guide link: $target"
    }
    # Recent network API versions return addressPrefixes (array) instead of addressPrefix, and VNets
    # created after 2026-03-31 default subnets to private (no egress) unless set explicitly.
    Assert (-not [regex]::IsMatch($guide, '\{prefix:addressPrefix,')) 'A subnet check reads addressPrefix without the addressPrefixes[0] fallback.'
    Assert ([regex]::Matches($guide, '--default-outbound-access true').Count -ge 2) 'APIM/Functions subnet creation does not set default outbound access.'
    Assert (-not $guide.Contains('access (Advanced)')) 'Storage key/anonymous access are on the Security tab, not Advanced.'
    Write-Host 'Real exporter, generated settings/policy/seed/workbook and copy-paste block parsing: PASS'
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
