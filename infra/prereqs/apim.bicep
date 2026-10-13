// D1 prerequisite: the API Management instance, in the tier, units and zones chosen at D0, with its
// system-assigned identity and outbound VNet integration (docs/PREREQUISITES-WORKBOOK.md, D1-14).
// Source: infra/poc/main.bicep (live since 2026-10-09). The API, backends, named values, policy and
// diagnostics are D2; APIM's role on a backend is onboarding Stage 2 data applied by D3.
//
// The identity is declared on every deployment of this module, so a re-run keeps it. Never use
// `az apim update` on this instance: it removes the managed identity unless
// --enable-managed-identity true is passed, and the resolver trusts only that identity (ADR-0009).
// Zones are set at creation only (Learn, reliability-api-management, v2 tiers).

targetScope = 'resourceGroup'

@description('Region; equals the deployment location.')
param location string

@description('Tags for every resource (answers target.tags).')
param tags object

@description('Instance name (answers names.apim).')
param name string

@description('availability.apim.sku.')
@allowed(['StandardV2', 'PremiumV2'])
param sku string

@description('availability.apim.units.')
@minValue(1)
param units int

@description('availability.apim.zones: [] for non-zonal.')
param zones array

@description('answers apim.publisherEmail; required by APIM at creation.')
param publisherEmail string

@description('answers apim.publisherName.')
param publisherName string

@description('Subnet id for outbound VNet integration (delegated to Microsoft.Web/serverFarms, with an NSG).')
param subnetId string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: name
  location: location
  tags: tags
  zones: empty(zones) ? null : zones
  sku: {
    name: sku
    capacity: units
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: 'External'
    virtualNetworkConfiguration: {
      subnetResourceId: subnetId
    }
  }
}

output id string = apim.id
output gatewayUrl string = apim.properties.gatewayUrl
output principalId string = apim.identity.principalId
