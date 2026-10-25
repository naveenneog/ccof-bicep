# Pure functions for the DR standby region driver (infra/dr/Invoke-DrStandby.ps1, ADR 0033).
# No Azure call here, so tests/Test-DrStandby.ps1 runs offline.
Set-StrictMode -Version Latest

$script:Guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:Region = '^[a-z][a-z0-9]{2,30}$'

function Get-DrValue { param($Object, [string]$Path)
    $v = $Object
    foreach ($p in $Path.Split('.')) {
        if ($null -eq $v) { return $null }
        if ($v -is [Collections.IDictionary]) { $v = if ($v.Contains($p)) { $v[$p] } else { $null } }
        elseif ($v.PSObject.Properties[$p]) { $v = $v.$p } else { return $null }
    }
    return $v
}

# Problems with the `standby` section of dr.config.json and the values it relies on; empty means usable.
function Get-DrStandbyProblems {
    param([Parameter(Mandatory)] $Config)
    $p = [Collections.Generic.List[string]]::new()
    foreach ($f in 'standby.stagedConfigPath', 'standby.stagedStateDirectory', 'standby.stateDirectory', 'standby.apim.publisherEmail', 'standby.apim.publisherName') {
        $v = Get-DrValue $Config $f
        if ([string]::IsNullOrWhiteSpace([string]$v)) { $p.Add("${f}:required") } elseif ("$v" -match '^REPLACE') { $p.Add("${f}:placeholder") }
    }
    $suffix = [string](Get-DrValue $Config 'standby.nameSuffix')
    if ($suffix -cnotmatch '^[a-z0-9]{1,2}$') { $p.Add('standby.nameSuffix:one_or_two_lowercase_letters_or_digits') }
    $loc = [string](Get-DrValue $Config 'secondary.location')
    if ($loc -cnotmatch $script:Region) { $p.Add('secondary.location:invalid') }
    if ($loc -and $loc -ceq [string](Get-DrValue $Config 'primary.location')) { $p.Add('secondary.location:same_as_primary') }
    foreach ($f in 'functionsPublicNetworkAccess', 'storagePublicNetworkAccess') {
        $v = [string](Get-DrValue $Config "standby.$f")
        if ($v -and $v -cnotin 'Enabled', 'Disabled') { $p.Add("standby.${f}:Enabled_or_Disabled") }
    }
    $sku = [string](Get-DrValue $Config 'standby.apim.sku')
    if ($sku -and $sku -cnotin 'StandardV2', 'PremiumV2') { $p.Add('standby.apim.sku:StandardV2_or_PremiumV2') }
    $max = Get-DrValue $Config 'cosmos.autoscaleMaxThroughput'
    if ($null -ne $max -and (-not ("$max" -match '^\d+$') -or [int]$max -lt 1000 -or [int]$max % 1000)) { $p.Add('cosmos.autoscaleMaxThroughput:multiple_of_1000_from_1000') }
    $conv = Get-DrValue $Config 'cosmos.convertServerless'
    if ($null -ne $conv -and $conv -isnot [bool]) { $p.Add('cosmos.convertServerless:true_or_false') }
    $fdStem = [string](Get-DrValue $Config 'frontDoor.stem')
    if ($fdStem -and $fdStem -cnotmatch '^[a-z][a-z0-9-]{2,39}$') { $p.Add('frontDoor.stem:lowercase_letters_digits_hyphens_3_to_40') }
    $fdMode = [string](Get-DrValue $Config 'frontDoor.wafMode')
    if ($fdMode -and $fdMode -cnotin 'Detection', 'Prevention') { $p.Add('frontDoor.wafMode:Detection_or_Prevention') }
    $probe = Get-DrValue $Config 'frontDoor.probeIntervalSeconds'
    if ($null -ne $probe -and (-not ("$probe" -match '^\d+$') -or [int]$probe -lt 5 -or [int]$probe -gt 255)) { $p.Add('frontDoor.probeIntervalSeconds:5_to_255') }
    $p.ToArray()
}

