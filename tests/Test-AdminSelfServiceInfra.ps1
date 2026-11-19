#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path $root ".env.self-service-infra-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch | Out-Null
$oldAzure = $env:AZURE_CONFIG_DIR
$oldTelemetry = $env:AZURE_CORE_COLLECT_TELEMETRY
$env:AZURE_CORE_COLLECT_TELEMETRY = 'false'
$env:AZURE_CONFIG_DIR = Join-Path $scratch 'azure-logged-out'
New-Item -ItemType Directory -Path $env:AZURE_CONFIG_DIR | Out-Null
try {
    . (Join-Path $root 'infra\staged\Invoke-StagedDeployment.ps1') -DotSourceOnly
    Import-Module (Join-Path $root 'infra\dr\DrStandby.psm1') -Force
    function Assert([bool]$Ok, [string]$Message) { if (-not $Ok) { throw $Message } }
    $site = '/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/rg/providers/Microsoft.Web/sites'
    $apim = $site.Replace('Microsoft.Web/sites', 'Microsoft.ApiManagement/service')
    $pairs = @(
        @{ region = 'A'; syncResourceId = "$site/a-sync"; reconcilerResourceId = "$site/a-reconciler" }
        @{ region = 'B'; syncResourceId = "$site/b-sync"; reconcilerResourceId = "$site/b-reconciler" }
    )
    $cfg = @{ stage1 = @{ includeAdmin = $true }; tenantId = 't'; subscriptionId = 's'; resourceGroup = 'rg'; cosmos = @{ databaseName = 'db'; roleNames = @{} }; sync = @{ mode = 'application-permission' }; backends = @(); admin = @{} }
    $baseline = Get-StgStageInput $cfg 3
    Assert ((Get-StgAdminSelfService $cfg).Count -eq 0) 'Legacy config must not add feature parameters.'
    $cfg.admin = @{ routingPublish = $false; applyNow = $false; configurationHistory = $false }
    Assert ((Get-StgStageInput $cfg 3) -ceq $baseline) 'False flags must preserve legacy Stage 3 hash.'
    Assert ((Get-StgAdminSelfService $cfg).Count -eq 0) 'False flags must not add settings or grants.'
    foreach ($feature in 'routingPublish', 'applyNow', 'configurationHistory') {
        $cfg.admin = @{ $feature = 'true' }; $errorText = ''
        try { $null = Get-StgAdminSelfService $cfg } catch { $errorText = "$_" }
        Assert ($errorText -match "admin\.$feature") "Non-boolean $feature must fail closed."
    }
    $cfg.admin = @{ routingPublish = $true }; $errorText = ''
    try { $null = Get-StgAdminSelfService $cfg } catch { $errorText = "$_" }
    Assert ($errorText -match 'gatewayResourceIds') 'Publishing needs approved APIM resource IDs.'
    $cfg.admin.gatewayResourceIds = @("$apim/a", "$apim/b")
    $cfg.admin.configurationHistory = $true
    $cfg.admin.applyNow = $true; $cfg.admin.workerResourceIds = $pairs
    $optional = Get-StgAdminSelfService $cfg
    Assert ($optional.routingPublish -and $optional.applyNow -and $optional.configurationHistory -and $optional.workerResourceIds.Count -eq 2) 'All independent opt-ins and fixed worker pairs must pass through.'
    foreach ($bad in @(
        @(@{ region = 'A'; syncResourceId = "$site/a-sync"; reconcilerResourceId = 'https://evil.invalid/script' }),
        @(@{ region = 'A'; syncResourceId = "$site/a-sync"; reconcilerResourceId = "$site/a-sync" }),
        @($pairs[0], $pairs[0]),
        @($pairs[0], @{ region = 'B'; syncResourceId = "$site/a-sync".ToUpperInvariant(); reconcilerResourceId = "$site/b-reconciler" }),
        @(@{ region = 'A'; syncResourceId = "$site/a-sync"; reconcilerResourceId = "$site/a-reconciler"; function = 'arbitrary' })
    )) {
        $cfg.admin.workerResourceIds = $bad; $errorText = ''
        try { $null = Get-StgAdminSelfService $cfg } catch { $errorText = "$_" }
        Assert ($errorText -match 'workerResourceIds') 'Malformed, duplicate or arbitrary worker targets must fail.'
    }
    $cfg.admin.workerResourceIds = $pairs
    $cfg.admin.gatewayResourceIds = @("$apim/a", "$apim/a".ToUpperInvariant()); $errorText = ''
    try { $null = Get-StgAdminSelfService $cfg } catch { $errorText = "$_" }
    Assert ($errorText -match 'gatewayResourceIds') 'Case-only aliases of the same APIM must not produce duplicate assignments.'
    $cfg.admin.gatewayResourceIds = @("$apim/a", "$apim/b")
    function Get-StgStage { param($Cfg, $Number) return @{ names = @{}; principals = @{ admin = 'admin-mi' } } }
    function Get-StgApimIdentity { return @{ principalId = 'apim-mi'; id = '/apim' } }
    function Invoke-StgBicep { param($Cfg, $Template, $Name, $Apply, $Parameters) $script:captured = $Parameters; return $null }
    function Get-StgStandbyOption { return $null }
    $null = Invoke-Stage3 $cfg
    Assert ($script:captured.adminGatewayResourceIds.Count -eq 2) 'Stage 3 must target both approved APIMs.'
    Assert ($script:captured.Contains('adminApplyNow') -and $script:captured.adminApplyNow) 'Apply opt-in must grant both workers narrow control-container access.'
    $enabledHash = Get-StgStageInput $cfg 3
    $cfg.admin.gatewayResourceIds = @("$apim/a", "$apim/c")
    Assert ((Get-StgStageInput $cfg 3) -cne $enabledHash) 'Stage 3 hash must track approved gateway changes.'
    $cfg.admin = @{ configurationHistory = $true }
    $null = Invoke-Stage3 $cfg
    Assert (-not $script:captured.Contains('adminGatewayResourceIds')) 'History must not add ARM grants.'
    Assert (-not $script:captured.Contains('adminApplyNow')) 'History alone must not grant workers control writes.'
    Assert ((Get-StgStageInput $cfg 3) -ceq $baseline) 'History must reuse existing container permissions.'
    $cfg.admin = @{ applyNow = $true; workerResourceIds = $pairs }
    Assert ((Get-StgStageInput $cfg 3) -cne $baseline) 'Apply opt-in must invalidate the legacy grants input hash.'
    $cfg.admin = @{ applyNow = $true; workerResourceIds = $pairs; configurationHistory = $true; routingPublish = $true; gatewayResourceIds = @("$apim/a", "$apim/b") }
    $cfg.reconciler = @{ timerEnabled = $true }; $cfg.syncTimerEnabled = $true; $cfg.network = @{}
    $dr = [pscustomobject]@{ secondary = [pscustomobject]@{ location = 'westus'; subnets = [pscustomobject]@{ privateEndpoints = @{ name = 'pe' }; functions = @{ name = 'fn' }; apim = @{ name = 'apim' } } }; standby = [pscustomobject]@{ nameSuffix = 'b'; apim = [pscustomobject]@{ sku = 'StandardV2'; zoneRedundant = $false } } }
    $standby = New-DrStandbyStagedConfig -Primary $cfg -Dr $dr -VnetId '/vnet' -ZoneIds @{} -GatewayResourceIds @("$apim/a", "$apim/b")
    Assert (-not $standby.syncTimerEnabled -and -not $standby.reconciler.timerEnabled) 'Self-service must preserve standby writer fence.'
    Assert ($standby.admin.workerResourceIds.Count -eq 2 -and $standby.admin.gatewayResourceIds.Count -eq 2) 'Both consoles must use the same approved cross-region targets.'
    $script:routingDetails = @("$apim/a", "$apim/b" | ForEach-Object { @{ principalId = 'admin-mi'; roleDefinitionId = '/roles/routing'; scope = $_ } })
    function Get-StgStage { param($Cfg, $Number) return @{ names = @{ cosmosAccount = 'cosmos' }; principals = @{ admin = 'admin-mi' }; workspaceId = '/workspace' } }
    function Get-StgStage1TargetIds { return @($script:routingDetails[0].scope) }
    function Invoke-StgBicep {
        return @{ storageOwnerDetails = @(); metricsPublisherDetails = @(); workspaceReaderDetails = @(); cosmosAssignmentDetails = @(); cosmosAssignmentIds = @(); adminRoutingDetails = $script:routingDetails }
    }
    function Get-StgArm {
        param($Path, $ApiVersion)
        $rows = if ($Path -match '/service/b/') { @($script:routingDetails[1]) } else { @($script:routingDetails[0]) }
        return @{ value = @($rows | ForEach-Object { @{ properties = $_ } }) }
    }
    function Invoke-StgAzJson { return @() }
    function Write-StgEvidence { param($Name, $Value) }
    $result = Invoke-Stage3 $cfg -Apply
    Assert ($result.verify.routing.Count -eq 2) 'Stage 3 readback must verify both local and cross-region routing assignments.'
    function Build([string]$Path) {
        $raw = & az bicep build --file (Join-Path $root $Path) --stdout --only-show-errors
        if ($LASTEXITCODE) { throw "Offline Bicep build failed: $Path" }
        return ($raw -join "`n") | ConvertFrom-Json -AsHashtable -Depth 100
    }
    $grants = Build 'infra\staged\stage3-grants.bicep'
    Assert ($grants.parameters.adminGatewayResourceIds.defaultValue.Count -eq 0) 'Default Stage 3 must deploy no routing grant.'
    Assert (-not $grants.parameters.adminApplyNow.defaultValue) 'Default Stage 3 must deploy no worker control grant.'
    $controlRole = @($grants.resources | Where-Object { $_.type -eq 'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions' -and $_.ContainsKey('condition') })[0]
    Assert ($controlRole.condition -match 'adminApplyNow') 'Worker control role definition itself must be optional.'
    $expectedControlActions = @(
        'Microsoft.DocumentDB/databaseAccounts/readMetadata'
        'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/executeQuery'
        'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/read'
        'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create'
        'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/replace'
    )
    Assert (($controlRole.properties.permissions[0].dataActions | Sort-Object) -join ',' -ceq (($expectedControlActions | Sort-Object) -join ',')) 'Worker control grants must have only metadata/query/read/create/replace.'
    $workerAssignments = @($grants.variables.cosmosAssignments | Where-Object when -eq 'apply-control')
    Assert ($workerAssignments.Count -eq 2 -and @($workerAssignments | Where-Object { $_.container -ne 'adminConfig' -or $_.principal -notin @('sync', 'reconciler') }).Count -eq 0) 'Both workers must be scoped only to adminConfig.'
    $settings = Build 'infra\staged\stage5-config.bicep'
    $json = $settings | ConvertTo-Json -Depth 100 -Compress
    foreach ($name in 'ADMIN_ROUTING_PUBLISH_ENABLED', 'ADMIN_APPLY_ENABLED', 'ADMIN_HISTORY_ENABLED', 'ADMIN_WORKER_RESOURCE_IDS') {
        Assert ($json.Contains($name)) "Stage 5 must map $name."
    }
    foreach ($name in 'CCOF_APPLY_WORKER_ENABLED', 'CCOF_APPLY_WORKER_RESOURCE_ID', 'CCOF_APPLY_WORKER_IDENTITY_RESOURCE_ID', 'CCOF_APPLY_WORKER_PAIRS', 'ADMIN_CONFIG_CONTAINER') {
        Assert ($json.Contains($name)) "Worker settings must map $name."
    }
    $workerSettings = Build 'infra\quickstart\modules\app-settings.bicep'
    Assert ($workerSettings.parameters.applyWorker.defaultValue.Count -eq 0) 'Existing quickstart must not acquire optional worker settings.'
    Assert ($workerSettings.variables.applyWorkerSettings -match 'enabled') 'Worker settings must be gated by the optional enabled flag.'
    foreach ($kind in 'sync', 'reconciler') {
        $resource = @($workerSettings.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites/config' -and $_.name -match "apps.$kind.functionApp" })[0]
        Assert ($resource.properties -match 'CCOF_APPLY_WORKER_RESOURCE_ID' -and $resource.properties -match "apps.$kind.functionApp") "Each $kind worker must receive its own exact resource ID."
        Assert ($resource.properties -match 'CCOF_APPLY_WORKER_IDENTITY_RESOURCE_ID' -and $resource.properties -match "identities.$kind") "Each $kind worker must receive its own existing managed identity resource ID, not an inferred name."
    }
    $routing = Build 'infra\staged\admin-routing-grant.bicep'
    Assert (@($routing.resources | Where-Object type -eq 'Microsoft.Authorization/roleDefinitions').Count -eq 0) 'Stage 3 must preserve its assignment-only ARM boundary.'
    $routingRole = Build 'infra\staged\admin-routing-role.bicep'
    $role = @($routingRole.resources | Where-Object type -eq 'Microsoft.Authorization/roleDefinitions')[0]
    $actions = @($role.properties.permissions[0].actions | Sort-Object)
    Assert (($actions -join ',') -ceq ((@('Microsoft.ApiManagement/service/read', 'Microsoft.ApiManagement/service/backends/read', 'Microsoft.ApiManagement/service/backends/write', 'Microsoft.Authorization/permissions/read') | Sort-Object) -join ',')) 'Routing must grant exactly backend publication and effective-permission reads.'
    $adminRole = @($grants.variables.cosmosRoleDefinitions | Where-Object key -eq 'adminProjectEditor')[0]
    Assert (-not ($adminRole.dataActions -match 'delete|upsert|\*')) 'History and job grants must not expand existing Cosmos writes.'
    Write-Host 'PASS: optional self-service config, Stage 3 grants, Stage 5 settings and DR writer fences.'
} finally {
    $env:AZURE_CONFIG_DIR = $oldAzure
    $env:AZURE_CORE_COLLECT_TELEMETRY = $oldTelemetry
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
