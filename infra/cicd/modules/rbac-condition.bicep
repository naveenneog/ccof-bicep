// ABAC condition for the deploy identity's Role Based Access Control Administrator assignments
// (https://learn.microsoft.com/en-us/azure/role-based-access-control/delegate-role-assignments-examples).
// It limits the role definitions (write and delete) and the principal TYPE (ServicePrincipal) of new assignments.
// PrincipalType ServicePrincipal covers managed identities AND ordinary application service principals: without
// principalIds, the deploy identity may grant the listed roles to any service principal in the tenant.
// With principalIds, writes and deletes are limited to exactly those object IDs.
@export()
func ccofRbacCondition(roleIds string[], principalIds string[]) string =>
  '((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/write\'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${join(roleIds, ', ')}} AND @Request[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {\'ServicePrincipal\'}${empty(principalIds) ? '' : ' AND @Request[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAnyValues:GuidEquals {${join(principalIds, ', ')}}'})) AND ((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/delete\'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${join(roleIds, ', ')}}${empty(principalIds) ? '' : ' AND @Resource[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAnyValues:GuidEquals {${join(principalIds, ', ')}}'}))'
