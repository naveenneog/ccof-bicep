// One CCOF runner VM: NIC without public IP, one user-assigned identity, SSH key only, no extension, no custom
// data. The host is bootstrapped afterwards by scripts/cicd/Install-CcofRunner.sh (docs/runbooks/CICD-SETUP.md).
targetScope = 'resourceGroup'

param location string
param vmName string
@allowed(['preview', 'apply'])
param role string
param subnetId string
param vmSize string

@description('{ id } for a gallery or managed image, or { publisher, offer, sku, version } for a marketplace image.')
param image object
param identityId string
param adminUsername string
param adminPublicKey string
param tags object = {}

var imageReference = contains(image, 'id') ? { id: image.id } : {
  publisher: image.publisher
  offer: image.offer
  sku: image.sku
  version: image.?version ?? 'latest'
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: subnetId }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: union(tags, { 'ccof-runner-role': role })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: imageReference
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 64
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
        deleteOption: 'Delete'
      }
    }
    osProfile: {
      computerName: take(vmName, 15)
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
        provisionVMAgent: true
        patchSettings: { patchMode: 'ImageDefault' }
      }
      allowExtensionOperations: true
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: { deleteOption: 'Delete' }
        }
      ]
    }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
}

output vmId string = vm.id
output privateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
