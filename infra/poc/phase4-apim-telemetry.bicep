// Property references and retrieval dates: docs/adr/0010-telemetry-and-usage-ledger.md.
targetScope = 'resourceGroup'

param workspaceResourceId string
param apimServiceName string
param apiName string
param location string
var workspaceName = last(split(workspaceResourceId, '/'))

@description('Explicitly enables operational alerts; requires complete administrator configuration.')
param enableAlerts bool = false

@secure()
@description('Validated administrator receivers, thresholds and cadence; no operational defaults.')
param alertConfiguration object = {}

@description('SHA-256 of the UTF-8 configuration text, recorded on alert resources.')
param alertConfigurationDigest string = ''

// With alerts off, D2 passes no configuration, so alertConfiguration is {}, and ARM still evaluates
// expressions of the alert resources it does not deploy: in a validation subscription (2026-10-13) the rules' dependsOn
// read alertConfiguration.actionGroup and the deployment failed with InvalidTemplate
// (docs/status/WP-TEL.md). Every alert value is therefore read from `alerting`: the administrator's
// configuration when alerts are on, else `alertsOff`, which has every field and deploys nothing (no
// rule; the action group's condition is false). ARM's if() evaluates only the branch it returns
// (https://learn.microsoft.com/azure/azure-resource-manager/templates/template-functions-logical#if,
// retrieved 2026-10-13).
var alertsOff = {
  configurationId: 'alerts-off'
  actionGroup: {
    name: 'alerts-off'
    location: 'global'
    shortName: 'alerts-off'
    emailReceivers: []
  }
  evaluationFrequencyMinutes: 0
  windowMinutes: 0
  resolverLatencyPercentile: 0
  failingPeriods: {
    numberOfEvaluationPeriods: 0
    minFailingPeriodsToAlert: 0
  }
  rules: []
}
var alerting = enableAlerts ? alertConfiguration : alertsOff

var gatewayQuery = loadTextContent('../../analytics/alerts/gateway-base.kql')
var resolverQuery = loadTextContent('../../analytics/alerts/resolver-base.kql')
var signalQueries = {
  'gateway-5xx': loadTextContent('../../analytics/alerts/gateway-5xx.kql')
  'gateway-429': loadTextContent('../../analytics/alerts/gateway-429.kql')
  'backend-failures': loadTextContent('../../analytics/alerts/backend-failures.kql')
  'resolver-failures': loadTextContent('../../analytics/alerts/resolver-failures.kql')
  'resolver-latency': loadTextContent('../../analytics/alerts/resolver-latency.kql')
  'budget-degraded': loadTextContent('../../analytics/alerts/budget-degraded.kql')
  'missing-telemetry': loadTextContent('../../analytics/alerts/missing-telemetry.kql')
}

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' existing = {
  parent: apim
  name: apiName
}

resource resourceLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${workspaceName}-apim'
  scope: apim
  properties: {
    workspaceId: workspaceResourceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'GatewayLogs'
        enabled: true
      }
      {
        category: 'GatewayLlmLogs'
        enabled: true
      }
    ]
  }
}

resource monitorLogger 'Microsoft.ApiManagement/service/loggers@2024-06-01-preview' = {
  parent: apim
  name: 'azuremonitor'
  properties: {
    loggerType: 'azureMonitor'
    description: 'ccof-wp=tel; keyless Azure Monitor resource logs'
    isBuffered: true
  }
}

resource apiDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = {
  parent: api
  name: 'azuremonitor'
  properties: {
    loggerId: monitorLogger.id
    alwaysLog: 'allErrors'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    verbosity: 'information'
    logClientIp: false
    frontend: {
      request: {
        body: { bytes: 0 }
        headers: []
      }
      response: {
        body: { bytes: 0 }
        headers: []
      }
    }
    backend: {
      request: {
        body: { bytes: 0 }
        headers: []
      }
      response: {
        body: { bytes: 0 }
        headers: []
      }
    }
    largeLanguageModel: {
      logs: 'enabled'
    }
  }
}

resource alertActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (enableAlerts) {
  name: alerting.actionGroup.name
  location: alerting.actionGroup.location
  tags: {
    'ccof-wp': 'tel'
    'ccof-config': alertConfigurationDigest
  }
  properties: {
    groupShortName: alerting.actionGroup.shortName
    enabled: true
    emailReceivers: alerting.actionGroup.emailReceivers
  }
}

resource alerts 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [for rule in (enableAlerts ? alerting.rules : []): {
  name: '${workspaceName}-${uniqueString(apim.id, apiName)}-${rule.signal}'
  location: location
  kind: 'LogAlert'
  tags: {
    'ccof-wp': 'tel'
    'ccof-config': alertConfigurationDigest
  }
  properties: {
    displayName: '${apimServiceName}: ${rule.signal}'
    description: 'Counts-only operational signal; configuration ${alerting.configurationId}. No automatic admission change.'
    enabled: true
    severity: rule.severity
    evaluationFrequency: 'PT${alerting.evaluationFrequencyMinutes}M'
    windowSize: 'PT${alerting.windowMinutes}M'
    scopes: [workspaceResourceId]
    autoMitigate: true
    skipQueryValidation: false
    actions: {
      actionGroups: [alertActionGroup!.id]
    }
    criteria: {
      allOf: [
        {
          query: format(
            'let _gatewayResourceId = \'{0}\'; let _apiId = \'{1}\'; let _windowMinutes = {2}; let _minimumSamples = {3}; let _latencyPercentile = {4};\n{5}\n{6}\n{7}',
            apim.id,
            apiName,
            alerting.windowMinutes,
            rule.minimumSamples,
            alerting.resolverLatencyPercentile,
            gatewayQuery,
            contains(['resolver-failures', 'resolver-latency', 'budget-degraded'], rule.signal) ? resolverQuery : '',
            signalQueries[rule.signal]
          )
          metricMeasureColumn: 'value'
          timeAggregation: 'Maximum'
          operator: 'GreaterThanOrEqual'
          threshold: rule.threshold
          failingPeriods: alerting.failingPeriods
        }
      ]
    }
  }
}]

output diagnosticSettingId string = resourceLogs.id
output loggerId string = monitorLogger.id
output apiDiagnosticId string = apiDiagnostic.id
output alertsEnabled bool = enableAlerts
output configurationDigest string = alertConfigurationDigest
