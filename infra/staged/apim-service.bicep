// Stage 1: an optional NEW API Management service and its resource-log diagnostic setting, deployed
// only after explicit approval (main.bicep approveNewPublicApimBootstrap). A module, so the setting's
// scope is an unconditional resource: what-if refused the conditional `scope: apim!` form with
// DeploymentWhatIfResourceInvalidResponse (live, 2026-10-20).
targetScope = 'resourceGroup'

param name string
param location string
param tags object
@allowed(['BasicV2', 'StandardV2'])
param sku string
@minValue(1)
param units int
@minLength(3)
param publisherEmail string
@minLength(1)
param publisherName string
param workspaceId string
@description('Zone redundancy for a NEW Standard v2 or Premium v2 instance; it can be chosen only at creation. properties.zoneRedundant exists from API 2025-03-01-preview (docs/UNKNOWNS.md APIM-ZR-01), so only that path uses the preview API.')
param zoneRedundant bool = false

resource apimStandard 'Microsoft.ApiManagement/service@2024-05-01' = if (!zoneRedundant) {
  name: name
  location: location
  tags: tags
  sku: { name: sku, capacity: units }
  identity: { type: 'SystemAssigned' }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    publicNetworkAccess: 'Enabled'
  }
}

resource apimZoneRedundant 'Microsoft.ApiManagement/service@2025-03-01-preview' = if (zoneRedundant) {
  name: name
  location: location
  tags: tags
  sku: { name: sku, capacity: units }
  identity: { type: 'SystemAssigned' }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    publicNetworkAccess: 'Enabled'
    zoneRedundant: true
  }
}

// Unconditional reference for the diagnostic setting's scope (see the header note on what-if).
resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: name
}

resource apimDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'ccof-gateway-logs'
  scope: apim
  dependsOn: [apimStandard, apimZoneRedundant]
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      { category: 'GatewayLogs', enabled: true }
      { category: 'GatewayLlmLogs', enabled: true }
    ]
  }
}

output id string = apim.id
output name string = apim.name
output principalId string = zoneRedundant ? apimZoneRedundant!.identity.principalId : apimStandard!.identity.principalId
output gatewayUrl string = zoneRedundant ? apimZoneRedundant!.properties.gatewayUrl : apimStandard!.properties.gatewayUrl
