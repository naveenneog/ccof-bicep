#Requires -Version 7.0
<#
.SYNOPSIS
    D2 steps that talk to Azure Resource Manager (docs/DEPLOYMENT-STAGES.md, D2 steps): the Cosmos
    schema, the apps' settings, the APIM API, operation, backends and named-value checks, and the
    smoke tests. Each step compares the live state and writes only what differs. Every call goes
    through $Ctx.Send (Method, Url, Body -> Status, Content, ErrorCode); HTTP probes through
    $Ctx.Pieces.Http. Values are never logged.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.Schema.psm1')

$script:Arm = 'https://management.azure.com'
# docs/LLD.md §1 containers, plus the leases of WP-SYNC (syncLease) and WP-REC (reconcilerLease), and
# the backend registry of C-8 (backends, partition key /backendId: P-RES-1, owner-approved; read by
# WP-RES src/resolver/backend.ts, written by onboarding Stage 2).
$script:Containers = [ordered]@{
    entitlement = '/personId'; projects = '/projectId'; subscriptionIndex = '/subscriptionId'
    budgetState = '/personId'; aggregateBudgetState = '/scopeId'; syncLease = '/id'; reconcilerLease = '/id'
    backends = '/backendId'
}
# Written by D2 only when absent: afterwards onboarding Stage 5 (budget mode) and D3 (sync timer) own them.
$script:InitialOnly = @('RESOLVER_BUDGET_ENFORCEMENT', 'RESOLVER_BUDGET_STATE_GRACE_SECONDS', 'RESOLVER_BUDGET_STATE_HARD_LIMIT_SECONDS', 'AzureWebJobs.syncEntitlement.Disabled')

function Get-CoreCosmosContainers { return $script:Containers }
function Get-CoreInitialOnlySettings { return $script:InitialOnly }

function New-CoreStepResult {
    param([string]$State, $Outputs = @{}, [string]$ReasonCode = $null, [string[]]$Lines = @(), [int]$Writes = 0)
    [pscustomobject]@{ State = $State; Outputs = $Outputs; ReasonCode = $ReasonCode; Lines = $Lines; Writes = $Writes }
}

function Wait-CoreArm {
    param($Ctx, [string]$Url)
    for ($i = 0; $i -lt 30; $i++) {
        $r = & $Ctx.Send 'GET' $Url $null
        if ($r.Status -eq 200) { return $r }
        & $Ctx.Sleep 5
    }
    return $r
}

function Invoke-CoreD2Schema {
    param($Ctx)
    $account = [string]$Ctx.D1.cosmos.id
    $db = [string]$Ctx.Answers.names.cosmosDatabase
    $registry = $Ctx.Answers.availability.registry
    $writes = 0
    $dbUrl = "$script:Arm$account/sqlDatabases/$db`?api-version=2024-11-15"
    $existing = & $Ctx.Send 'GET' $dbUrl $null
    if ($existing.Status -eq 404) {
        $options = switch ($registry.capacityMode) {
            'provisioned-autoscale' { @{ autoscaleSettings = @{ maxThroughput = [int]$registry.autoscaleMaxThroughput } } }
            'provisioned-manual' { @{ throughput = [int]$registry.manualThroughput } }
            default { @{} }
        }
        $put = & $Ctx.Send 'PUT' $dbUrl @{ properties = @{ resource = @{ id = $db }; options = $options } }
        if ($put.Status -notin @(200, 201, 202)) { return New-CoreStepResult 'failed' -ReasonCode "database_$($put.Status)_$($put.ErrorCode)" }
        if ((Wait-CoreArm $Ctx $dbUrl).Status -ne 200) { return New-CoreStepResult 'failed' -ReasonCode 'database_not_ready' }
        $writes++
    }
    elseif ($existing.Status -ne 200) { return New-CoreStepResult 'failed' -ReasonCode "database_read_$($existing.Status)" }
    foreach ($name in $script:Containers.Keys) {
        $url = "$script:Arm$account/sqlDatabases/$db/containers/$name`?api-version=2024-11-15"
        $current = & $Ctx.Send 'GET' $url $null
        if ($current.Status -eq 200) {
            $key = @($current.Content.properties.resource.partitionKey.paths)[0]
            if (-not [string]::Equals([string]$key, $script:Containers[$name], 'Ordinal')) { return New-CoreStepResult 'failed' -ReasonCode 'partition_key_mismatch' -Lines @("Container $name exists with another partition key; a partition key cannot change. Nothing was changed for it.") }
            continue
        }
        if ($current.Status -ne 404) { return New-CoreStepResult 'failed' -ReasonCode "container_read_$($current.Status)" -Lines @("Container $name could not be read (HTTP $($current.Status)); an unreadable container is never taken as absent. Nothing was changed for it.") }
        $put = & $Ctx.Send 'PUT' $url @{ properties = @{ resource = @{ id = $name; partitionKey = @{ paths = @($script:Containers[$name]); kind = 'Hash' } } } }
        if ($put.Status -notin @(200, 201, 202)) { return New-CoreStepResult 'failed' -ReasonCode "container_$($put.Status)_$($put.ErrorCode)" }
        if ((Wait-CoreArm $Ctx $url).Status -ne 200) { return New-CoreStepResult 'failed' -ReasonCode 'container_not_ready' }
        $writes++
    }
    New-CoreStepResult $(if ($writes) { 'applied' } else { 'unchanged' }) -Outputs @{ database = $db; containers = @($script:Containers.Keys) } -Writes $writes
}

