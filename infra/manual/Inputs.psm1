#Requires -Version 7.0
Set-StrictMode -Version Latest

function Get-ManualResourceInputs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary]$P,
        [Parameter(Mandatory)] [string]$RepositoryRoot,
        [System.Collections.IDictionary]$ApimCreateSettings
    )
    function Require-Value($Value, [string]$Name) {
        if ([string]::IsNullOrWhiteSpace([string]$Value)) { throw "manual_input_missing: $Name" }
    }
    function New-Input([string]$Id, [string]$Stage, [string]$Template, [hashtable]$Values, [string[]]$Needs) {
        $parameters = [ordered]@{}
        foreach ($key in $Values.Keys) { $parameters[$key] = @{ value = $Values[$key] } }
        [pscustomobject]@{
            Id = $Id; Stage = $Stage
            Template = Join-Path $RepositoryRoot $Template
            SubscriptionId = $P.names.subscriptionId
            ResourceGroup = $P.names.resourceGroup
            Parameters = $parameters; Needs = @($Needs)
        }
    }
    foreach ($field in @('subscriptionId', 'resourceGroup', 'deploymentPrefix')) {
        Require-Value $P.names[$field] "names.$field"
    }
    Require-Value $P.location 'location'
    $base = "/subscriptions/$($P.names.subscriptionId)/resourceGroups/$($P.names.resourceGroup)/providers"
    $net = $P.network
    if ($net.mode -cnotin @('create', 'existing')) { throw 'manual_network_mode: create or existing required' }
    if ($net.mode -eq 'create') {
        foreach ($field in @('vnetName', 'addressSpace', 'apimNsgName')) { Require-Value $net.create[$field] "network.create.$field" }
        foreach ($subnet in @('apim', 'privateEndpoints', 'functions')) {
            Require-Value $net.create.subnets[$subnet].name "network.create.subnets.$subnet.name"
            Require-Value $net.create.subnets[$subnet].prefix "network.create.subnets.$subnet.prefix"
        }
        # Same resource ids as network.bicep in Azure public cloud (this path's supported cloud).
        $subnets = @{
            privateEndpoints = "$base/Microsoft.Network/virtualNetworks/$($net.create.vnetName)/subnets/$($net.create.subnets.privateEndpoints.name)"
            functions = "$base/Microsoft.Network/virtualNetworks/$($net.create.vnetName)/subnets/$($net.create.subnets.functions.name)"
            cosmos = "$base/Microsoft.Network/privateDnsZones/privatelink.documents.azure.com"
            blob = "$base/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
        }
    }
    else {
        $subnets = @{
            privateEndpoints = $net.existing.privateEndpointSubnetId
            functions = $net.existing.functionsSubnetId
            cosmos = $net.existing.privateDnsZoneIds.cosmos
            blob = $net.existing.privateDnsZoneIds.blob
        }
        foreach ($key in $subnets.Keys) { Require-Value $subnets[$key] "network.existing.$key" }
    }
    $workspaceId = "$base/Microsoft.OperationalInsights/workspaces/$($P.names.logAnalyticsWorkspace)"
    New-Input 'workspace' 'resource-shells' 'infra\prereqs\log-analytics.bicep' @{
        location = $P.location; tags = $P.tags; name = $P.names.logAnalyticsWorkspace
        retentionInDays = $P.logRetentionDays
    } @()
    New-Input 'identities' 'resource-shells' 'infra\prereqs\identities.bicep' @{
        location = $P.location; tags = $P.tags; names = $P.names.identities
    } @()
    if ($net.mode -eq 'create') {
        New-Input 'network' 'minimum-private-prerequisites' 'infra\prereqs\network.bicep' @{
            location = $P.location; tags = $P.tags; vnetName = $net.create.vnetName
            addressSpace = $net.create.addressSpace; apimNsgName = $net.create.apimNsgName
            subnets = $net.create.subnets
        } @()
    }
    $networkNeeds = if ($net.mode -eq 'create') { @('network') } else { @('customer-network-verified') }
    New-Input 'cosmos' 'private-dependent-resources' 'infra\prereqs\cosmos-account.bicep' @{
        location = $P.location; tags = $P.tags; accountName = $P.names.cosmosAccount
        capacityMode = $P.cosmos.capacityMode; zoneRedundant = $P.cosmos.zoneRedundant
        privateEndpointName = $P.names.cosmosPrivateEndpoint
        privateEndpointSubnetId = $subnets.privateEndpoints; cosmosPrivateDnsZoneId = $subnets.cosmos
    } $networkNeeds
    $previous = $null
    $alwaysReady = @{ resolver = 'http'; sync = 'function:syncEntitlement'; reconciler = 'function:reconcileBudgets' }
    foreach ($app in @('resolver', 'sync', 'reconciler')) {
        $names = $P.names.apps[$app]
        $sizing = $P.functions[$app]
        $insights = if ($names.Contains('appInsights')) { [string]$names.appInsights } else { '' }
        $identityId = if ($app -eq 'resolver') { '' } else {
            "$base/Microsoft.ManagedIdentity/userAssignedIdentities/$($P.names.identities[$app])"
        }
        $needs = $networkNeeds + @('workspace', 'identities')
        if ($previous) { $needs += $previous }
        New-Input "app-$app" 'private-dependent-resources' 'infra\prereqs\function-app.bicep' @{
            location = $P.location; tags = $P.tags; functionAppName = $names.functionApp
            planName = $names.plan; storageAccountName = $names.storageAccount
            storageSku = $P.storageSku; deploymentContainerName = $names.deploymentContainer
            storagePrivateEndpointName = $names.storagePrivateEndpoint
            privateEndpointSubnetId = $subnets.privateEndpoints; blobPrivateDnsZoneId = $subnets.blob
            integrationSubnetId = $subnets.functions; appInsightsName = $insights
            logAnalyticsWorkspaceId = $workspaceId; userAssignedIdentityId = $identityId
            alwaysReadyName = $alwaysReady[$app]; alwaysReadyInstanceCount = $sizing.alwaysReady
            maximumInstanceCount = $sizing.maximumInstanceCount; instanceMemoryMB = $sizing.instanceMemoryMB
            zoneRedundant = $false
        } $needs
        $previous = "app-$app"
    }
    if ($ApimCreateSettings) {
        foreach ($field in @('sku', 'publisherEmail', 'publisherName', 'subnetId')) {
            Require-Value $ApimCreateSettings[$field] "apimCreateSettings.$field"
        }
        if (-not $ApimCreateSettings.Contains('units') -or -not $ApimCreateSettings.Contains('zones')) {
            throw 'manual_input_missing: apimCreateSettings.units and zones'
        }
        if ($P.apim.subscriptionId -ne $P.names.subscriptionId -or $P.apim.resourceGroup -ne $P.names.resourceGroup) {
            throw 'manual_apim_scope: create mode requires APIM in the target resource group'
        }
        New-Input 'apim' 'private-dependent-resources' 'infra\prereqs\apim.bicep' @{
            location = $P.location; tags = $P.tags; name = $P.apim.name
            sku = $ApimCreateSettings.sku; units = $ApimCreateSettings.units
            zones = $ApimCreateSettings.zones; publisherEmail = $ApimCreateSettings.publisherEmail
            publisherName = $ApimCreateSettings.publisherName; subnetId = $ApimCreateSettings.subnetId
        } $networkNeeds
    }
    if ($P.runner.enabled) { throw 'manual_runner_not_supported: use a customer private runner; this no-VM path requires runner.enabled=false' }
}

Export-ModuleMember -Function Get-ManualResourceInputs
