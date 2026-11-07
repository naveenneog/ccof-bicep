// Existing-network DR bootstrap: no VNet, subnet, NSG, DNS or peering resources.
targetScope = 'resourceGroup'

param location string
param tags object
param identityNames array = []

resource identities 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [for name in identityNames: {
  name: name
  location: location
  tags: tags
}]

output identities array = [for (name, i) in identityNames: {
  name: name
  id: identities[i].id
  principalId: identities[i].properties.principalId
  clientId: identities[i].properties.clientId
}]
