// D1 prerequisite: one Function App on the Flex Consumption plan, with its plan, its storage account
// (deployment package and host state), the storage's blob private endpoint and, optionally,
// workspace-based Application Insights (docs/PREREQUISITES-WORKBOOK.md, steps D1-09 to D1-13).
// Used for the resolver, the sync and the reconciler.
// Sources: infra/poc/phase3-cosmos-function.bicep (resolver, live 2026-10-10) and
// infra/sync/sync-function.bicep on wp/sync (sync, live 2026-10-11): storage with shared keys and
// public access off, a blob private endpoint only, VNet integration, identity-based deployment storage.
// No role assignment (D3) and no application setting (D2) here. The app cannot run its code until D3
// grants its identity Storage Blob Data Owner on this storage account and D2 deploys settings and code.

targetScope = 'resourceGroup'

@description('Region; equals the deployment location.')
param location string

@description('Tags for every resource (answers target.tags).')
param tags object

@description('Function App name (answers names.apps.<app>.functionApp).')
param functionAppName string

@description('Flex Consumption plan name; one app per plan.')
param planName string

@description('Storage account name, 3-24 lowercase letters and digits.')
param storageAccountName string

@description('Storage redundancy, a D0 decision (availability.storage.sku).')
@allowed(['Standard_LRS', 'Standard_ZRS'])
param storageSku string

@description('Blob container for the deployment package.')
param deploymentContainerName string

@description('Private endpoint name for the storage blob service.')
param storagePrivateEndpointName string

@description('Subnet id for private endpoints (D1 network).')
param privateEndpointSubnetId string

@description('Resource id of the privatelink.blob.core.windows.net private DNS zone.')
param blobPrivateDnsZoneId string

@description('VNet integration subnet id, delegated to Microsoft.App/environments.')
param integrationSubnetId string

@description('Application Insights name, or an empty string when the app logs through a diagnostic setting instead (reconciler, WP-REC).')
param appInsightsName string

@description('Log Analytics workspace id for Application Insights.')
param logAnalyticsWorkspaceId string

@description('Resource id of the user-assigned identity the app runs as, or an empty string for a system-assigned identity (resolver, ADR-0009).')
param userAssignedIdentityId string

@description('Always-ready group: "http" for HTTP functions, "function:<name>" for one function (Learn, flex-consumption-plan).')
param alwaysReadyName string

@description('Always-ready instances, a D0 decision (availability.functions.<app>.alwaysReady).')
@minValue(0)
param alwaysReadyInstanceCount int

@description('Maximum instance count, a D0 decision.')
param maximumInstanceCount int

@description('Instance memory in MB, a D0 decision.')
@allowed([512, 2048, 4096])
param instanceMemoryMB int

@description('Zone redundancy of the plan, a D0 decision; requires at least two always-ready instances.')
param zoneRedundant bool

var usesUserAssigned = !empty(userAssignedIdentityId)

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: storageSku }
  properties: {
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'AzureServices' }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: storage
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: deploymentContainerName
}

resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: storagePrivateEndpointName
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: '${storagePrivateEndpointName}-connection'
        properties: { privateLinkServiceId: storage.id, groupIds: ['blob'] }
      }
    ]
  }
}

resource storageDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: storagePrivateEndpoint
  name: 'blob-dns-zone-group'
  properties: {
    privateDnsZoneConfigs: [{ name: 'blob', properties: { privateDnsZoneId: blobPrivateDnsZoneId } }]
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = if (!empty(appInsightsName)) {
  name: empty(appInsightsName) ? 'unused' : appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
    DisableLocalAuth: true
  }
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  tags: tags
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  properties: {
    reserved: true
    zoneRedundant: zoneRedundant
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: usesUserAssigned ? {
    type: 'UserAssigned'
    userAssignedIdentities: { '${userAssignedIdentityId}': {} }
  } : {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    virtualNetworkSubnetId: integrationSubnetId
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: usesUserAssigned ? {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: userAssignedIdentityId
          } : {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: maximumInstanceCount
        instanceMemoryMB: instanceMemoryMB
        alwaysReady: alwaysReadyInstanceCount > 0 ? [{ name: alwaysReadyName, instanceCount: alwaysReadyInstanceCount }] : []
      }
      // Node 22 is the resolver's runtime (ADR-0003) and every app shares one build.
      runtime: { name: 'node', version: '22' }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
    }
  }
  dependsOn: [deploymentContainer, storageDnsGroup]
}

output functionAppId string = functionApp.id
output hostName string = functionApp.properties.defaultHostName
output planId string = plan.id
output storageAccountId string = storage.id
output appInsightsId string = empty(appInsightsName) ? '' : appInsights.id
output systemPrincipalId string = usesUserAssigned ? '' : functionApp.identity.principalId
