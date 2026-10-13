// D1 prerequisite: the Cosmos DB account of the registry, in the capacity mode, zones and region
// chosen at D0, reachable only through its private endpoint (docs/PREREQUISITES-WORKBOOK.md, D1-08).
// Sources: infra/poc/phase3-cosmos-function.bicep (account, private endpoint, DNS zone group);
// docs/AVAILABILITY.md rows 5 and 6. The database, its throughput and the containers are D2;
// data-plane role assignments are D3.
//
// Capacity mode is fixed at creation: serverless accounts run in one region, and converting to
// provisioned throughput is one-way (Learn, "Change capacity mode", via docs/AVAILABILITY.md [C3]).

targetScope = 'resourceGroup'

@description('Region; equals the deployment location and availability.registry.regions[0].')
param location string

@description('Tags for every resource (answers target.tags).')
param tags object

@description('Account name (answers names.cosmosAccount).')
param accountName string

@description('availability.registry.capacityMode.')
@allowed(['serverless', 'provisioned-autoscale', 'provisioned-manual'])
param capacityMode string

@description('availability.registry.zoneRedundant.')
param zoneRedundant bool

@description('Private endpoint name (answers names.cosmosPrivateEndpoint).')
param privateEndpointName string

@description('Subnet id for private endpoints (D1 network).')
param privateEndpointSubnetId string

@description('Resource id of the privatelink.documents.azure.com private DNS zone.')
param cosmosPrivateDnsZoneId string

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: accountName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [
      { locationName: location, failoverPriority: 0, isZoneRedundant: zoneRedundant }
    ]
    capabilities: capacityMode == 'serverless' ? [{ name: 'EnableServerless' }] : []
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    enableMultipleWriteLocations: false
    enableAutomaticFailover: false
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: privateEndpointName
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: '${privateEndpointName}-connection'
        properties: { privateLinkServiceId: account.id, groupIds: ['Sql'] }
      }
    ]
  }
}

resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: 'cosmos-dns-zone-group'
  properties: {
    privateDnsZoneConfigs: [{ name: 'documents', properties: { privateDnsZoneId: cosmosPrivateDnsZoneId } }]
  }
}

output id string = account.id
output endpoint string = account.properties.documentEndpoint
output privateEndpointId string = privateEndpoint.id
