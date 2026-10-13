#Requires -Version 7.0
# Fake ARM and az read operations for the D0 tests. The values follow the live reads of the Contoso
# PoC subscription on 2026-10-11 (docs/status/WP-HADEC.md): eastus2 and centralindia have zones but
# deny zone-redundant Cosmos accounts; southindia and westindia have no zones; westindia has no Flex
# Consumption, Log Analytics, Cognitive Services or Azure Managed Redis; PremiumV2 is offered only in
# eastus2 and swedencentral; Claude is listed in eastus2 (Global and Data Zone) and swedencentral.
$script:FakeRegionCalls = [Collections.Generic.List[string]]::new()

function New-FakeAvailabilityRegionOperations {
    param([hashtable]$Fail = @{})
    $script:FakeFail = $Fail
    $display = @{ eastus2 = 'East US 2'; swedencentral = 'Sweden Central'; centralindia = 'Central India'; southindia = 'South India'; westindia = 'West India' }
    $script:FakeDisplay = $display
    @{
        GetLocations = {
            param($s) $script:FakeRegionCalls.Add("locations:$s")
            if ($script:FakeFail.locations) { throw 'fixture-provider-error' }
            $zones = @{ eastus2 = @('1', '2', '3'); swedencentral = @('1', '2', '3'); centralindia = @('1', '2', '3'); southindia = @(); westindia = @() }
            $pairs = @{ eastus2 = 'centralus'; swedencentral = 'swedensouth'; centralindia = 'southindia'; southindia = 'centralindia'; westindia = 'southindia' }
            $geo = @{ eastus2 = 'United States'; swedencentral = 'Sweden'; centralindia = 'India'; southindia = 'India'; westindia = 'India' }
            @{ value = @(foreach ($n in $zones.Keys) {
                        # ARM omits availabilityZoneMappings for a region without zones.
                        $l = @{ name = $n; displayName = $script:FakeDisplay[$n]; metadata = @{ geography = $geo[$n]; geographyGroup = 'x'; physicalLocation = 'x'; pairedRegion = @(@{ name = $pairs[$n] }) } }
                        if ($zones[$n].Count) { $l.availabilityZoneMappings = @($zones[$n] | ForEach-Object { @{ logicalZone = $_ } }) }
                        $l }) }
        }
        GetProvider = {
            param($s, $ns) $script:FakeRegionCalls.Add("provider:$ns")
            if ($script:FakeFail[$ns]) { throw 'fixture-provider-error' }
            $all = @('East US 2', 'Sweden Central', 'Central India', 'South India', 'West India')
            $spec = switch ($ns) {
                'Microsoft.ApiManagement' { @('service', $all, @{ 'East US 2' = @('1', '2', '3'); 'Sweden Central' = @('1', '2', '3'); 'Central India' = @('1', '2', '3') }) }
                'Microsoft.Cache' { @('redisEnterprise', @('East US 2', 'Sweden Central', 'Central India', 'South India'), @{ 'East US 2' = @('1', '2', '3') }) }
                'Microsoft.OperationalInsights' { @('workspaces', @('East US 2', 'Sweden Central', 'Central India', 'South India'), @{}) }
                'Microsoft.CognitiveServices' { @('accounts', @('East US 2', 'Sweden Central', 'Central India', 'South India'), @{}) }
            }
            @{ resourceTypes = @(@{ resourceType = $spec[0]; locations = $spec[1]; zoneMappings = @($spec[2].Keys | ForEach-Object { @{ location = $_; zones = $spec[2][$_] } }) }) }
        }
        GetApimSkus = {
            param($s) if ($script:FakeFail.skus) { throw 'fixture-provider-error' }
            @(foreach ($r in @('eastus2', 'swedencentral', 'centralindia', 'southindia')) { @{ name = 'StandardV2'; locations = @($r); capacity = @{ maximum = 10 } } }
                foreach ($r in @('eastus2', 'swedencentral')) { @{ name = 'PremiumV2'; locations = @($r); capacity = @{ maximum = 30 } } })
        }
        GetCosmosLocations = {
            param($s) if ($script:FakeFail.cosmos) { throw 'fixture-provider-error' }
            $rows = @{ 'East US 2' = @($true, $false, $true); 'Sweden Central' = @($true, $true, $true); 'Central India' = @($true, $false, $true); 'South India' = @($false, $false, $true); 'West India' = @($false, $false, $false) }
            @(foreach ($k in $rows.Keys) { @{ name = $k; properties = @{ supportsAvailabilityZone = $rows[$k][0]; isSubscriptionRegionAccessAllowedForAz = $rows[$k][1]; isSubscriptionRegionAccessAllowedForRegular = $rows[$k][2]; isResidencyRestricted = $false } } })
        }
        GetFlexLocations = {
            param($s, $zr) if ($script:FakeFail.flex) { throw 'fixture-provider-error' }
            if ($zr) { @(@{ name = 'eastus2' }, @{ name = 'swedencentral' }, @{ name = 'centralindia' }) } else { @(@{ name = 'eastus2' }, @{ name = 'swedencentral' }, @{ name = 'centralindia' }, @{ name = 'southindia' }) }
        }
        GetModels = {
            param($s, $region) $script:FakeRegionCalls.Add("models:${s}:$region")
            if ($region -eq 'eastus2') { @(@{ model = @{ format = 'Anthropic'; name = 'claude-opus-5'; version = '2'; skus = @(@{ name = 'GlobalStandard' }, @{ name = 'DataZoneStandard' }) } }) }
            elseif ($region -eq 'swedencentral') { @(@{ model = @{ format = 'Anthropic'; name = 'claude-opus-5'; version = '2'; skus = @(@{ name = 'GlobalStandard' }) } }) }
            else { @() }
        }
    }
}
