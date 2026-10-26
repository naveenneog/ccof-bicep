// Configuration and grants only. Every referenced resource is already provisioned privately.
// Reuse quickstart configuration modules; never redeploy its network or workbook shell.
targetScope = 'resourceGroup'

param tenantId string
param location string
param names object
param apim object
param registrations object
param backends array
param cosmos object
param resolver object
param sync object
param reconciler object
param budgetState object
param groups array
param gateway object
param rateCard object
param workbook object
param enableAlerts bool = false
param syncTimerEnabled bool = false
@minLength(1)
param policyXml string
@minLength(1)
param apimIdentityAppId string
// Empty means leave the existing workbook entirely untouched, not create an empty shell.
param workbookContent object = {}
param workbookContentTags object = {}

var prefix = names.deploymentPrefix
var appKeys = ['resolver', 'sync', 'reconciler']
resource apimService 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apim.name
  scope: resourceGroup(apim.subscriptionId, apim.resourceGroup)
}
resource registry 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: names.cosmosAccount
}
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: names.logAnalyticsWorkspace
}
resource syncIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: names.identities.sync
}
resource reconcilerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: names.identities.reconciler
}
resource apps 'Microsoft.Web/sites@2024-04-01' existing = [for app in appKeys: {
  name: names.apps[app].functionApp
}]
resource resolverInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: names.apps.resolver.appInsights
}
resource syncInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: names.apps.sync.appInsights
}
resource reconcilerInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: names.apps.reconciler.appInsights
}
var principals = {
  resolver: apps[0].identity.principalId
  sync: syncIdentity.properties.principalId
  reconciler: reconcilerIdentity.properties.principalId
  runner: ''
}
module schema '../quickstart/modules/cosmos-data.bicep' = {
  name: '${prefix}-manual-schema'
  params: {
    accountName: names.cosmosAccount
    databaseName: names.cosmosDatabase
    capacityMode: cosmos.capacityMode
    autoscaleMaxThroughput: cosmos.autoscaleMaxThroughput
    roleNames: names.cosmosRoles
    principals: principals
    syncMode: sync.mode
  }
}
module workbookFull '../workbook/main.bicep' = if (!empty(workbookContent)) {
  name: '${prefix}-manual-workbook'
  params: {
    workbookResourceName: workbook.resourceName
    workbookDisplayName: workbook.displayName
    location: location
    workspaceResourceId: workspace.id
    workbookContent: workbookContent
    contentTags: workbookContentTags
  }
}
module roles '../quickstart/modules/rbac.bicep' = {
  name: '${prefix}-manual-roles'
  params: {
    names: names
    principals: principals
    workbookResourceName: workbook.resourceName
    // Reader grants require a content deployment. Omitting it does not delete previous grants.
    workbookReaderPrincipalIds: empty(workbookContent) ? [] : workbook.readerPrincipalIds
  }
  dependsOn: [workbookFull]
}
module api '../quickstart/modules/apim-api.bicep' = {
  name: '${prefix}-manual-api'
  scope: resourceGroup(apim.subscriptionId, apim.resourceGroup)
  params: {
    apimName: apim.name
    apiId: apim.apiId
    apiPath: apim.apiPath
    apiDisplayName: apim.apiDisplayName
    backends: [for b in backends: { id: b.id, url: b.url }]
    policyXml: policyXml
  }
}
module foundryRoles '../quickstart/modules/foundry-role.bicep' = [for b in backends: if (b.assignCognitiveServicesUser) {
  name: '${prefix}-manual-foundry-${b.id}'
  scope: resourceGroup(b.subscriptionId, b.resourceGroup)
  params: {
    accountName: b.accountName
    principalId: apimService.identity.principalId
    apimResourceId: apimService.id
  }
}]
module settings '../quickstart/modules/app-settings.bicep' = {
  name: '${prefix}-manual-settings'
  params: {
    names: names
    tenantId: tenantId
    cosmosEndpoint: registry.properties.documentEndpoint
    databaseName: names.cosmosDatabase
    syncClientId: syncIdentity.properties.clientId
    reconcilerClientId: reconcilerIdentity.properties.clientId
    resolverAppInsightsConnection: resolverInsights.properties.ConnectionString
    syncAppInsightsConnection: syncInsights.properties.ConnectionString
    reconcilerAppInsightsConnection: reconcilerInsights.properties.ConnectionString
    workspaceCustomerId: workspace.properties.customerId
    apimId: apimService.id
    resolver: resolver
    sync: sync
    reconciler: reconciler
    budgetState: budgetState
    syncTimerEnabled: syncTimerEnabled
    resolverApiAppId: registrations.resolverApi.appId
    apimIdentityAppId: apimIdentityAppId
    apimPrincipalId: apimService.identity.principalId
  }
  dependsOn: [schema, roles]
}
module telemetry '../poc/phase4-telemetry.bicep' = {
  name: '${prefix}-manual-telemetry'
  params: {
    workspaceResourceId: workspace.id
    apimResourceId: apimService.id
    apiName: apim.apiId
    location: location
    functionAppResourceIds: [for (app, i) in appKeys: apps[i].id]
    enableAlerts: enableAlerts
  }
  dependsOn: [api]
}

output gatewayUrl string = '${api.outputs.gatewayUrl}/${apim.apiPath}'
output resolverHostName string = apps[0].properties.defaultHostName
output functionAppIds object = { resolver: apps[0].id, sync: apps[1].id, reconciler: apps[2].id }
output syncPrincipalId string = syncIdentity.properties.principalId
output runnerPrincipalId string = ''
output runnerVmId string = ''
output cosmosEndpoint string = registry.properties.documentEndpoint
output cosmosAccountId string = registry.id
output workspaceId string = workspace.id
output apimPrincipalId string = apimService.identity.principalId
output projectIds array = union(map(groups, g => g.projectId), [])
output registrationIds object = registrations
output rateCardPath string = rateCard.path
output gatewayConfigurationId string = gateway.configurationId
