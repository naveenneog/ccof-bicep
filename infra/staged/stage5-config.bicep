// Stage 5: configuration of the deployed services. No role assignment, Entra object, schema, code or
// seed data. Reuses the quickstart's settings and API modules:
//   - infra/quickstart/modules/app-settings.bicep: resolver/sync/reconciler settings (timers stay off
//     unless syncTimerEnabled / reconciler.timerEnabled) and the resolver's App Service Authentication
//     that admits only the APIM identity (ADR-0009);
//   - infra/quickstart/modules/apim-api.bicep: the Claude Messages API, its backends and policy;
//   - infra/workbook/main.bicep: the chargeback workbook, only when content is supplied;
//   - the API-level Azure Monitor logger and diagnostic of infra/poc/phase4-apim-telemetry.bicep. Stage 1
//     already created the APIM and Function resource-log diagnostic settings; a second setting with the
//     same categories and workspace would be refused, so they are not repeated.
// A sites/config appsettings resource replaces the whole set: this stage is the only settings writer.
targetScope = 'resourceGroup'

param tenantId string
param location string = resourceGroup().location

@description('Stage 1 `names` plus cosmosDatabase.')
param names object

param cosmosEndpoint string
param syncClientId string
param reconcilerClientId string

@description('APIM: name, subscriptionId, resourceGroup, apiId, apiPath, apiDisplayName.')
param apim object
param backends array
@minLength(1)
param policyXml string
@description('The own-usage API policy (render.ts <apiId>.usage.policy.xml); empty: no usage API.')
param usagePolicyXml string = ''

param resolver object
param sync object
param reconciler object
param budgetState object = { graceSeconds: 900, hardLimitSeconds: 3600 }
param syncTimerEnabled bool = false

param resolverApiAppId string
param apimIdentityAppId string
param apimPrincipalId string

@description('Admin app: enabled, readerIds, editorIds, uiClientId (the admin registration), extraAllowedClientIds (default none; test clients only), gatewayUrl, clientId (developer registration), projectHeader, v3Enabled.')
param admin object = { enabled: false }

param workbook object = {}
@description('Empty leaves any existing workbook untouched.')
param workbookContent object = {}
param workbookContentTags object = {}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: names.logAnalyticsWorkspace
}
resource apimService 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apim.name
  scope: resourceGroup(apim.subscriptionId, apim.resourceGroup)
}
resource resolverInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: names.apps.resolver.appInsights
}
resource syncInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: names.apps.sync.appInsights
}
resource reconcilerInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: names.apps.reconciler.appInsights
}
resource reconcilerSite 'Microsoft.Web/sites@2024-04-01' existing = {
  name: names.apps.reconciler.functionApp
}

module settings '../quickstart/modules/app-settings.bicep' = {
  name: '${names.deploymentPrefix}-stage5-settings'
  params: {
    names: names
    tenantId: tenantId
    cosmosEndpoint: cosmosEndpoint
    databaseName: names.cosmosDatabase
    syncClientId: syncClientId
    reconcilerClientId: reconcilerClientId
    resolverAppInsightsConnection: resolverInsights.properties.ConnectionString
    syncAppInsightsConnection: syncInsights.properties.ConnectionString
    reconcilerAppInsightsConnection: reconcilerInsights.properties.ConnectionString
    workspaceCustomerId: workspace.properties.customerId
    apimId: apimService.id
    resolver: resolver
    sync: sync
    syncLimitsContainer: (admin.?enabled ?? false) ? 'adminConfig' : ''
    reconciler: reconciler
    budgetState: budgetState
    syncTimerEnabled: syncTimerEnabled
    resolverApiAppId: resolverApiAppId
    apimIdentityAppId: apimIdentityAppId
    apimPrincipalId: apimPrincipalId
  }
}

module api '../quickstart/modules/apim-api.bicep' = {
  name: '${names.deploymentPrefix}-stage5-api'
  scope: resourceGroup(apim.subscriptionId, apim.resourceGroup)
  params: {
    apimName: apim.name
    apiId: apim.apiId
    apiPath: apim.apiPath
    apiDisplayName: apim.apiDisplayName
    backends: [for b in backends: { id: b.id, url: b.url }]
    policyXml: policyXml
    usagePolicyXml: usagePolicyXml
  }
}

