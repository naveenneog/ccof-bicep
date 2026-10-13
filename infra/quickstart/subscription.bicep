// Quick-start (ADR-0024, Proposed): the subscription-scope entry used when the resource group does
// not exist yet. It creates the group and deploys main.bicep into it, so `az deployment sub what-if`
// can preview a run against a subscription that has no group yet (Learn, "Deploy resources to
// subscription", resource group plus module, retrieved 2026-10-13). `p` carries every main.bicep
// parameter: Deploy-Quickstart.ps1 builds it from main.bicepparam.

targetScope = 'subscription'

param resourceGroupName string
param location string

@description('Every main.bicep parameter, as built from main.bicepparam.')
param p object

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: p.tags
}

module core 'main.bicep' = {
  name: '${p.names.deploymentPrefix}-quickstart'
  scope: group
  params: {
    tenantId: p.tenantId
    location: location
    tags: p.tags
    names: p.names
    apim: p.apim
    network: p.network
    groups: p.groups
    registrations: p.registrations
    backends: p.backends
    cosmos: p.cosmos
    functions: p.functions
    storageSku: p.storageSku
    logRetentionDays: p.logRetentionDays
    resolver: p.resolver
    sync: p.sync
    reconciler: p.reconciler
    budgetState: p.budgetState
    gateway: p.gateway
    rateCard: p.rateCard
    runner: p.runner
    workbook: p.workbook
    enableAlerts: p.enableAlerts
    syncTimerEnabled: p.syncTimerEnabled
    policyXml: p.?policyXml ?? ''
    workbookContent: p.?workbookContent ?? {}
    workbookContentTags: p.?workbookContentTags ?? {}
    apimIdentityAppId: p.?apimIdentityAppId ?? ''
  }
}

output gatewayUrl string = core.outputs.gatewayUrl
output syncPrincipalId string = core.outputs.syncPrincipalId
