// Project admin API (docs/ADMIN-API.md): NEW resources only. Creates a Flex Consumption Function App
// with a system-assigned identity, its own storage account (identity-based, shared keys off), its own
// Log Analytics workspace and workspace-based Application Insights, and the two role assignments the
// app needs on ITS OWN storage and Insights. It does not reference, change or grant anything on the
// deployed APIM, resolver, sync or reconciler apps, or any existing network. The Cosmos endpoint and
// database are only written into the new app's settings; the Cosmos account is not touched.
//
// Networking is phase 2. Until then integrationSubnetId is empty, the app has no VNet integration and
// therefore cannot reach a Cosmos account whose public network access is disabled; its health check
// reports that as "blocked_by_network". The Cosmos data-role assignment is also phase 2 and is not here.

targetScope = 'resourceGroup'

param location string = resourceGroup().location
param tags object = {}

@description('Function App name (globally unique).')
param functionAppName string

@description('Storage account name, 3-24 lowercase letters and digits.')
param storageAccountName string

param planName string = '${functionAppName}-plan'
param appInsightsName string = '${functionAppName}-ai'
param logAnalyticsName string = '${functionAppName}-law'

@minValue(30)
param logRetentionDays int = 30

@description('Phase 2: VNet integration subnet delegated to Microsoft.App/environments. Empty: none.')
param integrationSubnetId string = ''

@description('Storage public network access. Enabled until the phase-2 private endpoint exists.')
@allowed(['Enabled', 'Disabled'])
param storagePublicNetworkAccess string = 'Enabled'

@description('Cosmos endpoint of the existing registry, read by the app; nothing is changed on the account.')
param cosmosEndpoint string

param cosmosDatabase string
param projectsContainer string = 'projects'

@description('Caller authentication settings. Empty values leave the API failing closed (503).')
param adminTenantId string = ''
param adminAudience string = ''
param adminScope string = ''
param adminAllowedClientIds string = ''
param adminReaderIds string = ''
param adminEditorIds string = ''

@minValue(1)
@maxValue(1000)
param maximumInstanceCount int = 40

var deploymentContainerName = 'app-package'
// Built-in role definition ids (Learn, "Azure built-in roles").
var storageBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var monitoringMetricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb'

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: logRetentionDays
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    DisableLocalAuth: true
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: storagePublicNetworkAccess
    networkAcls: { defaultAction: storagePublicNetworkAccess == 'Enabled' ? 'Allow' : 'Deny', bypass: 'AzureServices' }
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

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  tags: tags
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  properties: { reserved: true }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    virtualNetworkSubnetId: empty(integrationSubnetId) ? null : integrationSubnetId
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      scaleAndConcurrency: { maximumInstanceCount: maximumInstanceCount, instanceMemoryMB: 2048 }
      runtime: { name: 'node', version: '22' }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
    }
  }
  dependsOn: [deploymentContainer]
}

resource storageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, functionApp.id, storageBlobDataOwner)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwner)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource insightsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: appInsights
  name: guid(appInsights.id, functionApp.id, monitoringMetricsPublisher)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisher)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource settings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: {
    AzureWebJobsStorage__accountName: storage.name
    AzureWebJobsStorage__credential: 'managedidentity'
    APPLICATIONINSIGHTS_CONNECTION_STRING: appInsights.properties.ConnectionString
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'
    COSMOS_ENDPOINT: cosmosEndpoint
    COSMOS_DATABASE: cosmosDatabase
    ADMIN_PROJECTS_CONTAINER: projectsContainer
    ADMIN_TENANT_ID: adminTenantId
    ADMIN_AUDIENCE: adminAudience
    ADMIN_SCOPE: adminScope
    ADMIN_ALLOWED_CLIENT_IDS: adminAllowedClientIds
    ADMIN_READER_IDS: adminReaderIds
    ADMIN_EDITOR_IDS: adminEditorIds
  }
  dependsOn: [storageRole, insightsRole]
}

output functionAppName string = functionApp.name
output hostName string = functionApp.properties.defaultHostName
output principalId string = functionApp.identity.principalId
output storageAccountId string = storage.id
output appInsightsId string = appInsights.id
output logAnalyticsWorkspaceId string = workspace.id
