# Staged deployment: stages 0-4 (checks, resources, network, schema, grants). Dot-sourced by Invoke-StagedDeployment.ps1; not run directly.

# ---------------------------------------------------------------- stage 0: read-only checks

function Invoke-Stage0 {
    param($Cfg)
    $report = [ordered]@{}
    $account = Invoke-StgAzJson @('account', 'show', '--subscription', $Cfg.subscriptionId)
    Assert-Stg ($account.tenantId -ieq $Cfg.tenantId) "subscription $($Cfg.subscriptionId) is in tenant $($account.tenantId), not $($Cfg.tenantId)"
    $report.subscription = @{ id = $account.id; name = $account.name; tenant = $account.tenantId; user = $account.user.name }
    $exists = (Invoke-QsAz @('group', 'exists', '--subscription', $Cfg.subscriptionId, '--name', $Cfg.resourceGroup)) -eq 'true'
    $report.resourceGroup = @{ name = $Cfg.resourceGroup; exists = $exists }
    if ($exists) {
        $items = @(Invoke-StgAzJson @('resource', 'list', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup))
        $report.resourceGroup.resourceCount = $items.Count
        if ($items.Count -and -not (Read-StgState $Cfg).stages['1']) { Write-Host "WARNING: $($Cfg.resourceGroup) holds $($items.Count) resources and no Stage 1 state exists here; Stage 1 refuses a non-empty RG." -ForegroundColor Yellow }
    }
    $providers = 'Microsoft.Web', 'Microsoft.DocumentDB', 'Microsoft.Storage', 'Microsoft.Network', 'Microsoft.OperationalInsights', 'Microsoft.Insights', 'Microsoft.ManagedIdentity', 'Microsoft.ApiManagement', 'Microsoft.AlertsManagement'
    $report.providers = [ordered]@{}
    foreach ($p in $providers) {
        $state = (Invoke-StgAzJson @('provider', 'show', '--subscription', $Cfg.subscriptionId, '--namespace', $p)).registrationState
        $report.providers[$p] = $state
        Assert-Stg ($state -ceq 'Registered') "provider $p is $state; register it (subscription Contributor) before Stage 1"
    }
    $flex = @(Invoke-StgAzJson @('functionapp', 'list-flexconsumption-locations', '--subscription', $Cfg.subscriptionId)) | ForEach-Object { ([string]$_.name).Replace(' ', '').ToLowerInvariant() }
    Assert-Stg ($flex -contains $Cfg.location.ToLowerInvariant()) "Flex Consumption is not offered in $($Cfg.location)"
    $report.flexConsumptionRegion = $Cfg.location
    $report.backends = @()
    foreach ($b in $Cfg.backends) {
        $fd = $Cfg.stage1.foundry
        if ($fd.create -and $b.accountName -ceq $fd.accountName -and $fd.modelDeploymentsBlocked) {
            Write-Host "WARNING: backend $($b.id): model deployments blocked ($($fd.modelDeploymentsBlocked)); allowed requests cannot succeed." -ForegroundColor Yellow
            $report.backends += [ordered]@{ id = $b.id; account = "$($b.accountName) (created in Stage 1, no model deployments)"; blocked = $fd.modelDeploymentsBlocked }
            continue
        }
        if ($fd.create -and $b.accountName -ceq $fd.accountName) {
            $planned = @($fd.deployments | ForEach-Object { $_.name })
            $missing = @($b.deploymentInferenceGeo.Keys | Where-Object { $planned -cnotcontains $_ })
            Assert-Stg (-not $missing.Count) "backend $($b.id) names deployments that stage1.foundry does not create: $($missing -join ', ')"
            $models = @(Invoke-StgAzJson @('cognitiveservices', 'model', 'list', '--subscription', $Cfg.subscriptionId, '--location', $Cfg.location))
            foreach ($d in $fd.deployments) {
                $ok = @($models | Where-Object { $_.model.format -ceq 'Anthropic' -and $_.model.name -ceq $d.model -and $_.model.version -ceq "$($d.version)" -and @($_.model.skus | ForEach-Object name) -contains ($d.sku ?? 'GlobalStandard') })
                Assert-Stg ($ok.Count -ge 1) "model $($d.model)@$($d.version) ($($d.sku ?? 'GlobalStandard')) is not offered in $($Cfg.location) for this subscription"
            }
            $report.backends += [ordered]@{ id = $b.id; account = "$($b.accountName) (created in Stage 1)"; deployments = @($fd.deployments | ForEach-Object { "$($_.name)=$($_.model)@$($_.version)" }) }
            continue
        }
        $acct = Get-StgArm "/subscriptions/$($b.subscriptionId)/resourceGroups/$($b.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($b.accountName)" '2024-10-01'
        $deps = @((Get-StgArm "$($acct.id)/deployments" '2024-10-01').value | ForEach-Object { $_.name })
        $missing = @($b.deploymentInferenceGeo.Keys | Where-Object { $deps -cnotcontains $_ })
        Assert-Stg (-not $missing.Count) "backend $($b.id) lacks deployments: $($missing -join ', ')"
        $report.backends += [ordered]@{ id = $b.id; account = $acct.name; publicNetworkAccess = $acct.properties.publicNetworkAccess; deployments = @($b.deploymentInferenceGeo.Keys) }
    }
    $me = Get-StgGraph 'me?$select=id,userPrincipalName'
    $report.operator = @{ id = $me.id; upn = $me.userPrincipalName }
    foreach ($g in @($Cfg.groups | Where-Object { $_.groupId })) {
        $grp = Get-StgGraph "groups/$($g.groupId)?`$select=id,displayName,securityEnabled"
        Assert-Stg ($grp.securityEnabled -eq $true) "group $($g.groupId) is not a security group"
    }
    $null = Write-StgEvidence 'stage0.json' $report
    $report | ConvertTo-Json -Depth 10 | Write-Host
    return $report
}

