#Requires -Version 7.0
[CmdletBinding()]
param([string]$BicepPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $BicepPath) {
    $command = Get-Command bicep -ErrorAction SilentlyContinue
    if ($command) { $BicepPath = $command.Source }
    elseif (Test-Path (Join-Path $HOME '.azure\bin\bicep.exe')) { $BicepPath = Join-Path $HOME '.azure\bin\bicep.exe' }
    else { throw 'Offline Bicep CLI required. Supply -BicepPath; this test does not install tools or call Azure.' }
}

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Get-Resources($Template) {
    foreach ($resource in $Template.resources) {
        $resource
        if ($resource.properties.template) { Get-Resources $resource.properties.template }
        if ($resource.resources) { Get-Resources @{ resources = $resource.resources } }
    }
}
function Test-NoNetworkProperties($Node) {
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) {
            Assert-Contract ($key -notmatch '^(virtualNetworkSubnetId|virtualNetworkConfiguration|virtualNetworkType|subnetId|subnetResourceId|vnetRouteAllEnabled|vnetContentShareEnabled|outboundVnetRouting|virtualNetworkRules|privateEndpointConnections)$') "Forbidden network attachment property: $key"
            Test-NoNetworkProperties $Node[$key]
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        foreach ($value in $Node) { Test-NoNetworkProperties $value }
    }
}

$compiled = & $BicepPath build (Join-Path $root 'infra\staged\main.bicep') --stdout
if ($LASTEXITCODE -ne 0) { throw 'Resource-only stage-1 Bicep compilation failed.' }
$arm = ($compiled -join "`n") | ConvertFrom-Json -AsHashtable -Depth 100
$parameterBuild = & $BicepPath build-params (Join-Path $root 'infra\staged\main.bicepparam') --stdout
if ($LASTEXITCODE -ne 0) { throw 'Stage-1 Bicep parameter example compilation failed.' }
$null = ($parameterBuild -join "`n") | ConvertFrom-Json -Depth 100
$resources = @(Get-Resources $arm)
$allowed = @(
    'Microsoft.Resources/deployments',
    'Microsoft.OperationalInsights/workspaces',
    'Microsoft.ManagedIdentity/userAssignedIdentities',
    'Microsoft.DocumentDB/databaseAccounts',
    'Microsoft.Storage/storageAccounts',
    'Microsoft.Storage/storageAccounts/blobServices',
    'Microsoft.Storage/storageAccounts/blobServices/containers',
    'Microsoft.Insights/components',
    'Microsoft.Insights/diagnosticSettings',
    'Microsoft.Web/serverfarms',
    'Microsoft.Web/sites',
    'Microsoft.ApiManagement/service',
    'Microsoft.CognitiveServices/accounts',
    'Microsoft.CognitiveServices/accounts/deployments'
)
foreach ($resource in $resources) {
    Assert-Contract ($resource.type -in $allowed) "Not an approved stage-1 service resource: $($resource.type)"
    Assert-Contract ($resource.type -notmatch '^Microsoft\.Network/|^Microsoft\.Authorization/|sqlRole|Microsoft\.Graph|deploymentScripts|sqlDatabases') "Network, grants, scripts or schema found: $($resource.type)"
    if ($resource.type -eq 'Microsoft.Resources/deployments') {
        Assert-Contract ($resource.properties.template -and -not $resource.properties.templateLink) 'Uninspected external template reference is not allowed.'
    }
}
Test-NoNetworkProperties $arm
$serialized = $arm | ConvertTo-Json -Depth 100 -Compress
Assert-Contract ($serialized -notmatch 'graph\.microsoft\.com|WEBSITE_RUN_FROM_PACKAGE|sourcecontrols|zipDeploy') 'Stage 1 contains Graph, legacy package configuration or code deployment.'

