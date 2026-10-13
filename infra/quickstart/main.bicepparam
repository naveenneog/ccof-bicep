// Quick-start parameters (ADR-0024, Proposed). EVERY configuration value is here; docs/QUICKSTART.md
// explains each one. The values below are a validation shape
// with placeholder group ids: replace every value marked REPLACE before a live run.
// Deploy-Quickstart.ps1 reads this file (az bicep build-params), adds the values it computes
// (policyXml, workbookContent, apimIdentityAppId) and deploys main.bicep. Bicep has no decimal
// numbers, so fractions are strings.
using 'main.bicep'

// ---- 1. Tenant, subscription, resource group (the wrapper reads these three; Bicep uses tenantId) ----
param tenantId = 'REPLACE-tenant-id'
// subscriptionId and resource group: see names below.
param location = 'eastus2'
param tags = { workload: 'claude-code-on-foundry', environment: 'quickstart' }

// ---- 2. Names of every resource the quick-start creates ----
param names = {
  deploymentPrefix: 'ccofqs'
  // Wrapper: target subscription and resource group, and whether step 3 may create the group.
  subscriptionId: 'REPLACE-subscription-id'
  resourceGroup: 'ccof-qs-rg'
  resourceGroupMode: 'create'
  logAnalyticsWorkspace: 'ccofqs-law'
  cosmosAccount: 'ccofqs-cosmos'
  cosmosDatabase: 'ccof'
  cosmosPrivateEndpoint: 'ccofqs-pe-cosmos'
  cosmosRoles: {
    syncWriter: 'ccof sync entitlement writer'
    reconcilerWriter: 'ccof reconciler budget writer'
    projectWriter: 'ccof onboarding project writer'
  }
  identities: { sync: 'ccofqs-sync-id', reconciler: 'ccofqs-reconciler-id' }
  runnerVm: 'ccofqs-runner'
  apps: {
    resolver: { functionApp: 'ccofqs-resolver-func', plan: 'ccofqs-resolver-plan', storageAccount: 'ccofqsresolverstor', deploymentContainer: 'app-package-resolver', storagePrivateEndpoint: 'ccofqs-pe-resolver-storage', appInsights: 'ccofqs-resolver-ai' }
    sync: { functionApp: 'ccofqs-sync-func', plan: 'ccofqs-sync-plan', storageAccount: 'ccofqssyncstor', deploymentContainer: 'app-package-sync', storagePrivateEndpoint: 'ccofqs-pe-sync-storage', appInsights: 'ccofqs-sync-ai' }
    // The reconciler logs through a diagnostic setting, not Application Insights (WP-REC).
    reconciler: { functionApp: 'ccofqs-reconciler-func', plan: 'ccofqs-reconciler-plan', storageAccount: 'ccofqsrecstor', deploymentContainer: 'app-package-reconciler', storagePrivateEndpoint: 'ccofqs-pe-reconciler-storage' }
  }
}

// ---- 3. The EXISTING API Management (referenced, never changed); it must have a system-assigned identity ----
param apim = {
  name: 'REPLACE-existing-apim-name'
  subscriptionId: 'REPLACE-subscription-id'
  resourceGroup: 'REPLACE-apim-resource-group'
  apiId: 'claude-messages-qs'
  apiPath: 'anthropic-qs'
  apiDisplayName: 'Claude Messages (quick-start)'
}

// ---- 4. Network: create a VNet, or mode 'existing' with existing subnet and private DNS zone ids ----
param network = {
  mode: 'create'
  create: {
    vnetName: 'ccofqs-vnet'
    addressSpace: '10.63.0.0/16'
    apimNsgName: 'ccofqs-nsg-apim'
    subnets: {
      apim: { name: 'snet-apim', prefix: '10.63.1.0/24' }
      privateEndpoints: { name: 'snet-private-endpoints', prefix: '10.63.2.0/24' }
      functions: { name: 'snet-functions', prefix: '10.63.3.0/24' }
      // runner: { name: 'snet-runner', prefix: '10.63.4.0/27' }   only with runner.enabled true
    }
  }
  // existing: { privateEndpointSubnetId: '', functionsSubnetId: '', runnerSubnetId: '', privateDnsZoneIds: { cosmos: '', blob: '' } }
}

