#Requires -Version 7.0
<#
.SYNOPSIS
    D1 recording (docs/PILOT.md C-9; docs/DEPLOYMENT-STAGES.md): reads every prerequisite resource by
    its id, checks it against the D0 decisions and the answers, and returns the D1 record keys.
    Read-only: every Azure and Graph call goes through the -Get scriptblock (GET url -> object, or
    $null for 404), so the default test suite runs it against fakes.
#>

$script:Arm = 'https://management.azure.com'
$script:Graph = 'https://graph.microsoft.com/v1.0'

Import-Module (Join-Path $PSScriptRoot 'Core.Schema.psm1')
$script:Apps = @(
    @{ key = 'resolver'; group = 'http'; identity = $null }
    @{ key = 'sync'; group = 'function:syncEntitlement'; identity = 'sync' }
    @{ key = 'reconciler'; group = 'function:reconcileBudgets'; identity = 'reconciler' }
)

function Test-CoreIdEqual { param([string]$A, [string]$B) [string]::Equals($A.TrimEnd('/'), $B.TrimEnd('/'), [StringComparison]::OrdinalIgnoreCase) }

function ConvertTo-CoreRegionName { param([string]$Name) ($Name -replace '\s', '').ToLowerInvariant() }

function Get-CoreD1ExpectedIds {
    <#
    .SYNOPSIS
        The resource id of every D1 prerequisite, built from the answers. Pure.
    #>
    param([Parameter(Mandatory)] [System.Collections.IDictionary]$Answers)
    $sub = $Answers.target.subscriptionId
    $rgPath = "/subscriptions/$sub/resourceGroups/$($Answers.target.resourceGroup.name)"
    $p = "$rgPath/providers"
    $n = $Answers.names
    $ids = [ordered]@{
        resourceGroup = $rgPath
        workspace     = "$p/Microsoft.OperationalInsights/workspaces/$($n.logAnalyticsWorkspace)"
        cosmos        = "$p/Microsoft.DocumentDB/databaseAccounts/$($n.cosmosAccount)"
        cosmosPrivateEndpoint = "$p/Microsoft.Network/privateEndpoints/$($n.cosmosPrivateEndpoint)"
        apim          = "$p/Microsoft.ApiManagement/service/$($n.apim)"
        workbook      = "$p/Microsoft.Insights/workbooks/$($Answers.workbook.resourceName)"
        syncIdentity  = "$p/Microsoft.ManagedIdentity/userAssignedIdentities/$($n.identities.sync)"
        reconcilerIdentity = "$p/Microsoft.ManagedIdentity/userAssignedIdentities/$($n.identities.reconciler)"
    }
    foreach ($app in $script:Apps) {
        $a = $n.apps[$app.key]
        $ids["$($app.key).site"] = "$p/Microsoft.Web/sites/$($a.functionApp)"
        $ids["$($app.key).plan"] = "$p/Microsoft.Web/serverfarms/$($a.plan)"
        $ids["$($app.key).storage"] = "$p/Microsoft.Storage/storageAccounts/$($a.storageAccount)"
        $ids["$($app.key).appInsights"] = if ($a.appInsights) { "$p/Microsoft.Insights/components/$($a.appInsights)" } else { $null }
    }
    if ($Answers.network.mode -eq 'create') {
        $c = $Answers.network.create
        $vnet = "$p/Microsoft.Network/virtualNetworks/$($c.vnetName)"
        $ids['network.apimSubnet'] = "$vnet/subnets/$($c.subnets.apim.name)"
        $ids['network.privateEndpointSubnet'] = "$vnet/subnets/$($c.subnets.privateEndpoints.name)"
        $ids['network.functionsSubnet'] = "$vnet/subnets/$($c.subnets.functions.name)"
        $ids['network.runnerSubnet'] = if ($c.subnets.runner) { "$vnet/subnets/$($c.subnets.runner.name)" } else { $null }
        $ids['network.cosmosDnsZone'] = "$p/Microsoft.Network/privateDnsZones/privatelink.documents.azure.com"
        $ids['network.blobDnsZone'] = "$p/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
    }
    else {
        $e = $Answers.network.existing
        $ids['network.apimSubnet'] = $e.apimSubnetId
        $ids['network.privateEndpointSubnet'] = $e.privateEndpointSubnetId
        $ids['network.functionsSubnet'] = $e.functionsSubnetId
        $ids['network.runnerSubnet'] = $null
        $ids['network.cosmosDnsZone'] = $e.privateDnsZoneIds.cosmos
        $ids['network.blobDnsZone'] = $e.privateDnsZoneIds.blob
    }
    return $ids
}