# ---------------------------------------------------------------- stage 1: resources only

function Get-Stage1Parameters { param($Cfg)
    $p = [ordered]@{ location = $Cfg.location; tags = $Cfg.tags }
    foreach ($k in $Cfg.stage1.Keys) { $p[$k] = $Cfg.stage1[$k] }
    return $p
}

function Get-StgStage1Deployment {
    param($Cfg)
    try { return Invoke-StgAzJson @('deployment', 'group', 'show', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup, '--name', 'stage1-services') }
    catch { return $null }
}

function Assert-StgStage1Parameters {
    param($Deployment, $Cfg)
    $expected = Get-Stage1Parameters $Cfg
    foreach ($key in $expected.Keys) {
        if (-not $Deployment.properties.parameters.ContainsKey($key)) { throw "stage1_parameters_missing: previous deployment does not record parameter '$key'; use a new empty resource group or supply a reviewed migration." }
        $actualJson = ConvertTo-StgCanonical $Deployment.properties.parameters[$key].value | ConvertTo-Json -Depth 100 -Compress
        $expectedJson = ConvertTo-StgCanonical $expected[$key] | ConvertTo-Json -Depth 100 -Compress
        if ($actualJson -cne $expectedJson) { throw "stage1_parameters_changed: '$key' differs from the succeeded Stage 1 deployment; Stage 1 is create-only. Use a new prefix/RG for a new deployment." }
    }
}

function Get-StgStage1Outputs {
    param($Deployment)
    $out = @{}
    foreach ($key in $Deployment.properties.outputs.Keys) { $out[$key] = $Deployment.properties.outputs[$key].value }
    return $out
}

function Get-StgStage1StableOutput {
    param($Out)
    $principals = @{}; $clientIds = @{}
    foreach ($app in $Out.functionApps) { $principals[$app.key] = $app.service.principalId; $clientIds[$app.key] = $app.service.clientId }
    return [ordered]@{
        names = $Out.names
        principals = $principals
        clientIds = $clientIds
        cosmosEndpoint = $Out.cosmosEndpoint
        cosmosAccountId = $Out.cosmosAccountId
        workspaceId = $Out.workspaceId
        workspaceCustomerId = $Out.workspaceCustomerId
        apimName = $Out.apimName
        apimId = $Out.apimId
        apimPrincipalId = $Out.apimPrincipalId
        apimGatewayUrl = $Out.apimGatewayUrl
        apimStatus = $Out.apimStatus
        foundryAccountId = $Out.foundryAccountId
        foundryAnthropicUrl = $Out.foundryAnthropicUrl
    }
}

function New-StgStage1Result {
    param($Cfg, $Out)
    $principals = @{}; $clientIds = @{}
    foreach ($a in $Out.functionApps) { $principals[$a.key] = $a.service.principalId; $clientIds[$a.key] = $a.service.clientId }
    $verify = Test-Stage1 -Cfg $Cfg -Out $Out
    return @{ names = $Out.names; principals = $principals; clientIds = $clientIds; cosmosEndpoint = $Out.cosmosEndpoint; cosmosAccountId = $Out.cosmosAccountId
        workspaceId = $Out.workspaceId; workspaceCustomerId = $Out.workspaceCustomerId; apimName = $Out.apimName; apimId = $Out.apimId
        apimPrincipalId = $Out.apimPrincipalId; apimGatewayUrl = $Out.apimGatewayUrl; apimStatus = $Out.apimStatus
        foundryAccountId = $Out.foundryAccountId; foundryAnthropicUrl = $Out.foundryAnthropicUrl; verify = $verify }
}

