// Quick-start for ONE administrator who holds every Azure role (ADR-0024, Proposed): the whole core
// in one deployment, every value from main.bicepparam. It does not replace the checkpointed stages
// of ADR-0019; docs/QUICKSTART.md says what stays with them. Run it through Deploy-Quickstart.ps1
// (step 3), which first renders the gateway policy and builds the workbook (step 2).
// Reused modules: infra/prereqs (network, Log Analytics, identities, Cosmos account, Flex apps),
// infra/poc/phase4-telemetry.bicep (WP-TEL), infra/workbook (WP-WB). New modules: ./modules.
// Entra objects (app registrations, groups) are prerequisites and Graph application permissions are
// post-deployment (infra/quickstart/Grant-SyncGraphPermissions.ps1): neither is in this template.

targetScope = 'resourceGroup'

@description('Entra tenant id of the app registrations, groups and identities.')
param tenantId string

@description('Region of every new resource.')
param location string = resourceGroup().location

param tags object

@description('Every resource name (see main.bicepparam).')
param names object

@description('The EXISTING API Management: name, subscriptionId, resourceGroup, apiId, apiPath, apiDisplayName.')
param apim object

@description('mode create (vnetName, addressSpace, apimNsgName, subnets) or existing (subnet and private DNS zone ids).')
param network object

@description('Entra groups: groupId, projectId, classification, familyPolicy, budgets; optional backendId must agree per project and is required with multiple backends. Seeded by the wrapper (step 5).')
param groups array

@description('Step 8 client export: explicit projectId, classification and models {default, opus, sonnet, haiku}; each model must be admitted on the selected project backend. Empty refuses client export.')
param client object = {}

@description('Prerequisite app registrations: gatewayApi { appId, scope }, developerSignIn { appId }, resolverApi { appId }.')
param registrations object

@description('Foundry backends: id, subscriptionId, resourceGroup, accountName, url, deploymentInferenceGeo, assignCognitiveServicesUser.')
param backends array

@description('serverless or provisioned-autoscale; autoscaleMaxThroughput; zoneRedundant.')
param cosmos object

@description('Flex Consumption sizing per app: maximumInstanceCount, instanceMemoryMB, alwaysReady.')
param functions object

param storageSku string = 'Standard_LRS'
param logRetentionDays int = 31

@description('D2 answers resolver section.')
param resolver object

@description('D2 answers sync section plus the availability sync values (schedule, leaseSeconds, ...).')
param sync object

@description('D2 answers reconciler section.')
param reconciler object

param budgetState object = { graceSeconds: 900, hardLimitSeconds: 3600 }

@description('Gateway configuration values for render.ts (admission, token limit headers, cache).')
param gateway object

param rateCard object
@description('The private runner VM: enabled (default false) creates it; only the delegated-snapshot sync mode needs it. vmSize, adminUsername and sshPublicKey are read only when enabled.')
param runner object
param workbook object
param enableAlerts bool = false

@description('Set to true after Grant-SyncGraphPermissions.ps1 succeeded (application-permission mode).')
param syncTimerEnabled bool = false

@description('Written by the wrapper (step 2): the policy rendered by infra/gateway/render.ts. Empty: the API answers 503.')
param policyXml string = ''

@description('Written by step 2: analytics/workbooks/chargeback.ts output. Empty: preserve any existing workbook; never deploy an empty shell over it.')
param workbookContent object = {}

param workbookContentTags object = {}

@description('Written by the wrapper (step 1): appId of the APIM system-assigned identity, read through Graph.')
param apimIdentityAppId string = ''

var prefix = names.deploymentPrefix
var createNetwork = network.mode == 'create'
// Off unless runner.enabled is true, so a tenant whose policy denies marketplace VM images can deploy
// everything else; without the runner, its subnet is optional in both network modes.
var runnerEnabled = runner.?enabled ?? false
var appKeys = ['resolver', 'sync', 'reconciler']
var alwaysReadyNames = { resolver: 'http', sync: 'function:syncEntitlement', reconciler: 'function:reconcileBudgets' }

resource apimService 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apim.name
  scope: resourceGroup(apim.subscriptionId, apim.resourceGroup)
}

var apimPrincipalId = apimService.identity.principalId

module net '../prereqs/network.bicep' = if (createNetwork) {
  name: '${prefix}-qs-network'
  params: {
    location: location
    tags: tags
    vnetName: network.create.vnetName
    addressSpace: network.create.addressSpace
    apimNsgName: network.create.apimNsgName
    // A null runner subnet makes infra/prereqs/network.bicep create none.
    subnets: union(network.create.subnets, { runner: network.create.subnets.?runner })
  }
}