foreach ($name in 'cosmosPublicNetworkAccess', 'storagePublicNetworkAccess', 'functionsPublicNetworkAccess') {
    Assert-Contract ($arm.parameters[$name].defaultValue -ceq 'Disabled') "$name is not secure by default."
}
Assert-Contract ($arm.parameters.approveNewPublicApimBootstrap.defaultValue -eq $false) 'Public APIM bootstrap must be explicit opt-in.'
Assert-Contract ($arm.parameters.includeAdmin.defaultValue -eq $true) 'Separate admin service must be included by default.'
$foundryModule = @($arm.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and @($_.properties.template.resources | Where-Object type -EQ 'Microsoft.CognitiveServices/accounts').Count })
Assert-Contract ($foundryModule.Count -eq 1 -and $foundryModule[0].condition -match 'foundry') 'Foundry account must be an opt-in Stage 1 module.'
$foundryAccount = @($foundryModule[0].properties.template.resources | Where-Object type -EQ 'Microsoft.CognitiveServices/accounts')[0]
Assert-Contract ($foundryAccount.properties.disableLocalAuth -eq $true) 'Foundry account must be keyless.'
Assert-Contract ($foundryModule[0].properties.template.parameters.publicNetworkAccess.defaultValue -ceq 'Disabled') 'Foundry must default to private.'
$apim = @($resources | Where-Object type -EQ 'Microsoft.ApiManagement/service')
$apimModules = @($arm.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and @($_.properties.template.resources | Where-Object type -EQ 'Microsoft.ApiManagement/service').Count })
Assert-Contract ($apim.Count -eq 1 -and $apimModules.Count -eq 1 -and $apimModules[0].condition -match "parameters\('approveNewPublicApimBootstrap'\)") 'APIM must be conditional on approval of NEW public bootstrap.'
Assert-Contract ($arm.outputs.apimId.value -match "if\(parameters\('approveNewPublicApimBootstrap'\).*, ''\)") 'Deferred APIM must have an empty ID, not a pretend deployed resource.'
$cosmos = @($resources | Where-Object type -EQ 'Microsoft.DocumentDB/databaseAccounts')[0]
Assert-Contract ($cosmos.properties.disableLocalAuth -eq $true) 'Cosmos local auth must remain disabled.'
$storage = @($resources | Where-Object type -EQ 'Microsoft.Storage/storageAccounts')[0]
Assert-Contract ($storage.properties.allowSharedKeyAccess -eq $false -and $storage.properties.allowBlobPublicAccess -eq $false) 'Storage shared-key/blob public access must remain disabled.'
Assert-Contract ($storage.properties.networkAcls.defaultAction -ceq 'Deny' -and $storage.properties.networkAcls.bypass -ceq 'None') 'Storage firewall must deny without an implicit trusted-service bypass.'
$site = @($resources | Where-Object type -EQ 'Microsoft.Web/sites')[0]
Assert-Contract ($site.properties.functionAppConfig.runtime.name -ceq 'node' -and $site.properties.functionAppConfig.runtime.version -ceq '22') 'Flex runtime must be Node 22.'
Assert-Contract ($site.properties.functionAppConfig.deployment.storage.type -ceq 'blobContainer') 'Flex identity-backed deployment storage must be configured.'
$auth = $site.properties.functionAppConfig.deployment.storage.authentication
Assert-Contract ($auth -is [string] -and $auth -match 'UserAssignedIdentity' -and $auth -match 'SystemAssignedIdentity') 'Deployment storage must select the service identity, not a credential placeholder.'
Assert-Contract ($site.properties.siteConfig.ftpsState -ceq 'Disabled') 'FTP must remain disabled.'
$functionsTemplate = @($arm.resources | Where-Object type -EQ 'Microsoft.Resources/deployments')[0].properties.template
Assert-Contract ($functionsTemplate.parameters.publicNetworkAccess.defaultValue -ceq 'Disabled' -and
    $functionsTemplate.parameters.storagePublicNetworkAccess.defaultValue -ceq 'Disabled') 'Direct function module also needs secure defaults.'
