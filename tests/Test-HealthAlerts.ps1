#Requires -Version 7.0
# Offline tests for the health and outage e-mail alert add-on (infra/monitoring): configuration
# validation, parameter composition against the admin Health page's signals, owned-resource tagging,
# the what-if guard, removal selection, and infra/monitoring/Invoke-HealthAlerts.ps1 end to end with a
# stub `az` and a stub Invoke-WebRequest in a child pwsh. No Azure call is made.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:fail = 0; $script:pass = 0
function Check([string]$Name, $Ok) { if (@($Ok | Where-Object { $_ }).Count -gt 0) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'infra/monitoring/HealthAlerts.psm1') -Force

$sub = '00000000-0000-4000-8000-000000000002'
$otherSub = '00000000-0000-4000-8000-000000000009'
$rg = 'rg-sample'
$stem = 'sample-abc123'
$prov = "/subscriptions/$sub/resourceGroups/$rg/providers"
function New-Cfg([hashtable]$Extra = @{}) {
    $c = [ordered]@{
        schemaVersion = 1; subscriptionId = $sub; resourceGroup = $rg; stem = $stem
        emailReceivers = @('ops@example.com', 'oncall@example.org')
        frontDoor = [ordered]@{ host = 'sample-fd.z01.azurefd.net'; profileId = "$prov/Microsoft.Cdn/profiles/sample-fd" }
        foundryAccountIds = @("$prov/Microsoft.CognitiveServices/accounts/sample-foundry")
    }
    foreach ($k in $Extra.Keys) { $c[$k] = $Extra[$k] }
    return ($c | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable)
}
function New-Discovered([switch]$NoFrontDoor, [switch]$NoAdmin) {
    $apps = [ordered]@{}
    foreach ($a in 'resolver', 'sync', 'reconciler', 'admin') {
        if ($NoAdmin -and $a -eq 'admin') { continue }
        $apps[$a] = @{ componentId = "$prov/Microsoft.Insights/components/$stem-$a-ai"; siteId = "$prov/Microsoft.Web/sites/$stem-$a"
            host = "$stem-$a.azurewebsites.net"; publicNetworkAccess = $(if ($a -eq 'resolver') { 'Enabled' } else { 'Disabled' }) }
    }
    @{
        location = 'eastus2'; workspaceId = "$prov/Microsoft.OperationalInsights/workspaces/$stem-law"
        apps = $apps; cosmosId = "$prov/Microsoft.DocumentDB/databaseAccounts/$stem-cosmos"
        apim = @{ id = "$prov/Microsoft.ApiManagement/service/$stem-apim"; gatewayHost = "$stem-apim.azure-api.net"; apiId = 'claude-messages'
            capacityMetric = 'Capacity'; publicNetworkAccess = 'Disabled'; logWorkspaceId = "$prov/Microsoft.OperationalInsights/workspaces/$stem-law" }
        foundry = @(@{ id = "$prov/Microsoft.CognitiveServices/accounts/sample-foundry"; metric = 'ModelRequests' })
        frontDoor = $(if ($NoFrontDoor) { $null } else { @{ host = 'sample-fd.z01.azurefd.net'; profileId = "$prov/Microsoft.Cdn/profiles/sample-fd" } })
    }
}
function Problems($Cfg) { , @(Get-HaConfigProblems $Cfg) }

