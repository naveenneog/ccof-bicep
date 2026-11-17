// Dedicated subnet for the CCOF runner VMs (docs/runbooks/CICD-SETUP.md), deployed to the network resource group.
// Optional: customers usually provide an existing subnet. The NSG denies all inbound traffic: the runner only
// opens outbound HTTPS connections to GitHub and Azure, and maintenance uses Run Command or the customer's bastion.
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param vnetName string
param subnetName string = 'cicd-runner'

@description('IPv4 prefix inside the VNet address space, /24 to /29.')
param addressPrefix string
param nsgName string = '${vnetName}-${subnetName}-nsg'

@description('true keeps Azure default outbound access (lab only). Production subnets route egress through the customer firewall or a NAT gateway, and set false.')
param defaultOutboundAccess bool = false

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'deny-all-inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'The runner accepts no inbound connection.'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: subnetName
  properties: {
    addressPrefix: addressPrefix
    networkSecurityGroup: { id: nsg.id }
    defaultOutboundAccess: defaultOutboundAccess
    privateEndpointNetworkPolicies: 'Disabled'
  }
}

output subnetId string = subnet.id
output nsgId string = nsg.id