$script:ApiVersions = @{
    'Microsoft.Resources/resourceGroups' = '2024-03-01'
    'Microsoft.Network/virtualNetworks/subnets' = '2024-05-01'
    'Microsoft.Network/privateDnsZones' = '2024-06-01'
    'Microsoft.Network/privateEndpoints' = '2024-05-01'
    'Microsoft.OperationalInsights/workspaces' = '2023-09-01'
    'Microsoft.ManagedIdentity/userAssignedIdentities' = '2023-01-31'
    'Microsoft.DocumentDB/databaseAccounts' = '2024-11-15'
    'Microsoft.Web/sites' = '2024-04-01'
    'Microsoft.Web/serverfarms' = '2024-04-01'
    'Microsoft.Storage/storageAccounts' = '2024-01-01'
    'Microsoft.Insights/components' = '2020-02-02'
    'Microsoft.Insights/workbooks' = '2023-06-01'
    'Microsoft.ApiManagement/service' = '2024-05-01'
}

function Get-CoreArmUrl {
    param([string]$Id, [string]$Type)
    "$script:Arm$Id`?api-version=$($script:ApiVersions[$Type])"
}

function Add-CoreD1Problem {
    param($List, [string]$Path, [string]$Code, [string]$Detail)
    $List.Add([pscustomobject]@{ path = $Path; code = $Code; detail = $Detail })
}

