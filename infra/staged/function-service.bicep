// Stage 1 service shapes extracted from infra/prereqs/function-app.bicep.
// Intentionally no networking, settings, runtime grants or code package.
targetScope = 'resourceGroup'

param location string
param tags object
param functionAppName string
param storageAccountName string
param workspaceId string
param userAssignedIdentityId string = ''
param userAssignedPrincipalId string = ''
param userAssignedClientId string = ''

@allowed(['Disabled', 'Enabled'])
param publicNetworkAccess string = 'Disabled'

@allowed(['Disabled', 'Enabled'])
param storagePublicNetworkAccess string = 'Disabled'

@allowed(['Standard_LRS', 'Standard_ZRS'])
param storageSku string = 'Standard_LRS'

@minValue(40)
@maxValue(1000)
param maximumInstanceCount int = 40

@allowed([512, 2048, 4096])
param instanceMemoryMB int = 2048

var usesUserAssigned = !empty(userAssignedIdentityId)
var deploymentContainerName = 'app-package'

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
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: storagePublicNetworkAccess
    networkAcls: { defaultAction: 'Deny', bypass: 'None' }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: storage
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: deploymentContainerName
  properties: { publicAccess: 'None' }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${functionAppName}-ai'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspaceId
    DisableLocalAuth: true
  }
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: '${functionAppName}-plan'
  location: location
  tags: tags
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  properties: { reserved: true }
}

resource app 'Microsoft.Web/sites@2024-04-01' = {
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
    publicNetworkAccess: publicNetworkAccess
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
      }
      runtime: { name: 'node', version: '22' }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
    }
  }
  dependsOn: [deploymentContainer]
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'ccof-function-logs'
  scope: app
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ category: 'FunctionAppLogs', enabled: true }]
  }
}

output inventory object = {
  id: app.id
  name: app.name
  hostName: app.properties.defaultHostName
  principalId: usesUserAssigned ? userAssignedPrincipalId : app.identity.principalId
  clientId: usesUserAssigned ? userAssignedClientId : ''
  identityResourceId: userAssignedIdentityId
  planId: plan.id
  storageId: storage.id
  storageAccount: storage.name
  deploymentContainer: deploymentContainer.name
  appInsightsId: insights.id
  diagnosticSettingId: diagnostics.id
}
