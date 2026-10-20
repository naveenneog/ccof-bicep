// Stage 4: runtime access grants for the Stage 1 identities, and nothing else.
//   Azure RBAC: each app on its own deployment storage (Storage Blob Data Owner) and Application
//   Insights (Monitoring Metrics Publisher); reconciler and admin on the workspace (Log Analytics
//   Reader); the APIM identity on each Foundry account (Cognitive Services User, cross-scope).
//   Cosmos data plane: the quickstart's custom role definitions and assignments
//   (infra/quickstart/modules/cosmos-data.bicep; tests/Test-StagedStages.ps1 compares them), plus the
//   admin project editor of docs/ADMIN-QUICK-STAGES.md 7b and its catalog container.
// Operator: Owner, or Contributor plus Role Based Access Control Administrator (Azure RBAC), and the
// Cosmos sqlRoleDefinitions/write and sqlRoleAssignments/write actions. Names are deterministic, so
// a rerun converges; removing a principal here does not delete an earlier assignment.
targetScope = 'resourceGroup'

@description('Stage 1 output `names`.')
param names object

@description('Principal (object) ids from Stage 1: resolver, sync, reconciler, admin (empty admin when not deployed).')
param principals object

param databaseName string

@description('Custom Cosmos role names: syncWriter, reconcilerWriter, projectWriter, adminEditor.')
param roleNames object

@allowed(['application-permission', 'delegated-snapshot'])
param syncMode string = 'delegated-snapshot'

@description('APIM principal id and resource id; empty principal skips the Foundry grants.')
param apimPrincipalId string = ''
param apimResourceId string = ''

@description('Foundry backends: id, subscriptionId, resourceGroup, accountName, assignCognitiveServicesUser.')
param backends array = []

var blobOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var metricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb'
var logReader = '73c42c96-874c-492b-b04d-ab87d138a893'
var appKeys = filter(map(items(names.apps), a => a.key), k => !empty(principals[?k] ?? ''))
var workspaceReaders = filter(['reconciler', 'admin'], k => !empty(principals[?k] ?? ''))

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = [for k in appKeys: {
  name: names.apps[k].storageAccount
}]

resource insights 'Microsoft.Insights/components@2020-02-02' existing = [for k in appKeys: {
  name: names.apps[k].appInsights
}]

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: names.logAnalyticsWorkspace
}

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: names.cosmosAccount
}

resource storageOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (k, i) in appKeys: {
  name: guid(storage[i].id, k, blobOwner)
  scope: storage[i]
  properties: {
    principalId: principals[k]
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobOwner)
  }
}]

resource publisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (k, i) in appKeys: {
  name: guid(insights[i].id, k, metricsPublisher)
  scope: insights[i]
  properties: {
    principalId: principals[k]
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', metricsPublisher)
  }
}]

resource workspaceReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for k in workspaceReaders: {
  name: guid(workspace.id, k, logReader)
  scope: workspace
  properties: {
    principalId: principals[k]
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logReader)
  }
}]

module foundryRoles '../quickstart/modules/foundry-role.bicep' = [for b in backends: if (!empty(apimPrincipalId) && (b.?assignCognitiveServicesUser ?? true)) {
  name: '${names.deploymentPrefix}-stage4-foundry-${b.id}'
  scope: resourceGroup(b.subscriptionId, b.resourceGroup)
  params: { accountName: b.accountName, principalId: apimPrincipalId, apimResourceId: apimResourceId }
}]

// Same definitions as infra/quickstart/modules/cosmos-data.bicep, plus adminProjectEditor.
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
  {
    key: 'adminProjectEditor'
    roleName: 'adminEditor'
    dataActions: [
      'Microsoft.DocumentDB/databaseAccounts/readMetadata'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/executeQuery'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/readChangeFeed'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/read'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create'
      'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/replace'
    ]
  }
]

