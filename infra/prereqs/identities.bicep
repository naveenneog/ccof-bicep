// D1 prerequisite: the user-assigned identities of the sync and the reconciler
// (docs/PREREQUISITES-WORKBOOK.md, D1-07). They exist before their apps, so D3 can grant them and
// a Graph application permission can precede the sync's first token request
// (docs/DEPLOYMENT-GUIDE.md, Step 7). The resolver keeps a system-assigned identity, as in the PoC.

targetScope = 'resourceGroup'

@description('Region; equals the deployment location.')
param location string

@description('Tags for every resource (answers target.tags).')
param tags object

@description('Identity names (answers names.identities.sync and .reconciler).')
param names object

resource sync 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: names.sync
  location: location
  tags: tags
}

resource reconciler 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: names.reconciler
  location: location
  tags: tags
}

output syncId string = sync.id
output syncPrincipalId string = sync.properties.principalId
output syncClientId string = sync.properties.clientId
output reconcilerId string = reconciler.id
output reconcilerPrincipalId string = reconciler.properties.principalId
output reconcilerClientId string = reconciler.properties.clientId
