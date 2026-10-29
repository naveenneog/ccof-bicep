// Azure Front Door Premium in front of the primary and standby API Management gateways (ADR 0033,
// docs/DR-ACTIVE-PASSIVE.md "Edge"). Each origin reaches its APIM gateway over Private Link
// (origin type API Management, sub-resource Gateway); each connection is then approved on the APIM
// side (infra/dr/Invoke-DrFrontDoor.ps1). Priorities make the pair active/passive: Front Door sends
// traffic to the primary while its health probe passes, and to the standby otherwise. Before region B
// exists the same template deploys the primary origins only (Invoke-DrFrontDoor.ps1 -PrimaryOnly).
// https://learn.microsoft.com/azure/frontdoor/standard-premium/how-to-enable-private-link-apim
targetScope = 'resourceGroup'

@description('Name stem: profile <stem>-fd, endpoint <stem>, WAF policy <stem>waf (letters and digits only).')
@minLength(3)
@maxLength(40)
param stem string

param tags object = {}

@description('APIM gateways, primary first: [{ name, apimId, hostName, location, priority }]. priority 1 = primary, 2 = standby. One entry (primary only) before region B exists; the profile, endpoint, origin group and route names do not change when the standby entry is added later.')
@minLength(1)
@maxLength(2)
param apimOrigins array

@description('Admin Function Apps, primary first: [{ name, siteId, hostName, location, priority }]. priority 1 = primary, 2 = standby. One entry (primary only) before region B exists.')
@minLength(1)
@maxLength(2)
param adminOrigins array

@description('For the DR drill, disable the priority-1 APIM origin while leaving the standby origin enabled.')
param disablePrimaryOrigins bool = false

@description('For the DR drill, disable the priority-1 admin origin while leaving the standby origin enabled.')
param disablePrimaryAdminOrigins bool = false

@description('Inject a reversible origin-host-header fault on both priority-1 origins. The private-link targets and TLS host names stay unchanged; AFD health probes receive an HTTP 404 and should select region B.')
param simulatePrimaryFailure bool = false

@description('Detection logs WAF matches without blocking. Model prompts and code can match managed rules, so tune exclusions in Detection before Prevention.')
@allowed(['Detection', 'Prevention'])
param wafMode string = 'Detection'

@description('Seconds between health probes from each Front Door point of presence.')
@minValue(5)
@maxValue(255)
param probeIntervalSeconds int = 30

resource profile 'Microsoft.Cdn/profiles@2024-02-01' = {
  name: '${stem}-fd'
  location: 'global'
  tags: tags
  sku: { name: 'Premium_AzureFrontDoor' }
  properties: { originResponseTimeoutSeconds: 240 }
}

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-02-01' = {
  parent: profile
  name: stem
  location: 'global'
  tags: tags
  properties: { enabledState: 'Enabled' }
}

// The APIM gateway answers GET /status-0123456789abcdef with 200 and no API or subscription, but
// HEAD with 404 (both lab gateways, 2026-10-25). Front Door probes new profiles with HEAD by default,
// which would mark both origins unhealthy, so the probe is GET.
resource originGroup 'Microsoft.Cdn/profiles/originGroups@2024-02-01' = {
  parent: profile
  name: 'apim'
  properties: {
    loadBalancingSettings: { sampleSize: 4, successfulSamplesRequired: 3, additionalLatencyInMilliseconds: 0 }
    healthProbeSettings: {
      probePath: '/status-0123456789abcdef'
      probeRequestType: 'GET'
      probeProtocol: 'Https'
      probeIntervalInSeconds: probeIntervalSeconds
    }
    sessionAffinityState: 'Disabled'
  }
}

@batchSize(1)
resource origins 'Microsoft.Cdn/profiles/originGroups/origins@2024-02-01' = [for o in apimOrigins: {
  parent: originGroup
  name: o.name
  properties: {
    hostName: o.hostName
    originHostHeader: (o.priority == 1 && simulatePrimaryFailure) ? 'dr-drill.invalid' : o.hostName
    httpsPort: 443
    httpPort: 80
    priority: o.priority
    weight: 1000
    enabledState: (o.priority == 1 && disablePrimaryOrigins) ? 'Disabled' : 'Enabled'
    enforceCertificateNameCheck: true
    sharedPrivateLinkResource: {
      privateLink: { id: o.apimId }
      groupId: 'Gateway'
      privateLinkLocation: o.location
      requestMessage: 'CCOF Front Door origin ${o.name}'
    }
  }
}]

