#Requires -Version 7.0
<#
.SYNOPSIS
    Fakes for the WP-CORE stage tests: an in-memory Azure Resource Manager and Microsoft Graph that
    answer GET requests for a conforming D1 environment built from an answers file. No network.
#>

function New-CoreFakeGuid { param([string]$Seed) ([guid]::new([System.Security.Cryptography.MD5]::HashData([Text.Encoding]::UTF8.GetBytes($Seed)))).ToString() }

function New-CoreFakeEnvironment {
    <#
    .SYNOPSIS
        A dictionary of URL -> resource for every D1 resource of the answers, each one conforming.
        Tests change single entries to break one property.
    #>
    param([Parameter(Mandatory)] [System.Collections.IDictionary]$Answers, [Parameter(Mandatory)] [hashtable]$Ids)
    $env = [ordered]@{}
    $av = $Answers.availability
    function Put([string]$Key, [string]$Type, $Resource) { $env[(Get-CoreArmUrl $Ids[$Key] $Type)] = $Resource }
    Put 'resourceGroup' 'Microsoft.Resources/resourceGroups' @{ location = $Answers.target.location }
    Put 'network.apimSubnet' 'Microsoft.Network/virtualNetworks/subnets' @{ properties = @{ delegations = @(@{ properties = @{ serviceName = 'Microsoft.Web/serverFarms' } }); networkSecurityGroup = @{ id = 'nsg' } } }
    Put 'network.privateEndpointSubnet' 'Microsoft.Network/virtualNetworks/subnets' @{ properties = @{ delegations = @() } }
    Put 'network.functionsSubnet' 'Microsoft.Network/virtualNetworks/subnets' @{ properties = @{ delegations = @(@{ properties = @{ serviceName = 'Microsoft.App/environments' } }) } }
    Put 'network.cosmosDnsZone' 'Microsoft.Network/privateDnsZones' @{ name = 'privatelink.documents.azure.com' }
    Put 'network.blobDnsZone' 'Microsoft.Network/privateDnsZones' @{ name = 'privatelink.blob.core.windows.net' }
    Put 'workspace' 'Microsoft.OperationalInsights/workspaces' @{ location = $av.telemetry.workspaceRegion; properties = @{ retentionInDays = $av.telemetry.retentionDays; customerId = (New-CoreFakeGuid 'workspace') } }
    foreach ($name in @('sync', 'reconciler')) {
        Put "${name}Identity" 'Microsoft.ManagedIdentity/userAssignedIdentities' @{ properties = @{ principalId = (New-CoreFakeGuid "$name-principal"); clientId = (New-CoreFakeGuid "$name-client") } }
    }
    Put 'cosmos' 'Microsoft.DocumentDB/databaseAccounts' @{ properties = @{
            capabilities = @(if ($av.registry.capacityMode -eq 'serverless') { @{ name = 'EnableServerless' } })
            locations = @(@{ locationName = 'East US 2'; failoverPriority = 0; isZoneRedundant = $av.registry.zoneRedundant })
            publicNetworkAccess = 'Disabled'; disableLocalAuth = $true; documentEndpoint = "https://$($Answers.names.cosmosAccount).documents.azure.com:443/" } }
    Put 'cosmosPrivateEndpoint' 'Microsoft.Network/privateEndpoints' @{ properties = @{ privateLinkServiceConnections = @(@{ properties = @{ privateLinkServiceId = $Ids.cosmos; privateLinkServiceConnectionState = @{ status = 'Approved' } } }); manualPrivateLinkServiceConnections = @() } }
    $groups = @{ resolver = 'http'; sync = 'function:syncEntitlement'; reconciler = 'function:reconcileBudgets' }
    foreach ($key in @('resolver', 'sync', 'reconciler')) {
        $sizing = $av.functions[$key]
        $identity = if ($key -eq 'resolver') { @{ type = 'SystemAssigned'; principalId = (New-CoreFakeGuid 'resolver-principal') } }
        else { @{ type = 'UserAssigned'; userAssignedIdentities = @{ $Ids["${key}Identity"] = @{} } } }
        $ready = if ($sizing.alwaysReady -gt 0) { @(@{ name = $groups[$key]; instanceCount = $sizing.alwaysReady }) } else { @() }
        Put "$key.site" 'Microsoft.Web/sites' @{ identity = $identity; properties = @{
                defaultHostName = "$($Answers.names.apps[$key].functionApp).azurewebsites.net"; virtualNetworkSubnetId = $Ids['network.functionsSubnet']; serverFarmId = $Ids["$key.plan"]
                functionAppConfig = @{ runtime = @{ name = 'node'; version = '22' }; scaleAndConcurrency = @{ alwaysReady = $ready; maximumInstanceCount = $sizing.maximumInstanceCount; instanceMemoryMB = $sizing.instanceMemoryMB } } } }
        Put "$key.plan" 'Microsoft.Web/serverfarms' @{ sku = @{ name = 'FC1' }; properties = @{ zoneRedundant = $sizing.zoneRedundant } }
        Put "$key.storage" 'Microsoft.Storage/storageAccounts' @{ sku = @{ name = $av.storage.sku }; properties = @{ allowSharedKeyAccess = $false; publicNetworkAccess = 'Disabled' } }
        if ($Ids["$key.appInsights"]) { Put "$key.appInsights" 'Microsoft.Insights/components' @{ properties = @{ WorkspaceResourceId = $Ids.workspace } } }
    }
    $apimPrincipal = New-CoreFakeGuid 'apim-principal'
    Put 'apim' 'Microsoft.ApiManagement/service' @{ sku = @{ name = $av.apim.sku; capacity = $av.apim.units }; zones = @($av.apim.zones)
        identity = @{ type = 'SystemAssigned'; principalId = $apimPrincipal }
        properties = @{ virtualNetworkType = 'External'; virtualNetworkConfiguration = @{ subnetResourceId = $Ids['network.apimSubnet'] }; provisioningState = 'Succeeded'; gatewayUrl = "https://$($Answers.names.apim).azure-api.net" } }
    $env["https://graph.microsoft.com/v1.0/servicePrincipals/$apimPrincipal`?`$select=id,appId"] = @{ id = $apimPrincipal; appId = (New-CoreFakeGuid 'apim-app') }
    Put 'workbook' 'Microsoft.Insights/workbooks' @{ id = $Ids.workbook }
    $identity = $Answers.identity
    $apps = @{
        gatewayApi = @{ id = (New-CoreFakeGuid 'gw-object'); identifierUris = @("api://$($identity.gatewayApi.appId)"); api = @{ requestedAccessTokenVersion = $(if ($identity.gatewayApi.accessTokenVersion -eq 1) { $null } else { 2 }); oauth2PermissionScopes = @(@{ value = $identity.gatewayApi.scope; isEnabled = $true }) } }
        developerSignIn = @{ id = (New-CoreFakeGuid 'dev-object'); identifierUris = @(); api = @{}; publicClient = @{ redirectUris = @($identity.developerSignIn.redirectUris) } }
        resolverApi = @{ id = (New-CoreFakeGuid 'res-object'); identifierUris = @("api://$($identity.resolverApi.appId)"); api = @{ requestedAccessTokenVersion = 2 } }
    }
    if ($identity.gatewayApi.appId -eq $identity.developerSignIn.appId) {
        $apps.gatewayApi.publicClient = $apps.developerSignIn.publicClient
        $apps.developerSignIn = $apps.gatewayApi
    }
    foreach ($name in $apps.Keys) {
        $appId = $identity[$name].appId
        $env["https://graph.microsoft.com/v1.0/applications(appId='$appId')?`$select=id,appId,identifierUris,api,publicClient"] = $apps[$name]
        $env["https://graph.microsoft.com/v1.0/servicePrincipals(appId='$appId')?`$select=id,appId"] = @{ id = (New-CoreFakeGuid "$name-sp"); appId = $appId }
    }
    return $env
}

function New-CoreFakeGet {
    <#
    .SYNOPSIS
        A -Get scriptblock over a fake environment. Unknown URLs answer $null (404). Every URL asked is
        appended to $Calls, so a test can prove that nothing was read.
    #>
    param([Parameter(Mandatory)] [System.Collections.IDictionary]$Environment, [System.Collections.Generic.List[string]]$Calls)
    { param($Url) if ($null -ne $Calls) { $Calls.Add($Url) }; if ($Environment.Contains($Url)) { ConvertFrom-CoreJson ($Environment[$Url] | ConvertTo-Json -Depth 30) } else { $null } }.GetNewClosure()
}

Export-ModuleMember -Function New-CoreFakeEnvironment, New-CoreFakeGet, New-CoreFakeGuid
