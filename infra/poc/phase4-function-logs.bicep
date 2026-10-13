// D2 child configuration only; the app and workspace already exist from D1.
targetScope = 'resourceGroup'
param functionAppName string
param workspaceResourceId string

resource app 'Microsoft.Web/sites@2024-04-01' existing = {
  name: functionAppName
}

resource logs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'ccof-tel-${last(split(workspaceResourceId, '/'))}'
  scope: app
  properties: {
    workspaceId: workspaceResourceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'FunctionAppLogs'
        enabled: true
      }
    ]
  }
}

output diagnosticSettingId string = logs.id