// ---- 5. Prerequisites made by the Entra administrator (docs/QUICKSTART.md, phase 1) ----
param registrations = {
  gatewayApi: { appId: 'REPLACE-gateway-api-app-id', scope: 'access_as_user', accessTokenVersion: 1 }
  developerSignIn: { appId: 'REPLACE-developer-sign-in-client-id' }
  resolverApi: { appId: 'REPLACE-resolver-api-app-id' }
}

// The ALREADY-CREATED Entra groups, one per project and classification (at least three).
// tokenLimits: tokens per minute and quota per person and per group; admission: calls per person.
param groups = [
  {
    groupId: '11111111-1111-1111-1111-111111111111'
    projectId: 'CCOFQS01'
    classification: 'STD'
    displayName: 'Claude quick-start standard'
    modelAllowList: ['claude-haiku-4-5', 'claude-sonnet-5']
    tokenLimits: {
      person: { tokensPerMinute: 1000000, tokenQuota: 500000, tokenQuotaPeriod: 'Daily' }
      group: { tokensPerMinute: null, tokenQuota: 2000000, tokenQuotaPeriod: 'Daily' }
    }
    personBudget: { amount: 25000, currency: 'CCU', period: 'monthly' }
    aggregateBudget: { amount: 2000000, currency: 'CCU', period: 'monthly' }
    aggregateMode: 'strict'
    onboardingMode: 'block'
  }
  {
    groupId: '22222222-2222-2222-2222-222222222222'
    projectId: 'CCOFQS01'
    classification: 'PRM'
    displayName: 'Claude quick-start premium'
    modelAllowList: ['claude-haiku-4-5', 'claude-sonnet-5', 'claude-opus-5', 'claude-opus-5-5']
    tokenLimits: {
      person: { tokensPerMinute: 1000000, tokenQuota: 2000000, tokenQuotaPeriod: 'Daily' }
      group: { tokensPerMinute: null, tokenQuota: 5000000, tokenQuotaPeriod: 'Daily' }
    }
    personBudget: { amount: 100000, currency: 'CCU', period: 'monthly' }
    aggregateBudget: { amount: 1500000, currency: 'CCU', period: 'monthly' }
    aggregateMode: 'notify'
    onboardingMode: 'warn'
  }
  {
    groupId: '33333333-3333-3333-3333-333333333333'
    projectId: 'CCOFQS02'
    classification: 'STD'
    displayName: 'Claude quick-start second project'
    modelAllowList: ['claude-haiku-4-5', 'claude-sonnet-5']
    tokenLimits: {
      person: { tokensPerMinute: 1000000, tokenQuota: 500000, tokenQuotaPeriod: 'Daily' }
      group: { tokensPerMinute: null, tokenQuota: 2000000, tokenQuotaPeriod: 'Daily' }
    }
    personBudget: { amount: 25000, currency: 'CCU', period: 'monthly' }
    aggregateBudget: null
    aggregateMode: 'notify'
    onboardingMode: 'warn'
  }
]

// ---- 6. Foundry backends, each reached with the APIM's managed identity (any subscription) ----
// assignCognitiveServicesUser: false when stage D3 (or anyone) already granted the APIM identity
// Cognitive Services User on that account; ARM refuses a duplicate (RoleAssignmentExists).
param backends = [
  {
    id: 'foundry-contosohub-qs'
    subscriptionId: 'REPLACE-subscription-id'
    resourceGroup: 'REPLACE-foundry-resource-group'
    accountName: 'REPLACE-foundry-account-name'
    url: 'https://REPLACE-foundry-account-name.services.ai.azure.com/anthropic'
    resource: 'https://cognitiveservices.azure.com'
    deploymentInferenceGeo: { 'claude-opus-5': 'global', 'claude-sonnet-5': 'global', 'claude-opus-5-5': 'global', 'claude-haiku-4-5': 'global' }
    assignCognitiveServicesUser: true
  }
]

