// D2 composition. CORE supplies D1 checkpoint ids and owns stage/audit records.
targetScope = 'resourceGroup'
param workspaceResourceId string
param apimResourceId string
param apiName string
param location string
param functionAppResourceIds array
param enableAlerts bool = false
@secure()
param alertConfiguration object = {}
param alertConfigurationDigest string = ''

module apimConfiguration 'phase4-apim-telemetry.bicep' = {
  name: 'ccof-tel-apim-${uniqueString(apimResourceId, apiName)}'
  scope: resourceGroup(split(apimResourceId, '/')[2], split(apimResourceId, '/')[4])
  params: {
    workspaceResourceId: workspaceResourceId
    apimServiceName: last(split(apimResourceId, '/'))
    apiName: apiName
    location: location
    enableAlerts: enableAlerts
    alertConfiguration: alertConfiguration
    alertConfigurationDigest: alertConfigurationDigest
  }
}

module functionDiagnostics 'phase4-function-logs.bicep' = [for appId in functionAppResourceIds: {
  name: 'ccof-tel-function-${uniqueString(appId, workspaceResourceId)}'
  scope: resourceGroup(split(appId, '/')[2], split(appId, '/')[4])
  params: {
    functionAppName: last(split(appId, '/'))
    workspaceResourceId: workspaceResourceId
  }
}]

output workspaceId string = workspaceResourceId
output apiDiagnosticId string = apimConfiguration.outputs.apiDiagnosticId
output diagnosticSettingId string = apimConfiguration.outputs.diagnosticSettingId
output functionDiagnosticSettingIds array = [for (appId, i) in functionAppResourceIds: functionDiagnostics[i].outputs.diagnosticSettingId]
