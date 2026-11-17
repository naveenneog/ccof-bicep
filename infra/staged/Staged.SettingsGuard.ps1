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

# Admin settings that code reads and Stage 5 does not write: the fallback when no Stage 5 record holds
# the names that the last apply left (state from before the record existed).
$script:StgOperatorAdminSettings = @(
    'ADMIN_AUDIT_WORKSPACE_ID', 'ADMIN_BUDGET_LOOKBACK_DAYS', 'ADMIN_CHARGEBACK_MAX_QUERY_DAYS', 'ADMIN_CHARGEBACK_WORKSPACE_ID',
    'ADMIN_CLIENT_SCOPE', 'ADMIN_CLIENT_TENANT_ID', 'ADMIN_COST_SCOPE', 'ADMIN_DISCOVERY_SCOPES', 'ADMIN_EDITOR_ROLE',
    'ADMIN_GRAPH_ENABLED', 'ADMIN_HEALTH_TARGETS', 'ADMIN_LOG_RETENTION_DAYS', 'ADMIN_MANAGED_IDENTITY_CLIENT_ID',
    'ADMIN_READER_ROLE', 'ADMIN_RESOURCE_IDS', 'ADMIN_RETAIL_PRICES_ENABLED', 'ADMIN_USER_NAMES_ENABLED', 'ADMIN_PROBE_KEY_*')
# Settings that later steps own on an app and Stage 5 keeps with a fixed value when live: Stage 7's
# delegated snapshot leaves AzureWebJobs.snapshotApply.Disabled=true on sync (Invoke-SnapshotApplyThroughFunction.ps1,
# asserted by Stage 7 verify). Kept as 'true' so a rewrite never re-enables the function.
$script:StgStage5CarriedSettings = @{ sync = @{ 'AzureWebJobs.snapshotApply.Disabled' = 'true' } }
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

# Carried settings for the next Stage 5 apply, per app: only those live now (absent: parameters unchanged).
function Get-StgStage5CarriedSettings {
    param([Parameter(Mandatory)] [Collections.IDictionary]$Apps, [Parameter(Mandatory)] [scriptblock]$ListSettings)
    $carried = @{}
    foreach ($k in @($script:StgStage5CarriedSettings.Keys)) {
        if (-not $Apps.Contains($k) -or -not $Apps[$k].functionApp) { continue }
        $live = @(& $ListSettings ([string]$Apps[$k].functionApp))
        $keep = [ordered]@{}
        foreach ($name in $script:StgStage5CarriedSettings[$k].Keys) { if ($live -ccontains $name) { $keep[$name] = $script:StgStage5CarriedSettings[$k][$name] } }
        if ($keep.Count) { $carried[$k] = $keep }
    }
    return $carried
}

function Get-StgStage5SettingDrops {
    <# Returns @{ app; functionApp; key; hint } for every live setting the next Stage 5 apply would remove. #>
    param(
        [Parameter(Mandatory)] [Collections.IDictionary]$Apps,
        [Collections.IDictionary]$Previous,
        [hashtable]$Configured = @{},
        [Parameter(Mandatory)] [scriptblock]$ListSettings
    )
    foreach ($k in @($Apps.Keys | Sort-Object)) {
        $functionApp = [string]$Apps[$k].functionApp
        if (-not $functionApp) { continue }
        $live = @(& $ListSettings $functionApp)
        $written = @($Configured[$k])
        $recorded = if ($Previous -and $Previous.Contains($k)) { @($Previous[$k]) } else { $null }
        foreach ($key in $live) {
            if ($written -ccontains $key) { continue }
            $drops = if ($null -ne $recorded) { $recorded -cnotcontains $key }
                     elseif ($k -ceq 'admin') { [bool]@($script:StgOperatorAdminSettings | Where-Object { $key -clike $_ }).Count }
                     else { $false }
            if ($drops) { [ordered]@{ app = $k; functionApp = $functionApp; key = $key; hint = $script:StgSettingConfigHint[$key] } }
        }
    }
}

function Test-StgSettingDropAllowed {
    param($Cfg, [Parameter(Mandatory)] $Drop)
    $allowed = @(if ($Cfg -is [Collections.IDictionary] -and $Cfg.stage5 -is [Collections.IDictionary]) { $Cfg.stage5.allowDroppedSettings })
    return [bool]($allowed -ccontains $Drop.key -or $allowed -ccontains "$($Drop.app):$($Drop.key)")
}

function Assert-StgStage5SettingsKept {
    param($Cfg, $Stage1, [hashtable]$Admin, [switch]$Apply, [scriptblock]$ListSettings, [hashtable]$Carried = @{})
    $apps = $Stage1.names.apps
    if ($apps -isnot [Collections.IDictionary] -or -not $apps.Count) { return @() }
    if (-not $ListSettings) {
        $ListSettings = {
            param($name)
            @(Invoke-StgAzJson @('functionapp', 'config', 'appsettings', 'list', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup, '--name', $name) | ForEach-Object { [string]$_.name })
        }.GetNewClosure()
    }
    $record = (Read-StgState $Cfg).stages['5']
    $previous = if ($record -and $record.outputs -and $record.outputs.verify -and $record.outputs.verify.settings -is [Collections.IDictionary]) { $record.outputs.verify.settings } else { $null }
    $configured = Get-StgStage5ConfiguredOptionalSettings -Admin $Admin
    foreach ($k in $Carried.Keys) { $configured[$k] = @($configured[$k]) + @($Carried[$k].Keys) }
    $drops = @(Get-StgStage5SettingDrops -Apps $apps -Previous $previous -Configured $configured -ListSettings $ListSettings)
    $blocking = @($drops | Where-Object { -not (Test-StgSettingDropAllowed $Cfg $_) })
    $null = Write-StgEvidence 'stage5.settings-guard.json' ([ordered]@{ checkedAt = [DateTime]::UtcNow.ToString('o'); baseline = $(if ($previous) { 'stage5-record' } else { 'known-operator-settings' }); drops = $drops; blocking = @($blocking | ForEach-Object { "$($_.app):$($_.key)" }) })
    foreach ($d in $drops) {
        $how = if ($d.hint) { "set $($d.hint) in the configuration" } else { "add it to the configuration" }
        $note = if (Test-StgSettingDropAllowed $Cfg $d) { ' (acknowledged in stage5.allowDroppedSettings)' } else { '' }
        Write-Warning "Stage 5 would remove $($d.key) from $($d.functionApp)$note; $how, or acknowledge the removal in stage5.allowDroppedSettings."
    }
    if ($Apply -and $blocking.Count) {
        throw "stage5_settings_would_drop: Stage 5 replaces the whole settings set and would remove $(@($blocking | ForEach-Object { "$($_.app):$($_.key)" }) -join ', '). Set the matching configuration field (admin.graphEnabled, admin.userNamesEnabled) or list the setting in stage5.allowDroppedSettings, then rerun. Nothing was changed."
    }
    return $drops
}