# Region B names: the primary stem plus "-<suffix>"; storage <primary storage stem><suffix><app>.
function Get-DrStandbyNames {
    param([Parameter(Mandatory)] $PrimaryNames, [Parameter(Mandatory)] [string]$Suffix)
    $resolver = [string]$PrimaryNames.apps.resolver.functionApp
    if ($resolver -cnotmatch '^(?<stem>.+)-resolver$') { throw "primary_names_unexpected: resolver app $resolver does not end in -resolver" }
    $stem = $Matches.stem
    $storage = [string]$PrimaryNames.apps.resolver.storageAccount
    if ($storage -cnotmatch '^(?<s>[a-z0-9]+)res$') { throw "primary_names_unexpected: resolver storage $storage does not end in res" }
    $storageStem = "$($Matches.s)$Suffix"
    if ($storageStem.Length -gt 21) { throw "standby_storage_name_too_long: $storageStem plus a 3-letter app code exceeds 24 characters; use a one-letter nameSuffix" }
    return [ordered]@{ stem = "$stem-$Suffix"; storageStem = $storageStem; deploymentPrefix = "$($PrimaryNames.deploymentPrefix)$Suffix" }
}

# The staged configuration for region B: the primary's, with the standby location, timers off, the
# standby subnets in network mode existing, no Foundry private endpoint of its own (the primary's
# endpoints are reached over peering; a regional fallback account has its own) and the `standby`
# section that tells the stage functions to keep their names apart from region A's.
function New-DrStandbyStagedConfig {
    param([Parameter(Mandatory)] [Collections.IDictionary]$Primary, [Parameter(Mandatory)] $Dr, [Parameter(Mandatory)] [string]$VnetId, [Parameter(Mandatory)] [hashtable]$ZoneIds, [string[]]$GatewayResourceIds = @())
    $b = $Primary | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    $b.Remove('__path')
    $sec = $Dr.secondary
    $b.location = [string]$sec.location
    $b.syncTimerEnabled = $false
    if ($b.reconciler) { $b.reconciler.timerEnabled = $false }
    $sn = $sec.subnets
    $b.network = [ordered]@{ mode = 'existing'; existing = [ordered]@{
            privateEndpointSubnetId = "$VnetId/subnets/$($sn.privateEndpoints.name)"
            functionsSubnetId       = "$VnetId/subnets/$($sn.functions.name)"
            apimSubnetId            = "$VnetId/subnets/$($sn.apim.name)"
            privateDnsZoneIds       = $ZoneIds } }
    foreach ($be in @($b.backends)) { $be.privateEndpoint = $false }
    if (-not $b.stage1) { $b.stage1 = @{} }
    $b.stage1.apimSku = [string]$(if ($Dr.standby.apim.PSObject.Properties['sku'] -and $Dr.standby.apim.sku) { $Dr.standby.apim.sku } else { 'StandardV2' })
    # DR-05: one month can hold usage from both gateways, so both regions read both (app-settings.bicep).
    if ($GatewayResourceIds.Count) { $b.reconciler.ledgerGatewayResourceIds = @($GatewayResourceIds); if (-not $b.Contains('admin') -or -not $b.admin) { $b.admin = @{} }; $b.admin.gatewayResourceIds = @($GatewayResourceIds) }
    $b.standby = [ordered]@{ stage1DeploymentName = 'dr-standby-shells'; assignmentNameSalt = "dr-standby-$($Dr.standby.nameSuffix)"; endpointNameSuffix = "-$($Dr.standby.nameSuffix)" }
    return $b
}