var subnetIds = createNetwork ? {
  privateEndpoints: net!.outputs.privateEndpointSubnetId
  functions: net!.outputs.functionsSubnetId
  runner: net!.outputs.runnerSubnetId
  cosmosDnsZone: net!.outputs.cosmosDnsZoneId
  blobDnsZone: net!.outputs.blobDnsZoneId
} : {
  privateEndpoints: network.existing.privateEndpointSubnetId
  functions: network.existing.functionsSubnetId
  runner: network.existing.?runnerSubnetId ?? ''
  cosmosDnsZone: network.existing.privateDnsZoneIds.cosmos
  blobDnsZone: network.existing.privateDnsZoneIds.blob
}

module workspace '../prereqs/log-analytics.bicep' = {
  name: '${prefix}-qs-workspace'
  params: { location: location, tags: tags, name: names.logAnalyticsWorkspace, retentionInDays: logRetentionDays }
}

module identities '../prereqs/identities.bicep' = {
  name: '${prefix}-qs-identities'
  params: { location: location, tags: tags, names: names.identities }
}

module cosmosAccount '../prereqs/cosmos-account.bicep' = {
  name: '${prefix}-qs-cosmos'
  params: {
    location: location
    tags: tags
    accountName: names.cosmosAccount
    capacityMode: cosmos.capacityMode
    zoneRedundant: cosmos.zoneRedundant
    privateEndpointName: names.cosmosPrivateEndpoint
    privateEndpointSubnetId: subnetIds.privateEndpoints
    cosmosPrivateDnsZoneId: subnetIds.cosmosDnsZone
  }
}

// One app at a time: the three apps join the same Functions subnet, and in parallel two of them failed
// with "Failed to acquire ServiceAssociationLinkLease" (Validation, 2026-10-13).
// batchSize(1) is sequential (https://learn.microsoft.com/azure/azure-resource-manager/bicep/loops#deploy-in-batches, retrieved 2026-10-13).
@batchSize(1)
module apps '../prereqs/function-app.bicep' = [for app in appKeys: {
  name: '${prefix}-qs-app-${app}'
  params: {
    location: location
    tags: tags
    functionAppName: names.apps[app].functionApp
    planName: names.apps[app].plan
    storageAccountName: names.apps[app].storageAccount
    storageSku: storageSku
    deploymentContainerName: names.apps[app].deploymentContainer
    storagePrivateEndpointName: names.apps[app].storagePrivateEndpoint
    privateEndpointSubnetId: subnetIds.privateEndpoints
    blobPrivateDnsZoneId: subnetIds.blobDnsZone
    integrationSubnetId: subnetIds.functions
    appInsightsName: names.apps[app].?appInsights ?? ''
    logAnalyticsWorkspaceId: workspace.outputs.id
    userAssignedIdentityId: app == 'resolver' ? '' : (app == 'sync' ? identities.outputs.syncId : identities.outputs.reconcilerId)
    alwaysReadyName: alwaysReadyNames[app]
    alwaysReadyInstanceCount: functions[app].alwaysReady
    maximumInstanceCount: functions[app].maximumInstanceCount
    instanceMemoryMB: functions[app].instanceMemoryMB
    zoneRedundant: false
  }
}]

module privateRunner 'modules/runner.bicep' = if (runnerEnabled) {
  name: '${prefix}-qs-runner'
  params: {
    location: location
    tags: tags
    vmName: names.runnerVm
    subnetId: subnetIds.runner
    vmSize: runner.?vmSize ?? 'Standard_D2as_v7'
    adminUsername: runner.?adminUsername ?? 'ccofadmin'
    sshPublicKey: runner.?sshPublicKey ?? ''
  }
}

var principals = {
  resolver: apps[0].outputs.systemPrincipalId
  sync: identities.outputs.syncPrincipalId
  reconciler: identities.outputs.reconcilerPrincipalId
  // Empty when the runner is off: cosmos-data.bicep and rbac.bicep then skip its assignments.
  runner: runnerEnabled ? privateRunner!.outputs.principalId : ''
}