resource adminOriginGroup 'Microsoft.Cdn/profiles/originGroups@2024-02-01' = {
  parent: profile
  name: 'admin'
  properties: {
    loadBalancingSettings: { sampleSize: 4, successfulSamplesRequired: 3, additionalLatencyInMilliseconds: 0 }
    // The admin home/console routes are anonymous static UI handlers; API writes still require Entra auth.
    healthProbeSettings: {
      probePath: '/api/console'
      probeRequestType: 'GET'
      probeProtocol: 'Https'
      probeIntervalInSeconds: probeIntervalSeconds
    }
    sessionAffinityState: 'Disabled'
  }
}

@batchSize(1)
resource adminOriginResources 'Microsoft.Cdn/profiles/originGroups/origins@2024-02-01' = [for o in adminOrigins: {
  parent: adminOriginGroup
  name: o.name
  properties: {
    hostName: o.hostName
    originHostHeader: (o.priority == 1 && simulatePrimaryFailure) ? 'dr-drill.invalid' : o.hostName
    httpsPort: 443
    httpPort: 80
    priority: o.priority
    weight: 1000
    enabledState: (o.priority == 1 && disablePrimaryAdminOrigins) ? 'Disabled' : 'Enabled'
    enforceCertificateNameCheck: true
    sharedPrivateLinkResource: {
      privateLink: { id: o.siteId }
      groupId: 'sites'
      privateLinkLocation: o.location
      requestMessage: 'CCOF Front Door admin origin ${o.name}'
    }
  }
}]

resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = {
  parent: endpoint
  name: 'gateway'
  properties: {
    originGroup: { id: originGroup.id }
    supportedProtocols: ['Https']
    patternsToMatch: ['/*']
    forwardingProtocol: 'HttpsOnly'
    httpsRedirect: 'Enabled'
    linkToDefaultDomain: 'Enabled'
    enabledState: 'Enabled'
  }
  dependsOn: [origins]
}

resource adminRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = {
  parent: endpoint
  name: 'admin'
  properties: {
    originGroup: { id: adminOriginGroup.id }
    supportedProtocols: ['Https']
    patternsToMatch: ['/api/*']
    forwardingProtocol: 'HttpsOnly'
    httpsRedirect: 'Enabled'
    linkToDefaultDomain: 'Enabled'
    enabledState: 'Enabled'
  }
  dependsOn: [adminOriginResources]
}

resource waf 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies@2024-02-01' = {
  name: replace('${stem}waf', '-', '')
  location: 'global'
  tags: tags
  sku: { name: 'Premium_AzureFrontDoor' }
  properties: {
    policySettings: { enabledState: 'Enabled', mode: wafMode, requestBodyCheck: 'Enabled', javascriptChallengeExpirationInMinutes: 30 }
    managedRules: {
      managedRuleSets: [
        { ruleSetType: 'Microsoft_DefaultRuleSet', ruleSetVersion: '2.1', ruleSetAction: 'Block' }
        { ruleSetType: 'Microsoft_BotManagerRuleSet', ruleSetVersion: '1.0' }
      ]
    }
  }
}

resource security 'Microsoft.Cdn/profiles/securityPolicies@2024-02-01' = {
  parent: profile
  name: 'waf'
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: { id: waf.id }
      associations: [{ domains: [{ id: endpoint.id }], patternsToMatch: ['/*'] }]
    }
  }
}

output profileName string = profile.name
output profileId string = profile.id
output endpointHostName string = endpoint.properties.hostName
output originGroupId string = originGroup.id
output originNames array = [for (o, i) in apimOrigins: origins[i].name]
output adminOriginGroupId string = adminOriginGroup.id
output adminOriginNames array = [for (o, i) in adminOrigins: adminOriginResources[i].name]
output wafPolicyId string = waf.id