# Stage 1 record for region B: its own apps, identities and APIM; the primary's Cosmos account and
# workspace, which both regions share.
function New-DrStandbyStage1Outputs {
    param([Parameter(Mandatory)] [Collections.IDictionary]$Primary, [Parameter(Mandatory)] [Collections.IDictionary]$Shells,
        [Parameter(Mandatory)] [Collections.IDictionary]$Identities, [Parameter(Mandatory)] [Collections.IDictionary]$StandbyNames)
    $names = $Primary.names | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable -Depth 50
    $names.apps = $Shells.apps
    $names.deploymentPrefix = $StandbyNames.deploymentPrefix
    $names.identities = @{ sync = $Identities.sync.name; reconciler = $Identities.reconciler.name }
    $principals = [ordered]@{}; $clientIds = [ordered]@{}
    foreach ($f in @($Shells.functionApps)) {
        $principals[$f.key] = [string]$f.service.principalId
        $clientIds[$f.key] = [string]$f.service.clientId
    }
    foreach ($k in 'sync', 'reconciler') {
        if ($principals[$k] -ine $Identities[$k].principalId) { throw "standby_identity_mismatch: $k app runs as $($principals[$k]), expected $($Identities[$k].principalId)" }
    }
    return [ordered]@{
        names = $names; principals = $principals; clientIds = $clientIds
        cosmosAccountId = $Primary.cosmosAccountId; cosmosEndpoint = $Primary.cosmosEndpoint
        workspaceId = $Primary.workspaceId; workspaceCustomerId = $Primary.workspaceCustomerId
        apimId = $Shells.apimId; apimName = $Shells.apimName; apimPrincipalId = $Shells.apimPrincipalId; apimGatewayUrl = $Shells.apimGatewayUrl
        apimStatus = 'standby'; foundryAccountId = ''; foundryAnthropicUrl = ''
    }
}

function Get-DrGatewayResourceIds {
    param([Parameter(Mandatory)] [string]$PrimaryApimId, [string]$StandbyApimId)
    $ids = @($PrimaryApimId, $StandbyApimId | Where-Object { $_ })
    $ids = @($ids | Where-Object { $_ } | Select-Object -Unique)
    if ($ids.Count -lt 2) { throw 'standby_gateway_id_missing: both primary and standby APIM resource IDs are required for cross-region accounting.' }
    foreach ($id in $ids) {
        if ($id -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._-]{1,90}/providers/Microsoft\.ApiManagement/service/[A-Za-z0-9-]{1,50}$') {
            throw "standby_gateway_id_invalid: $id"
        }
    }
    return $ids
}

