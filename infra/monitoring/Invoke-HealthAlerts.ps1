#Requires -Version 7.2
<#
.SYNOPSIS
  Health and outage e-mail alerts over an existing CCOF deployment (docs/runbooks/HEALTH-ALERTS.md).

.DESCRIPTION
  Reads the deployment through Azure Resource Manager only (no Microsoft Graph), checks which public
  health endpoints answer, and deploys infra/monitoring/health-alerts.bicep in Incremental mode.
  Every resource it creates is named <stem>-health-* and tagged ccof-component=health-alerts.

  (default)           Preview: what-if; lists the changes; nothing is changed.
  -Apply              The same what-if, then the deployment. Any Delete, or any Create or Modify of a
                      resource this add-on does not own, stops the run before deployment (exit 3).
  -TestNotification   Asks Azure Monitor to send a test e-mail through the owned action group.
  -Remove             Lists the owned resources; with -Apply deletes them and nothing else.

  Exit codes: 0 done, 2 input refused, 3 refused or failed.

.EXAMPLE
  pwsh -File infra/monitoring/Invoke-HealthAlerts.ps1 -ConfigPath ~/health.config.json
  pwsh -File infra/monitoring/Invoke-HealthAlerts.ps1 -ConfigPath ~/health.config.json -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ConfigPath,
    [switch]$Apply,
    [switch]$Remove,
    [switch]$TestNotification,
    [string]$StateDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $PSScriptRoot 'HealthAlerts.psm1') -Force
function Stop-Ha([string]$Message, [int]$Code) { [Console]::Error.WriteLine($Message); exit $Code }

# One az call; JSON out. -AllowMissing returns $null for a 404; -Soft returns @{ error } instead of throwing.
function Invoke-HaAz([string[]]$Arguments, [switch]$AllowMissing, [switch]$Soft) {
    Assert-HaAzArguments $Arguments
    $ErrorActionPreference = 'Continue'
    $out = try { & az @Arguments --output json --only-show-errors 2>&1 } catch { $_ }
    $code = $LASTEXITCODE
    $err = (@($out | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) -join ' ').Trim()
    $text = (@($out | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) -join "`n").Trim()
    if ($code -ne 0) {
        if ($AllowMissing -and $err -match 'NotFound|could not be found|\(404\)|Not Found') { return $null }
        $short = "az $($Arguments[0..([Math]::Min(2, $Arguments.Count - 1))] -join ' ') failed: $($err.Substring(0, [Math]::Min(400, $err.Length)))"
        if ($Soft) { return @{ error = $short } }
        throw $short
    }
    if (-not $text) { return $null }
    return $text | ConvertFrom-Json -AsHashtable -Depth 100
}
function Get-HaArm([string]$Path, [string]$ApiVersion, [switch]$AllowMissing, [switch]$Soft) {
    Invoke-HaAz @('rest', '--method', 'get', '--url', "https://management.azure.com${Path}?api-version=$ApiVersion") -AllowMissing:$AllowMissing -Soft:$Soft
}
function Get-HaMetricNames([string]$Id) {
    $defs = Get-HaArm "$Id/providers/Microsoft.Insights/metricDefinitions" '2018-01-01' -Soft
    if ($defs -and $defs.Contains('error')) { return $defs }
    return @{ names = @($defs.value | ForEach-Object { $_.name.value }) }
}

# az resource list refuses --tag together with --resource-group; the tag is checked in Select-HaOwnedResources.
function Get-HaOwned {
    $all = @(Invoke-HaAz @('resource', 'list', '--subscription', $sub, '--resource-group', $rg) | Where-Object { $_ })
    $script:SmartDetectionGroup = @($all | Where-Object { "$($_.type)" -eq 'microsoft.insights/actiongroups' -and $_.name -ceq 'Application Insights Smart Detection' }).Count -gt 0
    Select-HaOwnedResources $all $prefix
}