function Test-CoreD1App {
    param($App, [System.Collections.IDictionary]$Answers, $Ids, [scriptblock]$Get, $Identities, $Problems)
    $key = $App.key
    $sizing = $Answers.availability.functions[$key]
    $out = [ordered]@{ functionAppId = $Ids["$key.site"]; hostName = $null; planId = $Ids["$key.plan"]; principalId = $null; identityId = $null; clientId = $null; storageAccountId = $Ids["$key.storage"]; appInsightsId = $Ids["$key.appInsights"] }
    $site = & $Get (Get-CoreArmUrl $Ids["$key.site"] 'Microsoft.Web/sites')
    if (-not $site) { Add-CoreD1Problem $Problems "apps.$key" 'not_found' 'the Function App does not exist or cannot be read'; return $out }
    $out.hostName = $site.properties.defaultHostName
    $config = $site.properties.functionAppConfig
    if ($config.runtime.name -ne 'node' -or [string]$config.runtime.version -ne '22') { Add-CoreD1Problem $Problems "apps.$key" 'runtime_mismatch' 'Flex Consumption with Node.js 22 (ADR-0003)' }
    if (-not (Test-CoreIdEqual ([string]$site.properties.virtualNetworkSubnetId) $Ids['network.functionsSubnet'])) { Add-CoreD1Problem $Problems "apps.$key" 'network_mismatch' 'VNet integration must use the Functions subnet' }
    if (-not (Test-CoreIdEqual ([string]$site.properties.serverFarmId) $Ids["$key.plan"])) { Add-CoreD1Problem $Problems "apps.$key" 'plan_mismatch' 'must run on its own Flex Consumption plan from the answers' }
    $scale = $config.scaleAndConcurrency
    $ready = [int](@($scale.alwaysReady | Where-Object { $_.name -eq $App.group } | ForEach-Object { [int]$_.instanceCount }) | Measure-Object -Sum).Sum
    if ($ready -ne [int]$sizing.alwaysReady -or [int]$scale.maximumInstanceCount -ne [int]$sizing.maximumInstanceCount -or [int]$scale.instanceMemoryMB -ne [int]$sizing.instanceMemoryMB) {
        Add-CoreD1Problem $Problems "apps.$key" 'sizing_mismatch' "always-ready ($($App.group)), maximum instances and memory must match availability.functions.$key"
    }
    if ($App.identity) {
        $identity = $Identities[$App.identity]
        $assigned = @($site.identity.userAssignedIdentities.Keys | Where-Object { Test-CoreIdEqual $_ $Ids["$($App.identity)Identity"] })
        if ($assigned.Count -eq 0) { Add-CoreD1Problem $Problems "apps.$key" 'identity_mismatch' "must run as the user-assigned identity names.identities.$($App.identity)" }
        if ($identity) { $out.identityId = $Ids["$($App.identity)Identity"]; $out.principalId = $identity.properties.principalId; $out.clientId = $identity.properties.clientId }
    }
    elseif ([string]$site.identity.type -notmatch 'SystemAssigned') { Add-CoreD1Problem $Problems "apps.$key" 'identity_mismatch' 'the resolver runs as its system-assigned identity' }
    else { $out.principalId = $site.identity.principalId }
    $plan = & $Get (Get-CoreArmUrl $Ids["$key.plan"] 'Microsoft.Web/serverfarms')
    if (-not $plan) { Add-CoreD1Problem $Problems "apps.$key.plan" 'not_found' 'the plan does not exist' }
    elseif ($plan.sku.name -ne 'FC1' -or [bool]$plan.properties.zoneRedundant -ne [bool]$sizing.zoneRedundant) { Add-CoreD1Problem $Problems "apps.$key.plan" 'plan_mismatch' "Flex Consumption (FC1) with zone redundancy as availability.functions.$key.zoneRedundant" }
    $storage = & $Get (Get-CoreArmUrl $Ids["$key.storage"] 'Microsoft.Storage/storageAccounts')
    if (-not $storage) { Add-CoreD1Problem $Problems "apps.$key.storage" 'not_found' 'the storage account does not exist' }
    else {
        if ($storage.sku.name -ne $Answers.availability.storage.sku) { Add-CoreD1Problem $Problems "apps.$key.storage" 'sku_mismatch' 'redundancy must match availability.storage.sku' }
        if ($storage.properties.allowSharedKeyAccess -ne $false -or $storage.properties.publicNetworkAccess -ne 'Disabled') { Add-CoreD1Problem $Problems "apps.$key.storage" 'access_mismatch' 'shared keys and public network access must be disabled' }
    }
    if ($Ids["$key.appInsights"]) {
        $component = & $Get (Get-CoreArmUrl $Ids["$key.appInsights"] 'Microsoft.Insights/components')
        if (-not $component) { Add-CoreD1Problem $Problems "apps.$key.appInsights" 'not_found' 'the Application Insights component does not exist' }
        elseif (-not (Test-CoreIdEqual ([string]$component.properties.WorkspaceResourceId) $Ids.workspace)) { Add-CoreD1Problem $Problems "apps.$key.appInsights" 'workspace_mismatch' 'must send to the D1 workspace' }
    }
    return $out
}

