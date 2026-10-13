#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$AnswersPath,
    [switch]$ValidateOnly,
    [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'preconditions.ps1')

function Write-Audit([string]$Outcome, [string]$Reason, [string]$WorkbookId = '') {
    [ordered]@{ schema = 'ccof.workbook.deploy.v1'; outcome = $Outcome; reason = $Reason; workbookId = $WorkbookId } |
        ConvertTo-Json -Compress | Write-Output
}

if ([string]::IsNullOrWhiteSpace($AnswersPath)) {
    Write-Audit 'refused' 'answers_required'
    exit 1
}
$answerFile = [IO.Path]::GetFullPath($AnswersPath)
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Push-Location $root
try {
    if (-not (Test-Path -LiteralPath $answerFile -PathType Leaf)) { throw 'answers_file_unavailable' }
    # A full path in this platform's separators: node on Linux reads \ as part of a file name.
    $buildOutput = @(& node (Join-Path $root 'analytics' 'workbooks' 'build.ts') --answers $answerFile 2>&1)
    $buildLine = @($buildOutput | Where-Object { $_ -is [string] -and $_.StartsWith('{') }) | Select-Object -Last 1
    # Success needs the build's own JSON outcome, not only exit code 0.
    if ($LASTEXITCODE -ne 0 -or -not $buildLine -or -not [string]::Equals([string]($buildLine | ConvertFrom-Json).outcome, 'validated', 'Ordinal')) {
        $buildOutput | Write-Output; throw 'offline_validation_failed'
    }
    $answers = Get-Content -LiteralPath $answerFile -Raw | ConvertFrom-Json
    $buildOutput | Write-Output
    $workbookId = "/subscriptions/$($answers.subscriptionId)/resourceGroups/$($answers.resourceGroupName)/providers/Microsoft.Insights/workbooks/$($answers.workbookResourceName)"
    $parametersPath = Join-Path $root (Join-Path $answers.outputDirectory 'parameters.json')
    $template = Join-Path $PSScriptRoot 'main.bicep'
    # Offline, so -ValidateOnly checks it too: every value the az calls below receive.
    Assert-WorkbookAzArguments $answers.subscriptionId @($answers.resourceGroupName, $answers.deploymentName, $answers.workspaceResourceId,
        $answers.gatewayResourceId, $answers.reconcilerResourceId, $workbookId, $template, "@$parametersPath")
    if ($ValidateOnly) {
        Write-Audit 'validated' 'no_remote_calls' $answers.workbookResourceName
        return
    }
    $tenant = & az account show --subscription $answers.subscriptionId --query tenantId --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'azure_account_unavailable' }
    if (-not [string]::Equals($tenant, $answers.tenantId, 'Ordinal')) { throw 'tenant_mismatch' }
    $workspaceType = & az resource show --subscription $answers.subscriptionId --ids $answers.workspaceResourceId --query type --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or $workspaceType -ine 'Microsoft.OperationalInsights/workspaces') { throw 'workspace_unavailable' }
    # The retention answer flags truncated periods; it must be the workspace's real retention.
    $retention = & az resource show --subscription $answers.subscriptionId --ids $answers.workspaceResourceId --query properties.retentionInDays --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not [string]::Equals([string]$retention, [string]$answers.retentionDays, 'Ordinal')) { throw 'retention_mismatch' }
    # A wrong gateway or reconciler id would show "no matching observations" forever; refuse it here.
    $gatewayType = & az resource show --subscription $answers.subscriptionId --ids $answers.gatewayResourceId --query type --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or $gatewayType -ine 'Microsoft.ApiManagement/service') { throw 'gateway_unavailable' }
    $reconcilerType = & az resource show --subscription $answers.subscriptionId --ids $answers.reconcilerResourceId --query type --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or $reconcilerType -ine 'Microsoft.Web/sites') { throw 'reconciler_unavailable' }
    $workbook = & az resource show --subscription $answers.subscriptionId --ids $workbookId --output json --only-show-errors | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not (Test-WorkbookResource $workbook $workbookId)) { throw 'workbook_prerequisite_missing' }
    if ($WhatIf) {
        $plan = & az deployment group what-if --subscription $answers.subscriptionId --resource-group $answers.resourceGroupName --name $answers.deploymentName --template-file $template --parameters "@$parametersPath" --no-pretty-print --output json --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'what_if_failed' }
        $plan | Set-Content -LiteralPath (Join-Path $answers.outputDirectory 'what-if.json') -Encoding utf8NoBOM
        Write-Audit 'validated' 'what_if_recorded' $answers.workbookResourceName
        return
    }
    $state = & az deployment group create --subscription $answers.subscriptionId --resource-group $answers.resourceGroupName --name $answers.deploymentName --template-file $template --parameters "@$parametersPath" --query properties.provisioningState --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not [string]::Equals($state, 'Succeeded', 'Ordinal')) { throw 'deployment_failed' }
    Write-Audit 'deployed' 'Succeeded' $workbookId
} catch {
    $reason = if ($_.Exception.Message -match '^[a-z_]+$') { $_.Exception.Message } else { 'workbook_operation_failed' }
    Write-Audit 'refused' $reason
    exit 1
} finally {
    Pop-Location
}
