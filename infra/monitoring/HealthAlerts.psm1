#Requires -Version 7.2
# Health and outage e-mail alerts (docs/runbooks/HEALTH-ALERTS.md): configuration validation, the
# probe plan, template parameters, the what-if guard and removal selection. No Azure call is made here;
# infra/monitoring/Invoke-HealthAlerts.ps1 reads Azure Resource Manager and passes the results in.
Set-StrictMode -Version Latest

$script:OwnedTag = 'ccof-component'
$script:OwnedValue = 'health-alerts'
$script:Guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$script:OwnedTypes = @('microsoft.insights/actiongroups', 'microsoft.insights/components', 'microsoft.insights/webtests',
    'microsoft.insights/metricalerts', 'microsoft.insights/scheduledqueryrules')
$script:TopFields = @('schemaVersion', 'subscriptionId', 'resourceGroup', 'stem', 'emailReceivers', 'tags', 'workspaceId', 'apim',
    'frontDoor', 'foundryAccountIds', 'allowCrossSubscriptionFoundry', 'probes', 'webTestLocations', 'evaluationFrequencyMinutes', 'rules')
$script:ProbeKeys = @('frontDoorGateway', 'frontDoorAdmin', 'apimDirect', 'adminDirect', 'resolverDirect')
$script:MetricWindows = @(5, 15, 30, 60, 360, 720, 1440)
# kind: metric (Azure Monitor metric alert), log (scheduled query rule) or availability (web test alert).
$script:Rules = [ordered]@{
    availability           = @{ kind = 'availability'; severity = 1; threshold = 2; windowMinutes = 5 }
    apimGateway5xx         = @{ kind = 'metric'; severity = 1; threshold = 10; windowMinutes = 15 }
    apimBackend5xx         = @{ kind = 'metric'; severity = 2; threshold = 10; windowMinutes = 15 }
    apimCapacity           = @{ kind = 'metric'; severity = 2; threshold = 80; windowMinutes = 15 }
    resolverUnavailable    = @{ kind = 'log'; severity = 1; threshold = 500; windowMinutes = 15; minimumSamples = 20 }
    gatewayTelemetrySilent = @{ kind = 'log'; severity = 3; threshold = 1440; derivedWindow = $true }
    functionServerErrors   = @{ kind = 'log'; severity = 2; threshold = 5; windowMinutes = 15 }
    syncRunFailures        = @{ kind = 'log'; severity = 2; threshold = 1; windowMinutes = 60 }
    reconcilerRunFailures  = @{ kind = 'log'; severity = 2; threshold = 3; windowMinutes = 30 }
    reconcilerStale        = @{ kind = 'log'; severity = 1; threshold = 30; derivedWindow = $true }
    cosmosThrottled        = @{ kind = 'metric'; severity = 3; threshold = 50; windowMinutes = 15 }
    cosmosServerErrors     = @{ kind = 'metric'; severity = 2; threshold = 5; windowMinutes = 15 }
    cosmosAvailability     = @{ kind = 'metric'; severity = 1; threshold = 99.9; windowMinutes = 60; fixedWindow = $true }
    foundryServerErrors    = @{ kind = 'metric'; severity = 2; threshold = 5; windowMinutes = 15 }
    frontDoorOriginHealth  = @{ kind = 'metric'; severity = 1; threshold = 90; windowMinutes = 15 }
    frontDoor5xx           = @{ kind = 'metric'; severity = 2; threshold = 5; windowMinutes = 15 }
}

function Test-HaArmId([string]$Value, [string]$Type) {
    $Value -match "^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._-]{1,90}/providers/$([regex]::Escape($Type))/[A-Za-z0-9._-]{1,260}$"
}
function Test-HaInt($Value) { $Value -is [int] -or $Value -is [long] }
function Test-HaNumber($Value) { (Test-HaInt $Value) -or $Value -is [double] -or $Value -is [decimal] }

