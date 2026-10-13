// Quick-start parameters (ADR-0024, Proposed). EVERY configuration value is here; docs/QUICKSTART.md
// explains each one. The values below are the Validation validation shape (config/answers/Validation-shape-a.json)
// with placeholder group ids: replace every value marked REPLACE before a live run.
// Deploy-Quickstart.ps1 reads this file (az bicep build-params), adds the values it computes
// (policyXml, workbookContent, apimIdentityAppId) and deploys main.bicep. Bicep has no decimal
// numbers, so fractions are strings.
using 'main.bicep'

// ---- 1. Tenant, subscription, resource group (the wrapper reads these three; Bicep uses tenantId) ----
param tenantId = 'REPLACE-00000000-0000-4000-8000-000000010001'
// subscriptionId REPLACE-00000000-0000-4000-8000-000000001000 and resource group sample-qs-rg: see quickstart below.
param location = 'eastus2'
param tags = { workload: 'claude-code-on-foundry', environment: 'quickstart' }

// ---- 2. Names of every resource the quick-start creates ----
param names = {
  deploymentPrefix: 'sampleqs'
  // Wrapper: target subscription and resource group, and whether step 3 may create the group.
  subscriptionId: 'REPLACE-00000000-0000-4000-8000-000000001000'
  resourceGroup: 'sample-qs-rg'
  resourceGroupMode: 'create'
  logAnalyticsWorkspace: 'sampleqs-law'
  cosmosAccount: 'sampleqs-cosmos'
  cosmosDatabase: 'ccof'
  cosmosPrivateEndpoint: 'sampleqs-pe-cosmos'
  cosmosRoles: {
    syncWriter: 'ccof sync entitlement writer'
    reconcilerWriter: 'ccof reconciler budget writer'
    projectWriter: 'ccof onboarding project writer'
  }
  identities: { sync: 'sampleqs-sync-id', reconciler: 'sampleqs-reconciler-id' }
  runnerVm: 'sampleqs-runner'
  apps: {
    resolver: { functionApp: 'sampleqs-resolver-func', plan: 'sampleqs-resolver-plan', storageAccount: 'sampleqsresolverstor', deploymentContainer: 'app-package-resolver', storagePrivateEndpoint: 'sampleqs-pe-resolver-storage', appInsights: 'sampleqs-resolver-ai' }
    sync: { functionApp: 'sampleqs-sync-func', plan: 'sampleqs-sync-plan', storageAccount: 'sampleqssyncstor', deploymentContainer: 'app-package-sync', storagePrivateEndpoint: 'sampleqs-pe-sync-storage', appInsights: 'sampleqs-sync-ai' }
    // The reconciler logs through a diagnostic setting, not Application Insights (WP-REC).
    reconciler: { functionApp: 'sampleqs-reconciler-func', plan: 'sampleqs-reconciler-plan', storageAccount: 'sampleqsrecstor', deploymentContainer: 'app-package-reconciler', storagePrivateEndpoint: 'sampleqs-pe-reconciler-storage' }
  }
}

// ---- 3. The EXISTING API Management (referenced, never changed); it must have a system-assigned identity ----
param apim = {
  name: 'sample-core-apim'
  subscriptionId: 'REPLACE-00000000-0000-4000-8000-000000001000'
  resourceGroup: 'sample-core-core-rg'
  apiId: 'claude-messages-qs'
  apiPath: 'anthropic-qs'
  apiDisplayName: 'Claude Messages (quick-start)'
}

