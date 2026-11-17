// Role assignments for one principal on the current resource group (infra/cicd/roles.bicep).
// conditionedRbacAdministrator, when set, is assigned with an ABAC condition: the principal may only create or
// delete assignments of assignableRoleIds, of principal type ServicePrincipal (managed identities and also ordinary
// application service principals), and, when assignablePrincipalIds is set, only for those object IDs.
targetScope = 'resourceGroup'

import { ccofRbacCondition } from 'rbac-condition.bicep'

param principalId string
param roleIds array = []
param conditionedRbacAdministrator string = ''
param assignableRoleIds string[] = []
@description('Object IDs the conditioned administrator may assign roles to. Empty: any service principal (see rbac-condition.bicep).')
param assignablePrincipalIds string[] = []

var condition = ccofRbacCondition(assignableRoleIds, assignablePrincipalIds)

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
    description: 'CCOF deploy identity: may assign only the roles Stage 3 grants, to service principals.'
  }
}