function Get-HaConfigProblems {
    param([Parameter(Mandatory)] [System.Collections.IDictionary]$Cfg)
    $p = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $Cfg.Keys) { if ($script:TopFields -cnotcontains $k) { $p.Add("unknown_field:$k") } }
    if ($Cfg['schemaVersion'] -ne 1) { $p.Add('schemaVersion must be 1') }
    foreach ($k in 'subscriptionId', 'resourceGroup', 'stem') { if ("$($Cfg[$k])" -match 'REPLACE') { $p.Add("${k}: replace the REPLACE placeholder") } }
    if ("$($Cfg['subscriptionId'])" -notmatch "$script:Guid|REPLACE") { $p.Add("subscriptionId '$($Cfg['subscriptionId'])' must be a subscription GUID") }
    if ("$($Cfg['resourceGroup'])" -notmatch '^[A-Za-z0-9._-]{1,90}$') { $p.Add("resourceGroup '$($Cfg['resourceGroup'])' must be 1-90 letters, digits, . _ -") }
    if ("$($Cfg['stem'])" -cnotmatch '^[a-z0-9][a-z0-9-]{2,50}$|REPLACE') { $p.Add("stem '$($Cfg['stem'])' must be the Stage 1 name stem <prefix>-<suffix> (lowercase letters, digits, -)") }
    $mails = @($Cfg['emailReceivers'] | Where-Object { $null -ne $_ })
    if ($mails.Count -lt 1 -or $mails.Count -gt 20) { $p.Add('emailReceivers must list 1-20 e-mail addresses') }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $mails) {
        $ok = $m -is [string] -and $m -match '^[^\s<>@,;"]+@[^\s<>@,;"]+\.[^\s<>@,;"]+$'
        if ($ok) { try { $ok = ([System.Net.Mail.MailAddress]::new($m)).Address -ceq $m } catch { $ok = $false } }
        if (-not $ok) { $p.Add("emailReceivers: '$m' is not a plain e-mail address") }
        elseif (-not $seen.Add($m)) { $p.Add("emailReceivers: duplicate address '$m'") }
        elseif ($m -match 'REPLACE') { $p.Add("emailReceivers: replace the REPLACE placeholder in '$m'") }
    }
    if ($Cfg.Contains('tags') -and $null -ne $Cfg.tags) {
        if ($Cfg.tags -isnot [System.Collections.IDictionary] -or @($Cfg.tags.Values | Where-Object { $_ -isnot [string] }).Count) { $p.Add('tags must be an object of string values') }
    }
    if ($Cfg['workspaceId'] -and -not (Test-HaArmId $Cfg.workspaceId 'Microsoft.OperationalInsights/workspaces')) { $p.Add("workspaceId '$($Cfg.workspaceId)' must be a Log Analytics workspace resource ID") }
    if ($Cfg['apim']) {
        foreach ($k in $Cfg.apim.Keys) { if ($k -cnotin 'id', 'apiId', 'logWorkspaceId') { $p.Add("unknown_field:apim.$k") } }
        if ($Cfg.apim['id'] -and -not (Test-HaArmId $Cfg.apim.id 'Microsoft.ApiManagement/service')) { $p.Add("apim.id '$($Cfg.apim.id)' must be an API Management service resource ID") }
        if ($Cfg.apim['apiId'] -and $Cfg.apim.apiId -notmatch '^[A-Za-z0-9-]{1,80}$') { $p.Add('apim.apiId must be the API name, for example claude-messages') }
        if ($Cfg.apim['logWorkspaceId'] -and -not (Test-HaArmId $Cfg.apim.logWorkspaceId 'Microsoft.OperationalInsights/workspaces')) { $p.Add("apim.logWorkspaceId '$($Cfg.apim.logWorkspaceId)' must be a Log Analytics workspace resource ID") }
    }
    if ($Cfg['frontDoor']) {
        foreach ($k in $Cfg.frontDoor.Keys) { if ($k -cnotin 'host', 'profileId') { $p.Add("unknown_field:frontDoor.$k") } }
        if ("$($Cfg.frontDoor['host'])" -cnotmatch '^(?=.{4,253}$)[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$') { $p.Add("frontDoor.host '$($Cfg.frontDoor['host'])' must be a lowercase host name without https:// or a path") }
        if ($Cfg.frontDoor['profileId'] -and -not (Test-HaArmId $Cfg.frontDoor.profileId 'Microsoft.Cdn/profiles')) { $p.Add("frontDoor.profileId '$($Cfg.frontDoor.profileId)' must be a Front Door profile resource ID") }
    }
    foreach ($id in @($Cfg['foundryAccountIds'] | Where-Object { $null -ne $_ })) {
        if (-not (Test-HaArmId $id 'Microsoft.CognitiveServices/accounts')) { $p.Add("foundryAccountIds: '$id' is not a Cognitive Services account resource ID") }
    }
    if ($Cfg.Contains('allowCrossSubscriptionFoundry') -and $Cfg.allowCrossSubscriptionFoundry -isnot [bool]) { $p.Add('allowCrossSubscriptionFoundry must be true or false') }
    if ($Cfg['probes']) {
        foreach ($k in $Cfg.probes.Keys) {
            if ($script:ProbeKeys -cnotcontains $k) { $p.Add("probes.${k}: unknown probe") }
            elseif ($Cfg.probes[$k] -cnotin 'auto', 'on', 'off') { $p.Add("probes.${k} must be auto, on or off") }
        }
    }
    if ($Cfg['webTestLocations']) {
        $loc = @($Cfg.webTestLocations)
        if ($loc.Count -gt 16 -or @($loc | Where-Object { $_ -notmatch '^[a-z]{2,4}-[a-z]{2}-[a-z0-9]{2,4}-(azr|edge)$' }).Count) { $p.Add('webTestLocations must list 1-16 availability test location IDs, for example us-va-ash-azr') }
    }
    $freq = if ($Cfg.Contains('evaluationFrequencyMinutes')) { $Cfg.evaluationFrequencyMinutes } else { 5 }
    if ($freq -notin 1, 5, 15, 30, 60) { $p.Add('evaluationFrequencyMinutes must be 1, 5, 15, 30 or 60') }
    if ($Cfg['rules']) {
        foreach ($name in $Cfg.rules.Keys) {
            if (-not $script:Rules.Contains($name)) { $p.Add("rules.${name}: unknown rule"); continue }
            $o = $Cfg.rules[$name]; $d = $script:Rules[$name]
            if ($o -isnot [System.Collections.IDictionary]) { $p.Add("rules.$name must be an object"); continue }
            foreach ($k in $o.Keys) { if ($k -cnotin 'enabled', 'severity', 'threshold', 'windowMinutes', 'minimumSamples') { $p.Add("unknown_field:rules.$name.$k") } }
            if ($o.Contains('enabled') -and $o.enabled -isnot [bool]) { $p.Add("rules.$name.enabled must be true or false") }
            if ($o.Contains('severity') -and (-not (Test-HaInt $o.severity) -or $o.severity -lt 0 -or $o.severity -gt 4)) { $p.Add("rules.$name.severity must be 0-4") }
            if ($o.Contains('threshold') -and (-not (Test-HaNumber $o.threshold) -or $o.threshold -le 0)) { $p.Add("rules.$name.threshold must be a positive number") }
            if ($o.Contains('minimumSamples') -and ($name -ne 'resolverUnavailable' -or -not (Test-HaInt $o.minimumSamples) -or $o.minimumSamples -lt 1)) { $p.Add("rules.$name.minimumSamples applies to resolverUnavailable only, a positive integer") }
            if ($o.Contains('windowMinutes')) {
                $w = $o.windowMinutes
                if ($d.ContainsKey('derivedWindow') -or $d.ContainsKey('fixedWindow')) { $p.Add("rules.$name.windowMinutes is fixed by the rule; set threshold only") }
                elseif ($d.kind -in 'metric', 'availability' -and $w -notin $script:MetricWindows) { $p.Add("rules.$name.windowMinutes must be one of $($script:MetricWindows -join ', ')") }
                elseif ($d.kind -eq 'log' -and (-not (Test-HaInt $w) -or $w -lt 5 -or $w -gt 2880)) { $p.Add("rules.$name.windowMinutes must be 5-2880") }
                elseif ($w -lt $freq) { $p.Add("rules.$name.windowMinutes must not be shorter than evaluationFrequencyMinutes") }
            }
            if ($d.ContainsKey('derivedWindow') -and $o.Contains('threshold') -and ($o.threshold -lt 5 -or $o.threshold -gt 1440)) { $p.Add("rules.$name.threshold must be 5-1440 minutes") }
        }
    }
    return $p.ToArray()
}