function Test-CoreD1Registrations {
    param([System.Collections.IDictionary]$Answers, [scriptblock]$Get, $Problems)
    $identity = $Answers.identity
    $result = [ordered]@{}
    foreach ($name in @('gatewayApi', 'developerSignIn', 'resolverApi')) {
        $appId = $identity[$name].appId
        $app = & $Get "$script:Graph/applications(appId='$appId')?`$select=id,appId,identifierUris,api,publicClient"
        $sp = & $Get "$script:Graph/servicePrincipals(appId='$appId')?`$select=id,appId"
        $entry = [ordered]@{ appId = $appId; objectId = $null; servicePrincipalId = $null; identifierUri = $null }
        if (-not $app) { Add-CoreD1Problem $Problems "identity.$name" 'not_found' 'the app registration does not exist in the target tenant or cannot be read'; $result[$name] = $entry; continue }
        $entry.objectId = $app.id
        $entry.identifierUri = @($app.identifierUris)[0]
        if ($sp) { $entry.servicePrincipalId = $sp.id }
        elseif ($name -ne 'developerSignIn') { Add-CoreD1Problem $Problems "identity.$name" 'service_principal_missing' 'the enterprise application (service principal) must exist' }
        $version = if ($null -eq $app.api.requestedAccessTokenVersion) { 1 } else { [int]$app.api.requestedAccessTokenVersion }
        switch ($name) {
            'gatewayApi' {
                $scope = @($app.api.oauth2PermissionScopes | Where-Object { $_.value -eq $identity.gatewayApi.scope -and $_.isEnabled })
                if ($scope.Count -eq 0) { Add-CoreD1Problem $Problems 'identity.gatewayApi' 'scope_missing' 'Expose an API must publish the enabled scope identity.gatewayApi.scope' }
                if (-not $entry.identifierUri) { Add-CoreD1Problem $Problems 'identity.gatewayApi' 'identifier_uri_missing' 'an Application ID URI is required' }
                if ($version -ne [int]$identity.gatewayApi.accessTokenVersion) { Add-CoreD1Problem $Problems 'identity.gatewayApi' 'token_version_mismatch' 'requestedAccessTokenVersion must match identity.gatewayApi.accessTokenVersion' }
            }
            'developerSignIn' {
                $uris = @($app.publicClient.redirectUris)
                $missing = @($identity.developerSignIn.redirectUris | Where-Object { $uris -cnotcontains $_ })
                if ($missing.Count) { Add-CoreD1Problem $Problems 'identity.developerSignIn' 'redirect_uri_missing' "public client redirect URIs lack $($missing.Count) answered URI(s)" }
            }
            'resolverApi' {
                if (@($app.identifierUris) -cnotcontains "api://$appId") { Add-CoreD1Problem $Problems 'identity.resolverApi' 'identifier_uri_missing' 'Application ID URI must be api://<appId> (ADR-0009)' }
                if ($version -ne 2) { Add-CoreD1Problem $Problems 'identity.resolverApi' 'token_version_mismatch' 'requestedAccessTokenVersion must be 2 (ADR-0009)' }
            }
        }
        $result[$name] = $entry
    }
    return $result
}

