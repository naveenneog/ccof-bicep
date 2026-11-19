// One-time security setup deploys admin-routing-role.bicep first. Stage 3 only assigns it.
targetScope = 'resourceGroup'
param apimName string
param principalId string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}
resource role 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: guid(apim.id, 'ccof-admin-routing-publisher')
}
resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(apim.id, principalId, role.id)
  scope: apim
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: role.id
  }
}
output assignmentId string = assignment.id
output details object = { principalId: principalId, roleDefinitionId: role.id, scope: apim.id }
