# Staged deployment: Stage 5 app-settings drop guard and the optional configuration fields used by
# pipeline onboarding (docs/runbooks/CICD-FOUNDRY-ONBOARDING.md, ADR 0040). Dot-sourced by
# Invoke-StagedDeployment.ps1; not run directly.
#
# Stage 5 replaces each Function App's whole settings set (sites/config appsettings). A setting added
# by hand after the last Stage 5 apply (for example ADMIN_GRAPH_ENABLED, set by the runbooks after
# Graph consent) disappears on the next Stage 5 apply. Before Stage 5 writes, the guard lists the live
# settings: a setting that is live, was not present after the last Stage 5 apply and is not written by
# the current configuration would be dropped. Preview warns; apply refuses unless the configuration
# writes the setting (admin.graphEnabled, admin.userNamesEnabled) or acknowledges the drop in
# stage5.allowDroppedSettings ("KEY" or "app:KEY").
#
# Values: a setting that Stage 5 writes with a default when the configuration omits its field
# ($script:StgStage5DefaultedSettings, for example ADMIN_V3_ENABLED = admin.v3Enabled ?? true) and
# whose live value differs would change. Preview warns; apply refuses unless the field is set or the
# change is acknowledged in stage5.allowChangedSettings. Carried settings keep their exact live value.
# Without a Stage 5 record the guard cannot know which names the last apply left, so every live name
# that the app's Stage 5 template block does not always write (and the configuration does not make it
# write now) counts as a drop (fail closed). Setting values are read into
# memory only; evidence and messages hold names, except the non-secret flags of the defaulted table.

# Admin settings that code reads and Stage 5 does not write: the fallback when no Stage 5 record holds
# the names that the last apply left (state from before the record existed).
$script:StgOperatorAdminSettings = @(
    'ADMIN_AUDIT_WORKSPACE_ID', 'ADMIN_BUDGET_LOOKBACK_DAYS', 'ADMIN_CHARGEBACK_MAX_QUERY_DAYS', 'ADMIN_CHARGEBACK_WORKSPACE_ID',
    'ADMIN_CLIENT_SCOPE', 'ADMIN_CLIENT_TENANT_ID', 'ADMIN_COST_SCOPE', 'ADMIN_DISCOVERY_SCOPES', 'ADMIN_EDITOR_ROLE',
    'ADMIN_GRAPH_ENABLED', 'ADMIN_HEALTH_TARGETS', 'ADMIN_LOG_RETENTION_DAYS', 'ADMIN_MANAGED_IDENTITY_CLIENT_ID',
    'ADMIN_READER_ROLE', 'ADMIN_RESOURCE_IDS', 'ADMIN_RETAIL_PRICES_ENABLED', 'ADMIN_USER_NAMES_ENABLED', 'ADMIN_PROBE_KEY_*')
# Settings that later steps own on an app and Stage 5 keeps when live: Stage 7's delegated snapshot leaves
# AzureWebJobs.snapshotApply.Disabled=true on sync (Invoke-SnapshotApplyThroughFunction.ps1, asserted by
# Stage 7 verify). The exact live value is carried, so a rewrite neither re-enables nor disables it.
$script:StgStage5CarriedSettings = @{ sync = @('AzureWebJobs.snapshotApply.Disabled') }
# Settings Stage 5 writes with a default when the configuration does not set the field
# (infra/staged/stage5-config.bicep, infra/quickstart/modules/app-settings.bicep). Boolean values compare
# case-insensitively. A DR standby configuration sets syncTimerEnabled explicitly (DrStandby.psm1).
$script:StgStage5DefaultedSettings = @(
    @{ app = 'admin'; key = 'ADMIN_V3_ENABLED'; field = 'admin.v3Enabled'; default = 'true'; boolean = $true }
    @{ app = 'admin'; key = 'ADMIN_PROJECT_HEADER'; field = 'gateway.projectHeaderName'; default = 'x-ccof-project'; boolean = $false }
    @{ app = 'sync'; key = 'AzureWebJobs.syncEntitlement.Disabled'; field = 'syncTimerEnabled'; default = 'true'; boolean = $true }
    @{ app = 'reconciler'; key = 'AzureWebJobs.reconcileBudgets.Disabled'; field = 'reconciler.timerEnabled'; default = 'true'; boolean = $true })
$script:StgSettingConfigHint = @{ ADMIN_GRAPH_ENABLED = 'admin.graphEnabled'; ADMIN_USER_NAMES_ENABLED = 'admin.userNamesEnabled'; ADMIN_GATEWAY_RESOURCE_IDS = 'admin.gatewayResourceIds' }