function Read-HaConfig {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "config_refused: no file at $Path" }
    try { $cfg = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 50 } catch { throw "config_refused: $Path is not JSON" }
    if ($cfg -isnot [System.Collections.IDictionary]) { throw 'config_refused: the file must hold a JSON object' }
    $problems = @(Get-HaConfigProblems $cfg)
    if ($problems.Count) { throw "config_refused: $($problems -join '; ')" }
    return $cfg
}

function Get-HaRule($Cfg, [string]$Name) {
    $d = $script:Rules[$Name]; $o = if ($Cfg['rules'] -and $Cfg.rules.Contains($Name)) { $Cfg.rules[$Name] } else { @{} }
    $r = @{ enabled = $true; severity = $d.severity; threshold = $d.threshold; windowMinutes = $d['windowMinutes']; minimumSamples = $d['minimumSamples'] }
    foreach ($k in $o.Keys) { $r[$k] = $o[$k] }
    if ($Name -eq 'gatewayTelemetrySilent') { $r.windowMinutes = [int]$r.threshold }
    if ($Name -eq 'reconcilerStale') { $r.windowMinutes = [Math]::Min(2880, 2 * [int]$r.threshold) }
    return $r
}
function ConvertTo-HaDuration([int]$Minutes) { if ($Minutes % 60 -eq 0) { "PT$($Minutes / 60)H" } else { "PT${Minutes}M" } }