function Get-CoreD2SchemaPlan {
    <#
    .SYNOPSIS
        Read-only (GET calls only): one line per write the schema step would make, or per conflict
        that would stop it, for -Action Plan.
    #>
    param([System.Collections.IDictionary]$D1, [System.Collections.IDictionary]$Answers, [scriptblock]$Send)
    $db = [string]$Answers.names.cosmosDatabase
    $base = "$script:Arm$([string]$D1.cosmos.id)/sqlDatabases/$db"
    $lines = [System.Collections.Generic.List[string]]::new()
    $database = & $Send 'GET' "$base`?api-version=2024-11-15" $null
    if ($database.Status -eq 404) { $lines.Add("would create database $db") }
    elseif ($database.Status -ne 200) { return @("cannot read database $db (HTTP $($database.Status)); Apply would fail") }
    foreach ($name in $script:Containers.Keys) {
        $current = if ($database.Status -eq 200) { & $Send 'GET' "$base/containers/$name`?api-version=2024-11-15" $null } else { $null }
        if ($current -and $current.Status -eq 200) {
            $key = [string]@($current.Content.properties.resource.partitionKey.paths)[0]
            if (-not [string]::Equals($key, $script:Containers[$name], 'Ordinal')) { $lines.Add("container $name has partition key $key, not $($script:Containers[$name]); Apply would fail and change nothing for it") }
            continue
        }
        if ($current -and $current.Status -ne 404) { $lines.Add("cannot read container $name (HTTP $($current.Status)); Apply would fail"); continue }
        $lines.Add("would create container $name ($($script:Containers[$name]))")
    }
    if (-not $lines.Count) { $lines.Add('no change: the database and every container exist with their partition keys') }
    return $lines.ToArray()
}

function ConvertTo-CoreSettingValue { param($Value) if ($Value -is [double] -or $Value -is [decimal]) { return ([double]$Value).ToString([Globalization.CultureInfo]::InvariantCulture) }; return [string]$Value }