# ---- configuration validation
$example = Get-Content -LiteralPath (Join-Path $repo 'infra/monitoring/health.config.example.json') -Raw | ConvertFrom-Json -AsHashtable
Check 'example config: only REPLACE placeholders are refused' (@(Problems $example | Where-Object { $_ -notmatch 'REPLACE' }).Count -eq 0 -and @(Problems $example).Count -gt 0)
Check 'sample config is valid' ((Problems (New-Cfg)).Count -eq 0)
Check 'empty emailReceivers is refused' ((Problems (New-Cfg @{ emailReceivers = @() })) -match 'emailReceivers')
$noReceivers = New-Cfg; $noReceivers.Remove('emailReceivers')
Check 'missing emailReceivers is refused' ((Problems $noReceivers) -match 'emailReceivers')
Check 'an invalid address is refused' ((Problems (New-Cfg @{ emailReceivers = @('not-an-address') })) -match 'emailReceivers')
Check 'a display-name address is refused' ((Problems (New-Cfg @{ emailReceivers = @('Ops <ops@example.com>') })) -match 'emailReceivers')
Check 'a duplicate address (any case) is refused' ((Problems (New-Cfg @{ emailReceivers = @('ops@example.com', 'OPS@example.com') })) -match 'duplicate')
Check 'an unknown top-level field is refused' ((Problems (New-Cfg @{ emailRecievers = @('x@example.com') })) -match 'unknown_field:emailRecievers')
Check 'a non-GUID subscription is refused' ((Problems (New-Cfg @{ subscriptionId = 'abc' })) -match 'subscriptionId')
Check 'a stem with unsafe characters is refused' ((Problems (New-Cfg @{ stem = 'bad stem&' })) -match 'stem')
Check 'a Front Door host with a scheme is refused' ((Problems (New-Cfg @{ frontDoor = @{ host = 'https://x.azurefd.net' } })) -match 'frontDoor.host')
Check 'a probe mode other than auto/on/off is refused' ((Problems (New-Cfg @{ probes = @{ apimDirect = 'yes' } })) -match 'probes.apimDirect')
Check 'an unknown probe is refused' ((Problems (New-Cfg @{ probes = @{ graph = 'on' } })) -match 'probes.graph')
Check 'an unknown rule is refused' ((Problems (New-Cfg @{ rules = @{ cpu = @{ threshold = 1 } } })) -match 'rules.cpu')
Check 'a severity outside 0-4 is refused' ((Problems (New-Cfg @{ rules = @{ apimGateway5xx = @{ severity = 5 } } })) -match 'rules.apimGateway5xx.severity')
Check 'a metric window Azure does not accept is refused' ((Problems (New-Cfg @{ rules = @{ cosmosThrottled = @{ windowMinutes = 7 } } })) -match 'rules.cosmosThrottled.windowMinutes')
Check 'an evaluation frequency Azure does not accept is refused' ((Problems (New-Cfg @{ evaluationFrequencyMinutes = 2 })) -match 'evaluationFrequencyMinutes')
Check 'a Foundry ID that is not a Cognitive Services account is refused' ((Problems (New-Cfg @{ foundryAccountIds = @("$prov/Microsoft.Web/sites/x") })) -match 'foundryAccountIds')
Check 'more than 20 receivers is refused' ((Problems (New-Cfg @{ emailReceivers = @(1..21 | ForEach-Object { "u$_@example.com" }) })) -match 'emailReceivers')
Check 'a non-string tag value is refused' ((Problems (New-Cfg @{ tags = @{ a = @{ b = 1 } } })) -match 'tags')

# ---- probes: candidates and the live check
$cfg = New-Cfg
$disc = New-Discovered
$cand = @(Get-HaProbeCandidates $cfg $disc)
$keys = @($cand | ForEach-Object { $_.key })
Check 'probe candidates: gateway and admin through Front Door, APIM, admin and resolver direct' (($keys -join ',') -ceq 'gateway-fd,admin-fd,gateway-direct,admin-direct,resolver-direct')
Check 'probe candidates: the paths and expected codes match the Front Door verify and the resolver health route' (
    ($cand | Where-Object { $_.key -eq 'gateway-fd' }).url -ceq 'https://sample-fd.z01.azurefd.net/status-0123456789abcdef' -and
    ($cand | Where-Object { $_.key -eq 'admin-fd' }).url -ceq 'https://sample-fd.z01.azurefd.net/api/console' -and
    ($cand | Where-Object { $_.key -eq 'resolver-direct' }).url -ceq "https://$stem-resolver.azurewebsites.net/api/health" -and
    ($cand | Where-Object { $_.key -eq 'resolver-direct' }).expectedStatus -eq 401 -and ($cand | Where-Object { $_.key -eq 'gateway-direct' }).expectedStatus -eq 200)
Check 'probe candidates: no Front Door host -> no Front Door probe' (@(Get-HaProbeCandidates (New-Cfg @{ frontDoor = $null }) (New-Discovered -NoFrontDoor) | Where-Object { $_.key -like '*-fd' }).Count -eq 0)
Check 'probe candidates: no admin app -> no admin probe' (@(Get-HaProbeCandidates $cfg (New-Discovered -NoAdmin) | Where-Object { $_.key -like 'admin-*' }).Count -eq 0)
$codes = @{ 'https://sample-fd.z01.azurefd.net/status-0123456789abcdef' = 200; 'https://sample-fd.z01.azurefd.net/api/console' = 200
    "https://$stem-apim.azure-api.net/status-0123456789abcdef" = 200; "https://$stem-admin.azurewebsites.net/api/console" = 403
    "https://$stem-resolver.azurewebsites.net/api/health" = 401 }
