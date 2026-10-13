// D1 (docs/PILOT.md C-9): the sync app's prerequisite resources, optional Bicep
// for the infrastructure teams' workbook. Resource creation only:
// - no role assignment: D3 applies infra/sync/sync.assignments.json;
// - no Cosmos container or role: D2 creates `syncLease`, D3 the custom role;
// - no app settings: D2 writes them (docs/SYNC.md, "Settings"). Without them
//   the timer is not even registered (CCOF_APP_ROLE), so nothing runs.
//
// A Flex Consumption app separate from the resolver, running as the
// user-assigned identity that will hold the Graph permission, VNet-integrated
// so it reaches the private Cosmos endpoint. Every value is a parameter with
// no default. The outputs are the ids D1 records.

targetScope = 'resourceGroup'

@description('Region of the app; must equal the VNet region.')
param location string

@description('Function App name.')
param functionAppName string

@description('Flex Consumption plan name.')
param planName string

@description('Storage account for the app host and its deployment package (3-24 lowercase letters and digits).')
param storageAccountName string

@description('Storage redundancy, an availability decision (D0).')
@allowed(['Standard_LRS', 'Standard_ZRS'])
param storageSku string

@description('Blob container for the deployment package.')
param deploymentContainerName string

@description('Private endpoint name for the storage account blob service.')
param storagePrivateEndpointName string

@description('Application Insights component name.')
param appInsightsName string

@description('Resource id of the Log Analytics workspace Application Insights writes to.')
param logAnalyticsWorkspaceId string

@description('Name of the existing user-assigned identity the app runs as.')
param identityName string

@description('Resource id of the VNet integration subnet (delegated to Microsoft.App/environments).')
param integrationSubnetId string

@description('Resource id of the subnet for private endpoints.')
param privateEndpointSubnetId string

@description('Resource id of the privatelink.blob.core.windows.net private DNS zone linked to the VNet.')
param blobPrivateDnsZoneId string

@description('Always-ready instances for the timer function. 0 = pay per use only. Availability decision (D0).')
@minValue(0)
param alwaysReadyInstanceCount int

@description('Flex Consumption maximum instance count. Availability decision (D0).')
param maximumInstanceCount int

@description('Flex Consumption instance memory in MB. Availability decision (D0).')
@allowed([512, 2048, 4096])
param instanceMemoryMB int

@description('Zone redundancy of the Flex plan, where the region supports it. Availability decision (D0).')
param zoneRedundant bool

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
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

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
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
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  properties: {
    reserved: true
    zoneRedundant: zoneRedundant
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
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
          authentication: { type: 'UserAssignedIdentity', userAssignedIdentityResourceId: identity.id }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: maximumInstanceCount
        instanceMemoryMB: instanceMemoryMB
        alwaysReady: alwaysReadyInstanceCount > 0 ? [{ name: 'function:syncEntitlement', instanceCount: alwaysReadyInstanceCount }] : []
      }
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
output appInsightsId string = appInsights.id
output identityId string = identity.id
output principalId string = identity.properties.principalId
output clientId string = identity.properties.clientId
