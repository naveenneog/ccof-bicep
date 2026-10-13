// =====================================================================================================
// CUSTOMER FORM: quick-start parameters (docs/QUICKSTART.md explains each one).
// Do not fill this file. Copy it to the git-ignored name and fill the copy (README, "Deploy from Azure
// Cloud Shell"):
//   cp infra/quickstart/customer-form.bicepparam infra/quickstart/.env.customer.bicepparam
// Every value that says REPLACE is a customer decision; the filled copy is the deployment's whole
// configuration (from the repository root):
//   pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -ParametersPath infra/quickstart/.env.customer.bicepparam -WhatIfOnly
// Step 1 of that script refuses while any REPLACE value is left, and reads the APIM, the three app
// registrations and the groups back before anything is created. The filled copy holds the customer's
// tenant, subscription and object ids: keep it out of git and out of public repositories.
// Sections 1-5: the customer's decisions. Section 6: defaults from the tested sample.
// =====================================================================================================
using 'main.bicep'

// ---- 1. CONTEXT ----------------------------------------------------------------------------------
// Customer Directory (tenant) ID: Microsoft Entra admin center > Overview.
param tenantId = 'REPLACE-tenant-id'
// Region of every new resource; it must support Flex Consumption:
//   az functionapp list-flexconsumption-locations -o table
param location = 'REPLACE-region'
// Subscription and resource group of the quick-start resources (Cosmos, Function Apps, workspace).
// The resource group exists already (resourceGroupMode 'existing' below).
var subscriptionId = 'REPLACE-subscription-id'
var resourceGroupName = 'REPLACE-resource-group'
// Name prefix: 3-12 lowercase letters and digits, no hyphen. Storage account names are the prefix
// plus up to 12 characters (24 at most, lowercase letters and digits only); Cosmos, Function App and
// storage names must be globally unique.
var prefix = 'REPLACE-prefix'

param tags = { workload: 'claude-code-on-foundry', environment: 'quickstart' }

param names = {
  deploymentPrefix: prefix
  subscriptionId: subscriptionId
  resourceGroup: resourceGroupName
  // 'existing': the subscription Owner created the group and assigned the deployer's roles on it.
  // 'create': step 3 creates the group (needs Contributor on the subscription).
  resourceGroupMode: 'existing'
  logAnalyticsWorkspace: '${prefix}-law'
  cosmosAccount: '${prefix}-cosmos'
  cosmosDatabase: 'ccof'
  cosmosPrivateEndpoint: '${prefix}-pe-cosmos'
  cosmosRoles: {
    syncWriter: 'ccof sync entitlement writer'
    reconcilerWriter: 'ccof reconciler budget writer'
    projectWriter: 'ccof onboarding project writer'
  }
  identities: { sync: '${prefix}-sync-id', reconciler: '${prefix}-reconciler-id' }
  runnerVm: '${prefix}-runner'
  apps: {
    resolver: { functionApp: '${prefix}-resolver-func', plan: '${prefix}-resolver-plan', storageAccount: '${prefix}resolverstor', deploymentContainer: 'app-package-resolver', storagePrivateEndpoint: '${prefix}-pe-resolver-storage', appInsights: '${prefix}-resolver-ai' }
    sync: { functionApp: '${prefix}-sync-func', plan: '${prefix}-sync-plan', storageAccount: '${prefix}syncstor', deploymentContainer: 'app-package-sync', storagePrivateEndpoint: '${prefix}-pe-sync-storage', appInsights: '${prefix}-sync-ai' }
    // The reconciler logs through a diagnostic setting, not Application Insights.
    reconciler: { functionApp: '${prefix}-reconciler-func', plan: '${prefix}-reconciler-plan', storageAccount: '${prefix}recstor', deploymentContainer: 'app-package-reconciler', storagePrivateEndpoint: '${prefix}-pe-reconciler-storage' }
  }
}

