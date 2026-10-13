// Quick-start (ADR-0024, Proposed): every application setting D2's settings step writes
// (scripts/Core.D2Steps.psm1, Get-CoreAppSettings), and the resolver's App Service Authentication
// that admits only the APIM's managed identity (ADR-0009; infra/poc/resolver-auth.ps1,
// New-ResolverAuthSettingsBody). Runtime values arrive as parameters, so the three *Settings
// variables stay in the compiled template where tests/Test-Quickstart.ps1 compares them with D2.
// A sites/config appsettings resource replaces the whole set (Learn, Microsoft.Web sites/config
// 2024-04-01, retrieved 2026-10-13): this deployment is the only writer of these apps' settings.

targetScope = 'resourceGroup'

param names object
param tenantId string
param cosmosEndpoint string
param databaseName string
param syncClientId string
param reconcilerClientId string
param resolverAppInsightsConnection string
param syncAppInsightsConnection string
param workspaceCustomerId string
param apimId string
param resolver object
param sync object
param reconciler object
param budgetState object

@description('false until the sync identity holds its Graph permission (or delegated-snapshot mode is used); D3 enables the timer in the staged path.')
param syncTimerEnabled bool

@description('Application (client) id of the Resolver API registration (ADR-0009).')
param resolverApiAppId string

@description('Application (client) id of the APIM system-assigned identity (Graph servicePrincipals/{principalId}.appId).')
param apimIdentityAppId string

@description('Object id of the APIM system-assigned identity.')
param apimPrincipalId string

var resolverSettings = {
  AzureWebJobsStorage__accountName: names.apps.resolver.storageAccount
  AzureWebJobsStorage__credential: 'managedidentity'
  CCOF_APP_ROLE: 'resolver'
  APPLICATIONINSIGHTS_CONNECTION_STRING: resolverAppInsightsConnection
  APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'
  COSMOS_ENDPOINT: cosmosEndpoint
  COSMOS_DATABASE: databaseName
  RESOLVER_COSMOS_REQUEST_TIMEOUT_MS: string(resolver.cosmosRequestTimeoutMs)
  RESOLVER_COSMOS_RETRY_ATTEMPTS: string(resolver.cosmosRetryAttempts)
  RESOLVER_COSMOS_RETRY_MAX_WAIT_SECONDS: string(resolver.cosmosRetryMaxWaitSeconds)
  RESOLVER_REQUEST_DEADLINE_MS: string(resolver.requestDeadlineMs)
  RESOLVER_BUDGET_ENFORCEMENT: resolver.budgetEnforcement
  RESOLVER_BUDGET_STATE_GRACE_SECONDS: string(budgetState.graceSeconds)
  RESOLVER_BUDGET_STATE_HARD_LIMIT_SECONDS: string(budgetState.hardLimitSeconds)
}

// D2 writes the two budget-state settings only when budgetEnforcement is budget-state.
var budgetStateKeys = ['RESOLVER_BUDGET_STATE_GRACE_SECONDS', 'RESOLVER_BUDGET_STATE_HARD_LIMIT_SECONDS']
var resolverWritten = resolver.budgetEnforcement == 'budget-state'
  ? resolverSettings
  : toObject(filter(items(resolverSettings), i => !contains(budgetStateKeys, i.key)), i => i.key, i => i.value)

var syncSettings = {
  AzureWebJobsStorage__accountName: names.apps.sync.storageAccount
  AzureWebJobsStorage__credential: 'managedidentity'
  AzureWebJobsStorage__clientId: syncClientId
  CCOF_APP_ROLE: 'sync'
  APPLICATIONINSIGHTS_CONNECTION_STRING: syncAppInsightsConnection
  APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD;ClientId=${syncClientId}'
  COSMOS_ENDPOINT: cosmosEndpoint
  COSMOS_DATABASE: databaseName
  SYNC_MANAGED_IDENTITY_CLIENT_ID: syncClientId
  SYNC_PROJECTS_CONTAINER: 'projects'
  SYNC_ENTITLEMENT_CONTAINER: 'entitlement'
  SYNC_LEASE_CONTAINER: 'syncLease'
  SYNC_TENANT_ID: tenantId
  SYNC_SCHEDULE: sync.schedule
  SYNC_LEASE_SECONDS: string(sync.leaseSeconds)
  SYNC_MAX_REMOVALS_PER_RUN: string(sync.maxRemovalsPerRun)
  SYNC_MAX_REMOVAL_FRACTION: sync.maxRemovalFraction
  SYNC_MEMBER_TYPES: sync.memberTypes
  SYNC_GRAPH_MAX_RETRIES: string(sync.graphMaxRetries)
  SYNC_GRAPH_MAX_RETRY_AFTER_SECONDS: string(sync.graphMaxRetryAfterSeconds)
  SYNC_GRAPH_TIMEOUT_SECONDS: string(sync.graphTimeoutSeconds)
  SYNC_WRITE_MODE: sync.writeMode
  'AzureWebJobs.syncEntitlement.Disabled': syncTimerEnabled ? 'false' : 'true'
}

