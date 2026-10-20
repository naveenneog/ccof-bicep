// Stage 3: Cosmos database and container structure only. No documents, no data-role definitions or
// assignments (Stage 4) and no settings. The container list matches the quickstart's
// (infra/quickstart/modules/cosmos-data.bicep, cosmosContainers); tests/Test-StagedStages.ps1 compares
// them. adminConfig is the admin catalog container (infra/admin/admin-v2-catalog.bicep), only with
// includeAdmin.
targetScope = 'resourceGroup'

@description('Stage 1 output `names`.')
param names object

@minLength(1)
param databaseName string

@allowed(['serverless', 'provisioned-autoscale'])
param capacityMode string = 'serverless'

@minValue(1000)
param autoscaleMaxThroughput int = 1000

param includeAdmin bool = true

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
var adminContainers = includeAdmin ? [{ name: 'adminConfig', partitionKey: '/scopeId' }] : []
var allContainers = concat(cosmosContainers, adminContainers)

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: names.cosmosAccount
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = {
  parent: account
  name: databaseName
  properties: {
    resource: { id: databaseName }
    options: capacityMode == 'provisioned-autoscale' ? { autoscaleSettings: { maxThroughput: autoscaleMaxThroughput } } : {}
  }
}

@batchSize(1)
resource containers 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = [for c in allContainers: {
  parent: database
  name: c.name
  properties: {
    resource: {
      id: c.name
      partitionKey: { paths: [c.partitionKey], kind: 'Hash' }
    }
  }
}]

output databaseName string = database.name
output containers array = [for c in allContainers: { name: c.name, partitionKey: c.partitionKey }]
