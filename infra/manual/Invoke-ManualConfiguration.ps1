#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ParametersPath,
    [ValidateSet(1, 2, 3, 4, 5, 7, 8)] [int]$Step,
    [string]$WorkbookParametersPath,
    [switch]$WhatIfOnly,
    [switch]$DotSourceOnly
)
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$callerDotSourceOnly = $DotSourceOnly
. (Join-Path $root 'infra\quickstart\Deploy-Quickstart.ps1') -ParametersPath $ParametersPath -WhatIfOnly:$WhatIfOnly -DotSourceOnly
$DotSourceOnly = $callerDotSourceOnly

function Assert-ManualStepPrerequisites {
    param([int]$Step, [System.Collections.IDictionary]$State, [string]$ParametersDigest)
    if ($Step -eq 1) { return }
    if (-not $State.Contains('parametersDigest') -or $State.parametersDigest -cne $ParametersDigest) {
        throw 'manual_parameters_changed: run steps 1 and 2 with these parameters before continuing'
    }
    $needs = @{
        2 = @('1'); 3 = @('1', '2'); 4 = @('1', '2', '3')
        5 = @('1', '2', '3', '4'); 7 = @('1', '2', '3', '4', '5')
        8 = @('1', '2', '3', '4', '5', '7')
    }
    foreach ($number in $needs[$Step]) {
        if (-not $State.completed.Contains($number)) { throw "manual_stage_missing: step $Step needs verified step $number" }
    }
}

function Invoke-ManualConfigDeploy {
    param($Ctx)
    $p = $Ctx.P
    if ($p.runner.enabled -or $p.sync.mode -ne 'application-permission') {
        throw 'manual_sync_mode: no-VM manual path requires application-permission and runner.enabled=false'
    }
    # Refresh Entra/APIM identity checks rather than trust hand-edited state outputs.
    $checks = Test-QsPrerequisites $Ctx
    foreach ($backend in $p.backends) {
        $account = Invoke-QsAz @('account', 'show', '--subscription', $backend.subscriptionId)
        if ($account.tenantId -ne $p.tenantId) {
            throw 'manual_cross_tenant_backend: use the reviewed checkpointed second-tenant authentication path, not this managed-identity seed'
        }
    }
    # The integrated family helper validates the whole route/policy batch before any config write.
    $null = New-QsSeedDocuments -P $p
    $build = $Ctx.State.completed['2'].outputs
    $policy = Get-Content -LiteralPath $build.policyPath -Raw
    if (-not $policy.Trim()) { throw 'manual_policy_empty' }
    $values = [ordered]@{}
    foreach ($key in @('tenantId', 'location', 'names', 'apim', 'registrations', 'backends', 'cosmos',
        'resolver', 'sync', 'reconciler', 'budgetState', 'groups', 'gateway', 'rateCard', 'workbook',
        'enableAlerts', 'syncTimerEnabled')) {
        $values[$key] = @{ value = $p[$key] }
    }
    $values.policyXml = @{ value = $policy }
    $values.apimIdentityAppId = @{ value = [string]$checks.apimIdentityAppId }
    if ($Ctx.WorkbookParametersPath) {
        $wb = (Get-Content -LiteralPath $Ctx.WorkbookParametersPath -Raw | ConvertFrom-Json -AsHashtable).parameters
        $expectedWorkspace = "/subscriptions/$($p.names.subscriptionId)/resourceGroups/$($p.names.resourceGroup)/providers/Microsoft.OperationalInsights/workspaces/$($p.names.logAnalyticsWorkspace)"
        if ($wb.workbookResourceName.value -ne $p.workbook.resourceName -or
            $wb.workspaceResourceId.value -ne $expectedWorkspace -or
            $wb.workbookDisplayName.value -ne $p.workbook.displayName -or $wb.location.value -ne $p.location -or
            -not $wb.workbookContent.value.items) { throw 'manual_workbook_target_mismatch_or_empty' }
        $values.workbookContent = $wb.workbookContent
        $values.workbookContentTags = $wb.contentTags
    }
    $path = Join-Path $Ctx.GeneratedDir 'configuration.parameters.json'
    @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'; parameters = $values
    } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    $verb = if ($Ctx.WhatIfOnly) { 'what-if' } else { 'create' }
    $result = Invoke-QsAz @('deployment', 'group', $verb, '--subscription', $p.names.subscriptionId,
        '--resource-group', $p.names.resourceGroup, '--name', "$($p.names.deploymentPrefix)-manual-configuration",
        '--mode', 'Incremental', '--template-file', (Join-Path $PSScriptRoot 'configuration.bicep'),
        '--parameters', "@$path")
    if ($Ctx.WhatIfOnly) { Write-Host ($result | ConvertTo-Json -Depth 100); throw 'manual_what_if_only: no configuration stage recorded' }
    if ($result.properties.provisioningState -cne 'Succeeded') { throw 'manual_configuration_not_succeeded' }
    $outputs = @{}
    foreach ($key in $result.properties.outputs.Keys) { $outputs[$key] = $result.properties.outputs[$key].value }
    return $outputs
}