$script:probed = @()
$get = { param($u) $script:probed += $u; $codes[$u] }
$res = Resolve-HaProbes $cand $get
$inc = @($res.included | ForEach-Object { $_.key })
Check 'locked-down: APIM and admin with public access disabled are not probed directly; Front Door is' (($inc -join ',') -ceq 'gateway-fd,admin-fd,resolver-direct')
Check 'locked-down: the direct APIM URL is never requested when ARM reports public access disabled' ($script:probed -notcontains "https://$stem-apim.azure-api.net/status-0123456789abcdef")
Check 'locked-down: every included web test URL uses the Front Door host or the public resolver' (@($res.included | Where-Object { $_.url -notmatch '^https://(sample-fd\.z01\.azurefd\.net|sample-abc123-resolver\.azurewebsites\.net)/' }).Count -eq 0)
Check 'auto: a public endpoint answering an unexpected code is left out with a note' (
    @((Resolve-HaProbes @($cand | Where-Object { $_.key -eq 'resolver-direct' }) { 503 }).included).Count -eq 0 -and
    ((Resolve-HaProbes @($cand | Where-Object { $_.key -eq 'resolver-direct' }) { 503 }).notes -join ' ') -match 'resolver-direct.*503.*401')
$on = @($cand | ForEach-Object { $x = $_.Clone(); if ($x.key -eq 'admin-direct') { $x.mode = 'on' }; $x })
Check 'on: included even when public access is disabled, with a warning' (@((Resolve-HaProbes $on $get).included | Where-Object { $_.key -eq 'admin-direct' }).Count -eq 1 -and ((Resolve-HaProbes $on $get).notes -join ' ') -match 'admin-direct')
$script:probed = @()
$off = @($cand | ForEach-Object { $x = $_.Clone(); $x.mode = 'off'; $x })
Check 'off: nothing included and nothing requested' (@((Resolve-HaProbes $off $get).included).Count -eq 0 -and $script:probed.Count -eq 0)

# ---- parameter composition
$p = New-HaParameters -Cfg $cfg -Discovered $disc -WebTests $res.included -RepoRoot $repo
$metricNames = @($p.metricRules | ForEach-Object { $_.name })
$logNames = @($p.logRules | ForEach-Object { $_.name })
$all = $metricNames + $logNames
$prefix = "$stem-health"
Check 'names: every rule, web test, component and action group starts with <stem>-health-' (
    @($all | Where-Object { -not $_.StartsWith("$prefix-") }).Count -eq 0 -and $p.namePrefix -ceq $prefix)
foreach ($n in 'apim-gateway-5xx', 'apim-backend-5xx', 'apim-capacity', 'cosmos-throttled', 'cosmos-server-errors', 'cosmos-availability', 'frontdoor-origin-health', 'frontdoor-5xx') {
    Check "metric rule present: $n" ($metricNames -contains "$prefix-$n")
}
foreach ($n in 'resolver-unavailable', 'gateway-telemetry-silent', 'function-server-errors', 'sync-run-failures', 'reconciler-run-failures', 'reconciler-stale') {
    Check "log rule present: $n" ($logNames -contains "$prefix-$n")
}
Check 'Foundry: one rule per readable account, on the account' (@($p.metricRules | Where-Object { $_.name -like "$prefix-foundry-*" -and $_.scope -ceq $disc.foundry[0].id -and $_.metric -ceq 'ModelRequests' }).Count -eq 1)
# Admin Health page (admin/ui-v3/pages/health.tsx) -> rules: every panel has at least one alert.
$q = @{}; foreach ($r in $p.logRules) { $q[$r.name] = $r.query }
Check 'Health page "Reconciler freshness" -> reconciler-stale reads written runs of the reconciler app and component' (
    $q["$prefix-reconciler-stale"] -match '"written"' -and $q["$prefix-reconciler-stale"].Contains($disc.apps.reconciler.siteId) -and $q["$prefix-reconciler-stale"].Contains($disc.apps.reconciler.componentId))
Check 'Health page "Telemetry freshness" -> gateway-telemetry-silent reads the gateway log of this APIM and API' (
    $q["$prefix-gateway-telemetry-silent"] -match 'ApiManagementGatewayLogs' -and $q["$prefix-gateway-telemetry-silent"].Contains($disc.apim.id) -and $q["$prefix-gateway-telemetry-silent"] -match "_apiId = 'claude-messages'")
Check 'Health page "Admin app" and "Endpoint probes" -> web tests and server errors cover all four apps' (
    @($disc.apps.Keys | Where-Object { -not $q["$prefix-function-server-errors"].Contains($disc.apps[$_].componentId) }).Count -eq 0 -and @($p.webTests).Count -eq 3)
Check 'Health page "Project registry (Cosmos DB)" -> Cosmos availability, 429 and 5xx' (@($p.metricRules | Where-Object { $_.scope -ceq $disc.cosmosId }).Count -eq 3)
Check 'gateway 503 entitlement_unavailable -> resolver outcome unavailable in TraceRecords ccof.resolver.v1' (
    $q["$prefix-resolver-unavailable"] -match 'ccof\.resolver\.v1' -and $q["$prefix-resolver-unavailable"] -match '"unavailable"')
