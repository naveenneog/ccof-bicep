targetScope = 'resourceGroup'

@description('Existing Cosmos account in this resource group. No account or network configuration is changed.')
param cosmosAccountName string
param databaseName string
param containerName string = 'adminConfig'

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' existing = {
  name: cosmosAccountName
}
resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' existing = {
  parent: account
  name: databaseName
}
resource catalog 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: database
  name: containerName
  properties: {
    resource: {
      id: containerName
      partitionKey: { paths: ['/scopeId'], kind: 'Hash' }
    }
  }
}
output containerResourceId string = catalog.id