function Get-HaProbeCandidates {
    param([Parameter(Mandatory)] $Cfg, [Parameter(Mandatory)] $Discovered)
    $mode = { param($k) if ($Cfg['probes'] -and $Cfg.probes.Contains($k)) { $Cfg.probes[$k] } else { 'auto' } }
    $c = [System.Collections.Generic.List[hashtable]]::new()
    $fd = $Discovered['frontDoor']; $admin = $Discovered.apps['admin']
    # Paths and codes are those infra/dr/Invoke-DrFrontDoor.ps1 -Phase Verify accepts.
    if ($fd) {
        $c.Add(@{ key = 'gateway-fd'; label = 'APIM gateway through Front Door'; url = "https://$($fd.host)/status-0123456789abcdef"; expectedStatus = 200; mode = (& $mode 'frontDoorGateway'); publicAccess = 'Enabled' })
        if ($admin) { $c.Add(@{ key = 'admin-fd'; label = 'Admin console through Front Door'; url = "https://$($fd.host)/api/console"; expectedStatus = 200; mode = (& $mode 'frontDoorAdmin'); publicAccess = 'Enabled' }) }
    }
    if ($Discovered['apim']) { $c.Add(@{ key = 'gateway-direct'; label = 'APIM gateway status endpoint'; url = "https://$($Discovered.apim.gatewayHost)/status-0123456789abcdef"; expectedStatus = 200; mode = (& $mode 'apimDirect'); publicAccess = $Discovered.apim.publicNetworkAccess }) }
    if ($admin) { $c.Add(@{ key = 'admin-direct'; label = 'Admin console'; url = "https://$($admin.host)/api/console"; expectedStatus = 200; mode = (& $mode 'adminDirect'); publicAccess = $admin.publicNetworkAccess }) }
    $res = $Discovered.apps['resolver']
    # Without a token the resolver's /api/health answers 401 (src/resolver/http-handler.ts handleHealthRequest).
    if ($res) { $c.Add(@{ key = 'resolver-direct'; label = 'Resolver health (401 without a token)'; url = "https://$($res.host)/api/health"; expectedStatus = 401; mode = (& $mode 'resolverDirect'); publicAccess = $res.publicNetworkAccess }) }
    return $c.ToArray()
}