function Get-ManualConfigurationSteps {
    @(
        [pscustomobject]@{ Number = 1; Name = 'checks'; Action = { param($c) Test-QsPrerequisites $c } }
        [pscustomobject]@{ Number = 2; Name = 'build'; Action = { param($c) Invoke-QsBuild $c } }
        [pscustomobject]@{ Number = 3; Name = 'configuration-and-grants'; Action = { param($c) Invoke-ManualConfigDeploy $c } }
        [pscustomobject]@{ Number = 4; Name = 'package-and-deploy-code'; Action = { param($c) Invoke-QsCode $c } }
        [pscustomobject]@{ Number = 5; Name = 'private-create-only-seed'; Action = { param($c) Invoke-QsSeed $c } }
        [pscustomobject]@{ Number = 7; Name = 'anonymous-smoke'; Action = { param($c) Invoke-QsSmoke $c } }
        [pscustomobject]@{ Number = 8; Name = 'client-artifacts'; Action = { param($c) Invoke-QsClient $c } }
    )
}

if ($DotSourceOnly) { return }
$ErrorActionPreference = 'Stop'
if (-not $ParametersPath -or -not $Step) { throw 'manual_usage: -ParametersPath and -Step required; see docs/MANUAL-DEPLOYMENT.md' }
if ($WhatIfOnly -and $Step -ne 3) { throw 'manual_what_if_step: -WhatIfOnly requires -Step 3' }
$full = Resolve-QsParametersPath $ParametersPath
$generated = Join-Path (Split-Path $full -Parent) '.env.manual.generated'
$statePath = Join-Path (Split-Path $full -Parent) '.env.manual.state.json'
$state = if (Test-Path -LiteralPath $statePath) {
    Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
} else { @{ completed = @{} } }
$digest = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
Assert-ManualStepPrerequisites -Step $Step -State $state -ParametersDigest $digest
New-Item -ItemType Directory -Path $generated -Force | Out-Null
# A successful rerun of any stage invalidates later evidence; failure must not leave old success.
foreach ($key in @($state.completed.Keys)) {
    if ([int]$key -ge $Step) { $state.completed.Remove($key) }
}
$state.parametersDigest = $digest
$state | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM
$ctx = @{
    ParametersPath = $full; ParametersText = (Get-Content -LiteralPath $full -Raw)
    P = (Read-QsParameters $full); GeneratedDir = $generated
    WorkbookParametersPath = $WorkbookParametersPath; WhatIfOnly = [bool]$WhatIfOnly
}
$run = Invoke-QuickstartSteps -Steps (Get-ManualConfigurationSteps) -StatePath $statePath -Context $ctx -Only $Step
if ($run.Failed) { exit 1 }
Write-Host "Manual step $Step verified and recorded; review the runbook before selecting the next step."
