// Stage 2: private network paths for the Stage 1 services.
// Creates (mode create) or references (mode existing) the VNet, subnets and private DNS zones, then a
// private endpoint with a DNS zone group for every service storage account (blob) and the Cosmos
// account (Sql). Function App VNet integration is a property of each existing site; the stage driver
// sets it one app at a time (Invoke-StagedDeployment.ps1 -Stage 2), because Flex apps joining one
// subnet in parallel failed with ServiceAssociationLinkLease (infra/quickstart/main.bicep note).
// No role assignment, application setting, schema or code here.
targetScope = 'resourceGroup'

@description('Stage 1 output `names` (resource names of the services).')
param names object

param location string = resourceGroup().location
param tags object = {}

@description('mode create: { vnetName, addressSpace, apimNsgName, subnets { apim, privateEndpoints, functions } }. mode existing: { privateEndpointSubnetId, functionsSubnetId, apimSubnetId?, privateDnsZoneIds { cosmos, blob } }.')
param network object

var appKeys = map(items(names.apps), a => a.key)
var createNetwork = network.mode == 'create'

// Authoritative subnet list: run create mode once per VNet (infra/prereqs/network.bicep header).
module net '../prereqs/network.bicep' = if (createNetwork) {
  name: '${names.deploymentPrefix}-stage2-vnet'
  params: {
    location: location
    tags: tags
    vnetName: network.create.vnetName
    addressSpace: network.create.addressSpace
    apimNsgName: network.create.apimNsgName
    subnets: network.create.subnets
  }
}

var ids = createNetwork ? {
  privateEndpoints: net!.outputs.privateEndpointSubnetId
  functions: net!.outputs.functionsSubnetId
  apim: net!.outputs.apimSubnetId
  cosmosZone: net!.outputs.cosmosDnsZoneId
  blobZone: net!.outputs.blobDnsZoneId
} : {
  privateEndpoints: network.existing.privateEndpointSubnetId
  functions: network.existing.functionsSubnetId
  apim: network.existing.?apimSubnetId ?? ''
  cosmosZone: network.existing.privateDnsZoneIds.cosmos
  blobZone: network.existing.privateDnsZoneIds.blob
}

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = [for k in appKeys: {
  name: names.apps[k].storageAccount
}]

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: names.cosmosAccount
}

resource storageEndpoints 'Microsoft.Network/privateEndpoints@2024-05-01' = [for (k, i) in appKeys: {
  name: '${names.apps[k].storageAccount}-blob-pe'
  location: location
  tags: tags
  properties: {
    subnet: { id: ids.privateEndpoints }
    privateLinkServiceConnections: [
      { name: 'blob', properties: { privateLinkServiceId: storage[i].id, groupIds: ['blob'] } }
    ]
  }
}]

resource storageZoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [for (k, i) in appKeys: {
  parent: storageEndpoints[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [{ name: 'blob', properties: { privateDnsZoneId: ids.blobZone } }]
  }
}]

resource cosmosEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${names.cosmosAccount}-sql-pe'
  location: location
  tags: tags
  properties: {
    subnet: { id: ids.privateEndpoints }
    privateLinkServiceConnections: [
      { name: 'sql', properties: { privateLinkServiceId: cosmos.id, groupIds: ['Sql'] } }
    ]
  }
}

resource cosmosZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: cosmosEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [{ name: 'documents', properties: { privateDnsZoneId: ids.cosmosZone } }]
  }
}

output functionsSubnetId string = ids.functions
output apimSubnetId string = ids.apim
output privateEndpointSubnetId string = ids.privateEndpoints
output storagePrivateEndpointIds array = [for (k, i) in appKeys: storageEndpoints[i].id]
output cosmosPrivateEndpointId string = cosmosEndpoint.id
output privateDnsZoneIds object = { cosmos: ids.cosmosZone, blob: ids.blobZone }
output functionApps array = [for k in appKeys: names.apps[k].functionApp]