# auto: only endpoints whose public network access is not Disabled in ARM and that answer the expected
# code now; on: always (a mismatch is reported); off: never, and not requested.
function Resolve-HaProbes {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Candidates, [Parameter(Mandatory)] [scriptblock]$Get)
    $included = [System.Collections.Generic.List[hashtable]]::new(); $notes = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $Candidates) {
        if ($c.mode -eq 'off') { $notes.Add("probe $($c.key): off in config"); continue }
        if ($c.mode -eq 'auto' -and $c.publicAccess -eq 'Disabled') { $notes.Add("probe $($c.key): skipped, public network access is Disabled (probes.* on forces it)"); continue }
        $code = [int](& $Get $c.url)
        if ($code -eq $c.expectedStatus) { $included.Add($c); $notes.Add("probe $($c.key): GET $($c.url) -> $code, web test added"); continue }
        if ($c.mode -eq 'on') { $included.Add($c); $notes.Add("probe $($c.key): WARNING GET $($c.url) -> $code, expected $($c.expectedStatus); web test added because the probe is on"); continue }
        $notes.Add("probe $($c.key): skipped, GET $($c.url) -> $code, expected $($c.expectedStatus)")
    }
    return @{ included = $included.ToArray(); notes = $notes.ToArray() }
}

function Get-HaKql([string]$RepoRoot, [string[]]$Files) { ($Files | ForEach-Object { (Get-Content -LiteralPath (Join-Path $RepoRoot "analytics/alerts/$_") -Raw).TrimEnd() }) -join "`n" }
function ConvertTo-HaKqlList([string[]]$Ids) { 'dynamic([' + (($Ids | ForEach-Object { "'$_'" }) -join ', ') + '])' }

