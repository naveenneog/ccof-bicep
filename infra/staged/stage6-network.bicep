// Stage 6 (modes existing and create; opt-in): private network paths for the Stage 1 services.
// The default network.mode verify does not use this template: the customer builds the network and
// Stage 6 only runs the read-only check scripts/manual/Test-NetworkConfiguration.ps1.
// Creates (mode create) or references (mode existing) the VNet, subnets and private DNS zones, then a
// private endpoint with a DNS zone group for every service storage account (blob) and the Cosmos
// account (Sql). Function App VNet integration is a property of each existing site; the stage driver
// sets it one app at a time (Invoke-StagedDeployment.ps1 -Stage 6), because Flex apps joining one
// subnet in parallel failed with ServiceAssociationLinkLease (infra/quickstart/main.bicep note).
// No role assignment, application setting, schema or code here.
targetScope = 'resourceGroup'

@description('Stage 1 output `names` (resource names of the services).')
param names object

param location string = resourceGroup().location
param tags object = {}

@description('mode create: { vnetName, addressSpace, apimNsgName, subnets { apim, privateEndpoints, functions } }. mode existing: { privateEndpointSubnetId, functionsSubnetId, apimSubnetId?, privateDnsZoneIds { cosmos, blob } }.')
param network object

@description('Foundry accounts in this resource group that get a private endpoint (account group): names. Zones: privatelink.cognitiveservices.azure.com, privatelink.openai.azure.com, privatelink.services.ai.azure.com, created and linked in create mode, or network.existing.privateDnsZoneIds.foundry { cognitiveServices, openAi, aiServices }.')
param foundryAccounts array = []

var appKeys = map(items(names.apps), a => a.key)
var createNetwork = network.mode == 'create'

// Authoritative subnet list: run create mode once per VNet (infra/prereqs/network.bicep header).
module net '../prereqs/network.bicep' = if (createNetwork) {
  name: '${names.deploymentPrefix}-stage6-vnet'
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

// Foundry private path (account sub-resource): one endpoint, three zone configurations, so the
// cognitiveservices, openai and services.ai host names all resolve privately from the VNet.
var foundryZoneNames = [
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.services.ai.azure.com'
]
var wantFoundryZones = createNetwork && !empty(foundryAccounts)

resource foundryZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for z in foundryZoneNames: if (wantFoundryZones) {
  name: z
  location: 'global'
  tags: tags
}]

resource foundryZoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (z, i) in foundryZoneNames: if (wantFoundryZones) {
  parent: foundryZones[i]
  name: '${network.?create.?vnetName ?? 'vnet'}-link'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: { id: createNetwork ? net!.outputs.vnetId : '' }
    registrationEnabled: false
  }
}]

var foundryZoneIds = createNetwork ? map(foundryZoneNames, z => resourceId('Microsoft.Network/privateDnsZones', z)) : [
  network.existing.?privateDnsZoneIds.?foundry.?cognitiveServices ?? ''
  network.existing.?privateDnsZoneIds.?foundry.?openAi ?? ''
  network.existing.?privateDnsZoneIds.?foundry.?aiServices ?? ''
]

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = [for f in foundryAccounts: {
  name: f
}]

resource foundryEndpoints 'Microsoft.Network/privateEndpoints@2024-05-01' = [for (f, i) in foundryAccounts: {
  name: '${f}-account-pe'
  location: location
  tags: tags
  properties: {
    subnet: { id: ids.privateEndpoints }
    privateLinkServiceConnections: [
      { name: 'account', properties: { privateLinkServiceId: foundry[i].id, groupIds: ['account'] } }
    ]
  }
}]

resource foundryZoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [for (f, i) in foundryAccounts: {
  parent: foundryEndpoints[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for (z, j) in foundryZoneNames: { name: replace(z, '.', '-'), properties: { privateDnsZoneId: foundryZoneIds[j] } }]
  }
  dependsOn: [foundryZoneLinks]
}]

output foundryPrivateEndpointIds array = [for (f, i) in foundryAccounts: foundryEndpoints[i].id]
output foundryPrivateDnsZoneIds array = foundryZoneIds
output vnetId string = createNetwork ? net!.outputs.vnetId : first(split(ids.functions, '/subnets/'))
output functionsSubnetId string = ids.functions
output apimSubnetId string = ids.apim
output privateEndpointSubnetId string = ids.privateEndpoints
output storagePrivateEndpointIds array = [for (k, i) in appKeys: storageEndpoints[i].id]
output cosmosPrivateEndpointId string = cosmosEndpoint.id
output privateDnsZoneIds object = { cosmos: ids.cosmosZone, blob: ids.blobZone }
output functionApps array = [for k in appKeys: names.apps[k].functionApp]
