// D1 prerequisite: the resource group (docs/PREREQUISITES-WORKBOOK.md, D1-02). Needs Contributor on
// the subscription (docs/DEPLOYMENT-GUIDE.md, People and roles).
// Deploy with: az deployment sub create --subscription <id> --location <region> --template-file ...

targetScope = 'subscription'

@description('answers target.resourceGroup.name.')
param name string

@description('answers target.location.')
param location string

@description('answers target.tags.')
param tags object

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: name
  location: location
  tags: tags
}

output id string = group.id