var reconcilerSettings = {
  AzureWebJobsStorage__accountName: names.apps.reconciler.storageAccount
  AzureWebJobsStorage__credential: 'managedidentity'
  AzureWebJobsStorage__clientId: reconcilerClientId
  CCOF_APP_ROLE: 'reconciler'
  COSMOS_ENDPOINT: cosmosEndpoint
  COSMOS_DATABASE: databaseName
  RECONCILER_MANAGED_IDENTITY_CLIENT_ID: reconcilerClientId
  RECONCILER_SCHEDULE: reconciler.schedule
  RECONCILER_VALIDITY_SECONDS: string(reconciler.validitySeconds)
  RECONCILER_LEASE_SECONDS: string(reconciler.leaseSeconds)
  RECONCILER_LOG_ANALYTICS_WORKSPACE_ID: workspaceCustomerId
  RECONCILER_LOG_ANALYTICS_ENDPOINT: reconciler.logAnalyticsEndpoint
  RECONCILER_LEDGER_GATEWAY_RESOURCE_ID: apimId
  RECONCILER_LEDGER_TIMEOUT_SECONDS: string(reconciler.ledgerTimeoutSeconds)
  RECONCILER_LEDGER_MAX_ROWS: string(reconciler.ledgerMaxRows)
  RECONCILER_MAX_STATES: string(reconciler.maxStates)
  RECONCILER_WRITE_CONCURRENCY: string(reconciler.writeConcurrency)
  RECONCILER_PROJECTS_CONTAINER: 'projects'
  RECONCILER_ENTITLEMENT_CONTAINER: 'entitlement'
  RECONCILER_BUDGET_STATE_CONTAINER: 'budgetState'
  RECONCILER_AGGREGATE_STATE_CONTAINER: 'aggregateBudgetState'
  RECONCILER_LEASE_CONTAINER: 'reconcilerLease'
  'AzureWebJobs.reconcileBudgets.Disabled': reconciler.timerEnabled ? 'false' : 'true'
}

resource resolverSite 'Microsoft.Web/sites@2024-04-01' existing = {
  name: names.apps.resolver.functionApp
}

resource syncSite 'Microsoft.Web/sites@2024-04-01' existing = {
  name: names.apps.sync.functionApp
}

resource reconcilerSite 'Microsoft.Web/sites@2024-04-01' existing = {
  name: names.apps.reconciler.functionApp
}

resource resolverAppSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: resolverSite
  name: 'appsettings'
  properties: resolverWritten
}

resource syncAppSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: syncSite
  name: 'appsettings'
  properties: syncSettings
}

resource reconcilerAppSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: reconcilerSite
  name: 'appsettings'
  properties: reconcilerSettings
}

// infra/poc/resolver-auth.ps1, New-ResolverAuthSettingsBody: v2 issuer, the resolver API audience,
// and only the APIM identity as the allowed application and principal (ADR-0009).
resource resolverAuth 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: resolverSite
  name: 'authsettingsV2'
  properties: {
    platform: { enabled: true }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
    }
    httpSettings: { requireHttps: true }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenantId}/v2.0'
          clientId: resolverApiAppId
        }
        validation: {
          allowedAudiences: ['api://${resolverApiAppId}', resolverApiAppId]
          defaultAuthorizationPolicy: {
            allowedApplications: [apimIdentityAppId]
            allowedPrincipals: { identities: [apimPrincipalId] }
          }
        }
      }
    }
    login: { tokenStore: { enabled: false } }
  }
  dependsOn: [resolverAppSettings]
}
