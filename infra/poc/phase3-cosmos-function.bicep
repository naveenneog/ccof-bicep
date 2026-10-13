// Phase 3 infrastructure: the Cosmos registry (matching what already exists live, for IaC parity -
// see infra/poc/create-cosmos-containers.ps1, run manually before this file existed) and the
// resolver Function App that reads it (src/resolver/function-app.ts, ADR-0003).
//
// COST NOTE, read before deploying: the Function App uses the Flex Consumption plan (FC1), which
// bills true pay-per-use (GB-seconds + executions) with NO fixed monthly floor, UNLESS
// alwaysReadyInstanceCount is set above 0 below (default 0 here - do not raise it without the
// owner's explicit cost sign-off, the same discipline this repo used for APIM's SKU and Multi-AZ
// decisions). Confirmed via Microsoft Learn ("Create and manage function apps in a Flex Consumption
// plan", ms.date 2026-09-08, retrieved 2026-10-09): "without specifying always ready instances, your
// app only incurs costs when actively executing functions." This is why Flex Consumption was chosen
// over the Premium EP1 plan (~$150/month fixed for one always-warm instance, Premium's own
// documented price) - VNet integration needs at least one of the two, and Flex Consumption gets it
// without the fixed floor.
//
// VNet integration is required, not optional: the Cosmos account has public network access enforced
// Disabled by this subscription's own Azure Policy (CosmosDB_PublicNetwork_Modify, confirmed live
// 2026-10-09, docs/STATUS.md Phase 3) - a Function App without VNet integration cannot reach it at
// all, the same block a developer's local machine hits running the integration test.
//
// DO NOT RUN until the owner has confirmed this is additive to infra/poc/main.bicep's existing VNet
// (sample-pilot-vnet) and resource group (sample-pilot-rg), and has seen this file's cost note.

targetScope = 'resourceGroup'

@description('Short prefix for every resource name, matching infra/poc/main.bicep\'s namePrefix.')
param namePrefix string

@description('Region. Matches the existing VNet/APIM/Cosmos region.')
param location string = 'eastus2'

@description('Name of the existing VNet from infra/poc/main.bicep to add the Functions subnet to.')
param existingVnetName string

@description('Address prefix for the new Functions VNet-integration subnet. Must not overlap infra/poc/main.bicep\'s existing 10.42.0.0/24, 10.42.1.0/24, 10.42.2.0/24.')
param functionsSubnetAddressPrefix string = '10.42.3.0/24'

@description('Always-ready Flex Consumption instances. 0 = true pay-per-use, no fixed monthly cost (see header comment). Do not raise without explicit owner cost sign-off.')
param alwaysReadyInstanceCount int = 0

@description('Existing Cosmos DB account name (already live - this declaration brings it under IaC without re-creating it; same name redeploys idempotently).')
param cosmosAccountName string = '${namePrefix}-cosmos'

@description('Cosmos SQL database name.')
param cosmosDatabaseName string = 'ccof'

var containerDefs = [
  { name: 'entitlement', partitionKeyPath: '/personId' }
  { name: 'projects', partitionKeyPath: '/projectId' }
  { name: 'subscriptionIndex', partitionKeyPath: '/subscriptionId' }
  { name: 'budgetState', partitionKeyPath: '/personId' }
  { name: 'aggregateBudgetState', partitionKeyPath: '/scopeId' }
]

// --- Cosmos DB: serverless, Entra RBAC only (disableLocalAuth forced true by this subscription's
// own policy regardless of what this template requests - confirmed live 2026-10-09) ---
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: cosmosAccountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [
      { locationName: location, failoverPriority: 0, isZoneRedundant: false }
    ]
    capabilities: [
      { name: 'EnableServerless' }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    disableLocalAuth: true
  }
}

resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = {
  parent: cosmosAccount
  name: cosmosDatabaseName
  properties: {
    resource: {
      id: cosmosDatabaseName
    }
  }
}

resource cosmosContainers 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = [
  for c in containerDefs: {
    parent: cosmosDatabase
    name: c.name
    properties: {
      resource: {
        id: c.name
        partitionKey: {
          paths: [c.partitionKeyPath]
          kind: 'Hash'
        }
      }
    }
  }
]

// --- Functions VNet-integration subnet: a standalone child resource, not a full VNet redeclare, so
// this file never risks dropping infra/poc/main.bicep's existing subnets (snet-appgw, snet-apim,
// snet-private-endpoints) if the two templates are ever applied out of order. ---
resource existingVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: existingVnetName
}

resource snetFunctions 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: existingVnet
  name: 'snet-functions'
  properties: {
    addressPrefix: functionsSubnetAddressPrefix
    delegations: [
      {
        // Microsoft.App/environments, NOT Microsoft.Web/serverFarms - confirmed live 2026-10-09:
        // a plausible-looking web search result claimed Microsoft.Web/serverFarms is correct for
        // Flex Consumption (true for classic Premium/Dedicated plans), but the actual ARM error
        // from attempting the deployment was explicit: "requires any of the following
        // delegation(s) [Microsoft.App/environments]" (service link name "legionservicelink" -
        // Flex Consumption's VNet integration plumbing is internally Container-Apps-based).
        // Live platform error > search-summarized claim when the two disagree.
        name: 'functions-delegation'
        properties: {
          serviceName: 'Microsoft.App/environments'
        }
      }
    ]
  }
}

