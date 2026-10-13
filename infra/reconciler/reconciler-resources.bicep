// The CCU budget reconciler's resources (docs/PILOT.md C-7; C-9 stage D1,
// optional Bicep for the prerequisites workbook). A Flex Consumption app,
// separate from the resolver and the sync, running as its own user-assigned
// identity, VNet-integrated so it reaches the private Cosmos endpoint. The
// pattern of infra/sync/sync-function.bicep (WP-SYNC), split per C-9:
//   - this file creates resources only: no role assignment (D3 applies
//     infra/reconciler/reconciler-permissions.json) and no app setting (D2
//     writes them, infra/reconciler/Deploy-Reconciler.ps1 -Action Settings);
//   - no Application Insights: the app's logs reach the workspace through a
//     FunctionAppLogs diagnostic setting (WP-TEL, D2).
//
// Every value is a parameter without a default, from the administrator's
// answers file (infra/reconciler/reconciler.answers.pilot.json).
//
// New resources: user-assigned identity, storage account + deployment
// container + blob private endpoint (DNS record in the existing
// privatelink.blob zone), Flex plan, Function App. Existing, referenced
// only: the subnets and the DNS zone.

targetScope = 'resourceGroup'

// Ownership marker: Deploy-Reconciler.ps1 -Action Rollback deletes only resources that carry it.
var ownerTags = { 'ccof-package': 'WP-REC' }

@description('Region of the app; must equal the VNet region.')
param location string

@description('Function App name (pilot: sample-pilot-rec-func).')
param functionAppName string

@description('Flex Consumption plan name.')
param planName string

@description('New storage account for the app host and its deployment package (3-24 lowercase letters and digits).')
param storageAccountName string

@description('Storage redundancy, an availability decision: Standard_LRS or Standard_ZRS.')
@allowed(['Standard_LRS', 'Standard_ZRS'])
param storageSku string

@description('Blob container for the deployment package.')
param deploymentContainerName string

@description('Private endpoint name for the storage account blob service.')
param storagePrivateEndpointName string

@description('Name of the new user-assigned identity the app runs as (pilot: sample-pilot-rec-id).')
param identityName string

@description('Resource id of the existing VNet integration subnet (delegated to Microsoft.App/environments).')
param integrationSubnetId string

@description('Resource id of the existing subnet for private endpoints.')
param privateEndpointSubnetId string

@description('Resource id of the existing privatelink.blob.core.windows.net private DNS zone linked to the VNet.')
param blobPrivateDnsZoneId string

@description('Always-ready instances for the timer function. 0 = pay per use only. Availability decision.')
@minValue(0)
param alwaysReadyInstanceCount int

@description('Flex Consumption maximum instance count. Availability decision.')
param maximumInstanceCount int

@description('Flex Consumption instance memory in MB. Availability decision.')
@allowed([512, 2048, 4096])
param instanceMemoryMB int

@description('Zone redundancy of the Flex plan, where the region supports it. Availability decision.')
param zoneRedundant bool

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: ownerTags
}

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  tags: ownerTags
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
  tags: ownerTags
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

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  tags: ownerTags
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  properties: {
    reserved: true
    zoneRedundant: zoneRedundant
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  tags: ownerTags
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
        alwaysReady: alwaysReadyInstanceCount > 0 ? [{ name: 'function:reconcileBudgets', instanceCount: alwaysReadyInstanceCount }] : []
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

// The D1 record keys of docs/DEPLOYMENT-STAGES.md (apps.reconciler.*).
output functionAppId string = functionApp.id
output functionAppName string = functionApp.name
output hostName string = functionApp.properties.defaultHostName
output planId string = plan.id
output identityId string = identity.id
output principalId string = identity.properties.principalId
output clientId string = identity.properties.clientId
output storageAccountId string = storage.id
