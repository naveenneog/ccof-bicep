// D1 prerequisite: the Log Analytics workspace that receives gateway logs, Function App logs and the
// usage ledger (docs/PREREQUISITES-WORKBOOK.md, D1-06).
// Source: infra/poc/phase4-telemetry.bicep on wp/tel (workspace properties, live 2026-10-11).
// Diagnostic settings and alerts are D2 (WP-TEL); reader roles are D3.

targetScope = 'resourceGroup'

@description('availability.telemetry.workspaceRegion.')
param location string

@description('Tags for every resource (answers target.tags).')
param tags object

@description('Workspace name (answers names.logAnalyticsWorkspace).')
param name string

@description('availability.telemetry.retentionDays.')
@minValue(30)
@maxValue(730)
param retentionInDays int

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionInDays
    features: {
      disableLocalAuth: true
      enableLogAccessUsingOnlyResourcePermissions: false
    }
  }
}

output id string = workspace.id
output customerId string = workspace.properties.customerId