function Get-CoreD1Record {
    <#
    .SYNOPSIS
        Reads and checks every D1 resource. Returns Problems (path, code, detail) and Outputs (the
        D1 record keys of docs/DEPLOYMENT-STAGES.md). Outputs are meaningful only when Problems is empty.
    #>
    param([Parameter(Mandatory)] [System.Collections.IDictionary]$Answers, [Parameter(Mandatory)] [scriptblock]$Get)
    $problems = [System.Collections.Generic.List[object]]::new()
    $ids = Get-CoreD1ExpectedIds -Answers $Answers
    $av = $Answers.availability
    $location = $Answers.target.location
    function Fail([string]$Path, [string]$Code, [string]$Detail) { Add-CoreD1Problem $problems $Path $Code $Detail }
    function Read([string]$Key, [string]$Type) {
        $resource = & $Get (Get-CoreArmUrl $ids[$Key] $Type)
        if ($null -eq $resource) { Fail $Key 'not_found' 'the resource does not exist or cannot be read with the signed-in identity' }
        return $resource
    }

    $rg = Read 'resourceGroup' 'Microsoft.Resources/resourceGroups'
    if ($rg -and (ConvertTo-CoreRegionName $rg.location) -ne $location) { Fail 'resourceGroup' 'region_mismatch' 'must be in target.location' }

    $subnetChecks = @(
        @{ key = 'network.apimSubnet'; delegation = 'Microsoft.Web/serverFarms'; nsg = $true }
        @{ key = 'network.privateEndpointSubnet'; delegation = $null; nsg = $false }
        @{ key = 'network.functionsSubnet'; delegation = 'Microsoft.App/environments'; nsg = $false }
    )
    foreach ($check in $subnetChecks) {
        $subnet = Read $check.key 'Microsoft.Network/virtualNetworks/subnets'
        if (-not $subnet) { continue }
        $delegations = @($subnet.properties.delegations | ForEach-Object { $_.properties.serviceName })
        if ($check.delegation -and $delegations -notcontains $check.delegation) { Fail $check.key 'delegation_missing' "must be delegated to $($check.delegation)" }
        if ($check.nsg -and -not $subnet.properties.networkSecurityGroup) { Fail $check.key 'nsg_missing' 'APIM integration needs a network security group on its subnet' }
    }
    foreach ($zone in @('network.cosmosDnsZone', 'network.blobDnsZone')) { [void](Read $zone 'Microsoft.Network/privateDnsZones') }

    $workspace = Read 'workspace' 'Microsoft.OperationalInsights/workspaces'
    if ($workspace) {
        if ((ConvertTo-CoreRegionName $workspace.location) -ne $av.telemetry.workspaceRegion) { Fail 'workspace' 'region_mismatch' 'must be in availability.telemetry.workspaceRegion' }
        if ([int]$workspace.properties.retentionInDays -ne [int]$av.telemetry.retentionDays) { Fail 'workspace' 'retention_mismatch' 'must equal availability.telemetry.retentionDays' }
    }

    $identities = @{}
    foreach ($name in @('sync', 'reconciler')) {
        $identity = Read "${name}Identity" 'Microsoft.ManagedIdentity/userAssignedIdentities'
        if ($identity) { $identities[$name] = $identity }
    }

    $cosmos = Read 'cosmos' 'Microsoft.DocumentDB/databaseAccounts'
    if ($cosmos) {
        $serverless = @($cosmos.properties.capabilities | Where-Object { $_.name -eq 'EnableServerless' }).Count -gt 0
        if ($serverless -ne ($av.registry.capacityMode -eq 'serverless')) { Fail 'cosmos' 'capacity_mode_mismatch' 'serverless or provisioned must match availability.registry.capacityMode' }
        $primary = @($cosmos.properties.locations | Where-Object { [int]$_.failoverPriority -eq 0 })[0]
        if (-not $primary -or (ConvertTo-CoreRegionName $primary.locationName) -ne $location) { Fail 'cosmos' 'region_mismatch' 'its write region must be target.location' }
        elseif ([bool]$primary.isZoneRedundant -ne [bool]$av.registry.zoneRedundant) { Fail 'cosmos' 'zones_mismatch' 'zone redundancy must match availability.registry.zoneRedundant' }
        if ($cosmos.properties.publicNetworkAccess -ne 'Disabled') { Fail 'cosmos' 'public_access_enabled' 'public network access must be Disabled' }
        if ($cosmos.properties.disableLocalAuth -ne $true) { Fail 'cosmos' 'local_auth_enabled' 'key-based authentication must be disabled' }
    }
    $endpoint = Read 'cosmosPrivateEndpoint' 'Microsoft.Network/privateEndpoints'
    if ($endpoint) {
        $connection = @($endpoint.properties.privateLinkServiceConnections + $endpoint.properties.manualPrivateLinkServiceConnections | Where-Object { $_ })[0]
        if (-not $connection -or -not (Test-CoreIdEqual $connection.properties.privateLinkServiceId $ids.cosmos)) { Fail 'cosmosPrivateEndpoint' 'wrong_target' 'must connect to the Cosmos account' }
        elseif ($connection.properties.privateLinkServiceConnectionState.status -ne 'Approved') { Fail 'cosmosPrivateEndpoint' 'not_approved' 'the connection must be Approved' }
    }

    $appOutputs = [ordered]@{}
    foreach ($app in $script:Apps) {
        $out = Test-CoreD1App -App $app -Answers $Answers -Ids $ids -Get $Get -Identities $identities -Problems $problems
        $appOutputs[$app.key] = $out
    }

    $apim = Read 'apim' 'Microsoft.ApiManagement/service'
    $apimAppId = $null
    if ($apim) {
        if ($apim.sku.name -ne $av.apim.sku -or [int]$apim.sku.capacity -ne [int]$av.apim.units) { Fail 'apim' 'tier_mismatch' 'tier and units must match availability.apim' }
        $zones = @($apim.zones | Where-Object { $_ } | Sort-Object); $wanted = @($av.apim.zones | Sort-Object)
        if (($zones -join ',') -ne ($wanted -join ',')) { Fail 'apim' 'zones_mismatch' 'zones must match availability.apim.zones' }
        if ([string]$apim.identity.type -notmatch 'SystemAssigned') { Fail 'apim' 'identity_missing' 'the system-assigned identity must be on (ADR-0009)' }
        if ($apim.properties.virtualNetworkType -ne 'External' -or -not (Test-CoreIdEqual ([string]$apim.properties.virtualNetworkConfiguration.subnetResourceId) $ids['network.apimSubnet'])) { Fail 'apim' 'network_mismatch' 'outbound VNet integration must use the APIM subnet' }
        if ($apim.properties.provisioningState -ne 'Succeeded') { Fail 'apim' 'not_ready' 'provisioning has not succeeded yet' }
        if ($apim.identity.principalId) {
            $sp = & $Get "$script:Graph/servicePrincipals/$($apim.identity.principalId)?`$select=id,appId"
            if ($sp) { $apimAppId = $sp.appId } else { Fail 'apim' 'identity_not_readable' "its identity's service principal cannot be read in Microsoft Graph" }
        }
    }
    $workbook = Read 'workbook' 'Microsoft.Insights/workbooks'
    $registrations = Test-CoreD1Registrations -Answers $Answers -Get $Get -Problems $problems

    $outputs = [ordered]@{
        target    = [ordered]@{ tenantId = $Answers.target.tenantId; subscriptionId = $Answers.target.subscriptionId; resourceGroup = $Answers.target.resourceGroup.name; location = $location }
        network   = [ordered]@{
            mode = $Answers.network.mode; apimSubnetId = $ids['network.apimSubnet']; privateEndpointSubnetId = $ids['network.privateEndpointSubnet']
            functionsSubnetId = $ids['network.functionsSubnet']; runnerSubnetId = $ids['network.runnerSubnet']
            cosmosDnsZoneId = $ids['network.cosmosDnsZone']; blobDnsZoneId = $ids['network.blobDnsZone']
        }
        workspace = [ordered]@{ id = $ids.workspace; customerId = $workspace.properties.customerId }
        cosmos    = [ordered]@{ id = $ids.cosmos; endpoint = $cosmos.properties.documentEndpoint; privateEndpointId = $ids.cosmosPrivateEndpoint }
        apim      = [ordered]@{ id = $ids.apim; gatewayUrl = $apim.properties.gatewayUrl; principalId = $apim.identity.principalId; appId = $apimAppId }
        apps      = $appOutputs
        registrations = $registrations
        workbook  = [ordered]@{ id = if ($workbook) { $ids.workbook } else { $null } }
    }
    [pscustomobject]@{ Problems = $problems.ToArray(); Outputs = $outputs }
}