module cosmosData 'modules/cosmos-data.bicep' = {
  name: '${prefix}-qs-cosmos-data'
  params: {
    accountName: names.cosmosAccount
    databaseName: names.cosmosDatabase
    capacityMode: cosmos.capacityMode
    autoscaleMaxThroughput: cosmos.autoscaleMaxThroughput
    roleNames: names.cosmosRoles
    principals: principals
    syncMode: sync.mode
  }
  dependsOn: [cosmosAccount]
}

module workbookFull '../workbook/main.bicep' = if (!empty(workbookContent)) {
  name: '${prefix}-qs-workbook'
  params: {
    workbookResourceName: workbook.resourceName
    workbookDisplayName: workbook.displayName
    location: location
    workspaceResourceId: workspace.outputs.id
    workbookContent: workbookContent
    contentTags: workbookContentTags
  }
}

module rbac 'modules/rbac.bicep' = {
  name: '${prefix}-qs-rbac'
  params: {
    names: names
    principals: principals
    workbookResourceName: workbook.resourceName
    workbookReaderPrincipalIds: workbook.readerPrincipalIds
  }
  dependsOn: [apps, cosmosAccount, workbookFull]
}

module gatewayApi 'modules/apim-api.bicep' = {
  name: '${prefix}-qs-apim-api'
  scope: resourceGroup(apim.subscriptionId, apim.resourceGroup)
  params: {
    apimName: apim.name
    apiId: apim.apiId
    apiPath: apim.apiPath
    apiDisplayName: apim.apiDisplayName
    backends: [for b in backends: { id: b.id, url: b.url }]
    policyXml: policyXml
  }
}

module foundryRoles 'modules/foundry-role.bicep' = [for b in backends: if (b.assignCognitiveServicesUser) {
  name: '${prefix}-qs-foundry-${b.id}'
  scope: resourceGroup(b.subscriptionId, b.resourceGroup)
  params: { accountName: b.accountName, principalId: apimPrincipalId, apimResourceId: apimService.id }
}]

module settings 'modules/app-settings.bicep' = {
  name: '${prefix}-qs-settings'
  params: {
    names: names
    tenantId: tenantId
    cosmosEndpoint: cosmosAccount.outputs.endpoint
    databaseName: names.cosmosDatabase
    syncClientId: identities.outputs.syncClientId
    reconcilerClientId: identities.outputs.reconcilerClientId
    // From the app modules' outputs: a reference() to the components in this template is read when a
    // fresh deployment starts, before the modules create them (ResourceNotFound, live run 2026-10-13).
    resolverAppInsightsConnection: apps[0].outputs.appInsightsConnectionString
    syncAppInsightsConnection: apps[1].outputs.appInsightsConnectionString
    workspaceCustomerId: workspace.outputs.customerId
    apimId: apimService.id
    resolver: resolver
    sync: sync
    reconciler: reconciler
    budgetState: budgetState
    syncTimerEnabled: syncTimerEnabled
    resolverApiAppId: registrations.resolverApi.appId
    apimIdentityAppId: apimIdentityAppId
    apimPrincipalId: apimPrincipalId
  }
  dependsOn: [apps, cosmosData, rbac]
}

module telemetry '../poc/phase4-telemetry.bicep' = {
  name: '${prefix}-qs-telemetry'
  params: {
    workspaceResourceId: workspace.outputs.id
    apimResourceId: apimService.id
    apiName: apim.apiId
    location: location
    functionAppResourceIds: [for (app, i) in appKeys: apps[i].outputs.functionAppId]
    enableAlerts: enableAlerts
  }
  dependsOn: [gatewayApi]
}

output gatewayUrl string = '${gatewayApi.outputs.gatewayUrl}/${apim.apiPath}'
output resolverHostName string = apps[0].outputs.hostName
output functionAppIds object = { resolver: apps[0].outputs.functionAppId, sync: apps[1].outputs.functionAppId, reconciler: apps[2].outputs.functionAppId }
output syncPrincipalId string = identities.outputs.syncPrincipalId
output runnerPrincipalId string = runnerEnabled ? privateRunner!.outputs.principalId : ''
output runnerVmId string = runnerEnabled ? privateRunner!.outputs.vmId : ''
output cosmosEndpoint string = cosmosAccount.outputs.endpoint
output cosmosAccountId string = cosmosAccount.outputs.id
output workspaceId string = workspace.outputs.id
output apimPrincipalId string = apimPrincipalId
output projectIds array = union(map(groups, g => g.projectId), [])
output clientSelection object = client
output registrationIds object = registrations
output rateCardPath string = rateCard.path
output gatewayConfigurationId string = gateway.configurationId
