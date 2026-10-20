// NEW service resources only. Do not redeploy over an existing environment:
// ARM is upsert, not a create-only API. Follow the empty-RG preflight in the runbook.
targetScope = 'resourceGroup'

@description('Approved lowercase alphanumeric prefix for NEW resources; never reuse existing production names.')
@minLength(3)
@maxLength(8)
param prefix string

param location string = resourceGroup().location
param tags object = {}

@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@allowed(['serverless', 'provisioned'])
param cosmosCapacityMode string = 'serverless'

@description('Service PNA defaults private. Enabling PNA alone does not configure storage firewall exceptions.')
@allowed(['Disabled', 'Enabled'])
param cosmosPublicNetworkAccess string = 'Disabled'

@allowed(['Disabled', 'Enabled'])
param storagePublicNetworkAccess string = 'Disabled'

@allowed(['Disabled', 'Enabled'])
param functionsPublicNetworkAccess string = 'Disabled'

@allowed(['Standard_LRS', 'Standard_ZRS'])
param storageSku string = 'Standard_LRS'

@description('Include the separate new admin service. No Entra application or data grants are created.')
param includeAdmin bool = true

@description('Explicit approval for a NEW public APIM bootstrap only. False defers APIM: Azure cannot create it with PNA Disabled before a private endpoint exists.')
param approveNewPublicApimBootstrap bool = false

@description('Required approved publisher contact if APIM bootstrap is enabled. Empty is a deliberate undeployed placeholder, not a working contact.')
param apimPublisherEmail string = ''

param apimPublisherName string = ''

@description('StandardV2 supports outbound VNet integration (private Foundry). BasicV2 is public-only; use it only where every backend is reachable without a VNet.')
@allowed(['BasicV2', 'StandardV2'])
param apimSku string = 'StandardV2'

@minValue(1)
param apimUnits int = 1

@minValue(40)
@maxValue(1000)
param maximumInstanceCount int = 40

@allowed([512, 2048, 4096])
param instanceMemoryMB int = 2048

var suffix = uniqueString(resourceGroup().id, prefix)
var stem = '${prefix}-${suffix}'
var storageStem = '${prefix}${suffix}'
var coreApps = [
  { key: 'resolver', storageSuffix: 'res', managedIdentity: '' }
  { key: 'sync', storageSuffix: 'syn', managedIdentity: 'sync' }
  { key: 'reconciler', storageSuffix: 'rec', managedIdentity: 'reconciler' }
]
var apps = concat(coreApps, includeAdmin ? [{ key: 'admin', storageSuffix: 'adm', managedIdentity: '' }] : [])

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${stem}-law'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionInDays
  }
}

resource syncIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${stem}-sync-id'
  location: location
  tags: tags
}

resource reconcilerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${stem}-reconciler-id'
  location: location
  tags: tags
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: '${stem}-cosmos'
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [{ locationName: location, failoverPriority: 0, isZoneRedundant: false }]
    capabilities: cosmosCapacityMode == 'serverless' ? [{ name: 'EnableServerless' }] : []
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    disableLocalAuth: true
    publicNetworkAccess: cosmosPublicNetworkAccess
    isVirtualNetworkFilterEnabled: true
    ipRules: []
    enableMultipleWriteLocations: false
    enableAutomaticFailover: false
  }
}

module functionServices 'function-service.bicep' = [for app in apps: {
  name: 'stage1-${app.key}'
  params: {
    location: location
    tags: tags
    functionAppName: '${stem}-${app.key}'
    storageAccountName: '${storageStem}${app.storageSuffix}'
    workspaceId: workspace.id
    userAssignedIdentityId: empty(app.managedIdentity) ? '' : (app.managedIdentity == 'sync' ? syncIdentity.id : reconcilerIdentity.id)
    userAssignedPrincipalId: empty(app.managedIdentity) ? '' : (app.managedIdentity == 'sync' ? syncIdentity.properties.principalId : reconcilerIdentity.properties.principalId)
    userAssignedClientId: empty(app.managedIdentity) ? '' : (app.managedIdentity == 'sync' ? syncIdentity.properties.clientId : reconcilerIdentity.properties.clientId)
    publicNetworkAccess: functionsPublicNetworkAccess
    storagePublicNetworkAccess: storagePublicNetworkAccess
    storageSku: storageSku
    maximumInstanceCount: maximumInstanceCount
    instanceMemoryMB: instanceMemoryMB
  }
}]

// APIM requires an approved inbound endpoint before PNA can be disabled.
// This opt-in creates a NEW public shell, never modifies an existing private gateway.
module apimService 'apim-service.bicep' = if (approveNewPublicApimBootstrap) {
  name: 'stage1-apim'
  params: {
    name: '${stem}-apim'
    location: location
    tags: tags
    sku: apimSku
    units: apimUnits
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    workspaceId: workspace.id
  }
}

output workspaceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output cosmosAccountId string = cosmos.id
output cosmosEndpoint string = cosmos.properties.documentEndpoint
output functionApps array = [for (app, i) in apps: { key: app.key, service: functionServices[i].outputs.inventory }]
output syncIdentityId string = syncIdentity.id
output reconcilerIdentityId string = reconcilerIdentity.id
output apimId string = approveNewPublicApimBootstrap ? apimService!.outputs.id : ''
output apimPrincipalId string = approveNewPublicApimBootstrap ? apimService!.outputs.principalId : ''
output apimGatewayUrl string = approveNewPublicApimBootstrap ? apimService!.outputs.gatewayUrl : ''
output apimStatus string = approveNewPublicApimBootstrap ? 'new-public-shell-needs-approved-private-cutover' : 'deferred-no-public-bootstrap-approved'
// The resource names later stages read (quickstart `names` shape, infra/quickstart/main.bicepparam).
// Stage 3 adds cosmosDatabase; Stage 4 adds cosmosRoles. Inventory only: no setting or grant.
output names object = {
  deploymentPrefix: prefix
  subscriptionId: subscription().subscriptionId
  resourceGroup: resourceGroup().name
  logAnalyticsWorkspace: workspace.name
  cosmosAccount: cosmos.name
  identities: { sync: syncIdentity.name, reconciler: reconcilerIdentity.name }
  apps: toObject(apps, a => a.key, a => {
    functionApp: '${stem}-${a.key}'
    plan: '${stem}-${a.key}-plan'
    storageAccount: '${storageStem}${a.storageSuffix}'
    deploymentContainer: 'app-package'
    appInsights: '${stem}-${a.key}-ai'
  })
}
output apimName string = approveNewPublicApimBootstrap ? apimService!.outputs.name : ''
output completionGate string = 'Services only: separate-team grants, schema/settings/code, and customer network required before runtime acceptance.'