function Add-CoreD1Leaves {
    # One entry (type, value) per scalar, keyed by its path. A key outside [A-Za-z0-9_] could flatten
    # onto another value's path ('apps' + 'sync.principalId'), so it throws, and so does a path seen
    # twice. An empty object or array is an entry of its own, never the same as an absent or null value.
    param($Node, [string]$Path, [System.Collections.Generic.Dictionary[string, object]]$Leaves)
    if ($Node -is [System.Collections.IDictionary]) {
        # get_Count() and get_Keys(): an entry named Count or Keys would answer .Count and .Keys.
        if ($Node.get_Count() -eq 0) { $Leaves.Add($Path, [pscustomobject]@{ Type = 'object'; Value = '{}' }); return }
        foreach ($key in @($Node.get_Keys())) {
            if ([string]$key -cnotmatch '^[A-Za-z0-9_]+\z') { throw "the key '$key' under '$Path' is not a D1 record key" }
            Add-CoreD1Leaves -Node $Node[$key] -Path $(if ($Path) { "$Path.$key" } else { [string]$key }) -Leaves $Leaves
        }
    }
    elseif ($Node -is [array]) {
        if ($Node.Count -eq 0) { $Leaves.Add($Path, [pscustomobject]@{ Type = 'array'; Value = '[]' }); return }
        for ($i = 0; $i -lt $Node.Count; $i++) { Add-CoreD1Leaves -Node $Node[$i] -Path "$Path[$i]" -Leaves $Leaves }
    }
    elseif ($null -eq $Node) { $Leaves.Add($Path, [pscustomobject]@{ Type = 'null'; Value = '' }) }
    else { $Leaves.Add($Path, [pscustomobject]@{ Type = $Node.GetType().Name; Value = [string]$Node }) }
}

