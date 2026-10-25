// DR prerequisites for the secondary (standby) region: network and identity shells only
// (ADR 0034, docs/design/DR-IMPLEMENTATION.md stages P1 and P2). No application, role
// assignment, data or policy is created here; later DR stages own those.
//
// - Secondary VNet with the same three subnets as the primary (infra/prereqs/network.bicep, live
//   since 2026-10-09): APIM v2 outbound integration (Microsoft.Web/serverFarms), Flex Functions
//   integration (Microsoft.App/environments) and an undelegated private-endpoint subnet.
// - Links from the secondary VNet to the primary region's existing private DNS zones (one zone set
//   per name, so both regions resolve the same private endpoints).
// - Optional two-way peering with the primary VNet, for private reachability to pool members.
// - User-assigned identity shells (for example sync-b, reconciler-b) whose principal IDs the access
//   handoff (P3) grants against.

targetScope = 'resourceGroup'

param location string
param tags object
param vnetName string
param addressSpace string
param apimNsgName string
@description('apim, privateEndpoints, functions: each { name, prefix }.')
param subnets object
param defaultOutboundAccess bool = true

@description('Existing private DNS zones to link: { subscriptionId, resourceGroup, zoneNames[] }; zoneNames may be empty.')
param dnsZones object

@description('Primary VNet resource ID to peer with; empty skips peering.')
param primaryVnetId string = ''

@description('Names of user-assigned identity shells to create in this resource group.')
param identityNames array = []

module network '../prereqs/network.bicep' = {
  name: 'dr-network'
  params: {
    location: location
    tags: tags
    vnetName: vnetName
    addressSpace: addressSpace
    apimNsgName: apimNsgName
    subnets: subnets
    defaultOutboundAccess: defaultOutboundAccess
    createDnsZones: false
  }
}

module dnsLinks 'modules/dns-links.bicep' = if (!empty(dnsZones.zoneNames)) {
  name: 'dr-dns-links'
  scope: resourceGroup(dnsZones.subscriptionId, dnsZones.resourceGroup)
  params: {
    vnetId: network.outputs.vnetId
    linkName: '${vnetName}-link'
    zoneNames: dnsZones.zoneNames
    tags: tags
  }
}

var primaryParts = split(primaryVnetId, '/')

module toPrimary 'modules/vnet-peering.bicep' = if (!empty(primaryVnetId)) {
  name: 'dr-peering-to-primary'
  params: {
    localVnetName: vnetName
    remoteVnetId: primaryVnetId
    peeringName: 'to-${last(primaryParts)}'
  }
  dependsOn: [network]
}

module fromPrimary 'modules/vnet-peering.bicep' = if (!empty(primaryVnetId)) {
  name: 'dr-peering-from-secondary'
  scope: resourceGroup(empty(primaryVnetId) ? subscription().subscriptionId : primaryParts[2], empty(primaryVnetId) ? resourceGroup().name : primaryParts[4])
  params: {
    localVnetName: empty(primaryVnetId) ? 'none' : last(primaryParts)
    remoteVnetId: network.outputs.vnetId
    peeringName: 'to-${vnetName}'
  }
}

resource identities 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [for name in identityNames: {
  name: name
  location: location
  tags: tags
}]

output vnetId string = network.outputs.vnetId
output apimSubnetId string = network.outputs.apimSubnetId
output functionsSubnetId string = network.outputs.functionsSubnetId
output privateEndpointSubnetId string = network.outputs.privateEndpointSubnetId
output dnsLinkIds array = empty(dnsZones.zoneNames) ? [] : dnsLinks!.outputs.linkIds
output identities array = [for (name, i) in identityNames: {
  name: name
  id: identities[i].id
  principalId: identities[i].properties.principalId
  clientId: identities[i].properties.clientId
}]