Check 'sync failures: ccof.sync.run.v1 outcome failed or partial, sync app only' (
    $q["$prefix-sync-run-failures"] -match '"failed", "partial"' -and $q["$prefix-sync-run-failures"].Contains($disc.apps.sync.componentId) -and -not $q["$prefix-sync-run-failures"].Contains($disc.apps.reconciler.componentId))
Check 'reconciler failures: refused (ledger_continuity_gap), failed, settings_invalid, split by reason' (
    $q["$prefix-reconciler-run-failures"] -match '"refused"' -and $q["$prefix-reconciler-run-failures"] -match 'by reason' -and
    @(($p.logRules | Where-Object { $_.name -eq "$prefix-reconciler-run-failures" }).dimensions | ForEach-Object { $_.name }) -contains 'reason')
Check 'run failures count distinct runIds (a run line can be in both FunctionAppLogs and AppTraces)' (
    $q["$prefix-sync-run-failures"] -match 'dcount\(tostring\(d\.runId\)\)' -and $q["$prefix-reconciler-run-failures"] -match 'dcount\(tostring\(d\.runId\)\)')
Check 'each log query starts with its let preamble and has no unresolved placeholder' (@($p.logRules | Where-Object { $_.query -notmatch '^let ' -or $_.query -match '\{\d\}' }).Count -eq 0)
Check 'availability: one alert per web test with the failed-location threshold' (@($p.availability).Count -eq 3 -and @($p.availability | Where-Object { $_.failedLocationCount -ne 2 }).Count -eq 0)
Check 'common alert schema on every receiver' (@($p.emailReceivers | Where-Object { $_.useCommonAlertSchema -ne $true }).Count -eq 0 -and @($p.emailReceivers).Count -eq 2)
Check 'owned tag: ccof-component=health-alerts survives a config tag that tries to override it' (
    (New-HaParameters -Cfg (New-Cfg @{ tags = @{ 'ccof-component' = 'other'; owner = 'ops' } }) -Discovered $disc -WebTests @() -RepoRoot $repo).tags['ccof-component'] -ceq 'health-alerts')
$pNoFd = New-HaParameters -Cfg (New-Cfg @{ frontDoor = $null }) -Discovered (New-Discovered -NoFrontDoor) -WebTests @() -RepoRoot $repo
Check 'Front Door optional: without it no Front Door rule' (@($pNoFd.metricRules | Where-Object { $_.name -like '*frontdoor*' }).Count -eq 0)
$pOff = New-HaParameters -Cfg (New-Cfg @{ rules = @{ reconcilerStale = @{ enabled = $false }; apimGateway5xx = @{ threshold = 25; severity = 0 } } }) -Discovered $disc -WebTests @() -RepoRoot $repo
Check 'a disabled rule is not deployed' (@($pOff.logRules | Where-Object { $_.name -eq "$prefix-reconciler-stale" }).Count -eq 0)
$g = $pOff.metricRules | Where-Object { $_.name -eq "$prefix-apim-gateway-5xx" }
Check 'threshold and severity overrides are applied' ($g.threshold -eq 25 -and $g.severity -eq 0)
Check 'durations: 60 minutes is PT1H, 15 is PT15M; frequency never exceeds the window' (
    ($p.metricRules | Where-Object { $_.name -eq "$prefix-cosmos-availability" }).window -ceq 'PT1H' -and ($p.metricRules | Where-Object { $_.name -eq "$prefix-cosmos-throttled" }).window -ceq 'PT15M' -and
    ($p.metricRules | Where-Object { $_.name -eq "$prefix-cosmos-availability" }).frequency -ceq 'PT1H')
$discNoFoundry = New-Discovered; $discNoFoundry.foundry = @(@{ id = "$prov/Microsoft.CognitiveServices/accounts/sample-foundry"; metric = $null })
Check 'an unreadable Foundry account (no metric) gets no rule' (@((New-HaParameters -Cfg $cfg -Discovered $discNoFoundry -WebTests @() -RepoRoot $repo).metricRules | Where-Object { $_.name -like '*foundry*' }).Count -eq 0)
Check 'description names the runbook section on every rule' (@(@($p.metricRules) + @($p.logRules) | Where-Object { $_.description -notmatch 'HEALTH-ALERTS\.md' }).Count -eq 0)

