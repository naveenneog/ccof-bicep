// Project admin API, private networking for the admin app's OWN storage (docs/ADMIN-API.md).
// Deploy into a NEW resource group: a dedicated VNet, its own privatelink.blob DNS zone and a blob
// private endpoint for the admin storage account. No existing VNet, DNS zone, Cosmos account or app
// is referenced or changed. Needed because tenant policy forces storage publicNetworkAccess=Disabled,
// and a Flex Consumption app then needs VNet integration plus a private endpoint to read its package.
//
// Reaching the private Cosmos registry is a separate, approved step (peering to the CCOF VNet, or a
// Cosmos private endpoint in this VNet, plus a Cosmos data role); it is not in this template.

targetScope = 'resourceGroup'

param location string = resourceGroup().location
param tags object = {}
param vnetName string = 'ccof-admin-vnet'
param addressPrefix string = '10.60.0.0/24'
param integrationSubnetPrefix string = '10.60.0.0/27'
param privateEndpointSubnetPrefix string = '10.60.0.32/27'

@description('Resource id of the admin storage account created by admin-resources.bicep.')
param adminStorageAccountId string

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [addressPrefix] }
    subnets: [
      {
        name: 'snet-admin-functions'
        properties: {
          addressPrefix: integrationSubnetPrefix
          delegations: [{ name: 'flex', properties: { serviceName: 'Microsoft.App/environments' } }]
        }
      }
      {
        name: 'snet-admin-private-endpoints'
        properties: { addressPrefix: privateEndpointSubnetPrefix }
      }
    ]
  }
}

resource blobZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
  tags: tags
}

resource blobZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: blobZone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}

resource storageEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${last(split(adminStorageAccountId, '/'))}-blob-pe'
  location: location
  tags: tags
  properties: {
    subnet: { id: vnet.properties.subnets[1].id }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: { privateLinkServiceId: adminStorageAccountId, groupIds: ['blob'] }
      }
    ]
  }
}

resource storageDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: storageEndpoint
  name: 'blob'
  properties: {
    privateDnsZoneConfigs: [{ name: 'blob', properties: { privateDnsZoneId: blobZone.id } }]
  }
}

output integrationSubnetId string = vnet.properties.subnets[0].id
output vnetId string = vnet.id