function Compare-CoreD1Record {
    <#
    .SYNOPSIS
        The values where a recorded stage-D1 differs from a D1 record read now (WP-SEC C1). Pure. Both
        sides take the JSON round trip the checkpoint record takes, then every scalar is compared by its
        path, type and value, ordinally. Returns one entry (path, recorded, live) per value that differs
        or that only one side has ('(absent)'); a value that could not be read live is empty. Throws
        for a key that is not a D1 record key, which the caller refuses.
    #>
    param([Parameter(Mandatory)] [AllowNull()] $Recorded, [Parameter(Mandatory)] [AllowNull()] $Live)
    $sides = foreach ($record in @($Recorded, $Live)) {
        $leaves = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        if ($null -ne $record) { Add-CoreD1Leaves -Node (ConvertFrom-CoreJson ($record | ConvertTo-Json -Depth 40 -Compress)) -Path '' -Leaves $leaves }
        , $leaves
    }
    $paths = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($side in $sides) { foreach ($key in $side.get_Keys()) { [void]$paths.Add($key) } }
    foreach ($path in $paths) {
        $leaf = foreach ($side in $sides) { if ($side.ContainsKey($path)) { $side[$path] } else { $null } }
        $same = $null -ne $leaf[0] -and $null -ne $leaf[1] -and [string]::Equals($leaf[0].Type, $leaf[1].Type, [StringComparison]::Ordinal) -and
            [string]::Equals($leaf[0].Value, $leaf[1].Value, [StringComparison]::Ordinal)
        if ($same) { continue }
        [pscustomobject]@{ path = $path; recorded = $(if ($leaf[0]) { $leaf[0].Value } else { '(absent)' }); live = $(if ($leaf[1]) { $leaf[1].Value } else { '(absent)' }) }
    }
}

function Get-CoreD1Live {
    <#
    .SYNOPSIS
        Get-CoreD1Record read through a stage's ARM and Graph client (-Send: method, url, body ->
        Status, Content). A GET that does not answer 200 reads as absent, so a value the stage cannot
        read never matches a recorded one.
    #>
    param([Parameter(Mandatory)] [System.Collections.IDictionary]$Answers, [Parameter(Mandatory)] [scriptblock]$Send)
    $get = { param($Url) $reply = & $Send 'GET' $Url $null; if ($reply.Status -eq 200) { $reply.Content } else { $null } }.GetNewClosure()
    Get-CoreD1Record -Answers $Answers -Get $get
}

function Test-CoreD1RecordCurrent {
    <#
    .SYNOPSIS
        WP-SEC C1. D2 and D3 write from the stage-D1 record, which is a shared file that every
        operator writes (docs/DEPLOYMENT-STAGES.md, "The checkpoint record"). Before a write they read
        D1 again with -ReadD1 (D1 answers -> Get-CoreD1Record's result) and use the record only while
        Azure and Microsoft Graph report the same values. Returns $null when every value matches,
        else the refusal lines: each differing path with its recorded and current value.
    #>
    param($Recorded, $Answers, [scriptblock]$ReadD1)
    if ($Recorded -isnot [System.Collections.IDictionary]) { return @('REFUSED before any write: the stage-D1 entry has no outputs. Record D1 again (scripts/Record-Prerequisites.ps1 -Action Record). Nothing was changed.') }
    try {
        if ($Answers -isnot [System.Collections.IDictionary] -or -not $ReadD1) { throw 'no D1 answers or reader' }
        $live = & $ReadD1 $Answers
    }
    catch { return @("REFUSED before any write: stage-D1 could not be read again ($($_.Exception.Message)). Nothing was changed.") }
    try { $differences = @(Compare-CoreD1Record -Recorded $Recorded -Live $live.Outputs) }
    catch { return @("REFUSED before any write: the stage-D1 record could not be compared with what Azure and Microsoft Graph report ($($_.Exception.Message)). Nothing was changed.") }
    if (-not $differences.Count) { return $null }
    @("REFUSED before any write: the stage-D1 record differs from what Azure and Microsoft Graph report now, in $($differences.Count) value(s). The record is a shared file, so a stage writes only from values it can read again. Nothing was changed.") +
    @($differences | ForEach-Object { "  - $($_.path): recorded '$($_.recorded)', now '$($_.live)'" }) +
    @($live.Problems | ForEach-Object { "  D1 check now: $($_.path) [$($_.code)]" }) +
    @('If the change is expected, an infrastructure operator records D1 again (scripts/Record-Prerequisites.ps1 -Action Record), then this stage is planned again.')
}

Export-ModuleMember -Function Get-CoreD1ExpectedIds, Get-CoreD1Record, Get-CoreArmUrl, Test-CoreIdEqual, ConvertTo-CoreRegionName, Compare-CoreD1Record, Get-CoreD1Live, Test-CoreD1RecordCurrent
