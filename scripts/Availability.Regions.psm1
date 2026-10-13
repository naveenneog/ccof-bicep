#Requires -Version 7.0
<#
.SYNOPSIS
    Live, read-only region facts for the availability decisions (ADR-0014, decision 6): zones,
    region pairs and geography, service and SKU availability, the subscription's Cosmos DB zone
    access, Flex Consumption zone redundancy and Claude models in the backend subscription.
    A read that fails is recorded as unavailable and never as an empty list (AGENT rules).
#>
Import-Module (Join-Path $PSScriptRoot 'Availability.Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Azure.psm1')

$script:Arm = 'https://management.azure.com'

function New-AvailabilityRegionOperations {
    param([string]$BackendAzureConfigDir)
    $configDir = $BackendAzureConfigDir; $arm = $script:Arm
    $pages = { param($s, $u) Get-OnboardingPages -Url $u -Send ({ param($m, $x, $b) Invoke-OnboardingRest $s $m $x $b }.GetNewClosure()) }
    @{
        GetLocations = { param($s) (Invoke-OnboardingRest $s 'GET' "$arm/subscriptions/$s/locations?api-version=2022-12-01" $null) }.GetNewClosure()
        GetProvider = { param($s, $ns) Invoke-OnboardingRest $s 'GET' "$arm/subscriptions/$s/providers/$ns`?api-version=2021-04-01" $null }.GetNewClosure()
        GetApimSkus = { param($s) & $pages $s "$arm/subscriptions/$s/providers/Microsoft.ApiManagement/skus?api-version=2024-05-01" }.GetNewClosure()
        GetCosmosLocations = { param($s) & $pages $s "$arm/subscriptions/$s/providers/Microsoft.DocumentDB/locations?api-version=2024-11-15" }.GetNewClosure()
        GetFlexLocations = {
            param($s, $zoneRedundant)
            $arguments = @('functionapp', 'list-flexconsumption-locations')
            if ($zoneRedundant) { $arguments += @('--zone-redundant', 'true') }
            Invoke-OnboardingAzJson ($arguments + @('--subscription', $s))
        }
        GetModels = {
            param($s, $region)
            $previous = $env:AZURE_CONFIG_DIR
            try {
                if ($configDir) { $env:AZURE_CONFIG_DIR = $configDir }
                & $pages $s "$arm/subscriptions/$s/providers/Microsoft.CognitiveServices/locations/$region/models?api-version=2024-10-01"
            }
            finally { $env:AZURE_CONFIG_DIR = $previous }
        }.GetNewClosure()
        ModelsProvider = {
            param($s)
            $previous = $env:AZURE_CONFIG_DIR
            try { if ($configDir) { $env:AZURE_CONFIG_DIR = $configDir }; Invoke-OnboardingRest $s 'GET' "$arm/subscriptions/$s/providers/Microsoft.CognitiveServices?api-version=2021-04-01" $null }
            finally { $env:AZURE_CONFIG_DIR = $previous }
        }.GetNewClosure()
    }
}

function Read-AvailabilityFact {
    param([scriptblock]$Read)
    try {
        $value = & $Read
        # A 404 or an empty body is not an empty list: the read failed (AGENT rules).
        if ($null -eq $value) { return @{ status = 'unavailable'; reasonCode = 'provider_read_empty'; value = $null } }
        @{ status = 'ok'; reasonCode = $null; value = $value }
    }
    catch {
        $code = $_.Exception.Data['AvailabilityCode']; if (-not $code) { $code = $_.Exception.Data['OnboardingCode'] }
        if (-not $code) { $code = 'provider_read_failed' }
        @{ status = 'unavailable'; reasonCode = [string]$code; value = $null }
    }
}

