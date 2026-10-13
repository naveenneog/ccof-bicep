// Quick-start (ADR-0024, Proposed): the registry database, every container D2's schema step creates,
// and the Cosmos data-plane role definitions and assignments of D3's data, on an account that
// infra/prereqs/cosmos-account.bicep created. tests/Test-Quickstart.ps1 checks the three variables
// below against scripts/Core.D2Steps.psm1 ($script:Containers) and the D3 data files
// (infra/poc/resolver-auth.assignments.json, infra/sync/sync.assignments.json,
// infra/reconciler/reconciler-permissions.json, docs/examples/onboarding.permissions.json).
// Resource shapes: Learn, Microsoft.DocumentDB databaseAccounts/sqlRoleDefinitions and
// sqlRoleAssignments 2024-11-15 (retrieved 2026-10-13).

targetScope = 'resourceGroup'

@description('Cosmos DB account name (created by the quick-start).')
param accountName string

@description('Database name (D2 answers names.cosmosDatabase).')
param databaseName string

@description('serverless, or provisioned-autoscale with autoscaleMaxThroughput on the database.')
@allowed(['serverless', 'provisioned-autoscale'])
param capacityMode string

@description('Database autoscale maximum RU/s; used only with provisioned-autoscale.')
param autoscaleMaxThroughput int

@description('Custom role names: syncWriter, reconcilerWriter, projectWriter (answers names.cosmosRoles).')
param roleNames object

@description('Principal (object) ids: resolver, sync, reconciler, runner.')
param principals object

@description('application-permission or delegated-snapshot (answers sync.mode); the runner holds the sync writer roles only in delegated-snapshot.')
@allowed(['application-permission', 'delegated-snapshot'])
param syncMode string

// D2's schema step, scripts/Core.D2Steps.psm1 ($script:Containers).
var cosmosContainers = [
  { name: 'entitlement', partitionKey: '/personId' }
  { name: 'projects', partitionKey: '/projectId' }
  { name: 'subscriptionIndex', partitionKey: '/subscriptionId' }
  { name: 'budgetState', partitionKey: '/personId' }
  { name: 'aggregateBudgetState', partitionKey: '/scopeId' }
  { name: 'syncLease', partitionKey: '/id' }
  { name: 'reconcilerLease', partitionKey: '/id' }
  { name: 'backends', partitionKey: '/backendId' }
]

// D3's custom role definitions (cosmosRoleDefinitions of the data files); roleName indexes roleNames.
var cosmosRoleDefinitions = [
  {
    key: 'syncEntitlementWriter'
    roleName: 'syncWriter'
    dataActions: [
      'Microsoft.DocumentDB/databaseAccounts/readMetadata'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/executeQuery'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/readChangeFeed'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/read'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/replace'
    ]
  }
  {
    key: 'reconcilerStateWriter'
    roleName: 'reconcilerWriter'
    dataActions: [
      'Microsoft.DocumentDB/databaseAccounts/readMetadata'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/read'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/replace'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/upsert'
    ]
  }
  {
    key: 'onbProjectWriter'
    roleName: 'projectWriter'
    dataActions: [
      'Microsoft.DocumentDB/databaseAccounts/readMetadata'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/read'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create'
    ]
  }
]

// D3's cosmos-data assignments. container '' is database scope; when '' always applies.
// 00000000-0000-0000-0000-000000000001 is Cosmos DB Built-in Data Reader.
var cosmosAssignments = [
  { id: 'resolver-cosmos-data-reader', principal: 'resolver', role: '00000000-0000-0000-0000-000000000001', container: '', when: '' }
  { id: 'sync-entitlement-writer', principal: 'sync', role: 'custom:syncEntitlementWriter', container: 'entitlement', when: '' }
  { id: 'sync-lease-writer', principal: 'sync', role: 'custom:syncEntitlementWriter', container: 'syncLease', when: '' }
  { id: 'sync-projects-reader', principal: 'sync', role: '00000000-0000-0000-0000-000000000001', container: 'projects', when: '' }
  { id: 'sync-runner-entitlement-writer', principal: 'runner', role: 'custom:syncEntitlementWriter', container: 'entitlement', when: 'delegated-snapshot' }
  { id: 'sync-runner-lease-writer', principal: 'runner', role: 'custom:syncEntitlementWriter', container: 'syncLease', when: 'delegated-snapshot' }
  { id: 'sync-runner-projects-reader', principal: 'runner', role: '00000000-0000-0000-0000-000000000001', container: 'projects', when: 'delegated-snapshot' }
  { id: 'reconciler-projects-reader', principal: 'reconciler', role: '00000000-0000-0000-0000-000000000001', container: 'projects', when: '' }
  { id: 'reconciler-entitlement-reader', principal: 'reconciler', role: '00000000-0000-0000-0000-000000000001', container: 'entitlement', when: '' }
  { id: 'reconciler-budget-state-writer', principal: 'reconciler', role: 'custom:reconcilerStateWriter', container: 'budgetState', when: '' }
  { id: 'reconciler-aggregate-state-writer', principal: 'reconciler', role: 'custom:reconcilerStateWriter', container: 'aggregateBudgetState', when: '' }
  { id: 'reconciler-lease-writer', principal: 'reconciler', role: 'custom:reconcilerStateWriter', container: 'reconcilerLease', when: '' }
  { id: 'onb-private-runner-project-writer', principal: 'runner', role: 'custom:onbProjectWriter', container: 'projects', when: '' }
]

var activeAssignments = filter(cosmosAssignments, a => empty(a.when) || a.when == syncMode)

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: accountName
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = {
  parent: account
  name: databaseName
  properties: {
    resource: { id: databaseName }
    options: capacityMode == 'provisioned-autoscale' ? { autoscaleSettings: { maxThroughput: autoscaleMaxThroughput } } : {}
  }
}

resource containers 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = [for c in cosmosContainers: {
  parent: database
  name: c.name
  properties: {
    resource: {
      id: c.name
      partitionKey: { paths: [c.partitionKey], kind: 'Hash' }
    }
  }
}]

resource roleDefinitions 'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions@2024-11-15' = [for d in cosmosRoleDefinitions: {
  parent: account
  name: guid(account.id, 'ccof-quickstart', d.key)
  properties: {
    roleName: roleNames[d.roleName]
    type: 'CustomRole'
    assignableScopes: [account.id]
    permissions: [{ dataActions: d.dataActions }]
  }
}]

resource assignments 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = [for a in activeAssignments: {
  parent: account
  name: guid(account.id, 'ccof-quickstart', a.id)
  properties: {
    roleDefinitionId: startsWith(a.role, 'custom:')
      ? '${account.id}/sqlRoleDefinitions/${guid(account.id, 'ccof-quickstart', substring(a.role, 7))}'
      : '${account.id}/sqlRoleDefinitions/${a.role}'
    principalId: principals[a.principal]
    scope: empty(a.container) ? '${account.id}/dbs/${databaseName}' : '${account.id}/dbs/${databaseName}/colls/${a.container}'
  }
  dependsOn: [roleDefinitions, containers]
}]

output databaseName string = database.name
output containerNames array = [for c in cosmosContainers: c.name]
output assignmentIds array = [for a in activeAssignments: a.id]
