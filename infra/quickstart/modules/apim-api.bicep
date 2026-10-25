// Quick-start (ADR-0024, Proposed): the gateway's API in an EXISTING API Management instance, as
// D2's apim step makes it (scripts/Core.D2Apim.psm1, Invoke-CoreD2Apim): the API, its one
// operation, one backend entity per Foundry backend, and the API policy. The service resource is
// only referenced (`existing`): this module never redeploys or changes it, so the system-assigned
// identity stays (`az apim update` would strip it; Core.D2Apim.psm1 header).
// Managed-identity backends need no named value: the rendered policy takes a token for the
// descriptor's resource (https://cognitiveservices.azure.com) with authentication-managed-identity
// (infra/gateway/assignments.json, gw-apim-foundry-user "why"); render.ts allows no named value
// other than second-tenant backend secrets (infra/gateway/render.ts header).

targetScope = 'resourceGroup'

param apimName string
param apiId string
param apiPath string
param apiDisplayName string

@description('[{ id, url }] for each Foundry backend; url ends with /anthropic.')
param backends array

@description('The policy rendered by infra/gateway/render.ts, or empty: then the API answers 503 until it is rendered (Core.D2Apim.psm1 InitialPolicy).')
param policyXml string

@description('The own-usage policy rendered by infra/gateway/render.ts (<apiId>.usage.policy.xml), or empty: then no usage API is created (docs/USAGE-SELF-SERVICE.md).')
param usagePolicyXml string = ''
@description('Path of the separate usage API; GET /<path>/me/usage.')
param usageApiPath string = 'ccof-usage'

// scripts/Core.D2Apim.psm1 $script:InitialPolicy: the gateway never serves unchecked.
var initialPolicy = '<policies><inbound><return-response><set-status code="503" reason="Service Unavailable" /><set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header><set-body>{"type":"error","error":{"type":"api_error","message":"The gateway is not configured yet."}}</set-body></return-response></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: apiId
  properties: {
    displayName: apiDisplayName
    path: apiPath
    protocols: ['https']
    subscriptionRequired: false
  }
}

resource operation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'create-message'
  properties: {
    displayName: 'Create message'
    method: 'POST'
    urlTemplate: '/v1/messages'
    templateParameters: []
    responses: []
  }
}

resource apimBackends 'Microsoft.ApiManagement/service/backends@2024-05-01' = [for b in backends: {
  parent: apim
  name: b.id
  properties: {
    url: b.url
    protocol: 'http'
    tls: { validateCertificateChain: true, validateCertificateName: true }
  }
}]

resource policy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: empty(policyXml) ? initialPolicy : policyXml
  }
  dependsOn: [operation, apimBackends]
}

// A separate API, so the Claude Messages policy never runs for usage requests and model requests
// never reach the usage policy. Same Entra token, same subscriptionRequired: false.
resource usageApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = if (!empty(usagePolicyXml)) {
  parent: apim
  name: '${apiId}-usage'
  properties: {
    displayName: '${apiDisplayName} usage'
    path: usageApiPath
    protocols: ['https']
    subscriptionRequired: false
  }
}

resource usageOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = if (!empty(usagePolicyXml)) {
  parent: usageApi
  name: 'get-my-usage'
  properties: {
    displayName: 'Get my usage'
    method: 'GET'
    urlTemplate: '/me/usage'
    templateParameters: []
    responses: []
  }
}

resource usagePolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = if (!empty(usagePolicyXml)) {
  parent: usageApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: usagePolicyXml
  }
  dependsOn: [usageOperation]
}

output apiResourceId string = api.id
output usageUrl string = empty(usagePolicyXml) ? '' : '${apim.properties.gatewayUrl}/${usageApiPath}/me/usage'
output gatewayUrl string = apim.properties.gatewayUrl
output principalId string = apim.identity.principalId