function New-DrFrontDoorParameters {
    param(
        [Parameter(Mandatory)] [string]$Stem,
        [Parameter(Mandatory)] [string]$PrimaryApimId,
        [Parameter(Mandatory)] [string]$PrimaryApimHost,
        [Parameter(Mandatory)] [string]$PrimaryApimLocation,
        [Parameter(Mandatory)] [string]$StandbyApimId,
        [Parameter(Mandatory)] [string]$StandbyApimHost,
        [Parameter(Mandatory)] [string]$StandbyApimLocation,
        [Parameter(Mandatory)] [string]$PrimaryAdminSiteId,
        [Parameter(Mandatory)] [string]$PrimaryAdminHost,
        [Parameter(Mandatory)] [string]$PrimaryAdminLocation,
        [Parameter(Mandatory)] [string]$StandbyAdminSiteId,
        [Parameter(Mandatory)] [string]$StandbyAdminHost,
        [Parameter(Mandatory)] [string]$StandbyAdminLocation,
        [string]$WafMode = 'Detection',
        [int]$ProbeIntervalSeconds = 30,
        [switch]$DisablePrimaryOrigins,
        [switch]$DisablePrimaryAdminOrigins,
        [switch]$SimulatePrimaryFailure,
        [hashtable]$Tags = @{}
    )
    if ($Stem -cnotmatch '^[a-z][a-z0-9-]{2,39}$') { throw 'frontdoor_stem_invalid: lowercase letters, digits and hyphens, 3-40 chars; endpoint name must be globally unique.' }
    if ($WafMode -cnotin 'Detection', 'Prevention') { throw 'frontdoor_waf_mode_invalid: use Detection or Prevention.' }
    if ($ProbeIntervalSeconds -lt 5 -or $ProbeIntervalSeconds -gt 255) { throw 'frontdoor_probe_interval_invalid: use 5-255 seconds.' }
    $specs = @(
        @{ id = $PrimaryApimId; host = $PrimaryApimHost; loc = $PrimaryApimLocation; group = 'apim' },
        @{ id = $StandbyApimId; host = $StandbyApimHost; loc = $StandbyApimLocation; group = 'apim' },
        @{ id = $PrimaryAdminSiteId; host = $PrimaryAdminHost; loc = $PrimaryAdminLocation; group = 'admin' },
        @{ id = $StandbyAdminSiteId; host = $StandbyAdminHost; loc = $StandbyAdminLocation; group = 'admin' }
    )
    foreach ($s in $specs) {
        if ($s.id -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._-]{1,90}/providers/Microsoft\.(ApiManagement/service|Web/sites)/[A-Za-z0-9-]{1,60}$') { throw "frontdoor_origin_id_invalid: $($s.id)" }
        if ($s.host -notmatch '^[A-Za-z0-9.-]{1,253}$' -or $s.host -notmatch '\.') { throw "frontdoor_origin_host_invalid: $($s.host)" }
        if ($s.loc -notmatch '^[a-z][a-z0-9]{2,30}$') { throw "frontdoor_origin_location_invalid: $($s.loc)" }
    }
    $apim = @(
        @{ name = 'primary-gateway'; apimId = $PrimaryApimId; hostName = $PrimaryApimHost; location = $PrimaryApimLocation; priority = 1 }
        @{ name = 'standby-gateway'; apimId = $StandbyApimId; hostName = $StandbyApimHost; location = $StandbyApimLocation; priority = 2 }
    )
    $admin = @(
        @{ name = 'primary-admin'; siteId = $PrimaryAdminSiteId; hostName = $PrimaryAdminHost; location = $PrimaryAdminLocation; priority = 1 }
        @{ name = 'standby-admin'; siteId = $StandbyAdminSiteId; hostName = $StandbyAdminHost; location = $StandbyAdminLocation; priority = 2 }
    )
    return @{
        stem = $Stem; tags = $Tags; apimOrigins = $apim; adminOrigins = $admin
        disablePrimaryOrigins = [bool]$DisablePrimaryOrigins
        disablePrimaryAdminOrigins = [bool]$DisablePrimaryAdminOrigins
        simulatePrimaryFailure = [bool]$SimulatePrimaryFailure
        wafMode = $WafMode; probeIntervalSeconds = $ProbeIntervalSeconds
    }
}

# What the Data phase still has to do to a Cosmos account (ARM GET, API 2024-05-15-preview).
function Get-DrCosmosSteps {
    param([Parameter(Mandatory)] $Account, [Parameter(Mandatory)] [string]$SecondaryLocation)
    $props = $Account.properties
    $caps = @($props.capabilities | ForEach-Object { $_.name })
    $steps = [Collections.Generic.List[string]]::new()
    $transition = Get-DrValue $props 'capacityModeChangeTransitionState.capacityModeTransitionStatus'
    if ($transition -and $transition -cne 'Completed' -and $transition -cne 'Succeeded') { $steps.Add('wait_capacity_change'); return $steps.ToArray() }
    $serverless = ($caps -contains 'EnableServerless') -and ([string](Get-DrValue $props 'capacityMode') -cne 'Provisioned')
    if ($serverless) { $steps.Add('convert_to_provisioned') }
    $want = ($SecondaryLocation -replace '\s', '').ToLowerInvariant()
    $have = @($props.locations | ForEach-Object { ($_.locationName -replace '\s', '').ToLowerInvariant() })
    if ($have -notcontains $want) { $steps.Add('add_secondary_region') }
    if (-not $props.enableAutomaticFailover) { $steps.Add('enable_service_managed_failover') }
    $steps.ToArray()
}

Export-ModuleMember -Function Get-DrValue, Get-DrStandbyProblems, Get-DrStandbyNames, New-DrStandbyStagedConfig, New-DrStandbyStage1Outputs, Get-DrGatewayResourceIds, New-DrFrontDoorParameters, Get-DrCosmosSteps
