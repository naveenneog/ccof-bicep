// Explicit one-time permission-owner setup; not deployed by default or by Stage 3.
targetScope = 'resourceGroup'
param apimName string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}
resource role 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(apim.id, 'ccof-admin-routing-publisher')
  properties: {
    roleName: 'CCOF admin routing publisher ${uniqueString(apim.id)}'
    description: 'Read APIM and effective permissions; read and publish backend members and pools only.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [{
      actions: [
        'Microsoft.ApiManagement/service/read'
        'Microsoft.ApiManagement/service/backends/read'
        'Microsoft.ApiManagement/service/backends/write'
        'Microsoft.Authorization/permissions/read'
      ]
      notActions: []
      dataActions: []
      notDataActions: []
    }]
  }
}
output roleDefinitionId string = role.id