// ---- 7. Sizing ----
param cosmos = { capacityMode: 'serverless', autoscaleMaxThroughput: 1000, zoneRedundant: false }
param functions = {
  resolver: { alwaysReady: 0, maximumInstanceCount: 40, instanceMemoryMB: 2048 }
  sync: { alwaysReady: 0, maximumInstanceCount: 40, instanceMemoryMB: 2048 }
  reconciler: { alwaysReady: 0, maximumInstanceCount: 40, instanceMemoryMB: 2048 }
}
param storageSku = 'Standard_LRS'
param logRetentionDays = 31
param enableAlerts = false
// runner.enabled false (the default): no runner VM. Only sync.mode 'delegated-snapshot' needs it; then
// { enabled: true, vmSize: 'Standard_D2as_v7', adminUsername: 'ccofadmin', sshPublicKey: '<public key>' }
// with a runner subnet in the network parameter.
param runner = { enabled: false }

// ---- 8. Application behaviour (the D2 answers sections) ----
param resolver = { budgetEnforcement: 'token-limits-only', cosmosRequestTimeoutMs: 2000, cosmosRetryAttempts: 2, cosmosRetryMaxWaitSeconds: 2, requestDeadlineMs: 4000 }
// mode: application-permission (needs the post-deployment Graph grant) or delegated-snapshot (docs/SYNC.md).
param sync = {
  mode: 'application-permission'
  schedule: '0 */1 * * * *'
  leaseSeconds: 300
  maxRemovalsPerRun: 5
  maxRemovalFraction: '0.1'
  memberTypes: 'user'
  graphMaxRetries: 3
  graphMaxRetryAfterSeconds: 30
  graphTimeoutSeconds: 30
  writeMode: 'apply'
}
// Set to true after Grant-SyncGraphPermissions.ps1 verified the permissions, then run
// Deploy-Quickstart.ps1 -Only 3 (the template alone writes the timer setting).
param syncTimerEnabled = false
param reconciler = { timerEnabled: false, schedule: '0 */2 * * * *', validitySeconds: 600, leaseSeconds: 300, ledgerTimeoutSeconds: 60, ledgerMaxRows: 100000, maxStates: 10000, writeConcurrency: 8, logAnalyticsEndpoint: 'https://api.loganalytics.io' }
param budgetState = { graceSeconds: 900, hardLimitSeconds: 3600 }

// ---- 9. Gateway policy inputs (infra/gateway/gateway-config.schema.json) ----
param gateway = {
  configurationId: 'ccofqs-gateway-1'
  admission: {
    perPerson: { calls: 120, renewalPeriodSeconds: 60 }
    resolverMisses: { calls: 200, renewalPeriodSeconds: 1, maxConcurrent: 100 }
  }
  resolverTimeoutSeconds: 10
  projectHeaderName: 'x-ccof-project'
  keyVersion: 1
  entitlementCache: { cachingType: 'internal', allowTtlSeconds: 120, refusalTtlSeconds: 30, lastKnownGoodGraceSeconds: 3600, refreshBackoffSeconds: 30, unavailableRetryAfterSeconds: 5 }
  tokenLimits: {
    estimatePromptTokens: false
    headers: {
      personRemainingQuota: 'x-ccof-person-quota-remaining'
      personRemainingTokens: 'x-ccof-person-tokens-remaining'
      groupRemainingQuota: 'x-ccof-group-quota-remaining'
      groupRemainingTokens: 'x-ccof-group-tokens-remaining'
      tokensConsumed: 'x-ccof-tokens-consumed'
    }
  }
  defaultAnthropicVersion: '2023-06-01'
}

// ---- 10. Rate card and workbook ----
param rateCard = { path: '../../config/rate-card.json', contractSchedulePath: '../../config/contract-schedule.json' }
param workbook = {
  // A GUID: the workbook resource name.
  resourceName: '5d0b7e43-6f2e-4b8e-9a51-0c6a2f3d9b11'
  displayName: 'Claude gateway chargeback (quick-start)'
  readerPrincipalIds: []
  settings: { defaultProjectId: '*', maxRows: 1000, topUsers: 25, maxQueryDays: 62, budgetLookbackDays: 31 }
}
