// One direction of a VNet peering, deployed in the resource group of the local VNet (ADR 0034 P2).
targetScope = 'resourceGroup'

param localVnetName string
param remoteVnetId string
param peeringName string

resource local 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: localVnetName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: local
  name: peeringName
  properties: {
    remoteVirtualNetwork: { id: remoteVnetId }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

output peeringId string = peering.id