# Read-StgConfig: optional fields added for pipeline onboarding (docs/runbooks/CICD-FOUNDRY-ONBOARDING.md).
function Get-StgOptionalFieldProblems {
    param($C)
    $guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if ($C.admin -is [Collections.IDictionary]) {
        foreach ($k in 'graphEnabled', 'userNamesEnabled') { if ($C.admin.Contains($k) -and $C.admin[$k] -isnot [bool]) { "admin.$k must be true or false" } }
    }
    if ($C.Contains('stage5')) {
        $allowed = $null; if ($C.stage5 -is [Collections.IDictionary]) { $allowed = $C.stage5.allowDroppedSettings }  # no if-expression: it would unroll a one-item list
        if ($C.stage5 -isnot [Collections.IDictionary] -or ($C.stage5.Contains('allowDroppedSettings') -and
            ($allowed -isnot [Collections.IList] -or @($allowed | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^([a-z]+:)?[A-Za-z0-9_.*-]+$' }).Count))) {
            'stage5.allowDroppedSettings must be a list of setting names ("KEY" or "app:KEY")'
        }
        $changed = $null; if ($C.stage5 -is [Collections.IDictionary]) { $changed = $C.stage5.allowChangedSettings }
        if ($C.stage5 -is [Collections.IDictionary] -and $C.stage5.Contains('allowChangedSettings') -and
            ($changed -isnot [Collections.IList] -or @($changed | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^([a-z]+:)?[A-Za-z0-9_.-]+$' }).Count)) {
            'stage5.allowChangedSettings must be a list of setting names ("KEY" or "app:KEY")'
        }
    }
    if ($C.Contains('automation')) {
        $ids = $null; if ($C.automation -is [Collections.IDictionary]) { $ids = $C.automation.backendWriterPrincipalIds }
        if ($C.automation -isnot [Collections.IDictionary] -or ($C.automation.Contains('backendWriterPrincipalIds') -and
            ($ids -isnot [Collections.IList] -or @($ids | Where-Object { $_ -isnot [string] -or $_ -notmatch $guid }).Count))) {
            'automation.backendWriterPrincipalIds must be a list of principal (object) id GUIDs'
        }
    }
    $backendIds = @($C['backends'] | Where-Object { $_ -is [Collections.IDictionary] -and $_.id } | ForEach-Object { "$($_.id)".ToLowerInvariant() })
    if (@($backendIds | Select-Object -Unique).Count -ne $backendIds.Count) { 'backends[].id must be unique (APIM backend names are case-insensitive)' }
}

# Pipeline identities granted read + create on the Cosmos backends container (Stage 3). Absent or empty:
# no grant and no change to the Stage 3 hash, so completed deployments keep theirs.
function Get-StgBackendWriterPrincipalIds {
    param($Cfg)
    if ($Cfg -isnot [Collections.IDictionary] -or $Cfg.automation -isnot [Collections.IDictionary]) { return @() }
    return @($Cfg.automation.backendWriterPrincipalIds | Where-Object { $_ } | ForEach-Object { "$_".ToLowerInvariant() } | Sort-Object -Unique)
}

# Optional settings that the current configuration writes, per app (the fixed set is in the record).
function Get-StgStage5ConfiguredOptionalSettings {
    param([Parameter(Mandatory)] [hashtable]$Admin)
    $keys = [Collections.Generic.List[string]]::new()  # not $admin: variables are case-insensitive
    if ($Admin.enabled) {
        if ($Admin.ContainsKey('gatewayResourceIds')) { $keys.Add('ADMIN_GATEWAY_RESOURCE_IDS') }
        if ($Admin.ContainsKey('graphEnabled')) { $keys.Add('ADMIN_GRAPH_ENABLED') }
        if ($Admin.ContainsKey('userNamesEnabled')) { $keys.Add('ADMIN_USER_NAMES_ENABLED') }
    }
    return @{ admin = @($keys) }
}

# Live settings of one app as an ordered name -> value map. The lister returns az's {name, value} objects
# (or a map); names alone are refused, because the guard compares values.
function Get-StgLiveSettingMap {
    param([Parameter(Mandatory)] [scriptblock]$ListSettings, [Parameter(Mandatory)] [string]$FunctionApp)
    $out = @(& $ListSettings $FunctionApp)
    $map = [ordered]@{}
    if ($out.Count -eq 1 -and $out[0] -is [Collections.IDictionary] -and -not $out[0].Contains('name')) { foreach ($k in $out[0].Keys) { $map[[string]$k] = $out[0][$k] }; return $map }
    foreach ($s in $out) {
        $name = if ($s -is [Collections.IDictionary]) { $s['name'] } elseif ($s -and $s.PSObject.Properties['name']) { $s.name } else { $null }
        if (-not $name) { throw "stage5_settings_unreadable: the settings of $FunctionApp were listed without name and value; the guard cannot compare them. Nothing was changed." }
        $map[[string]$name] = if ($s -is [Collections.IDictionary]) { $s['value'] } else { $s.value }
    }
    return $map
}

# Carried settings for the next Stage 5 apply, per app: only those live now, with their exact live value
# (absent: parameters unchanged).
function Get-StgStage5CarriedSettings {
    param([Parameter(Mandatory)] [Collections.IDictionary]$Apps, [Parameter(Mandatory)] [scriptblock]$ListSettings)
    $carried = @{}
    foreach ($k in @($script:StgStage5CarriedSettings.Keys)) {
        if (-not $Apps.Contains($k) -or -not $Apps[$k].functionApp) { continue }
        $live = Get-StgLiveSettingMap -ListSettings $ListSettings -FunctionApp ([string]$Apps[$k].functionApp)
        $keep = [ordered]@{}
        foreach ($name in $script:StgStage5CarriedSettings[$k]) { if ($live.Contains($name)) { $keep[$name] = [string]$live[$name] } }
        if ($keep.Count) { $carried[$k] = $keep }
    }
    return $carried
}

# Settings that the Stage 5 templates write only under a condition on the configuration
# (infra/quickstart/modules/app-settings.bicep, infra/staged/stage5-config.bicep). Without a Stage 5 record
# such a live setting counts as written only when its condition holds now.
$script:StgStage5ConditionalSettings = @(
    @{ app = 'resolver'; keys = @('RESOLVER_BUDGET_STATE_GRACE_SECONDS', 'RESOLVER_BUDGET_STATE_HARD_LIMIT_SECONDS'); when = { param($c) $c.resolver -is [Collections.IDictionary] -and "$($c.resolver.budgetEnforcement)" -ceq 'budget-state' } }
    @{ app = 'reconciler'; keys = @('RECONCILER_SOFT_LIMIT_PERCENT', 'RECONCILER_PACING_WINDOW_MINUTES'); when = { param($c) $c.reconciler -is [Collections.IDictionary] -and $c.reconciler.Contains('softLimitPercent') -and $c.reconciler.Contains('pacingWindowMinutes') } }
    @{ app = 'reconciler'; keys = @('RECONCILER_LEDGER_GATEWAY_RESOURCE_IDS'); when = { param($c) $c.reconciler -is [Collections.IDictionary] -and $c.reconciler.Contains('ledgerGatewayResourceIds') } }
    @{ app = 'reconciler'; keys = @('RECONCILER_CONTINUITY_GATE'); when = { param($c) $c.reconciler -is [Collections.IDictionary] -and $c.reconciler.Contains('continuityGate') } }
    @{ app = 'reconciler'; keys = @('RECONCILER_LEDGER_COVERAGE_START_AT'); when = { param($c) $c.reconciler -is [Collections.IDictionary] -and $c.reconciler.Contains('ledgerCoverageStartAt') } }
    @{ app = 'sync'; keys = @('SYNC_LIMITS_CONTAINER'); when = { param($c, $adminEnabled) $adminEnabled } })
# ADMIN_GATEWAY_RESOURCE_IDS: written only for the filtered list Stage 5 builds; Get-StgStage5ConfiguredOptionalSettings
# adds it from that same admin hashtable, so it is not decided from the raw configuration here.

# Setting names each Stage 5 template block writes whatever the configuration says: the object keys of
# resolverSettings, syncSettings and reconcilerSettings (app-settings.bicep) and of the admin properties
# object (stage5-config.bicep), minus the conditional names above. Used only when no Stage 5 record exists.
function Get-StgStage5TemplateSettingNames {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $quick = Get-Content -LiteralPath (Join-Path $root 'infra/quickstart/modules/app-settings.bicep') -Raw
    $stage5 = Get-Content -LiteralPath (Join-Path $root 'infra/staged/stage5-config.bicep') -Raw
    $blocks = @{
        resolver = [regex]::Match($quick, '(?ms)^var resolverSettings = \{(.*?)^\}').Groups[1].Value
        sync = [regex]::Match($quick, '(?ms)^var syncSettings = \{(.*?)^\}').Groups[1].Value
        reconciler = [regex]::Match($quick, '(?ms)^var reconcilerSettings = \{(.*?)^\}').Groups[1].Value
        admin = [regex]::Match($stage5, '(?ms)^resource adminSettings .*?adminOptionalFlags, \{(.*?)^  \}\)').Groups[1].Value
    }
    $conditional = @($script:StgStage5ConditionalSettings | ForEach-Object { $_.keys })
    $names = @{}
    foreach ($app in $blocks.Keys) {
        if (-not $blocks[$app]) { throw "stage5_settings_unreadable: the $app settings block was not found in the Stage 5 templates; the guard cannot tell which settings Stage 5 writes. Nothing was changed." }
        $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($m in [regex]::Matches($blocks[$app], "(?m)^\s*'?([A-Za-z_][A-Za-z0-9_.]*)'?\s*:")) { if ($conditional -cnotcontains $m.Groups[1].Value) { $null = $set.Add($m.Groups[1].Value) } }
        $names[$app] = $set
    }
    return $names
}

# Conditional names that the current configuration makes Stage 5 write, per app.
function Get-StgStage5ConditionalWritten {
    param($Cfg, [bool]$AdminEnabled)
    $out = @{}
    foreach ($c in $script:StgStage5ConditionalSettings) {
        if ($Cfg -is [Collections.IDictionary] -and (& $c.when $Cfg $AdminEnabled)) { $out[$c.app] = @($out[$c.app]) + @($c.keys) | Where-Object { $_ } }
    }
    return $out
}

function Get-StgStage5SettingDrops {
    <# Returns @{ app; functionApp; key; hint } for every live setting the next Stage 5 apply would remove.
       $Live (optional) receives each app's live map, so the value checks reuse one listing. #>
    param(
        [Parameter(Mandatory)] [Collections.IDictionary]$Apps,
        [Collections.IDictionary]$Previous,
        [hashtable]$Configured = @{},
        [Parameter(Mandatory)] [scriptblock]$ListSettings,
        [hashtable]$Live,
        # Without a record: the configuration and admin switch decide the conditional names.
        $Cfg,
        [bool]$AdminEnabled
    )
    $templateNames = $null; $conditionalWritten = $null
    foreach ($k in @($Apps.Keys | Sort-Object)) {
        $functionApp = [string]$Apps[$k].functionApp
        if (-not $functionApp) { continue }
        $liveMap = Get-StgLiveSettingMap -ListSettings $ListSettings -FunctionApp $functionApp
        if ($null -ne $Live) { $Live[$k] = $liveMap }
        $written = @($Configured[$k])
        $recorded = if ($Previous -and $Previous.Contains($k)) { @($Previous[$k]) } else { $null }
        foreach ($key in @($liveMap.Keys)) {
            if ($written -ccontains $key) { continue }
            $drops = if ($null -ne $recorded) { $recorded -cnotcontains $key }
                     else {
                         if ($null -eq $templateNames) { $templateNames = Get-StgStage5TemplateSettingNames; $conditionalWritten = Get-StgStage5ConditionalWritten -Cfg $Cfg -AdminEnabled $AdminEnabled }
                         ($k -ceq 'admin' -and [bool]@($script:StgOperatorAdminSettings | Where-Object { $key -clike $_ }).Count) -or
                         -not (($templateNames.Contains($k) -and $templateNames[$k].Contains($key)) -or @($conditionalWritten[$k]) -ccontains $key)
                     }
            if ($drops) { [ordered]@{ app = $k; functionApp = $functionApp; key = $key; hint = $script:StgSettingConfigHint[$key] } }
        }
    }
}

# Whether the configuration sets the field behind a defaulted setting (dotted path, a null value is unset).
function Test-StgConfigFieldSet {
    param($Cfg, [Parameter(Mandatory)] [string]$Field)
    $node = $Cfg
    foreach ($part in $Field.Split('.')) {
        if ($node -isnot [Collections.IDictionary] -or -not $node.Contains($part)) { return $false }
        $node = $node[$part]
    }
    return $null -ne $node
}

function Get-StgStage5SettingChanges {
    <# Returns @{ app; functionApp; key; live; written; hint } for every defaulted setting whose live value the
       next Stage 5 apply would change because the configuration leaves its field unset. #>
    param($Cfg, [Parameter(Mandatory)] [Collections.IDictionary]$Apps, [Parameter(Mandatory)] [hashtable]$Live, [bool]$AdminEnabled)
    foreach ($d in $script:StgStage5DefaultedSettings) {
        if (-not $Apps.Contains($d.app) -or -not $Live.Contains($d.app) -or -not $Live[$d.app].Contains($d.key)) { continue }
        if ($d.app -ceq 'admin' -and -not $AdminEnabled) { continue }
        if (Test-StgConfigFieldSet $Cfg $d.field) { continue }
        $value = [string]$Live[$d.app][$d.key]
        $same = if ($d.boolean) { $value.Trim() -ieq $d.default } else { $value -ceq $d.default }
        if (-not $same) { [ordered]@{ app = $d.app; functionApp = [string]$Apps[$d.app].functionApp; key = $d.key; live = $value; written = $d.default; hint = $d.field } }
    }
}
function Test-StgSettingDropAllowed {
    param($Cfg, [Parameter(Mandatory)] $Drop, [string]$List = 'allowDroppedSettings')
    $allowed = @(if ($Cfg -is [Collections.IDictionary] -and $Cfg.stage5 -is [Collections.IDictionary]) { $Cfg.stage5[$List] })
    return [bool]($allowed -ccontains $Drop.key -or $allowed -ccontains "$($Drop.app):$($Drop.key)")
}

function Assert-StgStage5SettingsKept {
    param($Cfg, $Stage1, [hashtable]$Admin, [switch]$Apply, [scriptblock]$ListSettings, [hashtable]$Carried = @{})
    $apps = $Stage1.names.apps
    if ($apps -isnot [Collections.IDictionary] -or -not $apps.Count) { return @() }
    if (-not $ListSettings) {
        $ListSettings = {
            param($name)
            @(Invoke-StgAzJson @('functionapp', 'config', 'appsettings', 'list', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup, '--name', $name))
        }.GetNewClosure()
    }
    $record = (Read-StgState $Cfg).stages['5']
    $previous = if ($record -and $record.outputs -and $record.outputs.verify -and $record.outputs.verify.settings -is [Collections.IDictionary]) { $record.outputs.verify.settings } else { $null }
    $configured = Get-StgStage5ConfiguredOptionalSettings -Admin $Admin
    foreach ($k in $Carried.Keys) { $configured[$k] = @($configured[$k]) + @($Carried[$k].Keys) }
    $live = @{}
    $drops = @(Get-StgStage5SettingDrops -Apps $apps -Previous $previous -Configured $configured -ListSettings $ListSettings -Live $live -Cfg $Cfg -AdminEnabled ([bool]$Admin.enabled))
    $changes = @(Get-StgStage5SettingChanges -Cfg $Cfg -Apps $apps -Live $live -AdminEnabled ([bool]$Admin.enabled))
    $blocking = @($drops | Where-Object { -not (Test-StgSettingDropAllowed $Cfg $_) })
    $blockingChanges = @($changes | Where-Object { -not (Test-StgSettingDropAllowed $Cfg $_ 'allowChangedSettings') })
    $null = Write-StgEvidence 'stage5.settings-guard.json' ([ordered]@{ checkedAt = [DateTime]::UtcNow.ToString('o'); baseline = $(if ($previous) { 'stage5-record' } else { 'stage5-templates' }); drops = $drops; blocking = @($blocking | ForEach-Object { "$($_.app):$($_.key)" })
        changes = $changes; blockingChanges = @($blockingChanges | ForEach-Object { "$($_.app):$($_.key)" }) })
    foreach ($c in $changes) {
        $note = if (Test-StgSettingDropAllowed $Cfg $c 'allowChangedSettings') { ' (acknowledged in stage5.allowChangedSettings)' } else { '' }
        Write-Warning "Stage 5 would change $($c.key) on $($c.functionApp) from '$($c.live)' to the default '$($c.written)'$note; set $($c.hint) in the configuration to keep the live value, or acknowledge the change in stage5.allowChangedSettings."
    }
    foreach ($d in $drops) {
        $how = if ($d.hint) { "set $($d.hint) in the configuration" } else { "add it to the configuration" }
        $note = if (Test-StgSettingDropAllowed $Cfg $d) { ' (acknowledged in stage5.allowDroppedSettings)' } else { '' }
        Write-Warning "Stage 5 would remove $($d.key) from $($d.functionApp)$note; $how, or acknowledge the removal in stage5.allowDroppedSettings."
    }
    if ($Apply -and $blockingChanges.Count) {
        throw "stage5_settings_would_change: Stage 5 would rewrite $(@($blockingChanges | ForEach-Object { "$($_.app):$($_.key) (set $($_.hint))" }) -join ', ') to its default, which differs from the live value. Set the field in the configuration or list the setting in stage5.allowChangedSettings, then rerun. Nothing was changed."
    }
    if ($Apply -and $blocking.Count) {
        throw "stage5_settings_would_drop: Stage 5 replaces the whole settings set and would remove $(@($blocking | ForEach-Object { "$($_.app):$($_.key)" }) -join ', '). Set the matching configuration field (admin.graphEnabled, admin.userNamesEnabled) or list the setting in stage5.allowDroppedSettings, then rerun. Nothing was changed."
    }
    return $drops
}