$parameterExample = Get-Content (Join-Path $root 'infra\staged\main.parameters.example.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
foreach ($name in $parameterExample.parameters.Keys) {
    Assert-Contract ($arm.parameters.ContainsKey($name)) "Unknown JSON example parameter: $name"
}
foreach ($name in $arm.parameters.Keys) {
    Assert-Contract ($arm.parameters[$name].ContainsKey('defaultValue') -or $parameterExample.parameters.ContainsKey($name)) "Missing required JSON example parameter: $name"
}
Assert-Contract ($parameterExample.parameters.approveNewPublicApimBootstrap.value -eq $false) 'JSON example must not approve public bootstrap.'
foreach ($name in 'cosmosPublicNetworkAccess', 'storagePublicNetworkAccess', 'functionsPublicNetworkAccess') {
    Assert-Contract ($parameterExample.parameters[$name].value -ceq 'Disabled') "JSON example $name must be secure."
}

$guidePath = Join-Path $root 'docs\runbooks\STAGED-CUSTOMER-DEPLOYMENT.md'
$guide = Get-Content $guidePath -Raw
$blocks = [regex]::Matches($guide, '(?s)```powershell\s*\r?\n(.*?)```')
Assert-Contract ($blocks.Count -ge 20) 'Runnable staged command coverage is unexpectedly missing.'
foreach ($block in $blocks) {
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($block.Groups[1].Value, [ref]$null, [ref]$errors)
    Assert-Contract (-not $errors.Count) "Staged PowerShell block does not parse: $($errors.Message -join '; ')"
}
foreach ($required in @(
    'separate identity/access', 'No access grants', 'create-only', 'canFetchContent=true',
    'Authorization="Bearer $armToken"', 'ConvertTo-Json -InputObject @($groups)',
    'DnsSubscription', 'DnsResourceGroup', 'ClientVnetResourceId', 'ClientHost',
    'ClientDnsZoneId', 'ClientPrivateEndpointId', '100.104.x.x', 'UNVERIFIED',
    'Microsoft.Web/serverFarms', 'Microsoft.App/environments',
    'privatelink.azurewebsites.net', 'privatelink.documents.azure.com',
    'config-zip', 'x-functions-key', '$body.checks.cosmos',
    'feat/project-admin-api', 'feat/admin-console-v2', 'retained', 'empty-RG',
    'adminTags', 'adminConfig', '/scopeId', 'ADMIN_GRAPH_ENABLED',
    'ADMIN_RESOURCE_IDS', 'ADMIN_DISCOVERY_SCOPES', 'ADMIN_WORKSPACE_ID',
    'ADMIN_LOG_RESOURCE_IDS', 'ADMIN_CONFIG_CONTAINER', 'ADMIN_RETAIL_PRICES_ENABLED',
    'ADMIN_COST_SCOPE', 'ADMIN_HEALTH_TARGETS'
)) {
    Assert-Contract ($guide.Contains($required)) "Missing runbook safety/contract requirement: $required"
}
Assert-Contract ($guide -notmatch 'scripts\\portal\\Build-AdminPackage') 'Admin builder path must match the actual admin package entrypoint.'
foreach ($path in @(
    'admin\Build-AdminPackage.ps1', 'scripts\portal\Build-PortalPackage.ps1',
    'scripts\manual\Run-Bundles.ps1', 'scripts\manual\Test-FoundryPrivatePath.ps1'
)) { Assert-Contract (Test-Path (Join-Path $root $path)) "Documented entry point missing: $path" }
$checker = Get-Command (Join-Path $root 'scripts\manual\Test-FoundryPrivatePath.ps1')
foreach ($name in @(
    'ApimResourceId', 'FoundryResourceId', 'BackendHost', 'DnsSubscription', 'DnsResourceGroup',
    'ClientVnetResourceId', 'ClientHost', 'ClientDnsZoneId', 'ClientPrivateEndpointId',
    'PrivateEndpointId', 'PrivateDnsZoneIds', 'DnsVnetResourceId'
)) { Assert-Contract ($checker.Parameters.ContainsKey($name)) "Documented checker parameter absent: $name" }
$adminBuilder = Get-Command (Join-Path $root 'admin\Build-AdminPackage.ps1')
Assert-Contract ($adminBuilder.Parameters.ContainsKey('OutFile')) 'Documented admin builder interface changed.'
$prose = [regex]::Replace($guide, '```[\s\S]*?```', '')
foreach ($link in [regex]::Matches($prose, '!?\[[^\]]*\]\(([^)]+)\)')) {
    $target = $link.Groups[1].Value.Split('#')[0]
    if (-not $target -or $target -match '^https?:') { continue }
    Assert-Contract (Test-Path (Join-Path (Split-Path $guidePath -Parent) $target)) "Broken staged-runbook link: $target"
}
"Staged deployment: Bicep and both parameter formats compiled/checked; $($resources.Count) recursive ARM service resources checked, $($blocks.Count) PowerShell blocks parsed. No Azure calls or runbook commands executed."