function Invoke-Stage1 {
    param($Cfg, [switch]$Apply)
    $exists = (Invoke-QsAz @('group', 'exists', '--subscription', $Cfg.subscriptionId, '--name', $Cfg.resourceGroup)) -eq 'true'
    if (-not $exists) {
        if (-not $Apply) { Write-Host "preview: resource group $($Cfg.resourceGroup) does not exist; -Apply creates it in $($Cfg.location) (subscription-scope resourceGroups/write)."; return $null }
        $null = Invoke-QsAz @('group', 'create', '--subscription', $Cfg.subscriptionId, '--name', $Cfg.resourceGroup, '--location', $Cfg.location, '--tags', 'workload=claude-code-on-foundry', 'deployment=staged', '--output', 'none')
    }
    $items = @(Invoke-StgAzJson @('resource', 'list', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup))
    $state = Read-StgState $Cfg
    $saved = $state.stages['1']

    # A verified local Stage 1 is read-only on rerun. Never redeploy an Incremental template
    # over a shared RG just because this command was invoked with -Apply.
    if ($saved) {
        $null = Get-StgStage $Cfg 1
        $previous = Get-StgStage1Deployment $Cfg
        if (-not $previous -or $previous.properties.provisioningState -cne 'Succeeded') { throw 'stage1_state_orphaned: local state says Stage 1 completed but its ARM deployment is not Succeeded; inspect the deployment before recovery.' }
        Assert-StgStage1Parameters $previous $Cfg
        if (-not $Apply) { Write-Host 'preview: Stage 1 is already verified for this target and config; no resource write will occur.'; return $null }
        Write-Host 'verify-only: Stage 1 is already verified for this target and config; no resource write will occur.'
        return New-StgStage1Result -Cfg $Cfg -Out (Get-StgStage1Outputs $previous)
    }

    $previous = if ($items.Count) { Get-StgStage1Deployment $Cfg } else { $null }
    $guarded = [bool]$Cfg.sharedResourceGroup -or ($previous -and $previous.properties.provisioningState -cne 'Succeeded')
    if ($items.Count -and $guarded) {
        # Shared RG or a rerun after failed apply: Modify is allowed only for exact resource IDs
        # recorded by this deployment's prior ARM operations, not any unrelated name that shares prefix.
        $priorTargets = if ($previous) { Get-StgStage1TargetIds $Cfg } else { @() }
        $preview = Invoke-QsAz @('deployment', 'group', 'what-if', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup, '--name', 'stage1-services',
            '--template-file', (Join-Path $script:StagedDir 'main.bicep'), '--parameters', "@$(Write-StgParameters $Cfg 'stage1-services' (Get-Stage1Parameters $Cfg))", '--no-pretty-print', '--output', 'json')
        $risky = Get-StgUnsafeSharedChanges -Changes @($preview.changes) -PriorStage1TargetIds $priorTargets
        $null = Write-StgEvidence 'stage1.shared-rg.what-if.json' @($preview.changes | ForEach-Object { [ordered]@{ change = $_.changeType; id = $_.resourceId } })
        foreach ($change in $preview.changes) { Write-Host ("  {0,-8} {1}" -f $change.changeType, ($change.resourceId -replace '^/subscriptions/[^/]+/resourceGroups/', '')) }
        if ($risky.Count) { throw "shared_rg_changes: what-if would change $($risky.Count) resources not recorded by this Stage 1 deployment: $(@($risky | ForEach-Object { "$($_.changeType) $($_.resourceId)" }) -join '; ')" }
        Write-Host "guarded preview: $($items.Count) existing resources; no unrelated Modify or Delete."
        if (-not $Apply -and -not ($previous -and $previous.properties.provisioningState -ceq 'Succeeded')) {
            Write-Host 'Stage 1 what-if is complete; rerun with -Apply to provision the approved resources.'
            return $null
        }
    }

    if ($previous -and $previous.properties.provisioningState -ceq 'Succeeded') {
        # This deployment already completed, but local state was lost: resume only if every Stage 1
        # parameter matches the ARM deployment record. A shared RG is still read-only here.
        Assert-StgStage1Parameters $previous $Cfg
        if (-not $Apply) { Write-Host 'preview: matching succeeded Stage 1 deployment found; no resource write will occur.'; return $null }
        Write-Host 'verify-only: matching succeeded Stage 1 deployment found; no resource write will occur.'
        return New-StgStage1Result -Cfg $Cfg -Out (Get-StgStage1Outputs $previous)
    }

    if ($items.Count -and -not $Cfg.sharedResourceGroup -and -not $previous) {
        throw "rg_not_empty: $($Cfg.resourceGroup) holds $($items.Count) resources and no succeeded stage1-services deployment; Stage 1 targets an empty RG unless sharedResourceGroup is explicitly enabled."
    }
    if (-not $Apply) { return Invoke-StgBicep -Cfg $Cfg -Template 'main.bicep' -Name 'stage1-services' -Parameters (Get-Stage1Parameters $Cfg) }
    $out = Invoke-StgBicep -Cfg $Cfg -Template 'main.bicep' -Name 'stage1-services' -Parameters (Get-Stage1Parameters $Cfg) -Apply
    return New-StgStage1Result -Cfg $Cfg -Out $out
}

