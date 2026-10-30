// Health and outage e-mail alerts: an add-on over an existing CCOF deployment
// (docs/runbooks/HEALTH-ALERTS.md). It creates only its own resources, all named <namePrefix>-* and
// tagged ccof-component=health-alerts: one action group, one Application Insights component that
// holds the availability tests, the tests, and metric and log alert rules. It reads the existing
// resources only as alert scopes; no setting, policy, diagnostic setting or role of theirs is written.
// infra/monitoring/Invoke-HealthAlerts.ps1 composes every parameter (HealthAlerts.psm1 New-HaParameters).
targetScope = 'resourceGroup'

@description('<stem>-health; every resource name starts with it.')
param namePrefix string

@description('Region of the Application Insights component, its tests and the log alert rules (the workspace region).')
param location string

param tags object = {}

@description('Log Analytics workspace of the deployment; the owned component sends availability results to it.')
param workspaceId string

@description('[{ name, emailAddress, useCommonAlertSchema }]')
param emailReceivers array

@description('[{ key, label, url, expectedStatus }]; empty: no component and no tests.')
param webTests array = []

param webTestLocations array = []

@description('[{ key, failedLocationCount, severity, window, description }], one per web test, same order.')
param availability array = []

@description('[{ name, displayName, description, scope, namespace, metric, aggregation, operator, threshold, dimensions, severity, window, frequency }]')
param metricRules array = []

@description('[{ name, displayName, description, scope, query, threshold, dimensions, severity, window, frequency }]')
param logRules array = []

var ownedTags = union(tags, { 'ccof-component': 'health-alerts' })
var componentName = '${namePrefix}-ai'
var componentId = resourceId('Microsoft.Insights/components', componentName)

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${namePrefix}-ag'
  location: 'Global'
  tags: ownedTags
  properties: {
    groupShortName: 'ccofhealth'
    enabled: true
    emailReceivers: emailReceivers
  }
}

resource component 'Microsoft.Insights/components@2020-02-02' = if (!empty(webTests)) {
  name: componentName
  location: location
  tags: ownedTags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspaceId
    DisableLocalAuth: true
  }
}

resource tests 'Microsoft.Insights/webtests@2022-06-15' = [for t in webTests: {
  name: '${namePrefix}-wt-${t.key}'
  location: location
  kind: 'standard'
  // Azure links a test to its component through this tag.
  tags: union(ownedTags, { 'hidden-link:${componentId}': 'Resource' })
  properties: {
    SyntheticMonitorId: '${namePrefix}-wt-${t.key}'
    Name: 'CCOF health: ${t.label}'
    Enabled: true
    Frequency: 300
    Timeout: 30
    Kind: 'standard'
    RetryEnabled: true
    Locations: [for l in webTestLocations: { Id: l }]
    Request: {
      RequestUrl: t.url
      HttpVerb: 'GET'
      ParseDependentRequests: false
      FollowRedirects: false
    }
    ValidationRules: {
      ExpectedHttpStatusCode: t.expectedStatus
      SSLCheck: true
      SSLCertRemainingLifetimeCheck: 7
    }
  }
  dependsOn: [component]
}]

resource availabilityAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [for (a, i) in availability: {
  name: '${namePrefix}-avail-${a.key}'
  location: 'global'
  tags: ownedTags
  properties: {
    description: a.description
    severity: a.severity
    enabled: true
    scopes: [tests[i].id, componentId]
    evaluationFrequency: 'PT1M'
    windowSize: a.window
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.WebtestLocationAvailabilityCriteria'
      webTestId: tests[i].id
      componentId: componentId
      failedLocationCount: a.failedLocationCount
    }
    actions: [{ actionGroupId: actionGroup.id }]
  }
}]

resource metricAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [for r in metricRules: {
  name: r.name
  location: 'global'
  tags: ownedTags
  properties: {
    description: '${r.displayName}. ${r.description}'
    severity: r.severity
    enabled: true
    scopes: [r.scope]
    targetResourceType: r.namespace
    evaluationFrequency: r.frequency
    windowSize: r.window
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'threshold'
          metricName: r.metric
          metricNamespace: r.namespace
          dimensions: r.dimensions
          operator: r.operator
          threshold: r.threshold
          timeAggregation: r.aggregation
        }
      ]
    }
    actions: [{ actionGroupId: actionGroup.id }]
  }
}]

// No managed identity: Azure runs the query with the permissions of the last user who edited the rule
// (https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-create-log-alert-rule).
resource logAlerts 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [for r in logRules: {
  name: r.name
  location: location
  kind: 'LogAlert'
  tags: ownedTags
  properties: {
    displayName: r.displayName
    description: r.description
    enabled: true
    severity: r.severity
    evaluationFrequency: r.frequency
    windowSize: r.window
    scopes: [r.scope]
    autoMitigate: true
    skipQueryValidation: false
    criteria: {
      allOf: [
        {
          query: r.query
          metricMeasureColumn: 'value'
          timeAggregation: 'Maximum'
          operator: 'GreaterThanOrEqual'
          threshold: r.threshold
          dimensions: r.dimensions
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}]

output actionGroupId string = actionGroup.id
output componentId string = empty(webTests) ? '' : componentId
output webTestNames array = [for (t, i) in webTests: tests[i].name]
output metricAlertNames array = [for (r, i) in metricRules: metricAlerts[i].name]
output logAlertNames array = [for (r, i) in logRules: logAlerts[i].name]
