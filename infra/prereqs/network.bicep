// D1 prerequisite: the minimum network the core needs where policy forces private access
// (docs/PILOT.md C-9; docs/PREREQUISITES-WORKBOOK.md, steps D1-03 to D1-05).
// Sources: NSG rules and the APIM subnet from infra/poc/main.bicep (live since 2026-10-09);
// the Functions subnet delegation and the private DNS zones from
// infra/poc/phase3-cosmos-function.bicep (live since 2026-10-10).
// No role assignment and no application setting here: D3 and D2 own those.
//
// The subnet list is authoritative: re-running this module after day-2 networking (D5) has added
// subnets would remove them. Run it once, at creation.

targetScope = 'resourceGroup'

@description('Region of the VNet; equals the deployment location.')
param location string

@description('Tags for every resource (answers target.tags).')
param tags object

@description('VNet name (answers network.create.vnetName).')
param vnetName string

@description('VNet address space (answers network.create.addressSpace).')
param addressSpace string

@description('NSG name for the APIM subnet (answers network.create.apimNsgName).')
param apimNsgName string

@description('Subnets: apim, privateEndpoints, functions, each { name, prefix }; runner { name, prefix }, null or absent.')
param subnets object

@description('Default outbound access of the APIM and Functions integration subnets. VNets created after 2026-03-31 default every subnet to private (false), which leaves APIM and the Functions without internet egress (Graph, Log Analytics, Application Insights). Set false only where a NAT gateway or firewall provides egress.')
param defaultOutboundAccess bool = true

// .? reads an absent runner as null: a caller may omit it, and a null-valued property is not relied on.
var runnerSubnets = subnets.?runner == null ? [] : [
  {
    name: subnets.runner.name
    properties: { addressPrefix: subnets.runner.prefix }
  }
]

// Microsoft's documented minimum rule set for APIM VNet integration, as in infra/poc/main.bicep.
// An NSG on the APIM subnet is required: without one, creation failed live with
// NetworkSecurityGroupNotFound (2026-10-09).
resource nsgApim 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: apimNsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      { name: 'Allow-Client-Communication-Inbound', properties: { priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'Internet', sourcePortRange: '*', destinationAddressPrefix: 'VirtualNetwork', destinationPortRanges: ['80', '443'] } }
      { name: 'Allow-Management-Endpoint-Inbound', properties: { priority: 110, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'ApiManagement', sourcePortRange: '*', destinationAddressPrefix: 'VirtualNetwork', destinationPortRange: '3443' } }
      { name: 'Allow-LoadBalancer-Inbound', properties: { priority: 120, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'AzureLoadBalancer', sourcePortRange: '*', destinationAddressPrefix: 'VirtualNetwork', destinationPortRange: '6390' } }
      { name: 'Allow-TrafficManager-Inbound', properties: { priority: 130, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'AzureTrafficManager', sourcePortRange: '*', destinationAddressPrefix: 'VirtualNetwork', destinationPortRange: '443' } }
      { name: 'Allow-Cert-Validation-Outbound', properties: { priority: 200, direction: 'Outbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'VirtualNetwork', sourcePortRange: '*', destinationAddressPrefix: 'Internet', destinationPortRange: '80' } }
      { name: 'Allow-Storage-Outbound', properties: { priority: 210, direction: 'Outbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'VirtualNetwork', sourcePortRange: '*', destinationAddressPrefix: 'Storage', destinationPortRange: '443' } }
      { name: 'Allow-SQL-Outbound', properties: { priority: 220, direction: 'Outbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'VirtualNetwork', sourcePortRange: '*', destinationAddressPrefix: 'SQL', destinationPortRange: '1433' } }
      { name: 'Allow-KeyVault-Outbound', properties: { priority: 230, direction: 'Outbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'VirtualNetwork', sourcePortRange: '*', destinationAddressPrefix: 'AzureKeyVault', destinationPortRange: '443' } }
      { name: 'Allow-Monitor-Outbound', properties: { priority: 240, direction: 'Outbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: 'VirtualNetwork', sourcePortRange: '*', destinationAddressPrefix: 'AzureMonitor', destinationPortRanges: ['1886', '443'] } }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [addressSpace] }
    subnets: concat([
      {
        name: subnets.apim.name
        properties: {
          addressPrefix: subnets.apim.prefix
          defaultOutboundAccess: defaultOutboundAccess
          networkSecurityGroup: { id: nsgApim.id }
          // APIM v2 outbound VNet integration uses this delegation (infra/poc/main.bicep).
          delegations: [{ name: 'apim-delegation', properties: { serviceName: 'Microsoft.Web/serverFarms' } }]
        }
      }
      {
        name: subnets.privateEndpoints.name
        properties: {
          addressPrefix: subnets.privateEndpoints.prefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: subnets.functions.name
        properties: {
          addressPrefix: subnets.functions.prefix
          defaultOutboundAccess: defaultOutboundAccess
          // Flex Consumption needs Microsoft.App/environments, not Microsoft.Web/serverFarms: the live
          // ARM error of 2026-10-09 (infra/poc/phase3-cosmos-function.bicep). Several Flex apps may
          // share one subnet (Learn, flex-consumption-plan, Virtual network integration).
          delegations: [{ name: 'functions-delegation', properties: { serviceName: 'Microsoft.App/environments' } }]
        }
      }
    ], runnerSubnets)
  }
}

// The Cosmos zone name has no environment() suffix; the blob zone follows the cloud's storage suffix.
var zoneNames = [
  'privatelink.documents.azure.com'
  'privatelink.blob.${environment().suffixes.storage}'
]

resource dnsZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zone in zoneNames: {
  name: zone
  location: 'global'
  tags: tags
}]

resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zone, i) in zoneNames: {
  parent: dnsZones[i]
  name: '${vnetName}-link'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}]

output vnetId string = vnet.id
output apimSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnets.apim.name)
output privateEndpointSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnets.privateEndpoints.name)
output functionsSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnets.functions.name)
output runnerSubnetId string = subnets.?runner == null ? '' : resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnets.runner.name)
output cosmosDnsZoneId string = dnsZones[0].id
output blobDnsZoneId string = dnsZones[1].id