# ---- what-if guard
function Change([string]$Type, [string]$Id, $Before = $null) { @{ changeType = $Type; resourceId = $Id; before = $Before } }
$ownedAg = "$prov/Microsoft.Insights/actionGroups/$prefix-ag"
$tagged = @{ tags = @{ 'ccof-component' = 'health-alerts' } }
Check 'what-if: Create of owned resources passes' (@(Get-HaWhatIfProblems @((Change 'Create' $ownedAg), (Change 'Create' "$prov/Microsoft.Insights/scheduledQueryRules/$prefix-sync-run-failures")) $prefix).Count -eq 0)
Check 'what-if: Modify of an owned, tagged resource passes (re-apply)' (@(Get-HaWhatIfProblems @(Change 'Modify' $ownedAg $tagged) $prefix).Count -eq 0)
Check 'what-if: Modify of an owned name without the tag is refused' (@(Get-HaWhatIfProblems @(Change 'Modify' $ownedAg @{ tags = @{} }) $prefix) -match 'not_owned')
Check 'what-if: Modify of a Function App is refused' (@(Get-HaWhatIfProblems @(Change 'Modify' "$prov/Microsoft.Web/sites/$stem-admin" $tagged) $prefix) -match 'Microsoft.Web/sites')
Check 'what-if: Delete is refused even for owned resources' (@(Get-HaWhatIfProblems @(Change 'Delete' $ownedAg $tagged) $prefix) -match 'Delete')
Check 'what-if: Create of a resource of another type with the prefix is refused' (@(Get-HaWhatIfProblems @(Change 'Create' "$prov/Microsoft.Web/sites/$prefix-x") $prefix) -match 'not_owned')
Check 'what-if: NoChange and Ignore on other resources pass' (@(Get-HaWhatIfProblems @((Change 'NoChange' "$prov/Microsoft.Web/sites/$stem-admin"), (Change 'Ignore' "$prov/Microsoft.ApiManagement/service/$stem-apim")) $prefix).Count -eq 0)

# ---- removal selection
$res = @(
    @{ id = "$prov/Microsoft.Insights/actionGroups/$prefix-ag"; name = "$prefix-ag"; type = 'Microsoft.Insights/actionGroups'; tags = @{ 'ccof-component' = 'health-alerts' } }
    @{ id = "$prov/Microsoft.Insights/components/$prefix-ai"; name = "$prefix-ai"; type = 'Microsoft.Insights/components'; tags = @{ 'ccof-component' = 'health-alerts' } }
    @{ id = "$prov/Microsoft.Insights/webtests/$prefix-wt-gateway-fd"; name = "$prefix-wt-gateway-fd"; type = 'Microsoft.Insights/webtests'; tags = @{ 'ccof-component' = 'health-alerts' } }
    @{ id = "$prov/Microsoft.Insights/metricAlerts/$prefix-cosmos-throttled"; name = "$prefix-cosmos-throttled"; type = 'Microsoft.Insights/metricAlerts'; tags = @{ 'ccof-component' = 'health-alerts' } }
    @{ id = "$prov/Microsoft.Insights/scheduledQueryRules/$prefix-sync-run-failures"; name = "$prefix-sync-run-failures"; type = 'Microsoft.Insights/scheduledQueryRules'; tags = @{ 'ccof-component' = 'health-alerts' } }
    @{ id = "$prov/microsoft.alertsmanagement/smartDetectorAlertRules/Failure Anomalies - $prefix-ai"; name = "Failure Anomalies - $prefix-ai"; type = 'microsoft.alertsmanagement/smartDetectorAlertRules'; tags = @{} }
    @{ id = "$prov/microsoft.alertsmanagement/smartDetectorAlertRules/Failure Anomalies - $stem-admin-ai"; name = "Failure Anomalies - $stem-admin-ai"; type = 'microsoft.alertsmanagement/smartDetectorAlertRules'; tags = @{} }
    @{ id = "$prov/Microsoft.Insights/components/$stem-admin-ai"; name = "$stem-admin-ai"; type = 'Microsoft.Insights/components'; tags = @{ 'ccof-component' = 'health-alerts' } }
    @{ id = "$prov/Microsoft.Insights/actionGroups/$prefix-old"; name = "$prefix-old"; type = 'Microsoft.Insights/actionGroups'; tags = @{ team = 'ops' } }
    @{ id = "$prov/Microsoft.Web/sites/$stem-admin"; name = "$stem-admin"; type = 'Microsoft.Web/sites'; tags = @{} }
    @{ id = "$prov/microsoft.insights/actiongroups/Application Insights Smart Detection"; name = 'Application Insights Smart Detection'; type = 'microsoft.insights/actiongroups'; tags = $null }
)
$sel = @(Select-HaOwnedResources $res $prefix)
$selNames = @($sel | ForEach-Object { $_.name })
Check 'remove: only tagged resources with the prefix, plus the component''s own Failure Anomalies rule, each once' (
    $selNames.Count -eq 6 -and $selNames -notcontains "$stem-admin-ai" -and $selNames -notcontains "$prefix-old" -and $selNames -notcontains "$stem-admin" -and $selNames -notcontains "Failure Anomalies - $stem-admin-ai" -and
    @(Select-HaOwnedResources @($res + $res) $prefix).Count -eq 6)