// ---- 2. NETWORK: every address range or id comes from the customer --------------------------------
// The VNet must be in the subscription and region of section 1: a private endpoint must be in its
// VNet's subscription and region (https://learn.microsoft.com/azure/private-link/private-endpoint-overview).
// Option A (active below): a NEW VNet from the customer's address ranges, with its own private DNS
// zones. The tested sample used a /16 address space, /24 private endpoints and /24 functions;
// smaller ranges are untested. The APIM subnet is created, but the quick-start does not attach the
// APIM to it. Nothing is peered to the customer's network. No runner subnet: the form creates no VM.
// Option B (commented out further down): subnets the customer's network team created in their own
// VNet, and their private DNS zones. To use it, delete option A and uncomment option B. Option B has
// not been deployed in a test yet.
param network = {
  mode: 'create'
  create: {
    vnetName: '${prefix}-vnet'
    addressSpace: 'REPLACE-address-space'
    apimNsgName: '${prefix}-nsg-apim'
    subnets: {
      apim: { name: 'snet-apim', prefix: 'REPLACE-apim-subnet-range' }
      privateEndpoints: { name: 'snet-private-endpoints', prefix: 'REPLACE-private-endpoint-subnet-range' }
      functions: { name: 'snet-functions', prefix: 'REPLACE-functions-subnet-range' }
    }
  }
}
// Option B. The functions subnet must be delegated to Microsoft.App/environments. The two zones must
// resolve from that VNet (linked to it, or through the customer's DNS servers). If the customer routes
// the VNet's outbound traffic through a firewall, it must allow the apps' outbound calls: Microsoft
// Graph (sync), the Log Analytics query endpoint (reconciler), Application Insights ingestion.
// param network = {
//   mode: 'existing'
//   existing: {
//     privateEndpointSubnetId: 'REPLACE-/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<private endpoint subnet>'
//     functionsSubnetId: 'REPLACE-/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<functions subnet>'
//     privateDnsZoneIds: {
//       cosmos: 'REPLACE-/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/privateDnsZones/privatelink.documents.azure.com'
//       blob: 'REPLACE-/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net'
//     }
//   }
// }

// ---- 3. API MANAGEMENT AND FOUNDRY ------------------------------------------------------------------
// The EXISTING API Management instance. Its system-assigned managed identity must be On (portal: the
// APIM > Security > Managed identities; not `az apim update`, which removes it). apiId and apiPath
// must not be in use in that APIM yet.
param apim = {
  name: 'REPLACE-apim-name'
  subscriptionId: subscriptionId
  resourceGroup: 'REPLACE-apim-resource-group'
  apiId: 'claude-messages'
  apiPath: 'anthropic'
  apiDisplayName: 'Claude Messages'
}

// One entry per Foundry account; APIM calls it with its managed identity. Replace subscriptionId when
// the account is in another subscription. url: https://<the account's custom subdomain>.services.ai.azure.com/anthropic
// deploymentInferenceGeo: one key per Foundry DEPLOYMENT NAME, exactly as listed by
//   az cognitiveservices account deployment list -g <resource group> -n <account> -o table
// with the value 'global' or 'us'. Step 8 writes the developers' client configuration with the names
// claude-sonnet-5, claude-opus-5 and claude-haiku-4-5 (Deploy-Quickstart.ps1, Invoke-QsClient): name
// the Foundry deployments so, or edit the generated client-config.json.
// assignCognitiveServicesUser: false when the APIM identity already holds Cognitive Services User on
// the account (ARM refuses a duplicate assignment).
var foundryAccount = 'REPLACE-foundry-account-name'
param backends = [
  {
    id: 'foundry-1'
    subscriptionId: subscriptionId
    resourceGroup: 'REPLACE-foundry-resource-group'
    accountName: foundryAccount
    url: 'https://${foundryAccount}.services.ai.azure.com/anthropic'
    resource: 'https://cognitiveservices.azure.com'
    deploymentInferenceGeo: { 'claude-opus-5': 'global', 'claude-sonnet-5': 'global', 'claude-opus-5-5': 'global', 'claude-haiku-4-5': 'global' }
    assignCognitiveServicesUser: true
  }
]

