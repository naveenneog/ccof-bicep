// DR standby region (region B) service shells, ADR 0033 and docs/DR-ACTIVE-PASSIVE.md.
// Deployed into the resource group that holds the standby network and identities (DR P1/P2), in
// the standby location. Reuses the primary region's Stage 1 modules, so both regions run the same
// service shapes. Region B shares region A's Log Analytics workspace and Cosmos DB account; it has
// its own Function Apps, storage, Application Insights and API Management instance.
// No settings, grants, network paths or code here: infra/dr/Invoke-DrStandby.ps1 applies those in
// later phases with the primary region's stage templates. Timers stay off until promotion.
targetScope = 'resourceGroup'

@description('Standby location, for example centralus.')
param location string
param tags object = {}

@description('Name stem of the standby services, for example <primary stem>-b. Function Apps are <stem>-<app>.')
@minLength(3)
@maxLength(40)
param stem string

@description('Storage account stem, lowercase letters and digits, at most 21 characters: storage names are <storageStem>res/syn/rec/adm.')
@minLength(3)
@maxLength(21)
param storageStem string

@description('Resource ID of the primary region\'s Log Analytics workspace (shared by both regions).')
param workspaceId string

@description('Standby identity shells from DR P1: { sync: { id, principalId, clientId }, reconciler: { ... } }.')
param identities object

param includeAdmin bool = true

@allowed(['Disabled', 'Enabled'])
param functionsPublicNetworkAccess string = 'Disabled'

@allowed(['Disabled', 'Enabled'])
param storagePublicNetworkAccess string = 'Disabled'

@allowed(['Standard_LRS', 'Standard_ZRS'])
param storageSku string = 'Standard_LRS'

@minValue(40)
@maxValue(1000)
param maximumInstanceCount int = 40

@allowed([512, 2048, 4096])
param instanceMemoryMB int = 2048

@description('Standby API Management: { sku: StandardV2, units, publisherEmail, publisherName }.')
param apim object

var coreApps = [
  { key: 'resolver', storageSuffix: 'res', managedIdentity: '' }
  { key: 'sync', storageSuffix: 'syn', managedIdentity: 'sync' }
  { key: 'reconciler', storageSuffix: 'rec', managedIdentity: 'reconciler' }
]
var apps = concat(coreApps, includeAdmin ? [{ key: 'admin', storageSuffix: 'adm', managedIdentity: '' }] : [])

module functionServices '../staged/function-service.bicep' = [for app in apps: {
  name: 'dr-standby-${app.key}'
  params: {
    location: location
    tags: tags
    functionAppName: '${stem}-${app.key}'
    storageAccountName: '${storageStem}${app.storageSuffix}'
    workspaceId: workspaceId
    userAssignedIdentityId: empty(app.managedIdentity) ? '' : identities[app.managedIdentity].id
    userAssignedPrincipalId: empty(app.managedIdentity) ? '' : identities[app.managedIdentity].principalId
    userAssignedClientId: empty(app.managedIdentity) ? '' : identities[app.managedIdentity].clientId
    publicNetworkAccess: functionsPublicNetworkAccess
    storagePublicNetworkAccess: storagePublicNetworkAccess
    storageSku: storageSku
    maximumInstanceCount: maximumInstanceCount
    instanceMemoryMB: instanceMemoryMB
  }
}]

module apimService '../staged/apim-service.bicep' = {
  name: 'dr-standby-apim'
  params: {
    name: '${stem}-apim'
    location: location
    tags: tags
    sku: apim.?sku ?? 'StandardV2'
    units: apim.?units ?? 1
    publisherEmail: apim.publisherEmail
    publisherName: apim.publisherName
    workspaceId: workspaceId
  }
}

output functionApps array = [for (app, i) in apps: { key: app.key, service: functionServices[i].outputs.inventory }]
output apimId string = apimService.outputs.id
output apimName string = apimService.outputs.name
output apimPrincipalId string = apimService.outputs.principalId
output apimGatewayUrl string = apimService.outputs.gatewayUrl
// Same shape as Stage 1 `names.apps`, so the primary region's Stage 3, 5 and 6 templates take it.
output apps object = toObject(apps, a => a.key, a => {
  functionApp: '${stem}-${a.key}'
  plan: '${stem}-${a.key}-plan'
  storageAccount: '${storageStem}${a.storageSuffix}'
  deploymentContainer: 'app-package'
  appInsights: '${stem}-${a.key}-ai'
})
