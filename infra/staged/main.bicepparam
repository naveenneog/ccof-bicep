using './main.bicep'

// Copy privately, replace the approved prefix/location, and review pricing/capacity.
// Secure defaults deliberately leave services non-running until stages 2-4.
param prefix = 'ccofnew'
param location = 'eastus2'
param tags = { deploymentStage: 'services-only' }
param includeAdmin = true
param cosmosCapacityMode = 'serverless'
param cosmosPublicNetworkAccess = 'Disabled'
param storagePublicNetworkAccess = 'Disabled'
param functionsPublicNetworkAccess = 'Disabled'

// Azure APIM cannot start with PNA Disabled before an approved PE exists.
// No public bootstrap is authorized by this example. APIM is deferred by default.
// Set true ONLY for an approved NEW public shell and fill both publisher values.
param approveNewPublicApimBootstrap = false
param apimPublisherEmail = ''
param apimPublisherName = ''