function Test-Stage1 {
    param($Cfg, $Out)
    $sub = $Cfg.subscriptionId; $rg = $Cfg.resourceGroup; $v = [ordered]@{ apps = @() }
    $state = Read-StgState $Cfg
    # Stage 1 is also the resource inventory recheck after later stages. Read their saved output only
    # when that stage's own config still matches; do not require its old prerequisite-output hash here.
    $schemaRecord = $state.stages['2']; $grantsRecord = $state.stages['3']; $configRecord = $state.stages['5']; $networkRecord = $state.stages['6']; $codeRecord = $state.stages['7']
    $network = if ($networkRecord -and $networkRecord.configHash -ceq (Get-StgStageInput $Cfg 6)) { $networkRecord.outputs } else { $null }
    $schema = if ($schemaRecord -and $schemaRecord.configHash -ceq (Get-StgStageInput $Cfg 2)) { $schemaRecord.outputs } else { $null }
    $grantsStage = if ($grantsRecord -and $grantsRecord.configHash -ceq (Get-StgStageInput $Cfg 3)) { $grantsRecord.outputs } else { $null }
    $config = if ($configRecord -and $configRecord.configHash -ceq (Get-StgStageInput $Cfg 5)) { $configRecord.outputs } else { $null }
    $code = if ($codeRecord -and $codeRecord.configHash -ceq (Get-StgStageInput $Cfg 7)) { $codeRecord.outputs } else { $null }
    foreach ($a in $Out.functionApps) {
        $site = Get-StgSite $Cfg $a.service.name
        $settings = @(Invoke-StgAzJson @('functionapp', 'config', 'appsettings', 'list', '--subscription', $sub, '--resource-group', $rg, '--name', $a.service.name))
        Assert-Stg ($site.publicNetworkAccess -ceq $Cfg.stage1.functionsPublicNetworkAccess) "$($a.service.name) PNA $($site.publicNetworkAccess)"
        $expectedSubnet = if ($network) { $network.functionsSubnetId } else { '' }
        Assert-Stg ($site.virtualNetworkSubnetId -ieq $expectedSubnet) "$($a.service.name) VNet subnet is '$($site.virtualNetworkSubnetId)', expected '$expectedSubnet' for completed stages"
        Assert-Stg ($site.httpsOnly -eq $true) "$($a.service.name) does not require HTTPS"
        Assert-Stg ($site.runtimeName -ceq 'node' -and $site.runtimeVersion -ceq '22') "$($a.service.name) runtime is $($site.runtimeName) $($site.runtimeVersion), expected Node 22"
        Assert-Stg ($site.ftpsState -ceq 'Disabled') "$($a.service.name) FTPS state is $($site.ftpsState)"
        $settingNames = @($settings | ForEach-Object { $_.name } | Sort-Object)
        $expectedSettings = if ($config) { @($config.verify.settings[$a.key] | Sort-Object) } else { @() }
        if ($a.key -ceq 'sync' -and $code) {
            $snapshotToggle = @($settings | Where-Object { $_.name -ceq 'AzureWebJobs.snapshotApply.Disabled' })
            Assert-Stg ($snapshotToggle.Count -eq 1 -and $snapshotToggle[0].value -ceq 'true') 'snapshotApply must remain disabled after the delegated snapshot cleanup'
            $expectedSettings += 'AzureWebJobs.snapshotApply.Disabled'
            $expectedSettings = @($expectedSettings | Sort-Object)
        }
        Assert-Stg (($settingNames -join '|') -ceq ($expectedSettings -join '|')) "$($a.service.name) application setting names differ from completed Stage 5 (actual=$($settingNames -join ', '); expected=$($expectedSettings -join ', '))"
        Assert-Stg ($a.service.principalId -match $script:Guid) "$($a.service.name) has no principal"
        $v.apps += [ordered]@{ app = $a.key; name = $a.service.name; publicNetworkAccess = $site.publicNetworkAccess; subnet = $site.virtualNetworkSubnetId; settings = $settings.Count; principalId = $a.service.principalId }
    }
    $ownedStorage = @($Out.names.apps.Values | ForEach-Object { $_.storageAccount })
    $storageItems = @(Invoke-StgAzJson @('storage', 'account', 'list', '--subscription', $sub, '--resource-group', $rg) | Where-Object { $ownedStorage -contains $_.name })
    Assert-Stg ($storageItems.Count -eq $ownedStorage.Count) "found $($storageItems.Count) deployed storage accounts; expected $($ownedStorage.Count)"
    foreach ($s in $storageItems) {
        Assert-Stg ($s.publicNetworkAccess -ceq $Cfg.stage1.storagePublicNetworkAccess) "$($s.name) storage PNA is $($s.publicNetworkAccess)"
        Assert-Stg ($s.allowSharedKeyAccess -eq $false -and $s.allowBlobPublicAccess -eq $false) "$($s.name) storage keys/blob public access are enabled"
        Assert-Stg ($s.networkRuleSet.defaultAction -ceq 'Deny' -and $s.networkRuleSet.bypass -ceq 'None') "$($s.name) storage firewall is not deny/none"
        Assert-Stg ($s.minimumTlsVersion -ceq 'TLS1_2' -and $s.enableHttpsTrafficOnly -eq $true) "$($s.name) storage TLS/HTTPS policy is not secure"
    }
    $cosmos = @(Invoke-StgAzJson @('cosmosdb', 'list', '--subscription', $sub, '--resource-group', $rg) | Where-Object { $_.name -ceq $Out.names.cosmosAccount })[0]
    Assert-Stg ($null -ne $cosmos) 'The Stage 1 Cosmos account is missing'
    Assert-Stg ($null -ne $cosmos) 'The Stage 1 Cosmos account is missing'
    Assert-Stg ($cosmos.publicNetworkAccess -ceq $Cfg.stage1.cosmosPublicNetworkAccess) "Cosmos publicNetworkAccess is $($cosmos.publicNetworkAccess)"
    Assert-Stg ($cosmos.disableLocalAuth -eq $true) 'Cosmos local auth is enabled'
    $databases = @(Invoke-StgAzJson @('cosmosdb', 'sql', 'database', 'list', '--subscription', $sub, '--resource-group', $rg, '--account-name', $cosmos.name))
    if ($schema) {
        Assert-Stg (@($databases | Where-Object { $_.name -ceq $schema.databaseName }).Count -eq 1) "Stage 2 database $($schema.databaseName) is missing"
    } else {
        Assert-Stg ($databases.Count -eq 0) 'Cosmos database exists before Stage 2'
    }
    # Only assignments on this deployment's resources count: a shared RG has its own, inherited ones.
    $ownedResourceIds = Get-StgStage1TargetIds $Cfg
    $grants = @((Get-StgArm "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Authorization/roleAssignments" '2022-04-01').value | Where-Object {
        (Test-StgExactResourceScope $_.properties.scope $ownedResourceIds) -and (!$grantsStage -or $_.properties.principalId -ine $grantsStage.apimPrincipalId)
    })
    $expectedGrantCount = if ($grantsStage) { [int]$grantsStage.verify.rgScopedAssignments } else { 0 }
    Assert-Stg ($grants.Count -eq $expectedGrantCount) "found $($grants.Count) Azure role assignments on this deployment's resources; completed Stage 3 records $expectedGrantCount"
    $cosmosRoles = @(Invoke-StgAzJson @('cosmosdb', 'sql', 'role', 'assignment', 'list', '--subscription', $sub, '--resource-group', $rg, '--account-name', $cosmos.name))
    $expectedCosmosRoles = if ($grantsStage) { @($grantsStage.verify.cosmos).Count } else { 0 }
    Assert-Stg ($cosmosRoles.Count -eq $expectedCosmosRoles) "found $($cosmosRoles.Count) Cosmos data assignments; completed Stage 3 records $expectedCosmosRoles"
    $v.cosmos = @{ name = $cosmos.name; publicNetworkAccess = $cosmos.publicNetworkAccess; localAuthDisabled = $cosmos.disableLocalAuth }
    $v.roleAssignmentsOnDeployedResources = $grants.Count
    $v.cosmosDataAssignments = $cosmosRoles.Count
    $v.applicationInsights = @()
    foreach ($app in $Out.functionApps) {
        if (-not $app.service.appInsightsId) { continue }
        $insights = Get-StgArm $app.service.appInsightsId '2020-02-02'
        Assert-Stg ($insights.properties.DisableLocalAuth -eq $true) "$($insights.name) App Insights local authentication is enabled"
        Assert-Stg ($insights.properties.WorkspaceResourceId -ieq $Out.workspaceId) "$($insights.name) targets workspace $($insights.properties.WorkspaceResourceId), expected $($Out.workspaceId)"
        $v.applicationInsights += [ordered]@{ name = $insights.name; localAuthDisabled = $insights.properties.DisableLocalAuth; workspaceId = $insights.properties.WorkspaceResourceId }
        $siteId = $app.service.id
        $diagnostics = @( (Get-StgArm "$siteId/providers/Microsoft.Insights/diagnosticSettings" '2021-05-01-preview').value | Where-Object { $_.name -ceq 'ccof-function-logs' })
        Assert-Stg ($diagnostics.Count -eq 1 -and $diagnostics[0].properties.workspaceId -ieq $Out.workspaceId) "$($app.service.name) FunctionAppLogs diagnostic setting is missing or targets another workspace"
    }
    if ($Cfg.stage1.foundry.create) {
        $fa = Get-StgArm $Out.foundryAccountId '2025-06-01'
        $fdeps = @((Get-StgArm "$($Out.foundryAccountId)/deployments" '2025-06-01').value)
        Assert-Stg ($fa.properties.publicNetworkAccess -ceq $Cfg.stage1.foundry.publicNetworkAccess) "Foundry publicNetworkAccess is $($fa.properties.publicNetworkAccess)"
        Assert-Stg ($fa.properties.disableLocalAuth -eq $true) 'Foundry local auth is enabled'
        foreach ($d in @($Cfg.stage1.foundry.deployments)) {
            $m = @($fdeps | Where-Object { $_.name -ceq $d.name -and $_.properties.provisioningState -ceq 'Succeeded' })
            Assert-Stg ($m.Count -eq 1) "Foundry deployment $($d.name) is not Succeeded"
        }
        $v.foundry = [ordered]@{ name = $fa.name; publicNetworkAccess = $fa.properties.publicNetworkAccess; localAuthDisabled = $fa.properties.disableLocalAuth; deployments = @($fdeps | ForEach-Object { "$($_.name)=$($_.properties.model.name)@$($_.properties.model.version) $($_.sku.name)/$($_.sku.capacity)" }) }
    }
    if ($Out.apimId) {
        $apim = Get-StgArm $Out.apimId '2024-05-01'
        Assert-Stg ($apim.properties.publicNetworkAccess -ceq 'Enabled') "New APIM bootstrap PNA is $($apim.properties.publicNetworkAccess), expected Enabled; Stage 6 verifies outbound VNet integration"
        Assert-Stg ($apim.identity.principalId -ieq $Out.apimPrincipalId) 'New APIM system-assigned identity differs from the Stage 1 output'
        Assert-Stg ($apim.sku.name -ceq $Cfg.stage1.apimSku) "APIM SKU is $($apim.sku.name), expected $($Cfg.stage1.apimSku)"
        $diag = @( (Get-StgArm "$($Out.apimId)/providers/Microsoft.Insights/diagnosticSettings" '2021-05-01-preview').value | Where-Object { $_.name -ceq 'ccof-gateway-logs' })
        Assert-Stg ($diag.Count -eq 1 -and $diag[0].properties.workspaceId -ieq $Out.workspaceId) 'APIM gateway diagnostics are missing or target another workspace'
        $v.apim = @{ sku = $apim.sku.name; publicNetworkAccess = $apim.properties.publicNetworkAccess; principalId = $apim.identity.principalId; diagnosticWorkspaceId = $diag[0].properties.workspaceId }
    }
    $v.apimStatus = $Out.apimStatus
    $null = Write-StgEvidence 'stage1.verify.json' $v
    return $v
}

