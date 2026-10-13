// D1 prerequisites in one deployment, for a single operator (the proof of concept and a validation
// validation). It composes the per-resource modules of this folder in the workbook's order; teams
// that create resources separately use the modules, or the portal steps of
// docs/PREREQUISITES-WORKBOOK.md, instead. Either way, scripts/Record-Prerequisites.ps1 then reads
// the resources and writes the D1 checkpoint record.
//
// Parameters: `answers`, the core answers file (config/core.answers.schema.json) with the D0
// availability decisions inline; `scripts/Record-Prerequisites.ps1 -Action Plan` writes it.
// No role assignment and no application setting: D3 and D2 own those.

targetScope = 'resourceGroup'

@description('The core answers (D1 sections), with availability inline. Validated by Record-Prerequisites.ps1 -Action Plan before use.')
param answers object

var location = answers.target.location
var tags = answers.target.tags
var names = answers.names
var availability = answers.availability
var createNetwork = answers.network.mode == 'create'

// The always-ready group of each app: HTTP functions for the resolver (infra/poc/phase3),
// one timer function each for the sync (WP-SYNC) and the reconciler (WP-REC).
var apps = [
  { key: 'resolver', alwaysReadyName: 'http', identity: '' }
  { key: 'sync', alwaysReadyName: 'function:syncEntitlement', identity: 'sync' }
  { key: 'reconciler', alwaysReadyName: 'function:reconcileBudgets', identity: 'reconciler' }
]

module network 'network.bicep' = if (createNetwork) {
  name: '${names.deploymentPrefix}-d1-network'
  params: {
    location: location
    tags: tags
    vnetName: answers.network.create.vnetName
    addressSpace: answers.network.create.addressSpace
    apimNsgName: answers.network.create.apimNsgName
    subnets: answers.network.create.subnets
  }
}

var subnetIds = createNetwork ? {
  apim: network!.outputs.apimSubnetId
  privateEndpoints: network!.outputs.privateEndpointSubnetId
  functions: network!.outputs.functionsSubnetId
  cosmosDnsZone: network!.outputs.cosmosDnsZoneId
  blobDnsZone: network!.outputs.blobDnsZoneId
} : {
  apim: answers.network.existing.apimSubnetId
  privateEndpoints: answers.network.existing.privateEndpointSubnetId
  functions: answers.network.existing.functionsSubnetId
  cosmosDnsZone: answers.network.existing.privateDnsZoneIds.cosmos
  blobDnsZone: answers.network.existing.privateDnsZoneIds.blob
}

module workspace 'log-analytics.bicep' = {
  name: '${names.deploymentPrefix}-d1-workspace'
  params: {
    location: availability.telemetry.workspaceRegion
    tags: tags
    name: names.logAnalyticsWorkspace
    retentionInDays: availability.telemetry.retentionDays
  }
}

module identities 'identities.bicep' = {
  name: '${names.deploymentPrefix}-d1-identities'
  params: {
    location: location
    tags: tags
    names: names.identities
  }
}

module cosmos 'cosmos-account.bicep' = {
  name: '${names.deploymentPrefix}-d1-cosmos'
  params: {
    location: location
    tags: tags
    accountName: names.cosmosAccount
    capacityMode: availability.registry.capacityMode
    zoneRedundant: availability.registry.zoneRedundant
    privateEndpointName: names.cosmosPrivateEndpoint
    privateEndpointSubnetId: subnetIds.privateEndpoints
    cosmosPrivateDnsZoneId: subnetIds.cosmosDnsZone
  }
}

module functionApps 'function-app.bicep' = [for app in apps: {
  name: '${names.deploymentPrefix}-d1-app-${app.key}'
  params: {
    location: location
    tags: tags
    functionAppName: names.apps[app.key].functionApp
    planName: names.apps[app.key].plan
    storageAccountName: names.apps[app.key].storageAccount
    storageSku: availability.storage.sku
    deploymentContainerName: names.apps[app.key].deploymentContainer
    storagePrivateEndpointName: names.apps[app.key].storagePrivateEndpoint
    privateEndpointSubnetId: subnetIds.privateEndpoints
    blobPrivateDnsZoneId: subnetIds.blobDnsZone
    integrationSubnetId: subnetIds.functions
    appInsightsName: names.apps[app.key].appInsights ?? ''
    logAnalyticsWorkspaceId: workspace.outputs.id
    userAssignedIdentityId: empty(app.identity) ? '' : (app.identity == 'sync' ? identities.outputs.syncId : identities.outputs.reconcilerId)
    alwaysReadyName: app.alwaysReadyName
    alwaysReadyInstanceCount: availability.functions[app.key].alwaysReady
    maximumInstanceCount: availability.functions[app.key].maximumInstanceCount
    instanceMemoryMB: availability.functions[app.key].instanceMemoryMB
    zoneRedundant: availability.functions[app.key].zoneRedundant
  }
}]

module apim 'apim.bicep' = {
  name: '${names.deploymentPrefix}-d1-apim'
  params: {
    location: location
    tags: tags
    name: names.apim
    sku: availability.apim.sku
    units: availability.apim.units
    zones: availability.apim.zones
    publisherEmail: answers.apim.publisherEmail
    publisherName: answers.apim.publisherName
    subnetId: subnetIds.apim
  }
}

output apimId string = apim.outputs.id
output cosmosId string = cosmos.outputs.id
output workspaceId string = workspace.outputs.id
output functionAppIds array = [for (app, i) in apps: functionApps[i].outputs.functionAppId]