// ---- 4. Network: create a VNet, or mode 'existing' with existing subnet and private DNS zone ids ----
param network = {
  mode: 'create'
  create: {
    vnetName: 'sampleqs-vnet'
    addressSpace: '10.63.0.0/16'
    apimNsgName: 'sampleqs-nsg-apim'
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
var developerGatewayAppId = 'REPLACE-developer-gateway-app-id'
param registrations = {
  gatewayApi: { appId: developerGatewayAppId, scope: 'access_as_user', accessTokenVersion: 2 }
  developerSignIn: { appId: developerGatewayAppId }
  resolverApi: { appId: 'REPLACE-resolver-api-app-id' }
}

// The ALREADY-CREATED Entra groups, one per project and classification (at least three).
// familyPolicy retains aggregate limits unchanged; family limits are additional ceilings.
// Removing a family revokes admission; null limits do not. Explicit backendId must agree per project.
// Fable/Mythos are CYB-only and require independently established real deployment IDs (none supplied).
param groups = [
  {
    groupId: 'REPLACE-11111111-1111-1111-1111-111111111111'
    projectId: 'sampleqs01'
    classification: 'STD'
    displayName: 'Claude quick-start standard'
    familyPolicy: {
      aggregateLimits: {
      person: { tokensPerMinute: 1000000, tokenQuota: 500000, tokenQuotaPeriod: 'Daily' }
      group: { tokensPerMinute: null, tokenQuota: 2000000, tokenQuotaPeriod: 'Daily' }
      }
      families: {
        haiku: { models: ['claude-haiku-4-5'], person: { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null }, group: { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null } }
        sonnet: { models: ['claude-sonnet-5'], person: { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null }, group: { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null } }
      }
    }
    personBudget: { amount: 25000, currency: 'CCU', period: 'monthly' }
    aggregateBudget: { amount: 2000000, currency: 'CCU', period: 'monthly' }
    aggregateMode: 'strict'
    onboardingMode: 'block'
  }
  {
    groupId: 'REPLACE-22222222-2222-2222-2222-222222222222'
    projectId: 'sampleqs01'
    classification: 'PRM'
    displayName: 'Claude quick-start premium'
    familyPolicy: {
      aggregateLimits: {
      person: { tokensPerMinute: 1000000, tokenQuota: 2000000, tokenQuotaPeriod: 'Daily' }
      group: { tokensPerMinute: null, tokenQuota: 5000000, tokenQuotaPeriod: 'Daily' }
      }
      families: {
        haiku: { models: ['claude-haiku-4-5'], person: { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null }, group: { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null } }
        sonnet: { models: ['claude-sonnet-5'], person: { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null }, group: { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null } }
        opus: { models: ['claude-opus-5', 'claude-opus-5-5'], person: { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null }, group: { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null } }
      }
    }
    personBudget: { amount: 100000, currency: 'CCU', period: 'monthly' }
    aggregateBudget: { amount: 1500000, currency: 'CCU', period: 'monthly' }
    aggregateMode: 'notify'
    onboardingMode: 'warn'
  }
  {
    groupId: 'REPLACE-33333333-3333-3333-3333-333333333333'
    projectId: 'sampleqs02'
    classification: 'STD'
    displayName: 'Claude quick-start second project'
    familyPolicy: {
      aggregateLimits: {
      person: { tokensPerMinute: 1000000, tokenQuota: 500000, tokenQuotaPeriod: 'Daily' }
      group: { tokensPerMinute: null, tokenQuota: 2000000, tokenQuotaPeriod: 'Daily' }
      }
      families: {
        haiku: { models: ['claude-haiku-4-5'], person: { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null }, group: { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null } }
        sonnet: { models: ['claude-sonnet-5'], person: { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null }, group: { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null } }
      }
    }
    personBudget: { amount: 25000, currency: 'CCU', period: 'monthly' }
    aggregateBudget: null
    aggregateMode: 'notify'
    onboardingMode: 'warn'
  }
]

// Explicit project/classification and exact admitted aliases for onboarding.json / client-config.json.
param client = {
  projectId: 'sampleqs01'
  classification: 'PRM'
  models: { default: 'claude-sonnet-5', sonnet: 'claude-sonnet-5', haiku: 'claude-haiku-4-5', opus: 'claude-opus-5' }
}

// ---- 6. Foundry backends, each reached with the APIM's managed identity (any subscription) ----
// assignCognitiveServicesUser: false when stage D3 (or anyone) already granted the APIM identity
// Cognitive Services User on that account; ARM refuses a duplicate (RoleAssignmentExists).
param backends = [
  {
    id: 'foundry-sample-hub-qs'
    subscriptionId: 'REPLACE-00000000-0000-4000-8000-000000001000'
    resourceGroup: 'rg-sample-hub'
    accountName: 'ai-sample-hub530569751908'
    url: 'https://example-ai-sample-hub530569751908.services.ai.azure.com/anthropic'
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
  configurationId: 'sampleqs-gateway-1'
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
  resourceName: 'REPLACE-00000000-0000-4000-8000-000000010000'
  displayName: 'Claude gateway chargeback (quick-start)'
  readerPrincipalIds: []
  settings: { defaultProjectId: '*', maxRows: 1000, topUsers: 25, maxQueryDays: 62, budgetLookbackDays: 31 }
}
