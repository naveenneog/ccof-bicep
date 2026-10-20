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

function Invoke-Stage1 {
    param($Cfg, [switch]$Apply)
    $exists = (Invoke-QsAz @('group', 'exists', '--subscription', $Cfg.subscriptionId, '--name', $Cfg.resourceGroup)) -eq 'true'
    if (-not $exists) {
        if (-not $Apply) { Write-Host "preview: resource group $($Cfg.resourceGroup) does not exist; -Apply creates it in $($Cfg.location) (subscription-scope resourceGroups/write)."; return $null }
        $null = Invoke-QsAz @('group', 'create', '--subscription', $Cfg.subscriptionId, '--name', $Cfg.resourceGroup, '--location', $Cfg.location, '--tags', 'workload=claude-code-on-foundry', 'deployment=staged', '--output', 'none')
    }
    $items = @(Invoke-StgAzJson @('resource', 'list', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup))
    $out = $null
    if ($items.Count -and -not (Read-StgState $Cfg).stages['1']) {
        # Resume: a stage1-services deployment that already succeeded here is verified, not redeployed.
        $previous = try { Invoke-StgAzJson @('deployment', 'group', 'show', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup, '--name', 'stage1-services') } catch { $null }
        if (-not $previous -or $previous.properties.provisioningState -cne 'Succeeded') { throw "rg_not_empty: $($Cfg.resourceGroup) holds $($items.Count) resources and no succeeded stage1-services deployment; Stage 1 deploys only into an empty RG (ARM is upsert)." }
        if (-not $Apply) { Write-Host 'preview: stage1-services already succeeded here; -Apply verifies it and records its outputs without redeploying.'; return $null }
        Write-Host "resume: stage1-services succeeded at $($previous.properties.timestamp); verifying it instead of redeploying."
        $out = @{}; foreach ($k in $previous.properties.outputs.Keys) { $out[$k] = $previous.properties.outputs[$k].value }
    }
    if (-not $out) { $out = Invoke-StgBicep -Cfg $Cfg -Template 'main.bicep' -Name 'stage1-services' -Parameters (Get-Stage1Parameters $Cfg) -Apply:$Apply }
    if (-not $Apply) { return $null }
    $principals = @{}; $clientIds = @{}
    foreach ($a in $out.functionApps) { $principals[$a.key] = $a.service.principalId; $clientIds[$a.key] = $a.service.clientId }
    $verify = Test-Stage1 -Cfg $Cfg -Out $out
    return @{ names = $out.names; principals = $principals; clientIds = $clientIds; cosmosEndpoint = $out.cosmosEndpoint; cosmosAccountId = $out.cosmosAccountId
        workspaceId = $out.workspaceId; workspaceCustomerId = $out.workspaceCustomerId; apimName = $out.apimName; apimId = $out.apimId
        apimPrincipalId = $out.apimPrincipalId; apimGatewayUrl = $out.apimGatewayUrl; apimStatus = $out.apimStatus; verify = $verify }
}

