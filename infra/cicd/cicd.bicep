// CCOF runner identities and, optionally, the runner VMs (docs/runbooks/CICD-SETUP.md).
// Two user-assigned identities: <prefix>-preview-id (read-only roles) and <prefix>-deploy-id (deploy roles,
// infra/cicd/roles.bicep). Each runner VM carries exactly one of them, so privilege is separated by runner.
// No federated credential, no secret, no VM extension and no custom data: the VM admin bootstraps the host with
// scripts/cicd/Install-CcofRunner.sh. With createVms false only the identities are created and the driver
// attaches them to the customer's existing VMs.
targetScope = 'resourceGroup'

param location string = resourceGroup().location

@minLength(3)
@maxLength(31)
param namePrefix string

@description('Create the runner VMs here. false: the customer provides the VMs (hardened image) and Invoke-CicdSetup.ps1 attaches the identities.')
param createVms bool = false

@description('Subnet for the VM NICs (no public IP).')
param subnetId string = ''
param vmSize string = 'Standard_B2s'

@description('Per role: { preview: image, apply: image }. An image is { id } (Compute Gallery image version or managed image) or { publisher, offer, sku, version }.')
param images object = {}

@description('OpenSSH public key for the admin account. Invoke-CicdSetup.ps1 passes a key whose private half was never written; maintenance is Run Command or the customer bastion.')
param adminPublicKey string = ''
param adminUsername string = 'ccofadmin'
param tags object = {}

var roles = [
  { role: 'preview', id: 'preview' }
  { role: 'apply', id: 'deploy' }
]

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [for r in roles: {
  name: '${namePrefix}-${r.id}-id'
  location: location
  tags: union(tags, { 'ccof-runner-role': r.role })
}]

module vm 'modules/runner-vm.bicep' = [for (r, i) in roles: if (createVms) {
  name: '${namePrefix}-${r.role}-vm'
  params: {
    location: location
    vmName: '${namePrefix}-${r.role}-vm'
    role: r.role
    subnetId: subnetId
    vmSize: vmSize
    image: images[r.role]
    identityId: identity[i].id
    adminUsername: adminUsername
    adminPublicKey: adminPublicKey
    tags: tags
  }
}]

output identities array = [for (r, i) in roles: {
  role: r.role
  name: identity[i].name
  id: identity[i].id
  clientId: identity[i].properties.clientId
  principalId: identity[i].properties.principalId
}]
output vmIds array = [for (r, i) in roles: createVms ? vm[i]!.outputs.vmId : '']
