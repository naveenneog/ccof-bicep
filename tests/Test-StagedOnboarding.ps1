#Requires -Version 7.0
# Offline tests for pipeline Foundry onboarding (docs/runbooks/CICD-FOUNDRY-ONBOARDING.md, ADR 0040):
# Stage 5 optional admin flags and the settings drop guard, optional configuration fields, the Stage 3
# backend writer grant, and the DR standby -Phase Backends checks. No Azure call is made.
$ErrorActionPreference = 'Stop'
$script:fail = 0; $script:pass = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'infra\staged\Invoke-StagedDeployment.ps1') -DotSourceOnly
$ErrorActionPreference = 'Stop'
function Build([string]$Relative) { (& az bicep build --file (Join-Path $root $Relative) --stdout --only-show-errors 2>$null) -join "`n" | ConvertFrom-Json -Depth 100 }
function Get-Resources($T) { if ($T.resources -is [array]) { @($T.resources) } else { @($T.resources.PSObject.Properties.Value) } }
$scratch = Join-Path $root ".env.onboarding-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch | Out-Null
$script:StateDir = $scratch

try {
# --- Stage 5 template: the flags are written only when configured -----------------------------------
$s5 = Build 'infra/staged/stage5-config.bicep'
$flags = "$($s5.variables.adminOptionalFlags)"
Check 'Stage 5 writes ADMIN_GRAPH_ENABLED only when admin.graphEnabled is present' ($flags -match "if\(contains\(parameters\('admin'\), 'graphEnabled'\), createObject\('ADMIN_GRAPH_ENABLED'" -and $flags -match "'true', 'false'")
Check 'Stage 5 writes ADMIN_USER_NAMES_ENABLED only when admin.userNamesEnabled is present' ($flags -match "if\(contains\(parameters\('admin'\), 'userNamesEnabled'\), createObject\('ADMIN_USER_NAMES_ENABLED'")
$adminSettings = @(Get-Resources $s5 | Where-Object { $_.type -ceq 'Microsoft.Web/sites/config' -and "$($_.name)" -match 'admin' })[0]
Check 'admin app settings include the optional flags' ("$($adminSettings.properties)" -match "variables\('adminOptionalFlags'\)")

# --- Optional configuration fields ------------------------------------------------------------------
$ok = @{ admin = @{ graphEnabled = $true; userNamesEnabled = $false }; stage5 = @{ allowDroppedSettings = @('ADMIN_X', 'admin:ADMIN_PROBE_KEY_A') }
    automation = @{ backendWriterPrincipalIds = @('00000000-0000-4000-8000-0000000000AA') }; backends = @(@{ id = 'a' }, @{ id = 'b' }) }
Check 'valid optional fields raise no problem' (@(Get-StgOptionalFieldProblems $ok).Count -eq 0)
Check 'absent optional fields raise no problem' (@(Get-StgOptionalFieldProblems @{ admin = @{}; backends = @(@{ id = 'a' }) }).Count -eq 0)
foreach ($bad in @(
    @{ n = 'admin.graphEnabled string'; c = @{ admin = @{ graphEnabled = 'true' } }; m = 'admin.graphEnabled' }
    @{ n = 'admin.userNamesEnabled number'; c = @{ admin = @{ userNamesEnabled = 1 } }; m = 'admin.userNamesEnabled' }
    @{ n = 'allowDroppedSettings string'; c = @{ stage5 = @{ allowDroppedSettings = 'ADMIN_X' } }; m = 'stage5.allowDroppedSettings' }
    @{ n = 'allowDroppedSettings bad name'; c = @{ stage5 = @{ allowDroppedSettings = @('ADMIN X') } }; m = 'stage5.allowDroppedSettings' }
    @{ n = 'stage5 not an object'; c = @{ stage5 = 'x' }; m = 'stage5.allowDroppedSettings' }
    @{ n = 'writer id not a GUID'; c = @{ automation = @{ backendWriterPrincipalIds = @('pipeline') } }; m = 'automation.backendWriterPrincipalIds' }
    @{ n = 'writer ids not a list'; c = @{ automation = @{ backendWriterPrincipalIds = '00000000-0000-4000-8000-0000000000aa' } }; m = 'automation.backendWriterPrincipalIds' }
    @{ n = 'duplicate backend id (case)'; c = @{ backends = @(@{ id = 'Foundry1' }, @{ id = 'foundry1' }) }; m = 'backends\[\]\.id must be unique' })) {
    Check "refused: $($bad.n)" ((@(Get-StgOptionalFieldProblems $bad.c) -join ';') -match $bad.m)
}
$example = Join-Path $root 'infra\staged\staged.config.example.json'
$c = Get-Content -LiteralPath $example -Raw | ConvertFrom-Json -AsHashtable -Depth 100
$c.tenantId = '00000000-0000-4000-8000-000000000001'; $c.subscriptionId = '00000000-0000-4000-8000-000000000002'; $c.resourceGroup = 'rg-new'
$vnetPath = '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets'
$c.network.existing = @{ functionsSubnetId = "$vnetPath/functions"; privateEndpointSubnetId = "$vnetPath/private"; apimSubnetId = "$vnetPath/apim" }
$cfgPath = Join-Path $scratch 'staged.config.json'
$c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $cfgPath -Encoding utf8NoBOM
$read = Read-StgConfig $cfgPath
$hash3 = Get-StgStageInput $read 3
$c.backends += @($c.backends[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable)
$c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $cfgPath -Encoding utf8NoBOM
$msg = ''; try { $null = Read-StgConfig $cfgPath } catch { $msg = "$_" }
Check 'Read-StgConfig refuses a duplicate backend id' ($msg -match 'backends\[\]\.id must be unique')

# Stage input hashes computed by origin/main (0560192) for a configuration without the new fields: a
# completed deployment must not see stage_config_changed after this change.
$frozen = @{ tenantId = '00000000-0000-4000-8000-000000000001'; subscriptionId = '00000000-0000-4000-8000-000000000002'; resourceGroup = 'rg'; location = 'eastus2'
    stage1 = @{ prefix = 'p' }; cosmos = @{ databaseName = 'db' }; sync = @{ mode = 'graph' }; admin = @{ v3Enabled = $true }; network = @{ mode = 'verify' }
    backends = @(@{ id = 'be1'; subscriptionId = '00000000-0000-4000-8000-000000000003'; resourceGroup = 'f'; accountName = 'a'; url = 'https://a'; privateEndpoint = $false }) }
Check 'Stage 3 hash of an existing configuration is unchanged' ((Get-StgStageInput $frozen 3) -ceq 'bd5a7dcf114bf99ee37834b8f8fb1944ae9624844e47b2539461a9d7ba24ca4d')
Check 'Stage 5 hash of an existing configuration is unchanged' ((Get-StgStageInput $frozen 5) -ceq '95706b92c5748161a87fcce7f571c00de535123e4a3365a559c890521900f0ae')
Check 'Stage 6 hash of an existing configuration is unchanged' ((Get-StgStageInput $frozen 6) -ceq '25977d330bd1548ea3a57b8b369de602e92f3443a20d4b99337c9fcd9b4a8771')
$frozen.automation = @{ backendWriterPrincipalIds = @() }
Check 'an empty writer list keeps the frozen Stage 3 hash' ((Get-StgStageInput $frozen 3) -ceq 'bd5a7dcf114bf99ee37834b8f8fb1944ae9624844e47b2539461a9d7ba24ca4d')
# --- Stage 3 backend writers: opt-in, hash unchanged when absent ------------------------------------
$read.automation = @{ backendWriterPrincipalIds = @() }
Check 'an empty writer list leaves the Stage 3 hash unchanged' ((Get-StgStageInput $read 3) -ceq $hash3)
$read.automation = @{ backendWriterPrincipalIds = @('00000000-0000-4000-8000-0000000000BB', '00000000-0000-4000-8000-0000000000bb') }
Check 'writer ids are normalized and change the Stage 3 hash' ((@(Get-StgBackendWriterPrincipalIds $read) -join ',') -ceq '00000000-0000-4000-8000-0000000000bb' -and (Get-StgStageInput $read 3) -cne $hash3)
$read.Remove('automation')
Check 'writer ids stay out of the other stage hashes' ((Get-StgStageInput $read 5) -ceq (Get-StgStageInput ($read + @{ automation = @{ backendWriterPrincipalIds = @('00000000-0000-4000-8000-0000000000bb') } }) 5))
$g = Build 'infra/staged/stage3-grants.bicep'
Check 'grants template: backendWriterPrincipalIds defaults to empty' (@($g.parameters.backendWriterPrincipalIds.defaultValue).Count -eq 0)
$writer = @(Get-Resources $g | Where-Object { $_.type -ceq 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments' -and "$($_.copy.input)$($_.copy.count)" -match "writers" })[0]
Check 'backend writers get the create-only role on the backends container' ($writer -and "$($writer.properties.roleDefinitionId)" -match 'onbProjectWriter' -and "$($writer.properties.scope)" -match "colls/backends")
Check 'region B (salted) never grants backend writers' ("$($g.variables.writers)" -match "if\(empty\(parameters\('assignmentNameSalt'\)\), parameters\('backendWriterPrincipalIds'\), createArray\(\)\)")

# --- Stage 5: flags reach the template only when configured; guard before any write -----------------
$script:captured = $null; $script:live = @{}; $script:record = $null; $script:listCalls = 0
$script:fakeContext = @{ P = @{ names = @{}; groups = @() }; GeneratedDir = $scratch; State = @{ completed = @{ '1' = @{ outputs = @{} } } }
    Apim = @{ id = '/fixture'; principalId = 'fixture' }; GatewayUrl = 'https://example.invalid/anthropic' }
$script:fakeEntra = @{ groups = @{}; admin = @{ appId = '00000000-0000-4000-8000-000000000001' }
    registrations = @{ developerSignIn = @{ appId = '00000000-0000-4000-8000-000000000002' }; resolverApi = @{ appId = '00000000-0000-4000-8000-000000000003' } } }
$script:stage1 = @{ names = @{ apps = [ordered]@{ admin = @{ functionApp = 'fx-admin' }; resolver = @{ functionApp = 'fx-resolver' } } } }
function Get-StgStage { param($Cfg, $Stage) if ($Stage -eq 3 -and $script:stage3Error) { throw $script:stage3Error }; if ($Stage -eq 4) { return $script:fakeEntra }; if ($Stage -eq 1) { return $script:stage1 }; return @{ clientIds = @{} } }
function Read-StgState { param($Cfg) @{ stages = @{ '5' = $script:record } } }
# Live values: $script:liveValues["app|KEY"], else the value Stage 5 writes by default (neutral), else 'x'.
$script:liveValues = @{}
function Invoke-StgAzJson { param([string[]]$Arguments) $script:listCalls++; $app = $Arguments[-1]
    @($script:live[$app] | ForEach-Object { $v = if ($script:liveValues.ContainsKey("$app|$_")) { $script:liveValues["$app|$_"] } elseif ($_ -like '*.Disabled' -or $_ -ceq 'ADMIN_V3_ENABLED') { 'true' } else { 'x' }; @{ name = $_; value = $v } }) }
function New-StgQsContext { param($Cfg) return $script:fakeContext }
function Get-StgManagedIdentityClientId { return '00000000-0000-4000-8000-000000000004' }
function npx { $global:LASTEXITCODE = 0 }
function node { $global:LASTEXITCODE = 0 }
function New-QsGatewayConfig { return @{ entra = @{} } }
function New-QsWorkbookAnswers { return 'fixture-answers' }
function Invoke-QsWorkbookBuild { return @{ parametersPath = (Join-Path $script:fakeContext.GeneratedDir 'workbook.parameters.json') } }
function Get-StgApim { return @{} }
function Invoke-StgExistingApimDiagnostics { return $null }
function Invoke-StgBicep { param($Cfg, $Template, $Name, $Apply, $Parameters) $script:captured = $Parameters; return $null }
New-Item -ItemType Directory -Path (Join-Path $scratch 'gateway') | Out-Null
'<policies />' | Set-Content (Join-Path $scratch 'gateway\fixture.policy.xml')
'{"parameters":{"workbookContent":{"value":{}},"contentTags":{"value":{}}}}' | Set-Content (Join-Path $scratch 'workbook.parameters.json')
$adminBase = @('ADMIN_ALLOWED_CLIENT_IDS', 'ADMIN_V3_ENABLED')
function New-S5Cfg([hashtable]$Admin = @{}, $Stage5) {
    $cfg = @{ subscriptionId = 's'; resourceGroup = 'rg'; stage1 = @{ includeAdmin = $true }; admin = (@{ extraAllowedClientIds = @() } + $Admin); apim = @{ apiId = 'fixture' }; gateway = @{} }
    if ($Stage5) { $cfg.stage5 = $Stage5 }
    return $cfg
}
function Invoke-S5([hashtable]$Cfg, [switch]$Apply) {
    $script:captured = $null; $e = ''
    $w = [Collections.Generic.List[string]]::new()
    try { Invoke-Stage5 -Cfg $Cfg -Apply:$Apply 3>&1 | ForEach-Object { if ($_ -is [Management.Automation.WarningRecord]) { $w.Add($_.Message) } } } catch { $e = "$_" }
    # Apply reads the settings back after the (faked) deployment; that read-back is out of scope here.
    if ($e -match '^verify_failed:' -and $script:captured) { $e = '' }
    return @{ error = $e; warnings = ($w -join "`n"); admin = $(if ($script:captured) { $script:captured.admin } else { $null }) }
}
# An existing configuration whose live settings match the last Stage 5 apply: unchanged parameters.
$script:record = @{ outputs = @{ verify = @{ settings = @{ admin = $adminBase; resolver = @('A') } } } }
$script:live = @{ 'fx-admin' = $adminBase; 'fx-resolver' = @('A') }
$r = Invoke-S5 (New-S5Cfg) -Apply
Check 'existing config: apply proceeds with no warning' (-not $r.error -and -not $r.warnings -and $r.admin)
Check 'existing config: no flag reaches the template' ($r.admin -and -not $r.admin.ContainsKey('graphEnabled') -and -not $r.admin.ContainsKey('userNamesEnabled'))
Check 'the guard lists every Stage 1 app' ($script:listCalls -ge 2)
# A flag set by hand after the last Stage 5 apply would be dropped.
$script:live['fx-admin'] = $adminBase + @('ADMIN_GRAPH_ENABLED', 'ADMIN_USER_NAMES_ENABLED')
$r = Invoke-S5 (New-S5Cfg)
Check 'preview warns about the dropped flags and continues' (-not $r.error -and $r.warnings -match 'ADMIN_GRAPH_ENABLED' -and $r.warnings -match 'admin\.graphEnabled' -and $r.warnings -match 'ADMIN_USER_NAMES_ENABLED' -and $r.admin)
$r = Invoke-S5 (New-S5Cfg) -Apply
Check 'apply refuses before any deployment when flags would drop' ($r.error -match '^stage5_settings_would_drop' -and $r.error -match 'admin:ADMIN_GRAPH_ENABLED' -and $null -eq $r.admin)
$guardPath = Join-Path $scratch 'evidence\stage5.settings-guard.json'
$guardEvidence = if (Test-Path -LiteralPath $guardPath) { Get-Content $guardPath -Raw | ConvertFrom-Json -AsHashtable } else { @{ baseline = ''; blocking = @() } }
Check 'guard writes evidence of the blocking drops' ($guardEvidence.baseline -ceq 'stage5-record' -and @($guardEvidence.blocking).Count -eq 2)
$r = Invoke-S5 (New-S5Cfg @{ graphEnabled = $true; userNamesEnabled = $true }) -Apply
Check 'configured flags keep the settings: apply proceeds' (-not $r.error -and -not $r.warnings -and $r.admin.graphEnabled -eq $true -and $r.admin.userNamesEnabled -eq $true)
$r = Invoke-S5 (New-S5Cfg @{ graphEnabled = $false; userNamesEnabled = 'yes' } @{ allowDroppedSettings = @('ADMIN_USER_NAMES_ENABLED') }) -Apply
Check 'explicit false is passed; a non-boolean flag is not' (-not $r.error -and $r.admin.graphEnabled -eq $false -and -not $r.admin.ContainsKey('userNamesEnabled'))
$r = Invoke-S5 (New-S5Cfg @{ graphEnabled = $true } @{ allowDroppedSettings = @('admin:ADMIN_USER_NAMES_ENABLED') }) -Apply
Check 'an acknowledged drop is allowed and still reported' (-not $r.error -and $r.warnings -match 'acknowledged' -and $r.admin)
$r = Invoke-S5 (New-S5Cfg @{ graphEnabled = $true } @{ allowDroppedSettings = @('resolver:ADMIN_USER_NAMES_ENABLED') }) -Apply
Check 'an acknowledgement for another app does not count' ($r.error -match 'admin:ADMIN_USER_NAMES_ENABLED' -and -not $r.admin)
# A pending Stage 3 change (a new backend's role) must not hide the Stage 5 preview; apply still needs it.
$script:live['fx-admin'] = $adminBase
$script:stage3Error = 'stage_config_changed: inputs for stage 3 changed after it was verified; preview and apply stage 3 again.'
$r = Invoke-S5 (New-S5Cfg)
Check 'Stage 5 preview runs with a pending Stage 3 change and says so' (-not $r.error -and $r.admin -and $r.warnings -match 'Stage 3 inputs changed')
$r = Invoke-S5 (New-S5Cfg) -Apply
Check 'Stage 5 apply still requires the verified Stage 3' ($r.error -match '^stage_config_changed' -and -not $r.admin)
$script:stage3Error = 'stage_order: stage 3 has not completed'
$r = Invoke-S5 (New-S5Cfg)
Check 'Stage 5 preview still requires a completed Stage 3' ($r.error -match '^stage_order' -and -not $r.admin)
$script:stage3Error = $null
# Without a Stage 5 record (older state) the names the last apply left are unknown: every live name the
# Stage 5 templates never write counts as a drop, on every app (fail closed), plus known operator settings.
$script:record = $null
$script:live = @{ 'fx-admin' = $adminBase + @('ADMIN_PROBE_KEY_EUS2', 'WEBSITE_X'); 'fx-resolver' = @('COSMOS_ENDPOINT', 'CUSTOM_RESOLVER') }
$r = Invoke-S5 (New-S5Cfg) -Apply
Check 'no record: known operator admin settings (wildcards) are protected' ($r.error -match 'admin:ADMIN_PROBE_KEY_EUS2')
Check 'no record: unknown names on any app are protected, template names are not' ($r.error -match 'admin:WEBSITE_X' -and $r.error -match 'resolver:CUSTOM_RESOLVER' -and $r.error -notmatch 'COSMOS_ENDPOINT|ADMIN_V3_ENABLED|ADMIN_ALLOWED_CLIENT_IDS')
$guardEvidence = Get-Content $guardPath -Raw | ConvertFrom-Json -AsHashtable
Check 'no record: the evidence names the template baseline' ($guardEvidence.baseline -ceq 'stage5-templates')
$r = Invoke-S5 (New-S5Cfg @{} @{ allowDroppedSettings = @('ADMIN_PROBE_KEY_EUS2', 'WEBSITE_X', 'resolver:CUSTOM_RESOLVER') }) -Apply
Check 'no record: acknowledged by key name' (-not $r.error -and $r.admin)
$script:live = @{ 'fx-admin' = $adminBase; 'fx-resolver' = @('COSMOS_ENDPOINT') }
$r = Invoke-S5 (New-S5Cfg) -Apply
Check 'no record: a deployment with only template names applies (first Stage 5 after an upgrade)' (-not $r.error -and $r.admin)
# No record: names that a template writes only under a configuration condition, or only on another app, are drops.
$stage1Apps = $script:stage1.names.apps
$script:stage1 = @{ names = @{ apps = [ordered]@{ admin = @{ functionApp = 'fx-admin' }; resolver = @{ functionApp = 'fx-resolver' }; sync = @{ functionApp = 'fx-sync' }; reconciler = @{ functionApp = 'fx-reconciler' } } } }
$script:live = @{ 'fx-admin' = $adminBase; 'fx-resolver' = @('COSMOS_ENDPOINT', 'RESOLVER_BUDGET_STATE_GRACE_SECONDS'); 'fx-sync' = @('SYNC_SCHEDULE', 'SYNC_LIMITS_CONTAINER', 'RESOLVER_BUDGET_ENFORCEMENT')
    'fx-reconciler' = @('RECONCILER_SCHEDULE', 'RECONCILER_LEDGER_GATEWAY_RESOURCE_IDS', 'RECONCILER_CONTINUITY_GATE', 'RECONCILER_SOFT_LIMIT_PERCENT', 'RECONCILER_PACING_WINDOW_MINUTES') }
$r = Invoke-S5 (New-S5Cfg) -Apply
Check 'no record: conditional names are drops when the configuration does not write them' ($r.error -match 'reconciler:RECONCILER_LEDGER_GATEWAY_RESOURCE_IDS' -and $r.error -match 'reconciler:RECONCILER_CONTINUITY_GATE' -and $r.error -match 'reconciler:RECONCILER_SOFT_LIMIT_PERCENT' -and $r.error -match 'resolver:RESOLVER_BUDGET_STATE_GRACE_SECONDS' -and -not $r.admin)
Check 'no record: a name that only another app writes is a drop' ($r.error -match 'sync:RESOLVER_BUDGET_ENFORCEMENT' -and $r.error -notmatch 'SYNC_SCHEDULE|RECONCILER_SCHEDULE|SYNC_LIMITS_CONTAINER')
$script:live['fx-sync'] = @('SYNC_SCHEDULE', 'SYNC_LIMITS_CONTAINER')
$cond = New-S5Cfg; $cond.resolver = @{ budgetEnforcement = 'budget-state' }; $cond.reconciler = @{ ledgerGatewayResourceIds = @('/a', '/b'); continuityGate = 'coverage'; softLimitPercent = 80; pacingWindowMinutes = 60 }
$r = Invoke-S5 $cond -Apply
Check 'no record: conditional names are kept when the configuration writes them' (-not $r.error -and $r.admin)
$cond.reconciler.Remove('pacingWindowMinutes')
$r = Invoke-S5 $cond -Apply
Check 'no record: the pacing pair needs both fields' ($r.error -match 'reconciler:RECONCILER_SOFT_LIMIT_PERCENT' -and $r.error -match 'reconciler:RECONCILER_PACING_WINDOW_MINUTES' -and $r.error -notmatch 'LEDGER_GATEWAY|CONTINUITY|BUDGET_STATE')
$script:stage1 = @{ names = @{ apps = $stage1Apps } }
# Values: a defaulted setting whose live value differs would change silently (ADMIN_V3_ENABLED = admin.v3Enabled ?? true).
$script:record = @{ outputs = @{ verify = @{ settings = @{ admin = $adminBase; resolver = @('A') } } } }
$script:live = @{ 'fx-admin' = $adminBase; 'fx-resolver' = @('A') }
$script:liveValues = @{ 'fx-admin|ADMIN_V3_ENABLED' = 'false' }
$r = Invoke-S5 (New-S5Cfg)
Check 'values: preview warns that ADMIN_V3_ENABLED=false would become true' (-not $r.error -and $r.warnings -match "ADMIN_V3_ENABLED on fx-admin from 'false' to the default 'true'" -and $r.warnings -match 'admin\.v3Enabled')
$r = Invoke-S5 (New-S5Cfg) -Apply
Check 'values: apply refuses before any deployment when a live value would change' ($r.error -match '^stage5_settings_would_change' -and $r.error -match 'admin:ADMIN_V3_ENABLED \(set admin\.v3Enabled\)' -and $null -eq $r.admin)
$guardEvidence = Get-Content $guardPath -Raw | ConvertFrom-Json -AsHashtable
Check 'values: the evidence records the blocking change' ((@($guardEvidence.blockingChanges) -join ',') -ceq 'admin:ADMIN_V3_ENABLED')
$r = Invoke-S5 (New-S5Cfg @{ v3Enabled = $false }) -Apply
Check 'values: setting admin.v3Enabled keeps the live value and applies' (-not $r.error -and -not $r.warnings -and $r.admin.v3Enabled -eq $false)
$r = Invoke-S5 (New-S5Cfg @{} @{ allowChangedSettings = @('admin:ADMIN_V3_ENABLED') }) -Apply
Check 'values: an acknowledged change applies and is still reported' (-not $r.error -and $r.warnings -match 'acknowledged in stage5.allowChangedSettings' -and $r.admin)
$r = Invoke-S5 (New-S5Cfg @{} @{ allowDroppedSettings = @('ADMIN_V3_ENABLED') }) -Apply
Check 'values: a drop acknowledgement does not acknowledge a change' ($r.error -match '^stage5_settings_would_change')
$script:liveValues = @{ 'fx-admin|ADMIN_V3_ENABLED' = 'True' }
$r = Invoke-S5 (New-S5Cfg) -Apply
Check 'values: boolean values compare case-insensitively' (-not $r.error -and -not $r.warnings)
$script:liveValues = @{ 'fx-admin|ADMIN_PROJECT_HEADER' = 'x-custom' }; $script:live['fx-admin'] = $adminBase + @('ADMIN_PROJECT_HEADER'); $script:record.outputs.verify.settings.admin = $script:live['fx-admin']
$r = Invoke-S5 (New-S5Cfg) -Apply
Check 'values: a live project header differing from the default is refused' ($r.error -match 'admin:ADMIN_PROJECT_HEADER \(set gateway\.projectHeaderName\)')
$cfgNull = New-S5Cfg; $cfgNull.gateway = @{ projectHeaderName = $null }; $r = Invoke-S5 $cfgNull -Apply
Check 'values: a null field is unset (the default is written)' ($r.error -match 'admin:ADMIN_PROJECT_HEADER')
$cfgHeader = New-S5Cfg; $cfgHeader.gateway = @{ projectHeaderName = 'x-custom' }
$r = Invoke-S5 $cfgHeader -Apply
Check 'values: a configured project header is the operator''s choice' (-not $r.error)
$script:liveValues = @{}; $script:live['fx-admin'] = $adminBase; $script:record.outputs.verify.settings.admin = $adminBase
$namesOnly = try { $null = Get-StgLiveSettingMap -ListSettings { param($n) @('A', 'B') } -FunctionApp fx; 'accepted' } catch { "$_" }
Check 'a lister that returns names without values is refused (values cannot be compared)' ($namesOnly -match '^stage5_settings_unreadable')
Check 'optional field: allowChangedSettings must be a list of names' ((@(Get-StgOptionalFieldProblems @{ stage5 = @{ allowChangedSettings = 'ADMIN_V3_ENABLED' } }) -join ';') -match 'allowChangedSettings' -and -not @(Get-StgOptionalFieldProblems @{ stage5 = @{ allowChangedSettings = @('admin:ADMIN_V3_ENABLED') } }).Count)
# A disabled admin app adds nothing to the configured settings.
Check 'disabled admin: no configured optional settings' (@((Get-StgStage5ConfiguredOptionalSettings -Admin @{ enabled = $false; graphEnabled = $true }).admin).Count -eq 0)
# Stage 7 leaves AzureWebJobs.snapshotApply.Disabled=true on sync after a delegated snapshot; Stage 5 keeps it disabled.
$script:stage1.names.apps['sync'] = @{ functionApp = 'fx-sync' }
$script:record = @{ outputs = @{ verify = @{ settings = @{ admin = $adminBase; resolver = @('A'); sync = @('S') } } } }
$script:live = @{ 'fx-admin' = $adminBase; 'fx-resolver' = @('A'); 'fx-sync' = @('S', 'AzureWebJobs.snapshotApply.Disabled') }
$r = Invoke-S5 (New-S5Cfg) -Apply
Check 'after Stage 7: the snapshotApply toggle is carried, not dropped' (-not $r.error -and -not $r.warnings -and $script:captured.syncCarriedSettings.'AzureWebJobs.snapshotApply.Disabled' -ceq 'true')
$script:liveValues = @{ 'fx-sync|AzureWebJobs.snapshotApply.Disabled' = 'false' }
$r = Invoke-S5 (New-S5Cfg) -Apply
Check 'carried: a live snapshotApply.Disabled=false is carried as false, not forced to true' (-not $r.error -and $script:captured.syncCarriedSettings.'AzureWebJobs.snapshotApply.Disabled' -ceq 'false')
$script:liveValues = @{ 'fx-sync|AzureWebJobs.syncEntitlement.Disabled' = 'false' }; $script:live['fx-sync'] = @('S', 'AzureWebJobs.syncEntitlement.Disabled'); $script:record.outputs.verify.settings.sync = $script:live['fx-sync']
$r = Invoke-S5 (New-S5Cfg) -Apply
Check 'values: a timer enabled by hand is not silently disabled' ($r.error -match 'sync:AzureWebJobs.syncEntitlement.Disabled \(set syncTimerEnabled\)')
$cfgTimer = New-S5Cfg; $cfgTimer.syncTimerEnabled = $true
$r = Invoke-S5 $cfgTimer -Apply
Check 'values: an explicit syncTimerEnabled is the operator''s choice' (-not $r.error)
$script:liveValues = @{}; $script:live['fx-sync'] = @('S'); $script:record.outputs.verify.settings.sync = @('S')
$r = Invoke-S5 (New-S5Cfg) -Apply
Check 'before Stage 7: nothing is carried (parameters unchanged)' (-not $r.error -and $script:captured -and -not $script:captured.ContainsKey('syncCarriedSettings'))
$script:stage1.names.apps.Remove('sync')
$syncModule = @(Get-Resources $s5 | Where-Object { $_.type -ceq 'Microsoft.Resources/deployments' -and "$($_.properties.parameters.syncCarriedSettings)" -match "parameters\('syncCarriedSettings'\)" })
Check 'Stage 5 template passes syncCarriedSettings to the app settings module (default empty)' ($syncModule.Count -eq 1 -and @($s5.parameters.syncCarriedSettings.defaultValue.PSObject.Properties).Count -eq 0)# No Stage 1 apps (fresh deployment preview): no listing.
$script:listCalls = 0
Check 'no apps: guard is a no-op' (@(Assert-StgStage5SettingsKept -Cfg @{} -Stage1 @{ names = @{ apps = @{} } } -Admin @{ enabled = $true }).Count -eq 0 -and $script:listCalls -eq 0)
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

# --- DR standby -Phase Backends -------------------------------------------------------------------
Import-Module (Join-Path $root 'infra/dr/DrStandby.psm1') -Force
Import-Module (Join-Path $root 'infra/dr/DrStandbyBackends.psm1') -Force
$hashOf = { param($cfg, $n) ($cfg | ConvertTo-Json -Depth 20 -Compress) + "|$n" }
$bOld = [ordered]@{ admin = @{ x = 1 }; backends = @(@{ id = 'be1'; url = 'https://one' }) }
$bNew = [ordered]@{ admin = @{ x = 1 }; backends = @(@{ id = 'be1'; url = 'https://one' }, @{ id = 'be2'; url = 'https://two' }) }
$records = @{ '3' = @{ configHash = (& $hashOf $bOld 3) }; '5' = @{ configHash = (& $hashOf $bOld 5) } }
Check 'Backends: added backend only is accepted' ($null -eq (Get-DrStandbyBackendsScopeProblem -Cfg $bNew -BackendIds @('be2') -Records $records -HashOf $hashOf))
Check 'Backends: id match is case-insensitive' ($null -eq (Get-DrStandbyBackendsScopeProblem -Cfg $bNew -BackendIds @('BE2') -Records $records -HashOf $hashOf))
$done = @{ '3' = @{ configHash = (& $hashOf $bNew 3) }; '5' = @{ configHash = (& $hashOf $bNew 5) } }
Check 'Backends: rerun after apply is accepted (idempotent)' ($null -eq (Get-DrStandbyBackendsScopeProblem -Cfg $bNew -BackendIds @('be2') -Records $done -HashOf $hashOf))
$bOther = [ordered]@{ admin = @{ x = 2 }; backends = $bNew.backends }
Check 'Backends: any other change is refused' ("$(Get-DrStandbyBackendsScopeProblem -Cfg $bOther -BackendIds @('be2') -Records $records -HashOf $hashOf)" -match '^standby_backends_scope:.*Stage 3')
$bChanged = [ordered]@{ admin = @{ x = 1 }; backends = @(@{ id = 'be1'; url = 'https://changed' }, @{ id = 'be2'; url = 'https://two' }) }
Check 'Backends: a changed existing backend is refused' ("$(Get-DrStandbyBackendsScopeProblem -Cfg $bChanged -BackendIds @('be2') -Records $records -HashOf $hashOf)" -match '^standby_backends_scope')
Check 'Backends: wrong id named is refused' ("$(Get-DrStandbyBackendsScopeProblem -Cfg $bNew -BackendIds @('be3') -Records $records -HashOf $hashOf)" -match '^standby_backends_unknown')
Check 'Backends: naming an existing backend instead of the new one is refused' ("$(Get-DrStandbyBackendsScopeProblem -Cfg $bNew -BackendIds @('be1') -Records $records -HashOf $hashOf)" -match '^standby_backends_scope')
Check 'Backends: naming every backend is refused' ("$(Get-DrStandbyBackendsScopeProblem -Cfg $bNew -BackendIds @('be1', 'be2') -Records $records -HashOf $hashOf)" -match '^standby_backends_scope: every backend')
Check 'Backends: empty ids are refused' ("$(Get-DrStandbyBackendsScopeProblem -Cfg $bNew -BackendIds @('') -Records $records -HashOf $hashOf)" -match '^standby_backends_ids_required')
Check 'Backends: missing Stage 5 record is refused' ("$(Get-DrStandbyBackendsScopeProblem -Cfg $bNew -BackendIds @('be2') -Records @{ '3' = $records['3'] } -HashOf $hashOf)" -match '^standby_backends_order:.*Stage 5')
Check 'Backends: the input configuration is not modified' (@($bNew.backends).Count -eq 2)
# Lab finding: a JSON round trip turned reconciler.ledgerCoverageStartAt into a DateTime and changed the Stage 5 hash.
$dated = @{ reconciler = @{ ledgerCoverageStartAt = '2026-11-01T00:00:00Z' }; backends = @(@{ id = 'be1' }, @{ id = 'be2' }) }
$datedOld = @{ reconciler = @{ ledgerCoverageStartAt = '2026-11-01T00:00:00Z' }; backends = @(@{ id = 'be1' }) }
$datedRecords = @{ '3' = @{ configHash = (& $hashOf $datedOld 3) }; '5' = @{ configHash = (& $hashOf $datedOld 5) } }
Check 'Backends: date-like strings keep their text in the comparison copy' ((Remove-DrStandbyBackends -Cfg $dated -BackendIds @('be2')).reconciler.ledgerCoverageStartAt -is [string])
Check 'Backends: a config with a date-like string and only an added backend is accepted' ($null -eq (Get-DrStandbyBackendsScopeProblem -Cfg $dated -BackendIds @('be2') -Records $datedRecords -HashOf $hashOf))
Check 'Backends: standby writers off is accepted' ($null -eq (Get-DrStandbyWritersProblem -Sync @{ 'AzureWebJobs.syncEntitlement.Disabled' = 'true' } -Reconciler @{ 'AzureWebJobs.reconcileBudgets.Disabled' = 'True' }))
Check 'Backends: a region B serving after failover is refused' ("$(Get-DrStandbyWritersProblem -Sync @{ 'AzureWebJobs.syncEntitlement.Disabled' = 'false' } -Reconciler @{ 'AzureWebJobs.reconcileBudgets.Disabled' = 'true' })" -match '^standby_backends_region_active')
Check 'Backends: unknown writer state is refused' ($null -ne (Get-DrStandbyWritersProblem -Sync @{} -Reconciler @{}))
$all = @('Data', 'Shells', 'Grants', 'Config', 'Network', 'Code', 'Verify', 'Backends')
function New-Evidence { $p = @{}; foreach ($n in $all) { $p[$n] = @{ completedAt = '2026-01-01T00:00:00Z' } }; @{ phases = $p } }
$s = New-Evidence; $removed = @(Clear-DrStandbyPhaseEvidence -State $s -Phase 'Backends')
Check 'Backends clears only itself and Verify' ((@($removed | Sort-Object) -join ',') -ceq 'Backends,Verify')
foreach ($p in 'Shells', 'Grants', 'Config') { $s = New-Evidence; $null = Clear-DrStandbyPhaseEvidence -State $s -Phase $p; Check "$p supersedes Backends" (-not $s.phases.Contains('Backends')) }
foreach ($p in 'Data', 'Network', 'Code', 'Verify') { $s = New-Evidence; $null = Clear-DrStandbyPhaseEvidence -State $s -Phase $p; Check "$p keeps Backends" ($s.phases.Contains('Backends')) }
$s = New-Evidence; foreach ($n in $all) { $s.phases[$n].completedAt = '2026-01-01T00:0' + [array]::IndexOf($all, $n) + ':00Z' }
Check 'Front Door readiness ignores the Backends phase' ($null -eq (Get-DrFrontDoorReadinessProblem -State $s))
$driver = Get-Content -Raw (Join-Path $root 'infra/dr/Invoke-DrStandby.ps1')
$body = [regex]::Match($driver, "(?s)'Backends' \{.*?\n\}").Value
Check 'Backends phase stops on scope and writer problems before Stage 3 and Stage 5' ($body -match '(?s)Get-DrStandbyBackendsScopeProblem.*if \(\$scope\) \{ Stop-Dr \$scope 3 \}.*Get-DrStandbyWritersProblem.*if \(\$active\) \{ Stop-Dr \$active 3 \}.*Invoke-Stage3.*Invoke-Stage5')
Check 'Backends phase clears prior evidence only after its scope and writer checks pass' ($driver -match '(?m)^if \(\(\$Apply -or \$Phase -ceq ''Verify''\) -and \$Phase -cne ''Backends''\) \{ \. \$clearDrEvidence \}' -and $body -match '(?s)if \(\$active\) \{ Stop-Dr \$active 3 \}\s*if \(\$Apply\) \{ \. \$clearDrEvidence \}.*Invoke-Stage3')
Check 'Backends phase does not touch admin redirects, network or code' ($body -and $body -notmatch 'Invoke-DrAdminRedirects|Invoke-Stage6|New-StgQsContext')

Write-Host "Test-StagedOnboarding: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0 -or $script:pass -lt 94) { exit 1 }