function Get-ProviderRegionSet {
    param($Fact, [string]$ResourceType, [hashtable]$NameByDisplay)
    $result = @{ listed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); zones = @{}; missing = $false }
    if ($Fact.status -ne 'ok') { return $result }
    $type = @($Fact.value.resourceTypes | Where-Object { [string]::Equals($_.resourceType, $ResourceType, 'OrdinalIgnoreCase') })[0]
    if (-not $type) { $result.missing = $true; return $result }
    foreach ($display in @($type.locations)) { $n = $NameByDisplay[([string]$display).Replace(' ', '').ToLowerInvariant()]; if ($n) { [void]$result.listed.Add($n) } }
    foreach ($mapping in @($type.zoneMappings)) {
        $n = $NameByDisplay[([string]$mapping.location).Replace(' ', '').ToLowerInvariant()]
        if ($n) { $result.zones[$n] = @($mapping.zones | Sort-Object) }
    }
    $result
}

function Get-AvailabilityRegionFacts {
    param(
        [Parameter(Mandatory)] [string]$SubscriptionId, [Parameter(Mandatory)] [string]$BackendSubscriptionId,
        [Parameter(Mandatory)] [string[]]$Regions, [Parameter(Mandatory)] [hashtable]$Operations
    )
    foreach ($id in @($SubscriptionId, $BackendSubscriptionId)) {
        if ($id -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { Stop-Availability 'subscription_invalid' 'Subscription ids must be GUIDs.' }
    }
    foreach ($region in $Regions) { if ($region -cnotmatch '^[a-z0-9]{2,40}$') { Stop-Availability 'region_invalid' "Region '$region' is not an Azure location name: use the ARM name, lower-case letters and digits without spaces." } }
    if (@($Regions | Sort-Object -Unique).Count -ne $Regions.Count) { Stop-Availability 'region_invalid' 'Candidate regions must be unique.' }
    $locations = Read-AvailabilityFact { & $Operations.GetLocations $SubscriptionId }
    if ($locations.status -ne 'ok') { Stop-Availability 'locations_unavailable' 'The subscription''s region list could not be read, so no region can be checked. No availability decision was recorded.' }
    $byName = @{}; $nameByDisplay = @{}
    foreach ($l in @($locations.value.value)) { $byName[$l.name] = $l; $nameByDisplay[([string]$l.displayName).Replace(' ', '').ToLowerInvariant()] = $l.name }
    foreach ($region in $Regions) { if (-not $byName.ContainsKey($region)) { Stop-Availability 'region_unknown' "Region '$region' is not available to subscription $SubscriptionId." } }

    $reads = [ordered]@{ locations = @{ status = 'ok'; reasonCode = $null } }
    $apimProvider = Read-AvailabilityFact { & $Operations.GetProvider $SubscriptionId 'Microsoft.ApiManagement' }
    $cacheProvider = Read-AvailabilityFact { & $Operations.GetProvider $SubscriptionId 'Microsoft.Cache' }
    $workspaces = Read-AvailabilityFact { & $Operations.GetProvider $SubscriptionId 'Microsoft.OperationalInsights' }
    $modelsReader = if ($Operations.ModelsProvider) { $Operations.ModelsProvider } else { { param($s) & $Operations.GetProvider $s 'Microsoft.CognitiveServices' }.GetNewClosure() }
    $cognitive = Read-AvailabilityFact { & $modelsReader $BackendSubscriptionId }
    $skus = Read-AvailabilityFact { @(& $Operations.GetApimSkus $SubscriptionId) }
    $cosmos = Read-AvailabilityFact { @(& $Operations.GetCosmosLocations $SubscriptionId) }
    $flex = Read-AvailabilityFact { @(& $Operations.GetFlexLocations $SubscriptionId $false) }
    $flexZr = Read-AvailabilityFact { @(& $Operations.GetFlexLocations $SubscriptionId $true) }
    foreach ($pair in @(@('apimProvider', $apimProvider), @('cacheProvider', $cacheProvider), @('workspacesProvider', $workspaces), @('cognitiveProvider', $cognitive),
            @('apimSkus', $skus), @('cosmos', $cosmos), @('flex', $flex), @('flexZoneRedundant', $flexZr))) {
        $reads[$pair[0]] = @{ status = $pair[1].status; reasonCode = $pair[1].reasonCode }
    }
    $apimSet = Get-ProviderRegionSet $apimProvider 'service' $nameByDisplay
    if ($apimSet.missing) { $reads.apimProvider = @{ status = 'unavailable'; reasonCode = 'resource_type_missing' } }
    $cacheSet = Get-ProviderRegionSet $cacheProvider 'redisEnterprise' $nameByDisplay
    if ($cacheSet.missing) { $reads.cacheProvider = @{ status = 'unavailable'; reasonCode = 'resource_type_missing' } }
    $workspaceSet = Get-ProviderRegionSet $workspaces 'workspaces' $nameByDisplay
    if ($workspaceSet.missing) { $reads.workspacesProvider = @{ status = 'unavailable'; reasonCode = 'resource_type_missing' } }
    $cognitiveSet = Get-ProviderRegionSet $cognitive 'accounts' $nameByDisplay
    if ($cognitiveSet.missing) { $cognitive = @{ status = 'unavailable'; reasonCode = 'resource_type_missing' }; $reads.cognitiveProvider = @{ status = 'unavailable'; reasonCode = 'resource_type_missing' } }
    $flexNames = @($flex.value | ForEach-Object { [string]$_.name }); $flexZrNames = @($flexZr.value | ForEach-Object { [string]$_.name })

    $facts = [ordered]@{}
    foreach ($region in $Regions) {
        $l = $byName[$region]
        $regionSkus = @{}
        foreach ($s in @($skus.value | Where-Object { @($_.locations) -contains $region })) {
            $max = [int]$s.capacity.maximum
            if (-not $regionSkus.ContainsKey($s.name) -or $regionSkus[$s.name] -lt $max) { $regionSkus[$s.name] = $max }
        }
        $cosmosEntry = @($cosmos.value | Where-Object { $nameByDisplay[([string]$_.name).Replace(' ', '').ToLowerInvariant()] -ceq $region })[0]
        $facts[$region] = [ordered]@{
            displayName = $l.displayName; geography = $l.metadata.geography; geographyGroup = $l.metadata.geographyGroup
            physicalLocation = $l.metadata.physicalLocation; pairedRegions = @($l.metadata.pairedRegion | ForEach-Object { $_.name })
            zones = @(@($l.availabilityZoneMappings) | Where-Object { $null -ne $_ -and $_.logicalZone } | ForEach-Object { [string]$_.logicalZone } | Sort-Object); zonesStatus = 'ok'
            apim = [ordered]@{ skus = $regionSkus; zones = @(if ($apimSet.zones.ContainsKey($region)) { $apimSet.zones[$region] }) }
            cosmos = [ordered]@{ listed = $null -ne $cosmosEntry; supportsAvailabilityZone = [bool]$cosmosEntry.properties.supportsAvailabilityZone
                zoneAccess = [bool]$cosmosEntry.properties.isSubscriptionRegionAccessAllowedForAz; regularAccess = [bool]$cosmosEntry.properties.isSubscriptionRegionAccessAllowedForRegular
                residencyRestricted = [bool]$cosmosEntry.properties.isResidencyRestricted }
            flex = [ordered]@{ available = $flexNames -ccontains $region; zoneRedundant = $flexZrNames -ccontains $region }
            redisEnterprise = [ordered]@{ available = $cacheSet.listed.Contains($region); zones = @(if ($cacheSet.zones.ContainsKey($region)) { $cacheSet.zones[$region] }) }
            logAnalytics = [ordered]@{ available = $workspaceSet.listed.Contains($region) }
            claude = Get-AvailabilityClaudeFacts -Operations $Operations -SubscriptionId $BackendSubscriptionId -Region $region -Provider $cognitive -Listed $cognitiveSet.listed
        }
    }
    [ordered]@{ subscriptionId = $SubscriptionId; backendSubscriptionId = $BackendSubscriptionId; retrievedAt = [DateTimeOffset]::UtcNow.ToString('o'); reads = $reads; regions = $facts }
}

function Get-AvailabilityClaudeFacts {
    param($Operations, [string]$SubscriptionId, [string]$Region, $Provider, $Listed)
    if ($Provider.status -ne 'ok') { return [ordered]@{ status = 'unavailable'; reasonCode = $Provider.reasonCode; models = $null; deploymentTypes = $null; note = $null } }
    if (-not $Listed.Contains($Region)) { return [ordered]@{ status = 'ok'; reasonCode = $null; models = @(); deploymentTypes = @(); note = 'cognitive_services_not_in_region' } }
    $read = Read-AvailabilityFact { @(& $Operations.GetModels $SubscriptionId $Region) }
    if ($read.status -ne 'ok') { return [ordered]@{ status = 'unavailable'; reasonCode = $read.reasonCode; models = $null; deploymentTypes = $null; note = $null } }
    $anthropic = @($read.value | Where-Object { [string]::Equals($_.model.format, 'Anthropic', 'Ordinal') })
    [ordered]@{
        status = 'ok'; reasonCode = $null; note = $null
        models = @($anthropic | ForEach-Object { "$($_.model.name)@$($_.model.version)" } | Sort-Object -Unique)
        deploymentTypes = @($anthropic | ForEach-Object { $_.model.skus | ForEach-Object { [string]$_.name } } | Sort-Object -Unique)
    }
}

function New-ConstraintResult { param([bool]$Allowed, [string]$Code, [string]$Reason) [pscustomobject]@{ Allowed = $Allowed; ReasonCode = $Code; Reason = $Reason } }

function Test-AvailabilityConstraint {
    param([Parameter(Mandatory)] [string]$Constraint, [Parameter(Mandatory)] [string]$Region, [Parameter(Mandatory)] $Facts, [hashtable]$Context = @{})
    $name, $argument = $Constraint.Split(':', 2)
    $f = $Facts.regions[$Region]
    $unavailable = { param($read) New-ConstraintResult $false 'fact_unavailable' "The $read facts for $Region could not be read ($($Facts.reads[$read].reasonCode)); the option cannot be verified." }
    switch -CaseSensitive ($name) {
        'apimSku' {
            if ($Facts.reads.apimSkus.status -ne 'ok') { return & $unavailable 'apimSkus' }
            if (-not $f.apim.skus.ContainsKey($argument)) { return New-ConstraintResult $false 'sku_not_offered' "API Management $argument is not offered in $Region." }
            return New-ConstraintResult $true $null $null
        }
        'apimZones' {
            if ($Facts.reads.apimProvider.status -ne 'ok') { return & $unavailable 'apimProvider' }
            if ($f.zones.Count -eq 0 -or $f.apim.zones.Count -eq 0) { return New-ConstraintResult $false 'no_zones' "$Region has no availability zones for API Management." }
            return New-ConstraintResult $true $null $null
        }
        'zones' { if ($f.zones.Count -eq 0) { return New-ConstraintResult $false 'no_zones' "$Region has no availability zones." }; return New-ConstraintResult $true $null $null }
        'cosmosRegular' {
            if ($Facts.reads.cosmos.status -ne 'ok') { return & $unavailable 'cosmos' }
            if (-not $f.cosmos.listed -or -not $f.cosmos.regularAccess) { return New-ConstraintResult $false 'region_access_denied' "This subscription cannot create a Cosmos DB account in $Region." }
            return New-ConstraintResult $true $null $null
        }
        'cosmosZones' {
            if ($Facts.reads.cosmos.status -ne 'ok') { return & $unavailable 'cosmos' }
            if (-not $f.cosmos.supportsAvailabilityZone) { return New-ConstraintResult $false 'no_zones' "Cosmos DB has no availability zones in $Region." }
            if (-not $f.cosmos.zoneAccess) { return New-ConstraintResult $false 'zone_access_denied' "This subscription is not allowed zone-redundant Cosmos DB accounts in $Region (isSubscriptionRegionAccessAllowedForAz is false)." }
            return New-ConstraintResult $true $null $null
        }
        'flex' { if ($Facts.reads.flex.status -ne 'ok') { return & $unavailable 'flex' }; if (-not $f.flex.available) { return New-ConstraintResult $false 'not_offered' "Flex Consumption is not offered in $Region." }; return New-ConstraintResult $true $null $null }
        'flexZoneRedundant' {
            if ($Facts.reads.flexZoneRedundant.status -ne 'ok' -or $Facts.reads.flex.status -ne 'ok') { return & $unavailable 'flexZoneRedundant' }
            if (-not $f.flex.zoneRedundant) { return New-ConstraintResult $false 'not_offered' "Zone-redundant Flex Consumption is not offered in $Region." }
            return New-ConstraintResult $true $null $null
        }
        'redisEnterprise' { if ($Facts.reads.cacheProvider.status -ne 'ok') { return & $unavailable 'cacheProvider' }; if (-not $f.redisEnterprise.available) { return New-ConstraintResult $false 'not_offered' "Azure Managed Redis is not offered in $Region." }; return New-ConstraintResult $true $null $null }
        'logAnalytics' { if ($Facts.reads.workspacesProvider.status -ne 'ok') { return & $unavailable 'workspacesProvider' }; if (-not $f.logAnalytics.available) { return New-ConstraintResult $false 'not_offered' "Log Analytics workspaces are not offered in $Region." }; return New-ConstraintResult $true $null $null }
        'laReplicationSecondary' {
            $primary = [string]$Context.chosen['telemetry.workspaceRegion']
            $group = @($Context.laReplication.Values | Where-Object { @($_.primary) -ccontains $primary })[0]
            if (-not $group) { return New-ConstraintResult $false 'not_offered' "Workspace replication is not offered for a workspace in $primary." }
            if ([string]::Equals($Region, $primary, 'Ordinal')) { return New-ConstraintResult $false 'same_region' 'The secondary region must differ from the workspace region.' }
            if (@($group.secondary) -cnotcontains $Region) { return New-ConstraintResult $false 'not_in_group' "$Region is not a replication secondary for $primary in the documented region groups (workspace replication page, retrieved 2026-10-11)." }
            if (@($group.exclusiveSet) -ccontains $Region -and @($group.exclusiveSet) -ccontains $primary) { return New-ConstraintResult $false 'excluded_pair' "$primary cannot replicate to $Region (documented exclusive set)." }
            if ($Facts.reads.workspacesProvider.status -ne 'ok') { return & $unavailable 'workspacesProvider' }
            if (-not $f.logAnalytics.available) { return New-ConstraintResult $false 'not_offered' "Log Analytics workspaces are not offered in $Region." }
            return New-ConstraintResult $true $null $null
        }
        'minCandidates' { if (@($Context.candidateRegions).Count -lt [int]$argument) { return New-ConstraintResult $false 'too_few_regions' "This option needs at least $argument candidate regions." }; return New-ConstraintResult $true $null $null }
        'minStampRegions' { if (@($Context.stampRegions).Count -lt [int]$argument) { return New-ConstraintResult $false 'too_few_regions' "This option needs at least $argument stamp regions." }; return New-ConstraintResult $true $null $null }
        'topology' { if (-not [string]::Equals([string]$Context.chosen['gateway.topology'], $argument, 'Ordinal')) { return New-ConstraintResult $false 'requires_other_choice' "This option applies only with the $argument topology." }; return New-ConstraintResult $true $null $null }
        'notServerless' { if (([string]$Context.chosen['registry.capacity']).StartsWith('serverless', 'Ordinal')) { return New-ConstraintResult $false 'requires_other_choice' 'A serverless account runs in one region only.' }; return New-ConstraintResult $true $null $null }
        'skuNot' { if (@($argument.Split(',')) -ccontains [string]$Context.chosen['cache.sku']) { return New-ConstraintResult $false 'sku_excluded' "SKU $($Context.chosen['cache.sku']) does not support this option." }; return New-ConstraintResult $true $null $null }
        default { Stop-Availability 'constraint_unknown' "Unknown constraint '$Constraint' in the recommendations file." }
    }
}

Export-ModuleMember -Function New-AvailabilityRegionOperations, Get-AvailabilityRegionFacts, Test-AvailabilityConstraint
