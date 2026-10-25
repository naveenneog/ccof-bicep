// Stage 5 helper: the API-level Azure Monitor logger and diagnostic (LLM token logging) of
// infra/poc/phase4-apim-telemetry.bicep, without its resource-log diagnostic setting (Stage 1 owns it).
targetScope = 'resourceGroup'

param apimName string
param apiId string

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimName
}

resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' existing = {
  parent: apim
  name: apiId
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
    sampling: { samplingType: 'fixed', percentage: 100 }
    verbosity: 'information'
    logClientIp: false
    frontend: {
      request: { body: { bytes: 0 }, headers: [] }
      response: { body: { bytes: 0 }, headers: [] }
    }
    backend: {
      request: { body: { bytes: 0 }, headers: [] }
      response: { body: { bytes: 0 }, headers: [] }
    }
    largeLanguageModel: { logs: 'enabled' }
  }
}

output diagnosticId string = apiDiagnostic.id