try { $cfg = Read-HaConfig $ConfigPath } catch { Stop-Ha "$_" 2 }
if ($Remove -and $TestNotification) { Stop-Ha 'input_refused: -Remove and -TestNotification are separate runs.' 2 }
if (-not $env:AZURE_CONFIG_DIR -and -not $env:ACC_CLOUD) {
    Stop-Ha 'Set AZURE_CONFIG_DIR to an Azure CLI profile signed in to the target tenant (workstation), or run in Azure Cloud Shell.' 2
}
$sub = [string]$cfg.subscriptionId; $rg = [string]$cfg.resourceGroup; $stem = [string]$cfg.stem
$prefix = "$stem-health"
$base = "/subscriptions/$sub/resourceGroups/$rg/providers"
$stateDir = if ($StateDirectory) { [IO.Path]::GetFullPath($StateDirectory) } else { Join-Path (Split-Path (Resolve-Path -LiteralPath $ConfigPath).Path -Parent) '.health-alerts' }
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$mode = if ($Apply) { 'apply' } else { 'preview' }

try {
    if ($Remove) {
        Write-Host "== health alerts remove ($mode), resource group $rg, prefix $prefix"
        $owned = @(Get-HaOwned)
        if (-not $owned.Count) { Write-Host 'No owned health-alert resource found. Nothing to remove.'; exit 0 }
        $owned | ForEach-Object { Write-Host ("  {0,-8} {1}" -f $(if ($Apply) { 'Delete' } else { 'Would delete' }), $_.id) }
        if (-not $Apply) { Write-Host "Preview only. $($owned.Count) owned resources; rerun with -Remove -Apply to delete them."; exit 0 }
        foreach ($r in $owned) { $null = Invoke-HaAz @('resource', 'delete', '--ids', $r.id) }
        Write-Host "Removed $($owned.Count) owned resources. No other resource was changed."
        if ($script:SmartDetectionGroup) {
            Write-Host "Left in place: action group 'Application Insights Smart Detection'. Azure creates it for the Failure Anomalies rules of any Application Insights component in $rg, so it can be shared. When no rule uses it: az monitor action-group delete --resource-group $rg --name 'Application Insights Smart Detection'"
        }
        exit 0
    }
    if ($TestNotification) {
        $agPath = "$base/Microsoft.Insights/actionGroups/$prefix-ag"
        if (-not (Get-HaArm $agPath '2023-01-01' -AllowMissing)) { Stop-Ha "action_group_missing: $prefix-ag does not exist; run with -Apply first." 3 }
        $bodyFile = Join-Path $stateDir 'test-notification.json'
        New-HaTestNotificationBody $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM
        $null = Invoke-HaAz @('rest', '--method', 'post', '--url', "https://management.azure.com$agPath/createNotifications?api-version=2021-09-01", '--headers', 'Content-Type=application/json', '--body', "@$bodyFile")
        Write-Host "Test notification accepted for $(@($cfg.emailReceivers).Count) receivers of $prefix-ag. Delivery can take a few minutes."
        exit 0
    }

    Write-Host "== health alerts ($mode), subscription $sub, resource group $rg, stem $stem"
    $rgObj = Get-HaArm "/subscriptions/$sub/resourcegroups/$rg" '2021-04-01' -AllowMissing
    if (-not $rgObj) { Stop-Ha "resource_group_missing: $rg in $sub." 3 }
    $wsId = if ($cfg['workspaceId']) { [string]$cfg.workspaceId } else { "$base/Microsoft.OperationalInsights/workspaces/$stem-law" }
    $ws = Get-HaArm $wsId '2023-09-01' -AllowMissing
    if (-not $ws) { Stop-Ha "workspace_missing: $wsId (Stage 1 creates <stem>-law; set workspaceId otherwise)." 3 }
    $notes = [System.Collections.Generic.List[string]]::new()
    $apps = [ordered]@{}
    foreach ($a in 'resolver', 'sync', 'reconciler', 'admin') {
        $comp = Get-HaArm "$base/Microsoft.Insights/components/$stem-$a-ai" '2020-02-02' -AllowMissing
        $site = Get-HaArm "$base/Microsoft.Web/sites/$stem-$a" '2023-12-01' -AllowMissing
        if (-not $comp -or -not $site) {
            if ($a -eq 'admin') { $notes.Add('admin app: not found, admin probes and its errors are not covered'); continue }
            Stop-Ha "stage1_resource_missing: $stem-$a or $stem-$a-ai not found in $rg." 3
        }
        $pna = [string]$site.properties['publicNetworkAccess']; if (-not $pna) { $pna = 'Enabled' }
        $apps[$a] = @{ componentId = [string]$comp.id; siteId = [string]$site.id; host = [string]$site.properties.defaultHostName; publicNetworkAccess = $pna }
    }
    $cosmosId = "$base/Microsoft.DocumentDB/databaseAccounts/$stem-cosmos"
    if (-not (Get-HaArm $cosmosId '2024-11-15' -AllowMissing)) { Stop-Ha "stage1_resource_missing: $stem-cosmos." 3 }
    $apimId = if ($cfg['apim'] -and $cfg.apim['id']) { [string]$cfg.apim.id } else { "$base/Microsoft.ApiManagement/service/$stem-apim" }
    $apimObj = Get-HaArm $apimId '2024-05-01' -AllowMissing
    if (-not $apimObj) { Stop-Ha "apim_missing: $apimId; set apim.id to the existing APIM resource ID." 3 }
    $apiId = if ($cfg['apim'] -and $cfg.apim['apiId']) { [string]$cfg.apim.apiId } else { 'claude-messages' }
    if (-not (Get-HaArm "$apimId/apis/$apiId" '2024-05-01' -AllowMissing)) { Stop-Ha "apim_api_missing: API '$apiId' not found on $apimId; set apim.apiId (staged config apim.apiId)." 3 }
    $apimMetrics = Get-HaMetricNames $apimId
    $capacity = if ($apimMetrics.Contains('error')) { '' } elseif ($apimMetrics.names -contains 'Capacity') { 'Capacity' } elseif ($apimMetrics.names -contains 'CpuPercent_Gateway') { 'CpuPercent_Gateway' } else { '' }
    if (-not $capacity) { $notes.Add('apim: neither Capacity nor CpuPercent_Gateway metric found; no capacity alert') }
    $apimPna = [string]$apimObj.properties['publicNetworkAccess']; if (-not $apimPna) { $apimPna = 'Enabled' }
    $apim = @{ id = [string]$apimObj.id; gatewayHost = ([uri][string]$apimObj.properties.gatewayUrl).Host; apiId = $apiId; capacityMetric = $capacity
        publicNetworkAccess = $apimPna; logWorkspaceId = $(if ($cfg['apim'] -and $cfg.apim['logWorkspaceId']) { [string]$cfg.apim.logWorkspaceId } else { [string]$ws.id }) }
    $foundry = foreach ($id in @($cfg['foundryAccountIds'] | Where-Object { $_ })) {
        $name = ($id -split '/')[-1]
        if (($id -split '/')[2] -ne $sub -and -not ($cfg['allowCrossSubscriptionFoundry'] -eq $true)) { $notes.Add("foundry ${name}: skipped, another subscription (allowCrossSubscriptionFoundry true includes it)"); continue }
        $m = Get-HaMetricNames $id
        if ($m.Contains('error')) { $notes.Add("foundry ${name}: skipped, metric definitions unreadable: $($m.error)"); continue }
        $metric = if ($m.names -contains 'ModelRequests') { 'ModelRequests' } elseif ($m.names -contains 'ServerErrors') { 'ServerErrors' } else { $null }
        if (-not $metric) { $notes.Add("foundry ${name}: skipped, no ModelRequests or ServerErrors metric"); continue }
        @{ id = $id; metric = $metric }
    }
    $fd = $null
    if ($cfg['frontDoor']) {
        $fd = @{ host = [string]$cfg.frontDoor.host; profileId = $null }
        if ($cfg.frontDoor['profileId']) {
            if (Get-HaArm $cfg.frontDoor.profileId '2024-02-01' -AllowMissing) { $fd.profileId = [string]$cfg.frontDoor.profileId }
            else { $notes.Add("front door: profile $($cfg.frontDoor.profileId) not found; no Front Door metric alerts") }
        }
    }
    $disc = @{ location = [string]$ws.location; workspaceId = [string]$ws.id; apps = $apps; cosmosId = $cosmosId; apim = $apim; foundry = @($foundry); frontDoor = $fd }

    $probeGet = {
        param($Url)
        try { [int](Invoke-WebRequest -Uri $Url -Method Get -SkipHttpErrorCheck -TimeoutSec 30 -MaximumRedirection 0).StatusCode } catch { 0 }
    }
    $probes = Resolve-HaProbes (Get-HaProbeCandidates $cfg $disc) $probeGet
    $parameters = New-HaParameters -Cfg $cfg -Discovered $disc -WebTests $probes.included -RepoRoot $repo
    foreach ($n in @($probes.notes) + @($notes)) { Write-Host "  note: $n" }
    Write-Host "Action group $prefix-ag: $(@($cfg.emailReceivers) -join ', ')"
    foreach ($t in $parameters.webTests) { Write-Host ("  web test   {0,-16} GET {1} expects {2}" -f $t.key, $t.url, $t.expectedStatus) }
    foreach ($r in @($parameters.metricRules) + @($parameters.logRules)) { Write-Host ("  alert sev{0} {1} threshold {2} window {3}" -f $r.severity, $r.name, $r.threshold, $r.window) }

    $parameterFile = Join-Path $stateDir 'health-alerts.parameters.json'
    $doc = [ordered]@{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = [ordered]@{} }
    foreach ($k in $parameters.Keys) { $doc.parameters[$k] = @{ value = $parameters[$k] } }
    $doc | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $parameterFile -Encoding utf8NoBOM
    $common = @('--subscription', $sub, '--resource-group', $rg, '--name', 'ccof-health-alerts', '--template-file', (Join-Path $PSScriptRoot 'health-alerts.bicep'), '--parameters', "@$parameterFile")
    $whatIf = Invoke-HaAz (@('deployment', 'group', 'what-if') + $common + @('--no-pretty-print'))
    $changes = @($whatIf.changes | Where-Object { $_ })
    $changes | Group-Object { $_.changeType } | ForEach-Object { Write-Host "$($_.Name)=$($_.Count)" }
    $changes | Where-Object { $_.changeType -notin 'NoChange', 'Ignore' } | ForEach-Object { Write-Host ("  {0,-8} {1}" -f $_.changeType, $_.resourceId) }
    $problems = @(Get-HaWhatIfProblems $changes $prefix)
    if ($problems.Count) { Stop-Ha "whatif_refused: this add-on changes only resources it owns. $($problems -join '; ')" 3 }
    if (-not $Apply) { Write-Host "Preview only. No changes were made. Parameters: $parameterFile"; exit 0 }
    $deployment = Invoke-HaAz (@('deployment', 'group', 'create', '--mode', 'Incremental') + $common)
    if ([string]$deployment.properties.provisioningState -cne 'Succeeded') { Stop-Ha "deployment_failed: $($deployment.properties.provisioningState)" 3 }
    $owned = @(Get-HaOwned)
    Write-Host "Deployed. Owned resources now in ${rg}: $($owned.Count)"
    $owned | ForEach-Object { Write-Host "  $($_.type) $($_.name)" }
    Write-Host 'Next: -TestNotification sends a test e-mail through the action group.'
    exit 0
} catch {
    Stop-Ha "health_alerts_failed: $_" 3
}