module apiTelemetry 'stage5-api-telemetry.bicep' = {
  name: '${names.deploymentPrefix}-stage5-api-telemetry'
  scope: resourceGroup(apim.subscriptionId, apim.resourceGroup)
  params: { apimName: apim.name, apiId: apim.apiId }
  dependsOn: [api]
}

module workbookFull '../workbook/main.bicep' = if (!empty(workbookContent)) {
  name: '${names.deploymentPrefix}-stage5-workbook'
  params: {
    workbookResourceName: workbook.resourceName
    workbookDisplayName: workbook.displayName
    location: location
    workspaceResourceId: workspace.id
    // An object parameter is recursively evaluated at the nested ARM boundary. Keep JSON-array
    // strings (for example the Period dropdown) opaque until they reach the workbook resource.
    workbookContent: {}
    workbookSerializedData: string(workbookContent)
    contentTags: workbookContentTags
  }
}

var adminEnabled = admin.?enabled ?? false
resource adminSite 'Microsoft.Web/sites@2024-04-01' existing = if (adminEnabled) {
  name: names.apps.?admin.?functionApp ?? 'none'
}
resource adminInsights 'Microsoft.Insights/components@2020-02-02' existing = if (adminEnabled) {
  name: names.apps.?admin.?appInsights ?? 'none'
}

// Admin app settings (docs/ADMIN-V3.md Settings, docs/ADMIN-QUICK-STAGES.md 4g). One shared
// workspace: the reconciler logs through its diagnostic setting (site id), the admin audit through its
// Application Insights component.
// Active/passive DR (DR-05): every gateway this deployment's usage can come from; absent for one region.
var adminGatewayList = admin.?gatewayResourceIds ?? []
resource adminSettings 'Microsoft.Web/sites/config@2024-04-01' = if (adminEnabled) {
  parent: adminSite
  name: 'appsettings'
  properties: union(empty(adminGatewayList) ? {} : { ADMIN_GATEWAY_RESOURCE_IDS: join(adminGatewayList, ',') }, {
    AzureWebJobsStorage__accountName: names.apps.?admin.?storageAccount ?? ''
    AzureWebJobsStorage__credential: 'managedidentity'
    APPLICATIONINSIGHTS_CONNECTION_STRING: adminInsights!.properties.ConnectionString
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'
    COSMOS_ENDPOINT: cosmosEndpoint
    COSMOS_DATABASE: names.cosmosDatabase
    ADMIN_PROJECTS_CONTAINER: 'projects'
    ADMIN_CONFIG_CONTAINER: 'adminConfig'
    ADMIN_TENANT_ID: tenantId
    ADMIN_AUDIENCE: admin.?uiClientId ?? ''
    ADMIN_SCOPE: 'Projects.Manage'
    ADMIN_ALLOWED_CLIENT_IDS: join(concat([admin.?uiClientId ?? ''], admin.?extraAllowedClientIds ?? []), ',')
    ADMIN_UI_CLIENT_ID: admin.?uiClientId ?? ''
    ADMIN_UI_SCOPE: empty(admin.?uiClientId ?? '') ? '' : 'api://${admin.uiClientId}/Projects.Manage'
    ADMIN_READER_IDS: join(admin.?readerIds ?? [], ',')
    ADMIN_EDITOR_IDS: join(admin.?editorIds ?? [], ',')
    ADMIN_V3_ENABLED: (admin.?v3Enabled ?? true) ? 'true' : 'false'
    ADMIN_WORKSPACE_ID: workspace.properties.customerId
    ADMIN_GATEWAY_RESOURCE_ID: apimService.id
    ADMIN_LOG_RESOURCE_IDS: join([reconcilerSite.id, adminInsights!.id, adminSite!.id], ',')
    ADMIN_RECONCILER_RESOURCE_ID: reconcilerSite.id
    ADMIN_RECONCILER_INTERVAL_MINUTES: '2'
    ADMIN_CLIENT_ID: admin.?clientId ?? ''
    ADMIN_GATEWAY_URL: admin.?gatewayUrl ?? ''
    ADMIN_PROJECT_HEADER: admin.?projectHeader ?? 'x-ccof-project'
  })
}

output gatewayUrl string = '${api.outputs.gatewayUrl}/${apim.apiPath}'
output settingsWritten array = concat(['resolver', 'sync', 'reconciler', 'resolver-auth'], adminEnabled ? ['admin'] : [])
output workbookDeployed bool = !empty(workbookContent)
