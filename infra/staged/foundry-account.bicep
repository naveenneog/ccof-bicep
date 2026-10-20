// Stage 1 (optional): a NEW Microsoft Foundry (AIServices) account with its Claude model deployments.
// Keyless (disableLocalAuth), and public network access as approved (Disabled for a private backend:
// Stage 2 then creates its private endpoint and DNS). No role assignment here: Stage 4 grants the APIM
// identity Cognitive Services User. Claude deployments are Marketplace-backed models; the subscription
// must be eligible and the offer terms accepted, or ARM refuses the deployment by name.
targetScope = 'resourceGroup'

param name string
param location string
param tags object

@allowed(['Disabled', 'Enabled'])
param publicNetworkAccess string = 'Disabled'

@description('Deployments: name, model, version, sku (GlobalStandard or DataZoneStandard), capacity.')
param deployments array

@description('Anthropic attestation sent with every Claude deployment: { organizationName, countryCode, industry }. The resource provider uses it to accept the Marketplace offer for Claude on the subscription; it must describe the real legal entity. No default.')
param modelProviderData object

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: name
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: name
    disableLocalAuth: true
    publicNetworkAccess: publicNetworkAccess
    networkAcls: { defaultAction: publicNetworkAccess == 'Disabled' ? 'Deny' : 'Allow', ipRules: [] }
    allowProjectManagement: true
  }
}

// One deployment at a time: the account accepts a single concurrent deployment write.
// 2025-10-01-preview: earlier API versions drop modelProviderData and fail with InvalidModelProviderData
// (live, 2026-10-20). The Marketplace purchase happens here; internal/sandbox subscriptions are refused.
@batchSize(1)
resource modelDeployments 'Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview' = [for d in deployments: {
  parent: account
  name: d.name
  sku: { name: d.?sku ?? 'GlobalStandard', capacity: d.?capacity ?? 10 }
  properties: {
    model: { format: 'Anthropic', name: d.model, version: d.version }
    // Required by the resource provider for Anthropic models (InvalidModelProviderData otherwise); missing from the Bicep types.
    #disable-next-line BCP037
    modelProviderData: modelProviderData
  }
}]

output id string = account.id
output name string = account.name
output anthropicUrl string = 'https://${name}.services.ai.azure.com/anthropic'
output deploymentNames array = [for (d, i) in deployments: modelDeployments[i].name]