function Get-CoreAppSettings {
    <#
    .SYNOPSIS
        The settings each app reads, from the answers and the D1 record. Names are the packages'
        contracts: src/resolver/config.ts (WP-RES), infra/sync/SyncDeploy.psm1 (WP-SYNC), the WP-REC
        contract of 2026-10-11, and the Functions host's identity-based storage settings.
    #>
    param([System.Collections.IDictionary]$Answers, [System.Collections.IDictionary]$D1, [hashtable]$Connections)
    $a = $Answers; $apps = $D1.apps; $av = $a.availability
    $cosmos = [ordered]@{ COSMOS_ENDPOINT = [string]$D1.cosmos.endpoint; COSMOS_DATABASE = [string]$a.names.cosmosDatabase }
    $result = [ordered]@{}
    foreach ($app in @('resolver', 'sync', 'reconciler')) {
        $s = [ordered]@{ AzureWebJobsStorage__accountName = ([string]$apps[$app].storageAccountId).Split('/')[-1]; AzureWebJobsStorage__credential = 'managedidentity'; CCOF_APP_ROLE = $app }
        if ($apps[$app].clientId) { $s.AzureWebJobsStorage__clientId = [string]$apps[$app].clientId }
        if ($apps[$app].appInsightsId) {
            $s.APPLICATIONINSIGHTS_CONNECTION_STRING = [string]$Connections[$app]
            $s.APPLICATIONINSIGHTS_AUTHENTICATION_STRING = if ($apps[$app].clientId) { "Authorization=AAD;ClientId=$($apps[$app].clientId)" } else { 'Authorization=AAD' }
        }
        foreach ($k in $cosmos.Keys) { $s[$k] = $cosmos[$k] }
        $result[$app] = $s
    }
    $r = $result.resolver
    $r.RESOLVER_COSMOS_REQUEST_TIMEOUT_MS = [string]$a.resolver.cosmosRequestTimeoutMs
    $r.RESOLVER_COSMOS_RETRY_ATTEMPTS = [string]$a.resolver.cosmosRetryAttempts
    $r.RESOLVER_COSMOS_RETRY_MAX_WAIT_SECONDS = [string]$a.resolver.cosmosRetryMaxWaitSeconds
    $r.RESOLVER_REQUEST_DEADLINE_MS = [string]$a.resolver.requestDeadlineMs
    $r.RESOLVER_BUDGET_ENFORCEMENT = [string]$a.resolver.budgetEnforcement
    if ($a.resolver.budgetEnforcement -eq 'budget-state') {
        $r.RESOLVER_BUDGET_STATE_GRACE_SECONDS = [string]$av.budgetState.graceSeconds
        $r.RESOLVER_BUDGET_STATE_HARD_LIMIT_SECONDS = [string]$av.budgetState.hardLimitSeconds
    }
    $y = $result.sync
    $y.SYNC_MANAGED_IDENTITY_CLIENT_ID = [string]$apps.sync.clientId
    $y.SYNC_PROJECTS_CONTAINER = 'projects'; $y.SYNC_ENTITLEMENT_CONTAINER = 'entitlement'; $y.SYNC_LEASE_CONTAINER = 'syncLease'
    $y.SYNC_TENANT_ID = [string]$a.target.tenantId
    $y.SYNC_SCHEDULE = [string]$av.sync.schedule; $y.SYNC_LEASE_SECONDS = [string]$av.sync.leaseSeconds
    $y.SYNC_MAX_REMOVALS_PER_RUN = [string]$av.sync.maxRemovalsPerRun; $y.SYNC_MAX_REMOVAL_FRACTION = ConvertTo-CoreSettingValue $av.sync.maxRemovalFraction
    $y.SYNC_MEMBER_TYPES = [string]$a.sync.memberTypes; $y.SYNC_GRAPH_MAX_RETRIES = [string]$a.sync.graphMaxRetries
    $y.SYNC_GRAPH_MAX_RETRY_AFTER_SECONDS = [string]$a.sync.graphMaxRetryAfterSeconds; $y.SYNC_GRAPH_TIMEOUT_SECONDS = [string]$a.sync.graphTimeoutSeconds
    $y.SYNC_WRITE_MODE = [string]$a.sync.writeMode
    $y.'AzureWebJobs.syncEntitlement.Disabled' = 'true'
    $c = $result.reconciler; $rc = $a.reconciler
    $c.RECONCILER_MANAGED_IDENTITY_CLIENT_ID = [string]$apps.reconciler.clientId
    $c.RECONCILER_SCHEDULE = [string]$rc.schedule; $c.RECONCILER_VALIDITY_SECONDS = [string]$rc.validitySeconds; $c.RECONCILER_LEASE_SECONDS = [string]$rc.leaseSeconds
    $c.RECONCILER_LOG_ANALYTICS_WORKSPACE_ID = [string]$D1.workspace.customerId; $c.RECONCILER_LOG_ANALYTICS_ENDPOINT = [string]$rc.logAnalyticsEndpoint; $c.RECONCILER_LEDGER_GATEWAY_RESOURCE_ID = [string]$D1.apim.id
    $c.RECONCILER_LEDGER_TIMEOUT_SECONDS = [string]$rc.ledgerTimeoutSeconds; $c.RECONCILER_LEDGER_MAX_ROWS = [string]$rc.ledgerMaxRows
    $c.RECONCILER_MAX_STATES = [string]$rc.maxStates; $c.RECONCILER_WRITE_CONCURRENCY = [string]$rc.writeConcurrency
    $c.RECONCILER_PROJECTS_CONTAINER = 'projects'; $c.RECONCILER_ENTITLEMENT_CONTAINER = 'entitlement'
    $c.RECONCILER_BUDGET_STATE_CONTAINER = 'budgetState'; $c.RECONCILER_AGGREGATE_STATE_CONTAINER = 'aggregateBudgetState'; $c.RECONCILER_LEASE_CONTAINER = 'reconcilerLease'
    $c.'AzureWebJobs.reconcileBudgets.Disabled' = if ($rc.timerEnabled) { 'false' } else { 'true' }
    return $result
}

