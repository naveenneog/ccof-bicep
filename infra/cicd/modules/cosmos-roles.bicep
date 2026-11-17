// Cosmos DB data-plane role assignments for the CCOF runner identities, scoped to one database
// (infra/cicd/roles.bicep). Built-in role definitions: 00000000-0000-0000-0000-000000000001 Data Reader,
// 00000000-0000-0000-0000-000000000002 Data Contributor.
targetScope = 'resourceGroup'

param accountName string
param databaseName string

@description('[{ principalId, roleDefinitionId }] with built-in Cosmos DB SQL role definition IDs.')
param assignments array

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: accountName
}

resource assignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = [for a in assignments: {
  parent: account
  name: guid(account.id, a.principalId, a.roleDefinitionId, databaseName)
  properties: {
    principalId: a.principalId
    roleDefinitionId: '${account.id}/sqlRoleDefinitions/${a.roleDefinitionId}'
    scope: '${account.id}/dbs/${databaseName}'
  }
}]