function New-HaParameters {
    param([Parameter(Mandatory)] $Cfg, [Parameter(Mandatory)] $Discovered, [AllowEmptyCollection()] [object[]]$WebTests = @(), [Parameter(Mandatory)] [string]$RepoRoot)
    $prefix = "$($Cfg.stem)-health"
    $freq = if ($Cfg.Contains('evaluationFrequencyMinutes')) { [int]$Cfg.evaluationFrequencyMinutes } else { 5 }
    $doc = 'docs/runbooks/HEALTH-ALERTS.md'
    $tags = [ordered]@{}; if ($Cfg['tags']) { foreach ($k in $Cfg.tags.Keys) { $tags[$k] = $Cfg.tags[$k] } }
    $tags[$script:OwnedTag] = $script:OwnedValue
    $metricList = [System.Collections.Generic.List[hashtable]]::new(); $logList = [System.Collections.Generic.List[hashtable]]::new()
    $addMetric = {
        param($Rule, $Name, $Display, $Scope, $Namespace, $Metric, $Aggregation, $Operator, $Dimensions, $What)
        $r = Get-HaRule $Cfg $Rule; if (-not $r.enabled) { return }
        $w = [int]$r.windowMinutes; $f = if ($Rule -eq 'cosmosAvailability') { 60 } else { [Math]::Min($w, $freq) }
        $metricList.Add(@{ name = "$prefix-$Name"; displayName = "CCOF health: $Display"; scope = $Scope; namespace = $Namespace; metric = $Metric
            aggregation = $Aggregation; operator = $Operator; threshold = $r.threshold; dimensions = @($Dimensions); severity = [int]$r.severity
            window = (ConvertTo-HaDuration $w); frequency = (ConvertTo-HaDuration $f); description = "$What See $doc#$($Rule.ToLowerInvariant())." })
    }
    $addLog = {
        param($Rule, $Name, $Display, $Scope, $Lets, $Files, $Dimensions, $What)
        $r = Get-HaRule $Cfg $Rule; if (-not $r.enabled) { return }
        $w = [int]$r.windowMinutes
        $logList.Add(@{ name = "$prefix-$Name"; displayName = "CCOF health: $Display"; scope = $Scope; threshold = $r.threshold
            query = "let _windowMinutes = $w; $Lets`n$(Get-HaKql $RepoRoot $Files)"; severity = [int]$r.severity
            window = (ConvertTo-HaDuration $w); frequency = (ConvertTo-HaDuration ([Math]::Min($w, $freq)))
            dimensions = @($Dimensions); description = "$What See $doc#$($Rule.ToLowerInvariant())." })
    }
    $apim = $Discovered['apim']
    if ($apim) {
        & $addMetric 'apimGateway5xx' 'apim-gateway-5xx' 'APIM gateway 5xx responses' $apim.id 'Microsoft.ApiManagement/service' 'Requests' 'Total' 'GreaterThanOrEqual' @(@{ name = 'GatewayResponseCodeCategory'; operator = 'Include'; values = @('5XX') }) 'APIM answered 5xx (includes 503 entitlement_unavailable and backend failures).'
        & $addMetric 'apimBackend5xx' 'apim-backend-5xx' 'Foundry backend 5xx seen by APIM' $apim.id 'Microsoft.ApiManagement/service' 'Requests' 'Total' 'GreaterThanOrEqual' @(@{ name = 'BackendResponseCodeCategory'; operator = 'Include'; values = @('5XX') }) 'A Foundry backend answered APIM with 5xx.'
        if ($apim.capacityMetric) { & $addMetric 'apimCapacity' 'apim-capacity' "APIM $($apim.capacityMetric) high" $apim.id 'Microsoft.ApiManagement/service' $apim.capacityMetric 'Average' 'GreaterThan' @() 'APIM gateway capacity or CPU is high; requests may queue or fail.' }
        $lets = "let _gatewayResourceId = '$($apim.id)'; let _apiId = '$($apim.apiId)'; let _minimumSamples = $((Get-HaRule $Cfg 'resolverUnavailable').minimumSamples);"
        & $addLog 'resolverUnavailable' 'resolver-unavailable' 'gateway 503 entitlement_unavailable rate (basis points)' $apim.logWorkspaceId $lets @('gateway-base.kql', 'resolver-base.kql', 'resolver-failures.kql') @() 'The gateway could not get an entitlement from the resolver (resolverOutcome unavailable); callers receive 503 entitlement_unavailable.'
        & $addLog 'gatewayTelemetrySilent' 'gateway-telemetry-silent' 'minutes without gateway telemetry' $apim.logWorkspaceId $lets @('gateway-base.kql', 'missing-telemetry.kql') @() 'No ApiManagementGatewayLogs row for the Claude API; chargeback and reconciler inputs are stale (admin Health: Telemetry freshness).'
    }
    $apps = $Discovered.apps
    $components = @($apps.Keys | ForEach-Object { $apps[$_].componentId })
    $both = { param($k) if ($apps[$k]) { @($apps[$k].siteId, $apps[$k].componentId) } else { @() } }
    & $addLog 'functionServerErrors' 'function-server-errors' 'Function App 5xx and exceptions' $Discovered.workspaceId "let _resourceIds = $(ConvertTo-HaKqlList $components);" @('function-server-errors.kql') @(@{ name = 'app'; operator = 'Include'; values = @('*') }) 'A Function App (resolver, sync, reconciler or admin) returned 5xx or logged exceptions.'
    if ($apps['sync']) { & $addLog 'syncRunFailures' 'sync-run-failures' 'sync run failed or partial' $Discovered.workspaceId "let _resourceIds = $(ConvertTo-HaKqlList (& $both 'sync'));" @('app-logs-base.kql', 'sync-run-failures.kql') @() 'A sync run line ccof.sync.run.v1 has outcome failed or partial.' }
    if ($apps['reconciler']) {
        $recLets = "let _resourceIds = $(ConvertTo-HaKqlList (& $both 'reconciler'));"
        & $addLog 'reconcilerRunFailures' 'reconciler-run-failures' 'reconciler run failed or refused' $Discovered.workspaceId $recLets @('app-logs-base.kql', 'reconciler-run-failures.kql') @(@{ name = 'reason'; operator = 'Include'; values = @('*') }) 'Reconciler runs ccof.reconciler.run.v1 ended failed, settings_invalid or refused (for example ledger_continuity_gap).'
        & $addLog 'reconcilerStale' 'reconciler-stale' 'minutes since the last written reconciler run' $Discovered.workspaceId $recLets @('app-logs-base.kql', 'reconciler-stale.kql') @() 'No written reconciler run; budget state is getting stale (admin Health: Reconciler freshness).'
    }
    $cos = $Discovered.cosmosId; $ns = 'Microsoft.DocumentDB/databaseAccounts'
    & $addMetric 'cosmosThrottled' 'cosmos-throttled' 'Cosmos DB 429 throttled requests' $cos $ns 'TotalRequests' 'Count' 'GreaterThanOrEqual' @(@{ name = 'StatusCode'; operator = 'Include'; values = @('429') }) 'Cosmos DB throttled requests (429).'
    & $addMetric 'cosmosServerErrors' 'cosmos-server-errors' 'Cosmos DB 5xx' $cos $ns 'TotalRequests' 'Count' 'GreaterThanOrEqual' @(@{ name = 'StatusCode'; operator = 'Include'; values = @('500', '503') }) 'Cosmos DB returned server errors (500 or 503).'
    & $addMetric 'cosmosAvailability' 'cosmos-availability' 'Cosmos DB availability below threshold (%)' $cos $ns 'ServiceAvailability' 'Average' 'LessThan' @() 'Cosmos DB hourly service availability is below the threshold (admin Health: Project registry).'
    $i = 0
    foreach ($f in @($Discovered['foundry'] | Where-Object { $_ -and $_.metric })) {
        $i++; $acct = ($f.id -split '/')[-1]
        $dims = if ($f.metric -eq 'ModelRequests') { @(@{ name = 'StatusCode'; operator = 'Include'; values = @('500', '502', '503', '504') }) } else { @() }
        & $addMetric 'foundryServerErrors' "foundry-$i-5xx" "Foundry $acct server errors" $f.id 'Microsoft.CognitiveServices/accounts' $f.metric 'Total' 'GreaterThanOrEqual' $dims "Foundry account $acct returned server errors."
    }
    $fd = $Discovered['frontDoor']
    if ($fd -and $fd['profileId']) {
        & $addMetric 'frontDoorOriginHealth' 'frontdoor-origin-health' 'Front Door origin health below threshold (%)' $fd.profileId 'Microsoft.Cdn/profiles' 'OriginHealthPercentage' 'Average' 'LessThan' @(@{ name = 'OriginGroup'; operator = 'Include'; values = @('*') }) 'Front Door health probes fail for an origin group (apim or admin).'
        & $addMetric 'frontDoor5xx' 'frontdoor-5xx' 'Front Door 5xx percentage' $fd.profileId 'Microsoft.Cdn/profiles' 'Percentage5XX' 'Average' 'GreaterThan' @() 'Front Door answered 5xx for more than the threshold percentage of requests.'
    }
    $avail = Get-HaRule $Cfg 'availability'
    $tests = @(if ($avail.enabled) { $WebTests | ForEach-Object { @{ key = $_.key; label = $_.label; url = $_.url; expectedStatus = [int]$_.expectedStatus } } })
    $locations = if ($Cfg['webTestLocations']) { @($Cfg.webTestLocations) } else { @('us-va-ash-azr', 'us-tx-sn1-azr', 'us-il-ch1-azr', 'us-ca-sjc-azr', 'emea-nl-ams-azr') }
    $n = 0
    return [ordered]@{
        namePrefix = $prefix; location = $Discovered.location; tags = $tags; workspaceId = $Discovered.workspaceId
        emailReceivers = @($Cfg.emailReceivers | ForEach-Object { $n++; @{ name = "email-$n"; emailAddress = $_; useCommonAlertSchema = $true } })
        webTests = $tests; webTestLocations = $locations
        availability = @($tests | ForEach-Object { @{ key = $_.key; failedLocationCount = [int]$avail.threshold; severity = [int]$avail.severity; window = (ConvertTo-HaDuration ([int]$avail.windowMinutes)); description = "Availability test $($_.label) failed from $($avail.threshold) or more locations. See $doc#availability." } })
        metricRules = $metricList.ToArray(); logRules = $logList.ToArray()
    }
}