# ---------------------------------------------------------------- stage 6: network (last setup stage)
# The customer usually builds the network. network.mode verify (the default) changes nothing and runs
# the read-only check scripts/manual/Test-NetworkConfiguration.ps1. Modes existing and create are
# opt-in: the driver creates private endpoints (and, for create, the VNet) and the integrations.

function Get-StgNetworkVerifyArguments {
    param($Cfg, $Stage1)
    $e = $Cfg.network.existing; $sub = $Cfg.subscriptionId; $rg = $Cfg.resourceGroup
    $apps = @($Stage1.names.apps.Keys | Sort-Object)
    $arguments = [ordered]@{
        SubscriptionId = $sub
        VnetResourceId = ($e.functionsSubnetId -replace '/subnets/[^/]+$', '')
        FlexSubnet = ($e.functionsSubnetId -split '/')[-1]
        PeSubnet = ($e.privateEndpointSubnetId -split '/')[-1]
        CosmosResourceId = $Stage1.cosmosAccountId
        StorageAccountIds = @($apps | ForEach-Object { "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$($Stage1.names.apps[$_].storageAccount)" })
        FunctionAppIds = @($apps | ForEach-Object { "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/sites/$($Stage1.names.apps[$_].functionApp)" })
    }
    if ($Stage1.apimName -and $Cfg.stage1.apimSku -in 'StandardV2', 'PremiumV2') {
        $arguments.ApimSubnet = ($e.apimSubnetId -split '/')[-1]
        $arguments.ApimResourceId = $Stage1.apimId
    }
    $foundry = @($Cfg.backends | Where-Object privateEndpoint | ForEach-Object { "/subscriptions/$($_.subscriptionId)/resourceGroups/$($_.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($_.accountName)" } | Select-Object -Unique)
    if ($foundry.Count) { $arguments.FoundryResourceId = $foundry }
    return $arguments
}

