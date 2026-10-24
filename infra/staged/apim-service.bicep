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

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
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

resource apimDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'ccof-gateway-logs'
  scope: apim
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
output principalId string = apim.identity.principalId
output gatewayUrl string = apim.properties.gatewayUrl
