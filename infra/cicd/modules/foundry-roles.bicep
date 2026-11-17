// Roles of the CCOF runner identities on one Foundry account (infra/cicd/roles.bicep). The deploy identity gets
// Role Based Access Control Administrator on the account, conditioned to Cognitive Services User for service
// principals: Stage 3 grants that role to the APIM identity (infra/quickstart/modules/foundry-role.bicep).
targetScope = 'resourceGroup'

param accountName string
param previewPrincipalId string
param previewRoleIds array
param deployPrincipalId string
param deployRoleIds array = []
param conditionedRbacAdministrator string
param assignableRoleIds array

var guids = join(assignableRoleIds, ', ')
var condition = '((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/write\'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${guids}} AND @Request[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {\'ServicePrincipal\'})) AND ((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/delete\'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${guids}}))'
var plain = concat(map(previewRoleIds, r => { principalId: previewPrincipalId, roleId: r }), map(deployRoleIds, r => { principalId: deployPrincipalId, roleId: r }))

resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: accountName
}

resource plainAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for a in plain: {
  name: guid(account.id, a.principalId, a.roleId)
  scope: account
  properties: {
    principalId: a.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', a.roleId)
  }
}]

resource rbacAdministrator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, deployPrincipalId, conditionedRbacAdministrator)
  scope: account
  properties: {
    principalId: deployPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', conditionedRbacAdministrator)
    conditionVersion: '2.0'
    condition: condition
    description: 'CCOF deploy identity: may assign only Cognitive Services User, to managed identities.'
  }
}
