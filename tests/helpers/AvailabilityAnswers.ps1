#Requires -Version 7.0
# One documented example input set for the D0 tests and the worked example in docs/HA-DECISIONS.md.
# It is an example, not a recommendation of these inputs.
function Get-AvailabilityTestSizing {
    [ordered]@{ peakRequestsPerSecond = 2000; apimUnitCapacityRequestsPerSecond = 1000; apimUnitCapacitySource = 'estimate'
                monthlyRequests = 1500000000; edgeBillingZone = 'Zone 5'; edgeEgressGBPerMonth = 15000; edgeToOriginGBPerMonth = 150000
                registryPeakReadsPerSecond = 800; registryRuPerRead = 1; registryPeakWritesPerSecond = 50; registryRuPerWrite = 10; registryStorageGB = 10
                registryMonthlyRequestUnits = 525000000; resolverExecutionsPerMonth = 150000000; resolverAverageDurationMs = 50; resolverConcurrentExecutionsPerInstance = 16; functionsStorageGB = 5
                logIngestionGBPerMonth = 3000; privateEndpointsPerStamp = 6; privateEndpointIngressGBPerMonth = 200; privateEndpointEgressGBPerMonth = 200 }
}

function Get-AvailabilityTestChoices {
    [ordered]@{
        'gateway.topology' = 'single-region'; 'gateway.regions' = @('swedencentral'); 'gateway.mode' = 'premium-v2-zone-redundant'; 'gateway.units' = 3
        'edge.frontDoor' = 'none'; 'registry.capacity' = 'provisioned-autoscale-zone-redundant'; 'registry.throughput' = 2000; 'registry.regions' = 'single-region'
        'resolver.zoneRedundancy' = 'zone-redundant'; 'resolver.instanceMemoryMB' = '2048'; 'resolver.alwaysReady' = 2; 'resolver.maximumInstanceCount' = 40
        'cache.option' = 'built-in'; 'cache.sku' = $null; 'cache.geoReplication' = $null; 'functions.storage' = 'Standard_ZRS'
        'sync.regions' = 'primary-region'; 'sync.zoneRedundancy' = 'non-zonal'; 'sync.instanceMemoryMB' = '2048'; 'sync.alwaysReady' = 0; 'sync.maximumInstanceCount' = 1
        'reconciler.regions' = 'primary-region'; 'reconciler.zoneRedundancy' = 'zone-redundant'; 'reconciler.instanceMemoryMB' = '2048'; 'reconciler.alwaysReady' = 2; 'reconciler.maximumInstanceCount' = 1
        'telemetry.workspaceRegion' = 'swedencentral'; 'telemetry.retentionDays' = 90; 'telemetry.replication' = 'none'; 'telemetry.secondaryRegion' = $null
        'entitlementCache.allowTtlSeconds' = 300; 'entitlementCache.refusalTtlSeconds' = 60; 'entitlementCache.lastKnownGoodGraceSeconds' = 3600; 'entitlementCache.refreshBackoffSeconds' = 30; 'entitlementCache.unavailableRetryAfterSeconds' = 30
        'budgetState.graceSeconds' = 600; 'budgetState.hardLimitSeconds' = 3600
        'sync.intervalMinutes' = 10; 'sync.maxRemovalsPerRun' = 50; 'sync.maxRemovalFraction' = '0.02'; 'sync.leaseSeconds' = 600
    }
}