function Invoke-CoreD2Settings {
    param($Ctx)
    $connections = @{}
    foreach ($app in @('resolver', 'sync', 'reconciler')) {
        $id = $Ctx.D1.apps[$app].appInsightsId
        if (-not $id) { continue }
        $component = & $Ctx.Send 'GET' "$script:Arm$id`?api-version=2020-02-02" $null
        if ($component.Status -ne 200 -or -not $component.Content.properties.ConnectionString) { return New-CoreStepResult 'failed' -ReasonCode "app_insights_unreadable_$app" }
        $connections[$app] = [string]$component.Content.properties.ConnectionString
    }
    $desired = Get-CoreAppSettings -Answers $Ctx.Answers -D1 $Ctx.D1 -Connections $connections
    $writes = 0; $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($app in $desired.Keys) {
        $site = "$script:Arm$($Ctx.D1.apps[$app].functionAppId)"
        $list = & $Ctx.Send 'POST' "$site/config/appsettings/list?api-version=2024-04-01" $null
        if ($list.Status -ne 200) { return New-CoreStepResult 'failed' -ReasonCode "settings_unreadable_$app" }
        $current = $list.Content.properties
        $merged = [ordered]@{}
        foreach ($k in @($current.Keys)) { $merged[$k] = [string]$current[$k] }
        foreach ($k in $desired[$app].Keys) {
            if ($script:InitialOnly -contains $k -and $merged.Contains($k)) { if ($merged[$k] -cne $desired[$app][$k]) { $kept.Add("${app}:$k") }; continue }
            $merged[$k] = $desired[$app][$k]
        }
        $changed = @($merged.Keys | Where-Object { -not $current.Contains($_) -or [string]$current[$_] -cne $merged[$_] }).Count -gt 0
        if (-not $changed) { continue }
        $put = & $Ctx.Send 'PUT' "$site/config/appsettings?api-version=2024-04-01" @{ properties = $merged }
        if ($put.Status -notin @(200, 201)) { return New-CoreStepResult 'failed' -ReasonCode "settings_write_$($put.Status)_$app" }
        # The read-back must answer 200 before it is compared: indexing a failed read's null content
        # throws inside Where-Object, which would skip the comparison and pass the write unverified.
        $read = & $Ctx.Send 'POST' "$site/config/appsettings/list?api-version=2024-04-01" $null
        if ($read.Status -ne 200 -or $read.Content.properties -isnot [System.Collections.IDictionary]) { return New-CoreStepResult 'failed' -ReasonCode "settings_not_verified_$app" -Lines @("The read-back of $app's settings after the write answered HTTP $($read.Status), so the write is not verified. Run this stage again.") }
        $check = $read.Content.properties
        $wrong = @($merged.Keys | Where-Object { [string]$check[$_] -cne $merged[$_] })
        if ($wrong.Count) { return New-CoreStepResult 'failed' -ReasonCode "settings_not_verified_$app" }
        $writes++
    }
    $lines = @($kept | ForEach-Object { "kept the live value of $_ (owned by a later stage)" })
    New-CoreStepResult $(if ($writes) { 'applied' } else { 'unchanged' }) -Outputs @{ apps = @($desired.Keys); keptLive = @($kept) } -Lines $lines -Writes $writes
}

Export-ModuleMember -Function Get-CoreCosmosContainers, Get-CoreInitialOnlySettings, New-CoreStepResult, Invoke-CoreD2Schema, Get-CoreD2SchemaPlan, Get-CoreAppSettings, Invoke-CoreD2Settings, Wait-CoreArm