function Test-Stage1 {
    param($Cfg, $Out)
    $sub = $Cfg.subscriptionId; $rg = $Cfg.resourceGroup; $v = [ordered]@{ apps = @() }
    foreach ($a in $Out.functionApps) {
        $site = Get-StgSite $Cfg $a.service.name
        $settings = @(Invoke-StgAzJson @('functionapp', 'config', 'appsettings', 'list', '--subscription', $sub, '--resource-group', $rg, '--name', $a.service.name))
        Assert-Stg ($site.publicNetworkAccess -ceq $Cfg.stage1.functionsPublicNetworkAccess) "$($a.service.name) PNA $($site.publicNetworkAccess)"
        Assert-Stg (-not $site.virtualNetworkSubnetId) "$($a.service.name) is already VNet-attached"
        Assert-Stg ($settings.Count -eq 0) "$($a.service.name) has $($settings.Count) application settings"
        Assert-Stg ($a.service.principalId -match $script:Guid) "$($a.service.name) has no principal"
        $v.apps += [ordered]@{ app = $a.key; name = $a.service.name; publicNetworkAccess = $site.publicNetworkAccess; settings = $settings.Count; principalId = $a.service.principalId }
    }
    foreach ($s in @(Invoke-StgAzJson @('storage', 'account', 'list', '--subscription', $sub, '--resource-group', $rg))) {
        Assert-Stg ($s.allowSharedKeyAccess -eq $false -and $s.networkRuleSet.defaultAction -ceq 'Deny') "$($s.name) storage is not keyless/deny"
    }
    $cosmos = @(Invoke-StgAzJson @('cosmosdb', 'list', '--subscription', $sub, '--resource-group', $rg))[0]
    Assert-Stg ($cosmos.disableLocalAuth -eq $true) 'Cosmos local auth is enabled'
    Assert-Stg (@(Invoke-StgAzJson @('cosmosdb', 'sql', 'database', 'list', '--subscription', $sub, '--resource-group', $rg, '--account-name', $cosmos.name)).Count -eq 0) 'Cosmos already has a database'
    $grants = @((Get-StgArm "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Authorization/roleAssignments" '2022-04-01').value | Where-Object { $_.properties.scope -like "*/resourceGroups/$rg*" })
    Assert-Stg ($grants.Count -eq 0) "$($grants.Count) role assignments at or below the RG"
    $v.cosmos = @{ name = $cosmos.name; publicNetworkAccess = $cosmos.publicNetworkAccess; localAuthDisabled = $cosmos.disableLocalAuth }
    $v.roleAssignmentsAtOrBelowRg = 0
    $v.apimStatus = $Out.apimStatus
    $null = Write-StgEvidence 'stage1.verify.json' $v
    return $v
}

# ---------------------------------------------------------------- stage 2: network

