// Quick-start (ADR-0024, Proposed): Cognitive Services User for the APIM's system-assigned identity
// on one Foundry account, in the account's own subscription and resource group (the caller sets
// `scope: resourceGroup(subscriptionId, resourceGroup)`; Learn, "Set scope for extension resources
// in Bicep" and "Deploy to resource group" cross-subscription modules, retrieved 2026-10-13).
// infra/gateway/assignments.json (gw-apim-foundry-user) is D3's data for the same grant.
// ARM refuses a second assignment of the same role to the same principal at the same scope under
// another name (RoleAssignmentExists), so the caller skips this module when D3 already made it.

targetScope = 'resourceGroup'

param accountName string
param principalId string

@description('The APIM resource id: a name seed known before the deployment starts, so what-if can resolve the assignment.')
param apimResourceId string

// Cognitive Services User (infra/gateway/assignments.json roleDefinitionId).
var roleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: accountName
}

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, apimResourceId, roleId)
  scope: account
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
  }
}

output assignmentId string = assignment.id