function Test-HaOwnedName([string]$ResourceId, [string]$Prefix) {
    $parts = $ResourceId -split '/providers/', 2
    if ($parts.Count -lt 2) { return $false }
    $seg = $parts[1] -split '/'
    if ($seg.Count -ne 3) { return $false }
    return ("$($seg[0])/$($seg[1])".ToLowerInvariant() -in $script:OwnedTypes) -and $seg[2].StartsWith("$Prefix-", [StringComparison]::OrdinalIgnoreCase)
}

# Refuses every change other than Create or re-apply (Modify) of resources this add-on owns.
function Get-HaWhatIfProblems {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Changes, [Parameter(Mandatory)] [string]$Prefix)
    $p = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $Changes) {
        $type = [string]$c.changeType; $id = [string]$c.resourceId
        if ($type -in 'NoChange', 'Ignore') { continue }
        if ($type -eq 'Delete') { $p.Add("Delete refused: $id"); continue }
        if (-not (Test-HaOwnedName $id $Prefix)) { $p.Add("${type} refused, not_owned: $id"); continue }
        if ($type -eq 'Modify') {
            $before = $c['before']; $bt = if ($before -and $before['tags']) { $before.tags } else { @{} }
            if ($bt[$script:OwnedTag] -cne $script:OwnedValue) { $p.Add("Modify refused, not_owned (no $($script:OwnedTag)=$($script:OwnedValue) tag): $id") }
        }
    }
    return $p.ToArray()
}

