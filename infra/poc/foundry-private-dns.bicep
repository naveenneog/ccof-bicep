// Private DNS for a Foundry account's private endpoint (ADR-0013).
//
// Creates the Foundry privatelink zones in this resource group, adds one zone group to the existing
// private endpoint so Azure keeps the A records in step with the endpoint, and then links each zone to the
// hub VNet. Links fall back to public resolution for names with no record here (NxDomainRedirect), so an
// account with a private endpoint elsewhere still resolves from the hub. The VNet and the endpoint are
// parameters: nothing environment-specific is in this file.
//
// Deploy (values from infra/poc/live-test.config.json, network.vnetName and
// network.foundryPrivateEndpointName):
//   az deployment group create --subscription <id> -g <rg> --template-file infra/poc/foundry-private-dns.bicep
//     --parameters vnetName=<vnet> privateEndpointName=<endpoint>

targetScope = 'resourceGroup'

@description('Existing hub VNet in this resource group (the one API Management integrates with).')
param vnetName string

@description('Existing private endpoint to the Foundry account, in this resource group.')
param privateEndpointName string

@description('One zone per Foundry endpoint suffix (MS Learn, "Azure Private Endpoint private DNS zone values", ms.date 2026-08-11, retrieved 2026-10-11). A zone group holds at most five zones.')
@minLength(1)
@maxLength(5)
param zoneNames array = [
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.services.ai.azure.com'
]

@description('Name of each zone\'s link to the VNet.')
param vnetLinkName string = '${vnetName}-link'

@description('NxDomainRedirect retries a name that has no record in these zones through public DNS (ADR-0013).')
@allowed([
  'Default'
  'NxDomainRedirect'
])
param resolutionPolicy string = 'NxDomainRedirect'

@description('Tags for the zones and their links.')
param tags object = {
  'ccof-wp': 'net'
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' existing = {
  name: privateEndpointName
}

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zoneName in zoneNames: {
  name: zoneName
  location: 'global'
  tags: tags
}]

resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for (zoneName, i) in zoneNames: {
      name: replace(zoneName, '.', '-')
      properties: {
        privateDnsZoneId: zones[i].id
      }
    }]
  }
}

// Linked after the zone group, so the endpoint's records exist before the VNet starts using the zones.
resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zoneName, i) in zoneNames: {
  parent: zones[i]
  name: vnetLinkName
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    resolutionPolicy: resolutionPolicy
    virtualNetwork: {
      id: vnet.id
    }
  }
  dependsOn: [
    zoneGroup
  ]
}]

output zoneIds array = [for (zoneName, i) in zoneNames: zones[i].id]
output zoneGroupId string = zoneGroup.id
