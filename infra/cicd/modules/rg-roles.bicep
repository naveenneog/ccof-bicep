// Role assignments for one principal on the current resource group (infra/cicd/roles.bicep).
// conditionedRbacAdministrator, when set, is assigned with an ABAC condition: the principal may only create or
// delete assignments of assignableRoleIds, and only for service principals (managed identities).
targetScope = 'resourceGroup'

param principalId string
param roleIds array = []
param conditionedRbacAdministrator string = ''
param assignableRoleIds array = []

var guids = join(assignableRoleIds, ', ')
var condition = '((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/write\'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${guids}} AND @Request[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {\'ServicePrincipal\'})) AND ((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/delete\'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${guids}}))'

resource plain 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for r in roleIds: {
  name: guid(resourceGroup().id, principalId, r)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', r)
  }
}]

resource conditioned 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(conditionedRbacAdministrator)) {
  name: guid(resourceGroup().id, principalId, conditionedRbacAdministrator)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', conditionedRbacAdministrator)
    conditionVersion: '2.0'
    condition: condition
    description: 'CCOF deploy identity: may assign only the roles Stage 3 grants, to managed identities.'
  }
}
