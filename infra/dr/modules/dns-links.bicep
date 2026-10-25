// Links one VNet to existing private DNS zones in the zones' own resource group (ADR 0034 P2).
targetScope = 'resourceGroup'

param vnetId string
param linkName string
param zoneNames array
param tags object

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' existing = [for zone in zoneNames: {
  name: zone
}]

resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zone, i) in zoneNames: {
  parent: zones[i]
  name: linkName
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: { id: vnetId }
    registrationEnabled: false
  }
}]

output linkIds array = [for (zone, i) in zoneNames: links[i].id]