function Invoke-Stage2 {
    param($Cfg, [switch]$Apply)
    $s1 = Get-StgStage $Cfg 1
    $out = Invoke-StgBicep -Cfg $Cfg -Template 'stage2-network.bicep' -Name 'stage2-network' -Apply:$Apply -Parameters @{ names = $s1.names; location = $Cfg.location; tags = $Cfg.tags; network = $Cfg.network }
    $apps = @($s1.names.apps.Keys | Sort-Object)
    if (-not $Apply) { Write-Host "then: VNet integration, one app at a time, for $($apps -join ', ') (az functionapp vnet-integration add)."; return $null }
    foreach ($k in $apps) {
        $name = $s1.names.apps[$k].functionApp
        $site = Get-StgSite $Cfg $name
        if ($site.virtualNetworkSubnetId -ieq $out.functionsSubnetId) { Write-Host "$name already integrated"; continue }
        $vnet = ($out.functionsSubnetId -split '/subnets/')[0]
        $null = Invoke-QsAz @('functionapp', 'vnet-integration', 'add', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup, '--name', $name, '--vnet', $vnet, '--subnet', $out.functionsSubnetId, '--output', 'none')
        Write-Host "$name integrated with $(($out.functionsSubnetId -split '/')[-1])"
    }
    $v = [ordered]@{ privateEndpoints = @(); apps = @() }
    foreach ($id in @($out.storagePrivateEndpointIds) + @($out.cosmosPrivateEndpointId)) {
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
    $null = Write-StgEvidence 'stage2.verify.json' $v
    return $out + @{ verify = $v }
}

# ---------------------------------------------------------------- stage 3: Cosmos schema

function Invoke-Stage3 {
    param($Cfg, [switch]$Apply)
    $s1 = Get-StgStage $Cfg 1
    $out = Invoke-StgBicep -Cfg $Cfg -Template 'stage3-schema.bicep' -Name 'stage3-schema' -Apply:$Apply -Parameters @{
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
    Assert-Stg ($docs.Count -eq 0) 'Stage 3 found data-role assignments already present'
    $null = Write-StgEvidence 'stage3.verify.json' $v
    return @{ databaseName = $out.databaseName; containers = $v }
}

# ---------------------------------------------------------------- stage 4: runtime grants

function Invoke-Stage4 {
    param($Cfg, [switch]$Apply)
    $s1 = Get-StgStage $Cfg 1; $null = Get-StgStage $Cfg 3
    $apim = Get-StgApimIdentity $Cfg
    $params = @{ names = $s1.names; principals = $s1.principals; databaseName = $Cfg.cosmos.databaseName; roleNames = $Cfg.cosmos.roleNames
        syncMode = $Cfg.sync.mode; apimPrincipalId = $apim.principalId; apimResourceId = $apim.id
        backends = @($Cfg.backends | ForEach-Object { @{ id = $_.id; subscriptionId = $_.subscriptionId; resourceGroup = $_.resourceGroup; accountName = $_.accountName; assignCognitiveServicesUser = ($_.assignCognitiveServicesUser -ne $false) } }) }
    $out = Invoke-StgBicep -Cfg $Cfg -Template 'stage4-grants.bicep' -Name 'stage4-grants' -Apply:$Apply -Parameters $params
    if (-not $Apply) { return $null }
    $v = [ordered]@{ azure = @(); cosmos = @(); foundry = @() }
    $roleNames = @{ 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' = 'Storage Blob Data Owner'; '3913510d-42f4-4e42-8a64-420c390055eb' = 'Monitoring Metrics Publisher'; '73c42c96-874c-492b-b04d-ab87d138a893' = 'Log Analytics Reader' }
    $rgAssignments = @((Get-StgArm "/subscriptions/$($Cfg.subscriptionId)/resourceGroups/$($Cfg.resourceGroup)/providers/Microsoft.Authorization/roleAssignments" '2022-04-01').value | Where-Object { $_.properties.scope -like "*/resourceGroups/$($Cfg.resourceGroup)/*" })
    foreach ($k in @($s1.principals.Keys | Sort-Object)) {
        $ra = @($rgAssignments | Where-Object { $_.properties.principalId -ieq $s1.principals[$k] })
        $v.azure += [ordered]@{ principal = $k; assignments = @($ra | ForEach-Object { $id = ($_.properties.roleDefinitionId -split '/')[-1]; "$(if ($roleNames[$id]) { $roleNames[$id] } else { $id }) @ $(($_.properties.scope -split '/')[-1])" } | Sort-Object) }
    }
    $unexpected = @($rgAssignments | Where-Object { $p = $_.properties.principalId; -not @($s1.principals.Values | Where-Object { $_ -ieq $p }).Count })
    Assert-Stg ($unexpected.Count -eq 0) "$($unexpected.Count) RG-scoped role assignments belong to principals outside Stage 1"
    $v.rgScopedAssignments = $rgAssignments.Count
    $cosmos = @(Invoke-StgAzJson @('cosmosdb', 'sql', 'role', 'assignment', 'list', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup, '--account-name', $s1.names.cosmosAccount))
    Assert-Stg ($cosmos.Count -eq @($out.cosmosAssignmentIds).Count) "Cosmos has $($cosmos.Count) data-role assignments, expected $(@($out.cosmosAssignmentIds).Count)"
    $v.cosmos = @($cosmos | ForEach-Object { $p = $_.principalId; $who = @($s1.principals.Keys | Where-Object { $s1.principals[$_] -ieq $p })[0]; "$who -> $($_.scope -replace '^.*/dbs/', 'dbs/')" } | Sort-Object)
    foreach ($b in $Cfg.backends) {
        $scope = "/subscriptions/$($b.subscriptionId)/resourceGroups/$($b.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($b.accountName)"
        $ra = @((Get-StgArm "$scope/providers/Microsoft.Authorization/roleAssignments" '2022-04-01').value | Where-Object { $_.properties.principalId -ieq $apim.principalId -and $_.properties.roleDefinitionId -like '*a97b65f3-24c7-4388-baec-2e87135dc908' })
        Assert-Stg ($ra.Count -ge 1) "APIM identity has no Cognitive Services User on $($b.accountName)"
        $v.foundry += "$($b.id): Cognitive Services User"
    }
    $null = Write-StgEvidence 'stage4.verify.json' $v
    return @{ cosmosAssignmentIds = $out.cosmosAssignmentIds; apimPrincipalId = $apim.principalId; verify = $v }
}