resource snetPrivateEndpoints 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: existingVnet
  name: 'snet-private-endpoints'
}

// --- Private endpoints for Storage and Cosmos - NOT optional, confirmed live 2026-10-09 (U-13,
// docs/UNKNOWNS.md): publicNetworkAccess: Disabled means private-endpoint-only, not "reachable from
// anywhere already inside the VNet" - the Function App's own VNet integration only lets it dial out;
// without these, there is no private DNS/routing path to either resource at all. Both connections
// auto-approve (same tenant/subscription as the VNet, unlike Phase 1's cross-tenant Foundry private
// endpoint, which needs manual approval - docs/STATUS.md Phase 1). ---
resource peStorage 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${namePrefix}-pe-storage'
  location: location
  properties: {
    subnet: { id: snetPrivateEndpoints.id }
    privateLinkServiceConnections: [
      {
        name: '${namePrefix}-pe-storage-connection'
        properties: {
          privateLinkServiceId: functionStorage.id
          groupIds: ['blob']
        }
      }
    ]
  }
}

resource peCosmos 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${namePrefix}-pe-cosmos'
  location: location
  properties: {
    subnet: { id: snetPrivateEndpoints.id }
    privateLinkServiceConnections: [
      {
        name: '${namePrefix}-pe-cosmos-connection'
        properties: {
          privateLinkServiceId: cosmosAccount.id
          groupIds: ['Sql']
        }
      }
    ]
  }
}

resource dnsZoneBlob 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.blob.core.windows.net'
  location: 'global'
}

resource dnsZoneCosmos 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.documents.azure.com'
  location: 'global'
}

resource dnsZoneBlobLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsZoneBlob
  name: '${existingVnetName}-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: existingVnet.id }
    registrationEnabled: false
  }
}

resource dnsZoneCosmosLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsZoneCosmos
  name: '${existingVnetName}-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: existingVnet.id }
    registrationEnabled: false
  }
}

resource peStorageDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: peStorage
  name: 'storage-dns-zone-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'blob', properties: { privateDnsZoneId: dnsZoneBlob.id } }
    ]
  }
}

resource peCosmosDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: peCosmos
  name: 'cosmos-dns-zone-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'documents', properties: { privateDnsZoneId: dnsZoneCosmos.id } }
    ]
  }
}

// --- Storage account for the Function App's deployment package and runtime state. Managed-identity
// auth only (allowSharedKeyAccess: false) - consistent with every other "no local/key auth" default
// this subscription enforces on Cosmos and this project already follows on the Foundry backend. ---
resource functionStorage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: replace('${namePrefix}fnstor', '-', '')
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  name: '${functionStorage.name}/default/app-package-resolver'
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-resolver-ai'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    DisableLocalAuth: true
  }
}

// --- Flex Consumption plan (FC1) - see header comment for the cost reasoning. ---
resource flexPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: '${namePrefix}-resolver-plan'
  location: location
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

resource resolverFunctionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: '${namePrefix}-resolver-func'
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: flexPlan.id
    httpsOnly: true
    virtualNetworkSubnetId: snetFunctions.id
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${functionStorage.properties.primaryEndpoints.blob}app-package-resolver'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
        alwaysReady: alwaysReadyInstanceCount > 0 ? [
          { name: 'http', instanceCount: alwaysReadyInstanceCount }
        ] : []
      }
      runtime: {
        name: 'node'
        version: '22'
      }
    }
    siteConfig: {
      appSettings: [
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__blobServiceUri', value: functionStorage.properties.primaryEndpoints.blob }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: functionStorage.properties.primaryEndpoints.queue }
        { name: 'AzureWebJobsStorage__tableServiceUri', value: functionStorage.properties.primaryEndpoints.table }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'COSMOS_ENDPOINT', value: cosmosAccount.properties.documentEndpoint }
        { name: 'COSMOS_DATABASE', value: cosmosDatabaseName }
      ]
    }
  }
  dependsOn: [
    deploymentContainer
  ]
}

// --- RBAC: Storage Blob Data Owner on the deployment container (control-plane Azure RBAC - Storage
// does not have a separate data-plane RBAC system the way Cosmos does). Cosmos's own data-plane role
// is intentionally NOT assigned here - it needs `az cosmosdb sql role assignment create` against
// Cosmos's own sqlRoleDefinitions, a different command family Bicep's generic roleAssignments
// resource cannot express; infra/poc/create-cosmos-containers.ps1 or a follow-up script must grant
// it after this deploys (docs/PERMISSIONS.md row 8 - "a real gap if assumed"). ---
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'

resource functionStorageRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionStorage.id, resolverFunctionApp.id, storageBlobDataOwnerRoleId)
  scope: functionStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
    principalId: resolverFunctionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output cosmosEndpoint string = cosmosAccount.properties.documentEndpoint
output functionAppName string = resolverFunctionApp.name
output functionAppPrincipalId string = resolverFunctionApp.identity.principalId
output functionsSubnetId string = snetFunctions.id
