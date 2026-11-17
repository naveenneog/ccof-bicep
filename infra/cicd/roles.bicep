// Least-privilege roles of the two CCOF runner identities (docs/runbooks/CICD-SETUP.md, "Roles" table).
// Deployed at subscription scope by Invoke-CicdSetup.ps1 -Phase Roles; the Foundry accounts may be in another
// subscription. No Owner and no User Access Administrator: role assignment rights are Role Based Access Control
// Administrator with an ABAC condition limited to the roles Stage 3 assigns, to service principals only.
targetScope = 'subscription'

param previewPrincipalId string
param deployPrincipalId string
param workloadResourceGroup string
param networkResourceGroup string
param cosmosAccountName string
param cosmosDatabaseName string = 'ccof'

@description('Foundry accounts: [{ subscriptionId, resourceGroup, accountName }].')
param foundry array

@description('Cognitive Services Contributor on each Foundry account, for approving private endpoint connections from the pipeline. Off by default: the Foundry owner approves.')
param foundryPrivateEndpointApproval bool = false

@description('Cosmos DB Built-in Data Contributor for the deploy identity on the database, for pipeline steps that write data (seeding). Off by default.')
param deployCosmosDataWriter bool = false

var reader = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var contributor = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
var networkContributor = '4d97b98b-1d4f-4787-a291-c67834d212e7'
var rbacAdministrator = 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
var cognitiveServicesContributor = '25fbc0a9-bd7c-42a3-aa1a-3b75d497ee68'
var blobOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var metricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb'
var logReader = '73c42c96-874c-492b-b04d-ab87d138a893'
var cognitiveServicesUser = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var cosmosDataReader = '00000000-0000-0000-0000-000000000001'
var cosmosDataContributor = '00000000-0000-0000-0000-000000000002'

var previewRoleIds = [reader]

module workloadPreview 'modules/rg-roles.bicep' = {
  name: 'ccof-cicd-roles-workload-preview'
  scope: resourceGroup(workloadResourceGroup)
  params: { principalId: previewPrincipalId, roleIds: previewRoleIds }
}

module networkPreview 'modules/rg-roles.bicep' = {
  name: 'ccof-cicd-roles-network-preview'
  scope: resourceGroup(networkResourceGroup)
  params: { principalId: previewPrincipalId, roleIds: previewRoleIds }
}

module workloadDeploy 'modules/rg-roles.bicep' = {
  name: 'ccof-cicd-roles-workload-deploy'
  scope: resourceGroup(workloadResourceGroup)
  params: {
    principalId: deployPrincipalId
    roleIds: [contributor]
    conditionedRbacAdministrator: rbacAdministrator
    assignableRoleIds: [blobOwner, metricsPublisher, logReader]
  }
}

module networkDeploy 'modules/rg-roles.bicep' = {
  name: 'ccof-cicd-roles-network-deploy'
  scope: resourceGroup(networkResourceGroup)
  params: { principalId: deployPrincipalId, roleIds: [networkContributor] }
}

module cosmos 'modules/cosmos-roles.bicep' = {
  name: 'ccof-cicd-roles-cosmos'
  scope: resourceGroup(workloadResourceGroup)
  params: {
    accountName: cosmosAccountName
    databaseName: cosmosDatabaseName
    assignments: concat(
      [{ principalId: previewPrincipalId, roleDefinitionId: cosmosDataReader }],
      deployCosmosDataWriter ? [{ principalId: deployPrincipalId, roleDefinitionId: cosmosDataContributor }] : []
    )
  }
}

module foundryRoles 'modules/foundry-roles.bicep' = [for (f, i) in foundry: {
  name: 'ccof-cicd-roles-foundry-${i}'
  scope: resourceGroup(f.subscriptionId, f.resourceGroup)
  params: {
    accountName: f.accountName
    previewPrincipalId: previewPrincipalId
    previewRoleIds: previewRoleIds
    deployPrincipalId: deployPrincipalId
    deployRoleIds: foundryPrivateEndpointApproval ? [cognitiveServicesContributor] : []
    conditionedRbacAdministrator: rbacAdministrator
    assignableRoleIds: [cognitiveServicesUser]
  }
}]
