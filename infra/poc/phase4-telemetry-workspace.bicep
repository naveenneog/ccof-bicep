// D1 optional resource creation. D2 owns diagnostics; D3 owns permissions.
targetScope = 'resourceGroup'
param workspaceName string
param location string

@minValue(30)
@maxValue(730)
param retentionInDays int = 31

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: {
    'ccof-wp': 'tel'
  }
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    features: {
      disableLocalAuth: true
      enableLogAccessUsingOnlyResourcePermissions: false
    }
  }
}

output workspaceResourceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