// The quickstart's assignments without the runner VM (the staged path seeds through the sync app),
// plus the admin editor on projects and adminConfig only (no delete, no upsert, no budget containers).
// 00000000-0000-0000-0000-000000000001 is Cosmos DB Built-in Data Reader.
var cosmosAssignments = [
  { id: 'resolver-cosmos-data-reader', principal: 'resolver', role: '00000000-0000-0000-0000-000000000001', container: '', when: '' }
  { id: 'sync-entitlement-writer', principal: 'sync', role: 'custom:syncEntitlementWriter', container: 'entitlement', when: '' }
  { id: 'sync-lease-writer', principal: 'sync', role: 'custom:syncEntitlementWriter', container: 'syncLease', when: '' }
  { id: 'sync-projects-reader', principal: 'sync', role: '00000000-0000-0000-0000-000000000001', container: 'projects', when: '' }
  { id: 'reconciler-projects-reader', principal: 'reconciler', role: '00000000-0000-0000-0000-000000000001', container: 'projects', when: '' }
  { id: 'reconciler-entitlement-reader', principal: 'reconciler', role: '00000000-0000-0000-0000-000000000001', container: 'entitlement', when: '' }
  { id: 'reconciler-budget-state-writer', principal: 'reconciler', role: 'custom:reconcilerStateWriter', container: 'budgetState', when: '' }
  { id: 'reconciler-aggregate-state-writer', principal: 'reconciler', role: 'custom:reconcilerStateWriter', container: 'aggregateBudgetState', when: '' }
  { id: 'reconciler-lease-writer', principal: 'reconciler', role: 'custom:reconcilerStateWriter', container: 'reconcilerLease', when: '' }
  { id: 'qs-sync-projects-writer', principal: 'sync', role: 'custom:onbProjectWriter', container: 'projects', when: '' }
  { id: 'qs-sync-backends-writer', principal: 'sync', role: 'custom:onbProjectWriter', container: 'backends', when: '' }
  { id: 'admin-projects-editor', principal: 'admin', role: 'custom:adminProjectEditor', container: 'projects', when: '' }
  { id: 'admin-config-editor', principal: 'admin', role: 'custom:adminProjectEditor', container: 'adminConfig', when: '' }
]
var activeAssignments = filter(cosmosAssignments, a => (empty(a.when) || a.when == syncMode) && !empty(principals[?a.principal] ?? ''))

resource roleDefinitions 'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions@2024-11-15' = [for d in cosmosRoleDefinitions: {
  parent: account
  name: guid(account.id, 'ccof-staged', d.key)
  properties: {
    roleName: roleNames[d.roleName]
    type: 'CustomRole'
    assignableScopes: [account.id]
    permissions: [{ dataActions: d.dataActions }]
  }
}]

// Cosmos applies one role-assignment write at a time per account.
@batchSize(1)
resource assignments 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = [for a in activeAssignments: {
  parent: account
  name: guid(account.id, 'ccof-staged', a.id)
  properties: {
    roleDefinitionId: startsWith(a.role, 'custom:')
      ? '${account.id}/sqlRoleDefinitions/${guid(account.id, 'ccof-staged', substring(a.role, 7))}'
      : '${account.id}/sqlRoleDefinitions/${a.role}'
    principalId: principals[a.principal]
    scope: empty(a.container) ? '${account.id}/dbs/${databaseName}' : '${account.id}/dbs/${databaseName}/colls/${a.container}'
  }
  dependsOn: [roleDefinitions]
}]

output storageOwnerAssignmentIds array = [for (k, i) in appKeys: storageOwner[i].id]
output metricsPublisherAssignmentIds array = [for (k, i) in appKeys: publisher[i].id]
output workspaceReaderAssignmentIds array = [for (k, i) in workspaceReaders: workspaceReader[i].id]
output cosmosAssignmentIds array = [for a in activeAssignments: a.id]
output foundryGrants array = [for b in backends: (!empty(apimPrincipalId) && (b.?assignCognitiveServicesUser ?? true)) ? b.id : '']