# Owned = tagged ccof-component=health-alerts AND named <prefix>-*, plus the Failure Anomalies rule
# Application Insights adds for the owned component. Order: alerts, web tests, component, action group.
function Select-HaOwnedResources {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Resources, [Parameter(Mandatory)] [string]$Prefix)
    $order = @('microsoft.insights/metricalerts', 'microsoft.insights/scheduledqueryrules', 'microsoft.alertsmanagement/smartdetectoralertrules',
        'microsoft.insights/webtests', 'microsoft.insights/components', 'microsoft.insights/actiongroups')
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $picked = foreach ($r in $Resources) {
        $type = ([string]$r.type).ToLowerInvariant(); $name = [string]$r.name
        $tags = if ($r['tags']) { $r.tags } else { @{} }
        $mine = ($tags[$script:OwnedTag] -ceq $script:OwnedValue -and (Test-HaOwnedName ([string]$r.id) $Prefix)) -or
            ($type -eq 'microsoft.alertsmanagement/smartdetectoralertrules' -and $name -ceq "Failure Anomalies - $Prefix-ai")
        if ($mine -and $seen.Add([string]$r.id)) { [pscustomobject]@{ id = [string]$r.id; name = $name; type = [string]$r.type; rank = [array]::IndexOf($order, $type) } }
    }
    return @($picked | Sort-Object rank, name)
}

function New-HaTestNotificationBody($Cfg) {
    $n = 0
    @{ alertType = 'metricstaticthreshold'; emailReceivers = @($Cfg.emailReceivers | ForEach-Object { $n++; @{ name = "email-$n"; emailAddress = $_; useCommonAlertSchema = $true } }) }
}

# az.cmd on Windows re-parses its command line: these characters break or inject.
function Assert-HaAzArguments([string[]]$Arguments) {
    foreach ($a in $Arguments) { if ($a -match '[()|&<>^]') { throw "az_argument_refused: '$a' holds ( ) | & < > or ^; pass it in a file." } }
}

Export-ModuleMember -Function Get-HaConfigProblems, Read-HaConfig, Get-HaProbeCandidates, Resolve-HaProbes, New-HaParameters,
    Get-HaWhatIfProblems, Select-HaOwnedResources, New-HaTestNotificationBody, Assert-HaAzArguments, Test-HaOwnedName, ConvertTo-HaDuration