function Invoke-StgNetworkVerify {
    param($Cfg, $Stage1, [switch]$Apply)
    $arguments = Get-StgNetworkVerifyArguments $Cfg $Stage1
    $check = Join-Path $script:Repo 'scripts/manual/Test-NetworkConfiguration.ps1'
    if (-not $Apply) {
        Write-Host "preview: network.mode verify: no network resource is created or changed."
        Write-Host "preview: -Apply runs $check (read-only) on VNet $(($arguments.VnetResourceId -split '/')[-1]): subnets $(@($arguments.FlexSubnet, $arguments.PeSubnet, $arguments.ApimSubnet | Where-Object { $_ }) -join ', '); $($arguments.FunctionAppIds.Count) Function Apps, $($arguments.StorageAccountIds.Count) storage accounts, Cosmos$(if ($arguments.ApimResourceId) { ', APIM' })$(if ($arguments.FoundryResourceId) { ", $(@($arguments.FoundryResourceId).Count) Foundry account(s)" })."
        return $null
    }
    $resultPath = Join-Path $script:StateDir 'network-check.json'
    Remove-Item -LiteralPath $resultPath -ErrorAction SilentlyContinue
    & $check @arguments -ResultPath $resultPath | Out-Host
    $exit = $LASTEXITCODE
    Assert-Stg (Test-Path -LiteralPath $resultPath) "network check wrote no results (exit $exit)"
    $rows = @(Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    $fail = @($rows | Where-Object State -ceq 'FAIL')
    $v = [ordered]@{ mode = 'verify'; check = 'scripts/manual/Test-NetworkConfiguration.ps1'; pass = @($rows | Where-Object State -ceq 'PASS').Count; warn = @($rows | Where-Object State -ceq 'WARN').Count; fail = $fail.Count; rows = $rows }
    $null = Write-StgEvidence 'stage6.verify.json' $v
    Assert-Stg ($fail.Count -eq 0 -and $exit -eq 0) "the customer network check reported $($fail.Count) FAIL rows: $(@($fail | ForEach-Object { "$($_.Area) $($_.Item): $($_.Detail)" }) -join '; '). Fix the network and rerun Stage 6; nothing was changed."
    return [ordered]@{ mode = 'verify'; vnetId = $arguments.VnetResourceId; functionsSubnetId = $Cfg.network.existing.functionsSubnetId
        privateEndpointSubnetId = $Cfg.network.existing.privateEndpointSubnetId; apimSubnetId = "$($Cfg.network.existing.apimSubnetId)"; verify = $v }
}

function Invoke-Stage6 {
    param($Cfg, [switch]$Apply)
    $s1 = Get-StgStage $Cfg 1
    if ($Cfg.network.mode -eq 'verify') { return Invoke-StgNetworkVerify -Cfg $Cfg -Stage1 $s1 -Apply:$Apply }    $foundryPrivate = @($Cfg.backends | Where-Object { $_.privateEndpoint -and $_.subscriptionId -ieq $Cfg.subscriptionId -and $_.resourceGroup -ieq $Cfg.resourceGroup } | ForEach-Object { $_.accountName } | Select-Object -Unique)
    $parameters = @{ names = $s1.names; location = $Cfg.location; tags = $Cfg.tags; network = $Cfg.network; foundryAccounts = @($foundryPrivate) }
    $vnetExists = $false
    if ($Cfg.network.mode -eq 'create') {
        $vnetId = "/subscriptions/$($Cfg.subscriptionId)/resourceGroups/$($Cfg.resourceGroup)/providers/Microsoft.Network/virtualNetworks/$($Cfg.network.create.vnetName)"
        $matches = @(Invoke-StgAzJson @('resource', 'list', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup, '--name', $Cfg.network.create.vnetName, '--resource-type', 'Microsoft.Network/virtualNetworks'))
        $vnetExists = [bool]@($matches | Where-Object { $_.id -ieq $vnetId }).Count
    }
    $state = Read-StgState $Cfg
    $action = Get-StgNetworkAction -Mode $Cfg.network.mode -VnetExists $vnetExists -StageStateExists ([bool]$state.stages['6'])
    if ($action -eq 'reuse') {
        $saved = Get-StgStage $Cfg 6
        $out = [ordered]@{}
        foreach ($key in $saved.Keys) { if ($key -cne 'verify' -and $key -cne 'durationSeconds') { $out[$key] = $saved[$key] } }
        Write-Host 'Stage 6 create-mode VNet already exists; skipping the authoritative network deployment.'
    } else {
        $out = Invoke-StgBicep -Cfg $Cfg -Template 'stage6-network.bicep' -Name 'stage6-network' -Apply:$Apply -Parameters $parameters
    }
    $apps = @($s1.names.apps.Keys | Sort-Object)
    $integrateApim = $s1.apimName -and $Cfg.stage1.apimSku -in 'StandardV2', 'PremiumV2'
    if (-not $Apply) {
        if ($action -eq 'reuse') { Write-Host 'preview: no network deployment; -Apply verifies and reconciles the remaining Stage 6 integrations.'; return $null }
        Write-Host "then: VNet integration, one app at a time, for $($apps -join ', ') (az functionapp vnet-integration add)."
        if ($integrateApim) { Write-Host "then: APIM $($s1.apimName) outbound VNet integration on the APIM subnet (virtualNetworkType External; ingress stays public)." }
        if ($foundryPrivate.Count) { Write-Host "Foundry private endpoints: $($foundryPrivate -join ', ')" }
        return $null
    }
    foreach ($k in $apps) {
        $name = $s1.names.apps[$k].functionApp
        $site = Get-StgSite $Cfg $name
        if ($site.virtualNetworkSubnetId -ieq $out.functionsSubnetId) { Write-Host "$name already integrated"; continue }
        $vnet = ($out.functionsSubnetId -split '/subnets/')[0]
        $null = Invoke-QsAz @('functionapp', 'vnet-integration', 'add', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup, '--name', $name, '--vnet', $vnet, '--subnet', $out.functionsSubnetId, '--output', 'none')
        Write-Host "$name integrated with $(($out.functionsSubnetId -split '/')[-1])"
    }
    if ($integrateApim) {
        Assert-Stg ([bool]$out.apimSubnetId) 'Standard v2 APIM integration needs network.create.subnets.apim or network.existing.apimSubnetId'
        $apimPath = "/subscriptions/$($Cfg.subscriptionId)/resourceGroups/$($Cfg.resourceGroup)/providers/Microsoft.ApiManagement/service/$($s1.apimName)"
        $now = Get-StgArm $apimPath '2024-05-01'
        if ($now.properties.virtualNetworkType -ceq 'External' -and $now.properties.virtualNetworkConfiguration.subnetResourceId -ieq $out.apimSubnetId) { Write-Host "$($s1.apimName) already integrated" }
        else {
            # PATCH keeps the identity and every other property (unlike az apim update, which drops the identity).
            $body = Join-Path $script:StateDir 'apim-vnet.json'
            @{ properties = @{ virtualNetworkType = 'External'; virtualNetworkConfiguration = @{ subnetResourceId = $out.apimSubnetId } } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $body -Encoding utf8NoBOM
            $null = Invoke-QsAz @('rest', '--method', 'patch', '--url', "https://management.azure.com$apimPath`?api-version=2024-05-01", '--headers', 'Content-Type=application/json', '--body', "@$body")
            Write-Host "$($s1.apimName): outbound VNet integration requested; waiting (Standard v2 updates take up to 45 minutes)."
            for ($i = 0; $i -lt 120; $i++) { Start-Sleep 30; $now = Get-StgArm $apimPath '2024-05-01'; if ($now.properties.provisioningState -ceq 'Succeeded') { break } }
        }
        Assert-Stg ($now.properties.provisioningState -ceq 'Succeeded' -and $now.properties.virtualNetworkType -ceq 'External' -and $now.properties.virtualNetworkConfiguration.subnetResourceId -ieq $out.apimSubnetId) "APIM integration state $($now.properties.provisioningState) $($now.properties.virtualNetworkType)"
        Assert-Stg ($now.identity.principalId -ieq $s1.apimPrincipalId) 'APIM system-assigned identity changed during VNet integration'
    }
    $v = [ordered]@{ privateEndpoints = @(); privateDnsLinks = @(); apps = @() }
    if ($integrateApim) { $v.apim = [ordered]@{ name = $s1.apimName; sku = $now.sku.name; virtualNetworkType = $now.properties.virtualNetworkType; subnet = ($now.properties.virtualNetworkConfiguration.subnetResourceId -split '/')[-1]; publicNetworkAccess = $now.properties.publicNetworkAccess; identityUnchanged = $true } }
    $dnsTargets = Get-StgNetworkDnsTargets -Cfg $Cfg -Outputs $out -HasFoundry ([bool]$foundryPrivate.Count)
    foreach ($zoneId in $dnsTargets.zoneIds) {
        $zone = Get-StgArm "$zoneId/virtualNetworkLinks" '2024-06-01'
        $linked = @($zone.value | Where-Object { $_.properties.virtualNetwork.id -ieq $dnsTargets.vnetId -and $_.properties.registrationEnabled -eq $false })
        Assert-Stg ($linked.Count -ge 1) "private DNS zone $(($zoneId -split '/')[-1]) is not linked to VNet $($dnsTargets.vnetId)"
        $v.privateDnsLinks += [ordered]@{ zoneId = $zoneId; vnetId = $dnsTargets.vnetId; linkCount = $linked.Count }
    }
    foreach ($id in @($out.storagePrivateEndpointIds) + @($out.cosmosPrivateEndpointId) + @($out.foundryPrivateEndpointIds | Where-Object { $_ })) {
        $pe = Get-StgArm $id '2024-05-01'
        $conn = @($pe.properties.privateLinkServiceConnections)[0].properties.privateLinkServiceConnectionState.status
        $zones = Get-StgArm "$id/privateDnsZoneGroups/default" '2024-05-01'
        $records = @($zones.properties.privateDnsZoneConfigs | ForEach-Object { $_.properties.recordSets } | ForEach-Object { "$($_.fqdn)=$(@($_.ipAddresses) -join ',')" })
        Assert-Stg ($conn -ceq 'Approved') "$($pe.name) connection is $conn"
        Assert-Stg ($records.Count -ge 1) "$($pe.name) has no DNS records"
        $v.privateEndpoints += [ordered]@{ name = $pe.name; connection = $conn; dns = $records }
    }
    foreach ($k in $apps) {
        $site = Get-StgSite $Cfg $s1.names.apps[$k].functionApp
        Assert-Stg ($site.virtualNetworkSubnetId -ieq $out.functionsSubnetId) "$($site.name) is not integrated"
        $v.apps += [ordered]@{ app = $k; subnet = ($site.virtualNetworkSubnetId -split '/')[-1] }
    }
    $null = Write-StgEvidence 'stage6.verify.json' $v
    return $out + @{ verify = $v }
}

# ---------------------------------------------------------------- stage 2: Cosmos schema

function Invoke-Stage2 {
    param($Cfg, [switch]$Apply)
    $s1 = Get-StgStage $Cfg 1
    $out = Invoke-StgBicep -Cfg $Cfg -Template 'stage2-schema.bicep' -Name 'stage2-schema' -Apply:$Apply -Parameters @{
        names = $s1.names; databaseName = $Cfg.cosmos.databaseName; capacityMode = $Cfg.cosmos.capacityMode
        autoscaleMaxThroughput = $Cfg.cosmos.autoscaleMaxThroughput; includeAdmin = [bool]$Cfg.stage1.includeAdmin }
    if (-not $Apply) { return $null }
    $actual = @(Invoke-StgAzJson @('cosmosdb', 'sql', 'container', 'list', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup, '--account-name', $s1.names.cosmosAccount, '--database-name', $Cfg.cosmos.databaseName))
    $v = @()
    foreach ($c in $out.containers) {
        $m = @($actual | Where-Object { $_.name -ceq $c.name })
        Assert-Stg ($m.Count -eq 1) "container $($c.name) missing"
        Assert-Stg (@($m[0].resource.partitionKey.paths)[0] -ceq $c.partitionKey) "container $($c.name) partition key $(@($m[0].resource.partitionKey.paths)[0])"
        $v += [ordered]@{ name = $c.name; partitionKey = $c.partitionKey }
    }
    $docs = @(Invoke-StgAzJson @('cosmosdb', 'sql', 'role', 'assignment', 'list', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup, '--account-name', $s1.names.cosmosAccount))
    # Before the grants stage this proves Stage 2 granted nothing; a rerun after Stage 3 finds its grants.
    if (-not (Read-StgState $Cfg).stages['3']) { Assert-Stg ($docs.Count -eq 0) 'Stage 2 found data-role assignments before Stage 3' }
    $null = Write-StgEvidence 'stage2.verify.json' $v
    return @{ databaseName = $out.databaseName; containers = $v }
}

# ---------------------------------------------------------------- stage 3: runtime grants

function Invoke-Stage3 {
    param($Cfg, [switch]$Apply)
    $s1 = Get-StgStage $Cfg 1; $null = Get-StgStage $Cfg 2
    $apim = Get-StgApimIdentity $Cfg
    $params = @{ names = $s1.names; principals = $s1.principals; databaseName = $Cfg.cosmos.databaseName; roleNames = $Cfg.cosmos.roleNames
        syncMode = $Cfg.sync.mode; apimPrincipalId = $apim.principalId; apimResourceId = $apim.id
        backends = @($Cfg.backends | ForEach-Object { @{ id = $_.id; subscriptionId = $_.subscriptionId; resourceGroup = $_.resourceGroup; accountName = $_.accountName; assignCognitiveServicesUser = ($_.assignCognitiveServicesUser -ne $false) } }) }
    $out = Invoke-StgBicep -Cfg $Cfg -Template 'stage3-grants.bicep' -Name 'stage3-grants' -Apply:$Apply -Parameters $params
    if (-not $Apply) { return $null }
    $v = [ordered]@{ azure = @(); cosmos = @(); foundry = @() }
    $roleNames = @{ 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' = 'Storage Blob Data Owner'; '3913510d-42f4-4e42-8a64-420c390055eb' = 'Monitoring Metrics Publisher'; '73c42c96-874c-492b-b04d-ab87d138a893' = 'Log Analytics Reader' }
    $ownedResourceIds = Get-StgStage1TargetIds $Cfg
    $rgAssignments = @((Get-StgArm "/subscriptions/$($Cfg.subscriptionId)/resourceGroups/$($Cfg.resourceGroup)/providers/Microsoft.Authorization/roleAssignments" '2022-04-01').value | Where-Object { (Test-StgExactResourceScope $_.properties.scope $ownedResourceIds) -and $_.properties.principalId -ine $apim.principalId })
    $expectedAzure = @($out.storageOwnerDetails) + @($out.metricsPublisherDetails) + @($out.workspaceReaderDetails)
    foreach ($expected in $expectedAzure) {
        $matches = @($rgAssignments | Where-Object {
            $_.properties.principalId -ieq $expected.principalId -and
            $_.properties.roleDefinitionId -ieq $expected.roleDefinitionId -and
            $_.properties.scope -ieq $expected.scope
        })
        Assert-Stg ($matches.Count -eq 1) "expected exactly one Azure grant $($expected.roleDefinitionId) for $($expected.principalId) on $($expected.scope); found $($matches.Count)"
    }
    Assert-Stg ($rgAssignments.Count -eq $expectedAzure.Count) "found $($rgAssignments.Count) Azure role assignments on this deployment's resources; expected $($expectedAzure.Count)"
    foreach ($k in @($s1.principals.Keys | Sort-Object)) {
        $ra = @($rgAssignments | Where-Object { $_.properties.principalId -ieq $s1.principals[$k] })
        $v.azure += [ordered]@{ principal = $k; assignments = @($ra | ForEach-Object { $id = ($_.properties.roleDefinitionId -split '/')[-1]; "$(if ($roleNames[$id]) { $roleNames[$id] } else { $id }) @ $(($_.properties.scope -split '/')[-1])" } | Sort-Object) }
    }
    $v.rgScopedAssignments = $rgAssignments.Count
    $cosmos = @(Invoke-StgAzJson @('cosmosdb', 'sql', 'role', 'assignment', 'list', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup, '--account-name', $s1.names.cosmosAccount))
    Assert-Stg ($cosmos.Count -eq @($out.cosmosAssignmentDetails).Count) "Cosmos has $($cosmos.Count) data-role assignments, expected $(@($out.cosmosAssignmentDetails).Count)"
    foreach ($expected in $out.cosmosAssignmentDetails) {
        $matches = @($cosmos | Where-Object {
            $_.principalId -ieq $expected.principalId -and
            $_.roleDefinitionId -ieq $expected.roleDefinitionId -and
            $_.scope -ieq $expected.scope
        })
        Assert-Stg ($matches.Count -eq 1) "expected exactly one Cosmos grant $($expected.roleDefinitionId) for $($expected.principalId) at $($expected.scope); found $($matches.Count)"
    }
    $v.cosmos = @($cosmos | ForEach-Object { $p = $_.principalId; $who = @($s1.principals.Keys | Where-Object { $s1.principals[$_] -ieq $p })[0]; "$who -> $($_.scope -replace '^.*/dbs/', 'dbs/')" } | Sort-Object)
    foreach ($b in $Cfg.backends) {
        $scope = "/subscriptions/$($b.subscriptionId)/resourceGroups/$($b.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($b.accountName)"
        $ra = @((Get-StgArm "$scope/providers/Microsoft.Authorization/roleAssignments" '2022-04-01').value | Where-Object { $_.properties.principalId -ieq $apim.principalId -and $_.properties.roleDefinitionId -like '*a97b65f3-24c7-4388-baec-2e87135dc908' })
        Assert-Stg ($ra.Count -ge 1) "APIM identity has no Cognitive Services User on $($b.accountName)"
        $v.foundry += "$($b.id): Cognitive Services User"
    }
    $null = Write-StgEvidence 'stage3.verify.json' $v
    return @{ cosmosAssignmentIds = $out.cosmosAssignmentIds; apimPrincipalId = $apim.principalId; verify = $v }
}