Check 'remove: alert rules first, web tests before the component, action group last' (
    $selNames[-1] -ceq "$prefix-ag" -and [array]::IndexOf($selNames, "$prefix-wt-gateway-fd") -lt [array]::IndexOf($selNames, "$prefix-ai") -and
    [array]::IndexOf($selNames, "$prefix-cosmos-throttled") -lt [array]::IndexOf($selNames, "$prefix-wt-gateway-fd"))

# ---- template
$built = (& az bicep build --file (Join-Path $repo 'infra/monitoring/health-alerts.bicep') --stdout --only-show-errors 2>$null) -join "`n"
$arm = try { $built | ConvertFrom-Json -AsHashtable -Depth 100 } catch { $null }
Check 'health-alerts.bicep builds' ($null -ne $arm)
if ($arm) {
    $armResources = @(if ($arm.resources -is [System.Collections.IDictionary]) { $arm.resources.Values } else { $arm.resources })
    $types = @($armResources | ForEach-Object { $_.type } | Sort-Object -Unique)
    Check 'template: only action group, component, web tests, metric alerts and log alerts' (
        @($types | Where-Object { $_ -notin 'Microsoft.Insights/actionGroups', 'Microsoft.Insights/components', 'Microsoft.Insights/webtests', 'Microsoft.Insights/metricAlerts', 'Microsoft.Insights/scheduledQueryRules' }).Count -eq 0)
    Check 'template: log alerts have no managed identity and every resource carries the owned tags' (
        $built -notmatch '"identity"' -and @($armResources | Where-Object { "$($_.tags)" -notmatch 'ownedTags|union' }).Count -eq 0)
}
$texts = @('infra/monitoring/Invoke-HealthAlerts.ps1', 'infra/monitoring/HealthAlerts.psm1', 'infra/monitoring/health-alerts.bicep') | ForEach-Object { Get-Content -LiteralPath (Join-Path $repo $_) -Raw }
Check 'no Microsoft Graph and no az ad in the add-on' (@($texts | Where-Object { $_ -match 'graph\.microsoft|''ad''|az ad ' }).Count -eq 0)

