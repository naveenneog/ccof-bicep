// Quick-start (ADR-0024, Proposed): the private runner, a Linux VM with no public IP and a
// system-assigned identity, in the runner subnet. It makes the Cosmos data-plane writes from inside
// the VNet (Cosmos public access is off), driven by Run Command (scripts/runner/run-private.ps1
// pattern). SSH takes a public key only; there is no password.

targetScope = 'resourceGroup'

param location string
param tags object
param vmName string
param subnetId string
param vmSize string
param adminUsername string

@description('An SSH public key (not a secret). Run Command needs no SSH connection; the key is required by the Linux VM API when password authentication is off.')
param sshPublicKey string

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [{ path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey }] }
      }
    }
    storageProfile: {
      imageReference: { publisher: 'Canonical', offer: 'ubuntu-24_04-lts', sku: 'server', version: 'latest' }
      osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'StandardSSD_LRS' }, deleteOption: 'Delete' }
    }
    networkProfile: { networkInterfaces: [{ id: nic.id, properties: { deleteOption: 'Delete' } }] }
    securityProfile: { securityType: 'TrustedLaunch', uefiSettings: { secureBootEnabled: true, vTpmEnabled: true } }
  }
}

output principalId string = vm.identity.principalId
output vmId string = vm.id