// ---- 4. ENTRA (created by the customer's Entra administrator before the deployment) -----------------
// Application (client) IDs: Entra admin center > App registrations > the app > Overview.
// Gateway API: scope access_as_user exposed; manifest requestedAccessTokenVersion 1.
// Developer Sign-in: Allow public client flows Yes; redirect URIs http://localhost and
//   https://login.microsoftonline.com/common/oauth2/nativeclient; delegated permission access_as_user.
// Resolver API: Application ID URI api://<its appId>; manifest requestedAccessTokenVersion 2.
param registrations = {
  gatewayApi: { appId: 'REPLACE-gateway-api-app-id', scope: 'access_as_user', accessTokenVersion: 1 }
  developerSignIn: { appId: 'REPLACE-developer-sign-in-app-id' }
  resolverApi: { appId: 'REPLACE-resolver-api-app-id' }
}

// One entry per existing Entra security group (Entra admin center > Groups > the group > Object ID).
// projectId and classification: letters, digits, '-' and '_' (up to 80 characters). One project can
// have several classifications, each with its own group; the sample below has two classifications of
// project 1 and one of project 2. modelAllowList: deployment names from section 3.
// tokenLimits: tokens per minute and quota, per person and per group. Budgets (CCU) are recorded but
// not enforced while resolver.budgetEnforcement is 'token-limits-only' (section 6).
var project1 = 'REPLACE-project-1-id'
var project2 = 'REPLACE-project-2-id'
param groups = [
  {
    groupId: 'REPLACE-group-1-object-id'
    projectId: project1
    classification: 'STD'
    displayName: 'Claude project 1 standard'
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
    groupId: 'REPLACE-group-2-object-id'
    projectId: project1
    classification: 'PRM'
    displayName: 'Claude project 1 premium'
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
    groupId: 'REPLACE-group-3-object-id'
    projectId: project2
    classification: 'STD'
    displayName: 'Claude project 2 standard'
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

// ---- 5. SIZING ----------------------------------------------------------------------------------
param cosmos = { capacityMode: 'serverless', autoscaleMaxThroughput: 1000, zoneRedundant: false }
param functions = {
  resolver: { alwaysReady: 0, maximumInstanceCount: 40, instanceMemoryMB: 2048 }
  sync: { alwaysReady: 0, maximumInstanceCount: 40, instanceMemoryMB: 2048 }
  reconciler: { alwaysReady: 0, maximumInstanceCount: 40, instanceMemoryMB: 2048 }
}
param storageSku = 'Standard_LRS'
param logRetentionDays = 31
// No VM: runner.enabled false (the default) creates no runner VM, so a tenant whose policy denies
// marketplace VM images deploys everything else. Only sync.mode 'delegated-snapshot' needs the
// runner; this form uses application-permission (section 6).
param runner = { enabled: false }

// ---- 6. DEFAULTS (the tested sample; no customer value needed) ----------------------------------
param enableAlerts = false
param resolver = { budgetEnforcement: 'token-limits-only', cosmosRequestTimeoutMs: 2000, cosmosRetryAttempts: 2, cosmosRetryMaxWaitSeconds: 2, requestDeadlineMs: 4000 }
// application-permission: the customer's Privileged Role Administrator grants Microsoft Graph
// permissions after the deployment (Grant-SyncGraphPermissions.ps1). delegated-snapshot is not usable
// from this repository (README, Known limits).
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
// Set to true after the Graph grant, then run Deploy-Quickstart.ps1 -Only 3.
param syncTimerEnabled = false
param reconciler = { timerEnabled: false, schedule: '0 */2 * * * *', validitySeconds: 600, leaseSeconds: 300, ledgerTimeoutSeconds: 60, ledgerMaxRows: 100000, maxStates: 10000, writeConcurrency: 8, logAnalyticsEndpoint: 'https://api.loganalytics.io' }
param budgetState = { graceSeconds: 900, hardLimitSeconds: 3600 }
param gateway = {
  configurationId: '${prefix}-gateway-1'
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
param rateCard = { path: '../../config/rate-card.json', contractSchedulePath: '../../config/contract-schedule.json' }
// readerPrincipalIds: optional object ids of the people or groups who open the chargeback workbook.
// resourceName: a GUID, the workbook's resource name (any new GUID works: New-Guid in PowerShell).
param workbook = {
  resourceName: '5d0b7e43-6f2e-4b8e-9a51-0c6a2f3d9b11'
  displayName: 'Claude gateway chargeback'
  readerPrincipalIds: []
  settings: { defaultProjectId: '*', maxRows: 1000, topUsers: 25, maxQueryDays: 62, budgetLookbackDays: 31 }
}