# ---- the driver end to end with a stub az
$dir = Join-Path $repo '.env.public-test-scratch/health-alerts'
Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$stub = Join-Path $dir 'stub.ps1'
@'
function global:az {
    $l = $args -join ' '; Add-Content -LiteralPath $env:FAKE_AZ_LOG -Value $l; $global:LASTEXITCODE = 0
    $p = "/subscriptions/$env:FAKE_SUB/resourceGroups/rg-sample/providers"
    if ($l -match '^rest --method get --url https://management\.azure\.com/subscriptions/[^/]+/resourcegroups/rg-sample\?') { return '{"location":"eastus2"}' }
    if ($l -match '/workspaces/sample-abc123-law\?') { return '{"id":"' + $p + '/Microsoft.OperationalInsights/workspaces/sample-abc123-law","location":"eastus2"}' }
    if ($l -match '/components/sample-abc123-(\w+)-ai\?') { return '{"id":"' + $p + '/Microsoft.Insights/components/sample-abc123-' + $Matches[1] + '-ai"}' }
    if ($l -match '/sites/sample-abc123-(\w+)\?') { $pna = if ($Matches[1] -eq 'resolver') { 'Enabled' } else { 'Disabled' }; return '{"id":"' + $p + '/Microsoft.Web/sites/sample-abc123-' + $Matches[1] + '","properties":{"defaultHostName":"sample-abc123-' + $Matches[1] + '.azurewebsites.net","publicNetworkAccess":"' + $pna + '"}}' }
    if ($l -match '/databaseAccounts/sample-abc123-cosmos\?') { return '{"id":"' + $p + '/Microsoft.DocumentDB/databaseAccounts/sample-abc123-cosmos"}' }
    if ($l -match '/service/sample-abc123-apim/apis/claude-messages\?') { return '{"name":"claude-messages"}' }
    if ($l -match '/service/sample-abc123-apim/providers/Microsoft\.Insights/metricDefinitions') { return '{"value":[{"name":{"value":"Requests"}},{"name":{"value":"Capacity"}}]}' }
    if ($l -match '/service/sample-abc123-apim\?') { return '{"id":"' + $p + '/Microsoft.ApiManagement/service/sample-abc123-apim","properties":{"gatewayUrl":"https://sample-abc123-apim.azure-api.net","publicNetworkAccess":"Disabled"}}' }
    if ($l -match '/accounts/sample-foundry/providers/Microsoft\.Insights/metricDefinitions') { return '{"value":[{"name":{"value":"ModelRequests"}},{"name":{"value":"ServerErrors"}}]}' }
    if ($l -match '/accounts/other-foundry/providers/Microsoft\.Insights/metricDefinitions') { $global:LASTEXITCODE = 1; Write-Error '(AuthorizationFailed) no read access'; return }
    if ($l -match '/profiles/sample-fd\?') { return '{"id":"' + $p + '/Microsoft.Cdn/profiles/sample-fd"}' }
    if ($l -match '^deployment group what-if ') { return (Get-Content -LiteralPath $env:FAKE_WHATIF -Raw) }
    if ($l -match '^deployment group create ') { return '{"properties":{"provisioningState":"Succeeded","outputs":{}}}' }
    if ($l -match '--tag .*--resource-group|--resource-group .*--tag') { $global:LASTEXITCODE = 2; Write-Error "ERROR: you cannot use '--tag' with '--resource-group'"; return }
    if ($l -match '^resource list --subscription \S+ --resource-group rg-sample --output') { return (Get-Content -LiteralPath $env:FAKE_OWNED -Raw) }
    if ($l -match '^resource delete --ids ') { return '' }
    if ($l -match '^rest --method get --url .*/actionGroups/sample-abc123-health-ag\?') { return '{"id":"' + $p + '/Microsoft.Insights/actionGroups/sample-abc123-health-ag"}' }
    if ($l -match '^rest --method post --url .*/actionGroups/sample-abc123-health-ag/createNotifications\?api-version=2021-09-01 --headers Content-Type=application/json --body @(\S+)') { Copy-Item -LiteralPath $Matches[1] -Destination (Join-Path (Split-Path $env:FAKE_AZ_LOG) 'notify-body.json') -Force; return '' }
    $global:LASTEXITCODE = 3; Write-Error "(ResourceNotFound) stub: unexpected $l"
}
function global:Invoke-WebRequest {
    param([string]$Uri, [string]$Method, [switch]$SkipHttpErrorCheck, [int]$TimeoutSec, [int]$MaximumRedirection)
    Add-Content -LiteralPath $env:FAKE_PROBE_LOG -Value $Uri
    $codes = Get-Content -LiteralPath $env:FAKE_PROBES -Raw | ConvertFrom-Json -AsHashtable
    [pscustomobject]@{ StatusCode = [int]$codes[$Uri] }
}
'@ | Set-Content -LiteralPath $stub -Encoding utf8NoBOM
$codes | ConvertTo-Json | Set-Content (Join-Path $dir 'probes.json')
function Run-Driver([string[]]$ScriptArgs, $Cfg, $WhatIf = @{ changes = @() }, $Owned = @()) {
    $env:FAKE_SUB = $sub; $env:FAKE_AZ_LOG = Join-Path $dir 'az.log'; Set-Content $env:FAKE_AZ_LOG ''
    $env:FAKE_PROBE_LOG = Join-Path $dir 'probe.log'; Set-Content $env:FAKE_PROBE_LOG ''
    $env:FAKE_PROBES = Join-Path $dir 'probes.json'
    $env:FAKE_WHATIF = Join-Path $dir 'whatif.json'; $WhatIf | ConvertTo-Json -Depth 20 | Set-Content $env:FAKE_WHATIF
    $env:FAKE_OWNED = Join-Path $dir 'owned.json'; ConvertTo-Json @($Owned) -Depth 20 | Set-Content $env:FAKE_OWNED
    $cfgPath = Join-Path $dir 'health.config.json'; $Cfg | ConvertTo-Json -Depth 20 | Set-Content $cfgPath
    Remove-Item (Join-Path $dir 'notify-body.json') -ErrorAction SilentlyContinue
    $cmd = ". '$stub'; `$env:AZURE_CONFIG_DIR = '$dir'; & '$(Join-Path $repo 'infra/monitoring/Invoke-HealthAlerts.ps1')' -ConfigPath '$cfgPath' $($ScriptArgs -join ' '); exit `$LASTEXITCODE"
    $out = pwsh -NoProfile -Command $cmd 2>&1 | Out-String
    @{ code = $LASTEXITCODE; out = $out; log = @(Get-Content $env:FAKE_AZ_LOG | Where-Object { $_ }); probes = @(Get-Content $env:FAKE_PROBE_LOG | Where-Object { $_ }) }
}
$e2eCfg = New-Cfg @{ foundryAccountIds = @("$prov/Microsoft.CognitiveServices/accounts/sample-foundry", "/subscriptions/$otherSub/resourceGroups/rg-x/providers/Microsoft.CognitiveServices/accounts/other-foundry"); allowCrossSubscriptionFoundry = $true }
$creates = @{ changes = @(@{ changeType = 'Create'; resourceId = $ownedAg }, @{ changeType = 'NoChange'; resourceId = "$prov/Microsoft.Web/sites/$stem-admin" }) }
$r = Run-Driver @() $e2eCfg $creates
Check 'preview: exit 0, what-if run, nothing created' ($r.code -eq 0 -and @($r.log | Where-Object { $_ -match '^deployment group what-if ' }).Count -eq 1 -and @($r.log | Where-Object { $_ -match '^deployment group create|^resource delete' }).Count -eq 0)
Check 'preview: lists Create and says nothing changed' ($r.out -match "Create\s+.*$prefix-ag" -and $r.out -match 'Preview only')
Check 'preview: an unreadable Foundry account is skipped with a message, not a failure' ($r.out -match 'other-foundry.*skipped')
$pf = Join-Path $dir '.health-alerts/health-alerts.parameters.json'
$params = if (Test-Path $pf) { (Get-Content $pf -Raw | ConvertFrom-Json -AsHashtable).parameters } else { @{} }
Check 'preview: parameter file has three web tests via Front Door and the public resolver' ($params.Contains('webTests') -and (@($params.webTests.value | ForEach-Object { $_.key }) -join ',') -ceq 'gateway-fd,admin-fd,resolver-direct')
Check 'az arguments: no ( ) | & < > ^ (az.cmd quoting) and no Graph or az ad call' (@($r.log | Where-Object { $_ -match '[()|&<>^]' -or $_ -match '^ad |graph\.microsoft' }).Count -eq 0)
Check 'reads only: every az call before what-if is a GET' (@($r.log | Where-Object { $_ -notmatch '^rest --method get |^deployment group what-if ' }).Count -eq 0)
$bad = @{ changes = @(@{ changeType = 'Create'; resourceId = $ownedAg }, @{ changeType = 'Modify'; resourceId = "$prov/Microsoft.Web/sites/$stem-admin"; before = @{ tags = @{} } }) }
$r = Run-Driver @('-Apply') $e2eCfg $bad
Check 'apply: a Modify of a resource it does not own stops before deployment (exit 3)' ($r.code -eq 3 -and $r.out -match 'Microsoft.Web/sites' -and @($r.log | Where-Object { $_ -match '^deployment group create' }).Count -eq 0)
$r = Run-Driver @('-Apply') $e2eCfg $creates
Check 'apply: incremental deployment after a clean what-if (exit 0)' ($r.code -eq 0 -and @($r.log | Where-Object { $_ -match '^deployment group create .*--mode Incremental .*--name ccof-health-alerts ' }).Count -eq 1)
$r = Run-Driver @('-Apply') (New-Cfg @{ emailReceivers = @() })
Check 'empty receivers: exit 2 before any az call' ($r.code -eq 2 -and $r.log.Count -eq 0 -and $r.out -match 'emailReceivers')
$r = Run-Driver @('-TestNotification') $e2eCfg
$nb = if (Test-Path (Join-Path $dir 'notify-body.json')) { Get-Content (Join-Path $dir 'notify-body.json') -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
Check 'test notification: one POST to the owned action group with every receiver' ($r.code -eq 0 -and $nb.Contains('emailReceivers') -and @($nb.emailReceivers).Count -eq 2 -and @($nb.emailReceivers | Where-Object { -not $_.useCommonAlertSchema }).Count -eq 0)
$r = Run-Driver @('-Apply') $e2eCfg $creates $res
Check 'apply readback: lists the resource group without --tag and prints only owned resources' ($r.code -eq 0 -and $r.out -match 'Owned resources now in rg-sample: 6' -and $r.out -notmatch "Web/sites $stem-admin")
$owned = $res
$r = Run-Driver @('-Remove') $e2eCfg @{ changes = @() } $owned
Check 'remove preview: lists owned resources, deletes nothing' ($r.code -eq 0 -and @($r.log | Where-Object { $_ -match '^resource delete' }).Count -eq 0 -and $r.out -match "$prefix-ag")
$r = Run-Driver @('-Remove', '-Apply') $e2eCfg @{ changes = @() } $owned
$deleted = @($r.log | Where-Object { $_ -match '^resource delete --ids ' } | ForEach-Object { ($_ -replace '^resource delete --ids ', '') -replace ' --subscription.*$', '' })
Check 'remove apply: deletes exactly the six owned resources and nothing else' ($r.code -eq 0 -and $deleted.Count -eq 6 -and @($deleted | Where-Object { $_ -match "/sites/|$stem-admin-ai|$prefix-old" }).Count -eq 0)
Check 'remove apply: the shared Smart Detection action group Azure creates is left in place and named' (@($deleted | Where-Object { $_ -match 'Smart Detection' }).Count -eq 0 -and $r.out -match "Left in place: action group 'Application Insights Smart Detection'")
Check 'remove apply: makes no deployment and reads no endpoint' (@($r.log | Where-Object { $_ -match '^deployment ' }).Count -eq 0 -and $r.probes.Count -eq 0)

Write-Host "Test-HealthAlerts: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0 -or $script:pass -lt 92) { exit 1 }
