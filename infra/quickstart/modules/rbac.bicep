// Quick-start (ADR-0024, Proposed): the Azure RBAC grants of D3's data for the quick-start's own
// resources: each app's identity on its deployment storage (Storage Blob Data Owner), Application
// Insights ingestion (Monitoring Metrics Publisher), the reconciler's ledger read (Log Analytics
// Reader), the private runner's registry read (Reader on the Cosmos account), and the optional
// workbook readers. Sources: infra/poc/resolver-auth.assignments.json, infra/sync/sync.assignments.json,
// infra/reconciler/reconciler-permissions.json, docs/examples/onboarding.permissions.json,
// infra/workbook/assignments.json. Names are deterministic, so a rerun converges.

targetScope = 'resourceGroup'

param names object
param principals object
param workbookResourceName string
param workbookReaderPrincipalIds array

var blobOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var metricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb'
var logReader = '73c42c96-874c-492b-b04d-ab87d138a893'
var readerRole = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var workbookReader = 'b279062a-9be3-42a0-92ae-8b3cf002ec4d'
var apps = ['resolver', 'sync', 'reconciler']
var insightsApps = ['resolver', 'sync']

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = [for app in apps: {
  name: names.apps[app].storageAccount
}]

resource insights 'Microsoft.Insights/components@2020-02-02' existing = [for app in insightsApps: {
  name: names.apps[app].appInsights
}]

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: names.logAnalyticsWorkspace
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: names.cosmosAccount
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' existing = {
  name: workbookResourceName
}

resource storageOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (app, i) in apps: {
  name: guid(storage[i].id, app, blobOwner)
  scope: storage[i]
  properties: {
    principalId: principals[app]
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobOwner)
  }
}]

resource publisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (app, i) in insightsApps: {
  name: guid(insights[i].id, app, metricsPublisher)
  scope: insights[i]
  properties: {
    principalId: principals[app]
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', metricsPublisher)
  }
}]

resource reconcilerLogReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(workspace.id, 'reconciler', logReader)
  scope: workspace
  properties: {
    principalId: principals.reconciler
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logReader)
  }
}

// Only when the runner exists (main.bicep passes an empty principal when runner.enabled is false).
resource runnerRegistryReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principals.runner)) {
  name: guid(cosmos.id, 'runner', readerRole)
  scope: cosmos
  properties: {
    principalId: principals.runner
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRole)
  }
}

resource workbookReaders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for p in workbookReaderPrincipalIds: {
  name: guid(workbook.id, p, workbookReader)
  scope: workbook
  properties: {
    principalId: p
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', workbookReader)
  }
}]

resource workbookLogReaders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for p in workbookReaderPrincipalIds: {
  name: guid(workspace.id, p, logReader)
  scope: workspace
  properties: {
    principalId: p
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logReader)
  }
}]
