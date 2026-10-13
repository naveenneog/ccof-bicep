#Requires -Version 7.0
<#
.SYNOPSIS
    The availability decision engine (ADR-0014, decision 6; C-9 stage D0). Loads the versioned
    recommendations file, prices each option per candidate region, checks its region constraints
    and validates a choice. A recommendation is shown, never applied: nothing here picks a value.
#>
Import-Module (Join-Path $PSScriptRoot 'Availability.Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'Availability.Pricing.psm1')
Import-Module (Join-Path $PSScriptRoot 'Availability.Regions.psm1')

$script:Types = @('option', 'integer', 'decimal', 'regions', 'region', 'sku', 'text', 'info')
$script:Formulas = @('apimUnits', 'cosmosThroughput', 'flexAlwaysReady', 'syncAlwaysReady', 'reconcilerAlwaysReady', 'none')

function Import-AvailabilityRecommendations {
    param([Parameter(Mandatory)] [string]$Path)
    try { $data = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { Stop-Availability 'recommendations_invalid' 'The recommendations file is not readable JSON.' }
    Assert-AvailabilityRecommendations $data
    $data
}

function Find-AvailabilityPriceKey {
    param($Value, [string]$Path = '')
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ($key -in @('unitPrice', 'retailPrice', 'price', 'prices')) { "$Path.$key" }
            Find-AvailabilityPriceKey $Value[$key] "$Path.$key"
        }
    }
    elseif ($Value -is [array]) { for ($i = 0; $i -lt $Value.Count; $i++) { Find-AvailabilityPriceKey $Value[$i] "$Path[$i]" } }
}

function Assert-AvailabilityRecommendations {
    param($Data)
    $fail = { param($m) Stop-Availability 'recommendations_invalid' "Recommendations file: $m" }
    if ($Data.schemaVersion -ne 1 -or -not $Data.dataVersion -or $Data.decisions -isnot [array] -or $Data.costModels -isnot [Collections.IDictionary]) { & $fail 'schemaVersion 1, dataVersion, decisions and costModels are required.' }
    $priceKeys = @(Find-AvailabilityPriceKey $Data)
    if ($priceKeys.Count) { & $fail "it must hold no price ($($priceKeys[0]))." }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($d in $Data.decisions) {
        if ($d.id -cnotmatch '^[a-z][A-Za-z0-9.]{2,80}$' -or -not $ids.Add($d.id)) { & $fail "decision id '$($d.id)' is invalid or repeated." }
        if ($d.type -cnotin $script:Types -or $d.stage -cnotin @('0', '2') -or -not $d.title -or -not $d.owner -or -not $d.recommendation) { & $fail "decision '$($d.id)' needs a known type, stage, title, owner and recommendation." }
        foreach ($s in @($d.recommendation.sources)) { if (-not $Data.sources.Contains($s)) { & $fail "decision '$($d.id)' cites unknown source '$s'." } }
        if ($d.type -eq 'option') {
            $optionIds = @($d.options | ForEach-Object { $_.id })
            if ($optionIds.Count -eq 0 -or @($optionIds | Sort-Object -Unique).Count -ne $optionIds.Count) { & $fail "decision '$($d.id)' needs unique options." }
            if ($optionIds -cnotcontains $d.recommendation.option) { & $fail "decision '$($d.id)' recommends an option it does not offer." }
            foreach ($o in $d.options) {
                if (-not $o.impact.covers -or -not $o.impact.uncovered -or -not $o.impact.sla) { & $fail "option '$($d.id)/$($o.id)' needs covers, uncovered and sla." }
                Assert-AvailabilityCostSpec $Data $o.cost "$($d.id)/$($o.id)"
            }
        }
        if ($d.type -in @('integer', 'decimal') -and $d.recommendation.formula -cnotin $script:Formulas) { & $fail "decision '$($d.id)' uses an unknown formula." }
        if ($d.cost) { Assert-AvailabilityCostSpec $Data $d.cost $d.id }
        if ($d.costOf -and -not @($Data.decisions | Where-Object { $_.id -ceq $d.costOf }).Count) { & $fail "decision '$($d.id)' prices an unknown decision." }
        if ($d.costShownIn -and -not @($Data.decisions | Where-Object { $_.id -ceq $d.costShownIn }).Count) { & $fail "decision '$($d.id)' shows its cost in an unknown decision." }
        if ($d.type -eq 'info' -and -not $d.decidedIn) { & $fail "information row '$($d.id)' needs decidedIn." }
    }
    foreach ($d in $Data.decisions) { $null = Get-AvailabilityCostCarrier $Data $d }
    foreach ($name in $Data.costModels.Keys) {
        foreach ($c in $Data.costModels[$name]) {
            foreach ($k in @('serviceName', 'productName', 'skuName', 'meterName', 'unit')) { if (-not $c.meter[$k]) { & $fail "cost model '$name' lacks meter.$k." } }
            if ($c.scope -cnotin @('region', 'global', 'billingZone') -or @($c.quantity).Count -eq 0) { & $fail "cost model '$name' needs a scope and a quantity." }
        }
    }
}

function Assert-AvailabilityCostSpec {
    param($Data, $Spec, [string]$Where)
    if ($null -eq $Spec -or ($Spec -is [array] -and $Spec.Count -eq 0)) { return }
    if ($Spec -is [string]) { if (-not $Data.costModels.Contains($Spec)) { Stop-Availability 'recommendations_invalid' "Recommendations file: '$Where' uses unknown cost model '$Spec'." }; return }
    if ($Spec -is [Collections.IDictionary] -and $Spec.costOf) { return }
    Stop-Availability 'recommendations_invalid' "Recommendations file: '$Where' has an invalid cost."
}

function Get-AvailabilityDecision { param($Data, [string]$Id) @($Data.decisions | Where-Object { $_.id -ceq $Id })[0] }

function Get-AvailabilityCostCarrier {
    <# The decision whose sign-off row carries this decision's cost (costShownIn, then costOf), so each cost is counted once. #>
    param($Data, $Decision)
    $current = $Decision
    for ($hop = 0; $hop -lt 8; $hop++) {
        $next = if ($current.costShownIn) { $current.costShownIn } elseif ($current.costOf) { $current.costOf } else { return $current.id }
        $current = Get-AvailabilityDecision $Data $next
        if (-not $current) { Stop-Availability 'recommendations_invalid' "Recommendations file: '$($Decision.id)' shows its cost in unknown decision '$next'." }
    }
    Stop-Availability 'recommendations_invalid' "Recommendations file: the cost references of '$($Decision.id)' form a loop."
}

function Get-AvailabilityOption { param($Decision, [string]$Id) @($Decision.options | Where-Object { $_.id -ceq $Id })[0] }

function Test-AvailabilityApplies {
    param($Decision, $Chosen)
    if (-not $Decision.appliesTo) { return $true }
    foreach ($key in $Decision.appliesTo.Keys) { if (@($Decision.appliesTo[$key]) -cnotcontains [string]$Chosen[$key]) { return $false } }
    $true
}

function Get-AvailabilityTrafficShare {
    <# The share of the total traffic a stamp region carries: all of it with one stamp; an even share
       when stamps serve at once; all in the primary and none in a standby (trafficShare in the data). #>
    param($Data, $Chosen, [string]$Region)
    $stamps = @($Chosen['gateway.regions'] | Where-Object { $_ })
    if ($stamps.Count -le 1) { return [decimal]1 }
    $topology = Get-AvailabilityOption (Get-AvailabilityDecision $Data 'gateway.topology') ([string]$Chosen['gateway.topology'])
    if ($topology -and $topology.trafficShare -ceq 'primary') { if ($Region -and $stamps -ccontains $Region -and $Region -cne $stamps[0]) { return [decimal]0 }; return [decimal]1 }
    [decimal]1 / $stamps.Count
}

function Get-AvailabilityVariables {
    param($Data, $Sizing, $Chosen, [hashtable]$Override = @{}, [string]$Region)
    $d = { param($v, $n) ConvertTo-AvailabilityDecimal $v $n }
    $hours = & $d $Data.conventions.hoursPerMonth 'hoursPerMonth'
    # Traffic inputs are totals across the stamps; each stamp region is priced for its share.
    $share = Get-AvailabilityTrafficShare $Data $Chosen $Region
    $requests10K = (& $d $Sizing.monthlyRequests 'monthlyRequests') / 10000
    $executions = & $d $Sizing.resolverExecutionsPerMonth 'resolverExecutionsPerMonth'
    $v = @{ hoursPerMonth = $hours
        monthlyRequests10K = $requests10K; stampRequests10K = $requests10K * $share
        edgeEgressGB = & $d $Sizing.edgeEgressGBPerMonth 'edgeEgressGBPerMonth'; edgeToOriginGB = & $d $Sizing.edgeToOriginGBPerMonth 'edgeToOriginGBPerMonth'
        cosmosServerlessMillions = (& $d $Sizing.registryMonthlyRequestUnits 'registryMonthlyRequestUnits') / 1000000
        cosmosStorageGB = & $d $Sizing.registryStorageGB 'registryStorageGB'; functionsStorageGB = & $d $Sizing.functionsStorageGB 'functionsStorageGB'
        logIngestionGB = & $d $Sizing.logIngestionGBPerMonth 'logIngestionGBPerMonth'
        privateEndpoints = & $d $Sizing.privateEndpointsPerStamp 'privateEndpointsPerStamp'
        privateEndpointIngressGB = & $d $Sizing.privateEndpointIngressGBPerMonth 'privateEndpointIngressGBPerMonth'
        privateEndpointEgressGB = & $d $Sizing.privateEndpointEgressGBPerMonth 'privateEndpointEgressGBPerMonth'
        resolverExecutions10 = $executions / 10 * $share }
    # The decision each missing variable waits for, so a "depends" cost names the right one.
    $why = @{}
    $units = if ($Override.ContainsKey('apimUnits')) { $Override.apimUnits } else { $Chosen['gateway.units'] }
    if ($null -ne $units) { $v.apimUnits = & $d $units 'apimUnits'; $v.apimAdditionalUnits = $v.apimUnits - 1 } else { $why.apimUnits = 'gateway.units'; $why.apimAdditionalUnits = 'gateway.units' }
    $ru = if ($Override.ContainsKey('throughput')) { $Override.throughput } else { $Chosen['registry.throughput'] }
    if ($null -ne $ru) { $v.cosmosHundreds = (& $d $ru 'throughput') / 100 } else { $why.cosmosHundreds = 'registry.throughput' }
    $retention = if ($Override.ContainsKey('retentionDays')) { $Override.retentionDays } else { $Chosen['telemetry.retentionDays'] }
    if ($null -ne $retention) {
        $extra = [Math]::Max(0, [int]$retention - [int]$Data.conventions.includedRetentionDays)
        $v.logRetainedGB = $v.logIngestionGB * 24 / $hours * $extra
    }
    else { $why.logRetainedGB = 'telemetry.retentionDays' }
    $memory = Get-AvailabilityAppMemoryGB $Data $Chosen 'resolver' $Override
    if ($null -ne $memory) {
        $durationMs = & $d $Sizing.resolverAverageDurationMs 'resolverAverageDurationMs'
        $concurrency = & $d $Sizing.resolverConcurrentExecutionsPerInstance 'resolverConcurrentExecutionsPerInstance'
        if ($concurrency -lt 1) { Stop-Availability 'number_invalid' 'resolverConcurrentExecutionsPerInstance must be at least 1.' }
        # Flex bills memory while an instance is actively executing; concurrent executions share that time (F1).
        $v.resolverExecutionGBs = $executions * $durationMs / 1000 / $concurrency * $memory * $share
        $ready = if ($null -ne $Override['alwaysReady:resolver']) { $Override['alwaysReady:resolver'] } else { $Chosen['resolver.alwaysReady'] }
        if ($null -ne $ready) { $v.resolverAlwaysReadyGBs = (& $d $ready 'alwaysReady') * $memory * $hours * 3600 } else { $why.resolverAlwaysReadyGBs = 'resolver.alwaysReady' }
    }
    else { $why.resolverExecutionGBs = 'resolver.instanceMemoryMB'; $why.resolverAlwaysReadyGBs = 'resolver.instanceMemoryMB' }
    foreach ($app in @('sync', 'reconciler')) {
        if ($null -eq $Override["alwaysReady:$app"]) { continue }
        $appMemory = Get-AvailabilityAppMemoryGB $Data $Chosen $app $Override
        if ($null -ne $appMemory) { $v.alwaysReadyGBs = (& $d $Override["alwaysReady:$app"] 'alwaysReady') * $appMemory * $hours * 3600 } else { $why.alwaysReadyGBs = "$app.instanceMemoryMB" }
    }
    $v.__why = $why
    $v
}
function Get-AvailabilityAppMemoryGB {
    param($Data, $Chosen, [string]$App, [hashtable]$Override = @{})
    if ($null -ne $Override["memory:$App"]) { return ([decimal]$Override["memory:$App"]) / 1024 }
    $id = $Chosen["$App.instanceMemoryMB"]
    if ($null -eq $id) { return $null }
    $option = Get-AvailabilityOption (Get-AvailabilityDecision $Data "$App.instanceMemoryMB") ([string]$id)
    ([decimal]$option.value) / 1024
}

function Get-AvailabilityFormula {
    param([string]$Name, $Data, $Sizing, $Chosen, $Facts, [string]$Region, [string]$OptionId)
    switch -CaseSensitive ($Name) {
        'apimUnits' {
            $peak = ConvertTo-AvailabilityDecimal $Sizing.peakRequestsPerSecond 'peakRequestsPerSecond'
            $capacity = ConvertTo-AvailabilityDecimal $Sizing.apimUnitCapacityRequestsPerSecond 'apimUnitCapacityRequestsPerSecond'
            if ($capacity -le 0) { Stop-Availability 'number_invalid' 'apimUnitCapacityRequestsPerSecond must be above zero.' }
            $required = [int][Math]::Ceiling($peak / $capacity)
            $mode = if ($OptionId) { $OptionId } else { [string]$Chosen['gateway.mode'] }
            $zones = @($Facts.regions[$Region].apim.zones).Count
            $units = $required; $text = "ceil($peak / $capacity per unit, $($Sizing.apimUnitCapacitySource)) = $required"
            if ($mode -like '*zone-redundant' -and $zones -ge 2) {
                $units = [Math]::Max(2, [int][Math]::Ceiling($required * $zones / ($zones - 1)))
                $text += "; with $zones zones, ceil($required x $zones / $($zones - 1)), at least 2 = $units"
            }
            $sku = if ($mode -like 'premium*') { 'PremiumV2' } else { 'StandardV2' }
            $max = $Facts.regions[$Region].apim.skus[$sku]
            if ($max -and $units -gt $max) { $text += "; one $sku instance holds at most $max units, so $([Math]::Ceiling($units / $max)) instances are needed" }
            return @{ value = $units; explanation = $text }
        }
        'cosmosThroughput' {
            $reads = (ConvertTo-AvailabilityDecimal $Sizing.registryPeakReadsPerSecond 'reads') * (ConvertTo-AvailabilityDecimal $Sizing.registryRuPerRead 'ruPerRead')
            $writes = (ConvertTo-AvailabilityDecimal $Sizing.registryPeakWritesPerSecond 'writes') * (ConvertTo-AvailabilityDecimal $Sizing.registryRuPerWrite 'ruPerWrite')
            $mode = if ($OptionId) { $OptionId } else { [string]$Chosen['registry.capacity'] }
            $floor = if ($mode -like '*autoscale*') { 1000 } else { 400 }; $step = if ($mode -like '*autoscale*') { 1000 } else { 100 }
            $value = [Math]::Max($floor, [int]([Math]::Ceiling(($reads + $writes) / $step) * $step))
            return @{ value = $value; explanation = "reads $reads RU/s + writes $writes RU/s, rounded up to a multiple of $step, at least $floor = $value" }
        }
        'flexAlwaysReady' { return @{ value = 2; explanation = 'two always-ready instances' } }
        'syncAlwaysReady' { return Get-AvailabilityZoneMinimum $Chosen 'sync' }
        'reconcilerAlwaysReady' { return Get-AvailabilityZoneMinimum $Chosen 'reconciler' }
        default { return @{ value = $null; explanation = 'no formula: see the reason' } }
    }
}

function Get-AvailabilityZoneMinimum {
    param($Chosen, [string]$App)
    $zone = $Chosen["$App.zoneRedundancy"]
    if ($null -eq $zone) { return @{ value = $null; explanation = 'zone redundancy is not chosen yet' } }
    $n = if ([string]$zone -ceq 'zone-redundant') { 2 } else { 0 }
    @{ value = $n; explanation = "$n for the chosen zone redundancy ($zone)" }
}

function Measure-AvailabilityDecisionCost {
    param($Data, $Spec, [string]$Region, $Sizing, $Chosen, $Snapshot, [hashtable]$Override = @{})
    if ($null -eq $Spec -or ($Spec -is [array] -and $Spec.Count -eq 0)) { return [pscustomobject]@{ Status = 'none'; Total = [decimal]0; Lines = @(); Reason = $null } }
    if ($Spec -is [Collections.IDictionary]) {
        $target = Get-AvailabilityDecision $Data $Spec.costOf
        $picked = $Chosen[$Spec.costOf]
        if ($null -eq $picked) { return [pscustomobject]@{ Status = 'depends'; Total = $null; Lines = @(); Reason = "Priced once $($Spec.costOf) is decided." } }
        $Spec = (Get-AvailabilityOption $target ([string]$picked)).cost
        return Measure-AvailabilityDecisionCost $Data $Spec $Region $Sizing $Chosen $Snapshot $Override
    }
    $subs = @{}
    $sku = if ($Override.ContainsKey('cache.sku')) { $Override['cache.sku'] } else { $Chosen['cache.sku'] }
    if ($sku) { $subs['cache.sku'] = $sku }
    $vars = $null
    try {
        $vars = Get-AvailabilityVariables $Data $Sizing $Chosen $Override $Region
        $cost = Measure-AvailabilityCost -Model $Data.costModels[$Spec] -Region $Region -BillingZone $Sizing.edgeBillingZone -Variables $vars -Snapshot $Snapshot -Substitutions $subs
        $cost | Add-Member -NotePropertyName Reason -NotePropertyValue $null -PassThru
    }
    catch {
        if ($_.Exception.Data['AvailabilityCode'] -ne 'variable_undefined') { throw }
        $hint = if ($vars -and $_.Exception.Message -match "needs '(\w+)'") { $vars.__why[$Matches[1]] } else { $null }
        $reason = if ($hint) { "Priced once $hint is decided." } else { Get-AvailabilityDependsReason $_.Exception.Message }
        [pscustomobject]@{ Status = 'depends'; Total = $null; Lines = @(); Reason = $reason }
    }
}

function Get-AvailabilityDependsReason {
    <# Names the decision a cost still waits for, instead of the formula variable. #>
    param([string]$Message)
    $sources = @{ apimUnits = 'gateway.units'; apimAdditionalUnits = 'gateway.units'; cosmosHundreds = 'registry.throughput'; logRetainedGB = 'telemetry.retentionDays'
        resolverExecutionGBs = 'resolver.instanceMemoryMB'; resolverAlwaysReadyGBs = 'resolver.alwaysReady'; alwaysReadyGBs = 'the always-ready count and instance memory' }
    if ($Message -match "needs '(\w+)'" -and $sources.ContainsKey($Matches[1])) { return "Priced once $($sources[$Matches[1]]) is decided." }
    if ($Message -match '\{([A-Za-z.]+)\}') { return "Priced once $($Matches[1]) is decided; the list price of each SKU is shown." }
    'Priced once a later decision is made.'
}

function Get-AvailabilityBearingRegions {
    param($Decision, $Option, $Chosen)
    $stamps = @($Chosen['gateway.regions'] | Where-Object { $_ })
    if ($Decision.bearingFrom -and $null -ne $Chosen[$Decision.bearingFrom]) {
        $from = [string]$Chosen[$Decision.bearingFrom]
        if ($from -ceq 'primary-region') { return @($stamps | Select-Object -First 1) }
        if ($from -ceq 'every-stamp-region') { return $stamps }
        return @($from)
    }
    $bearing = if ($Option -and $Option.bearing) { $Option.bearing } else { $Decision.bearing }
    if ($bearing -ceq 'primary' -and $stamps.Count) { return @($stamps[0]) }
    $stamps
}

function Get-AvailabilityTotal {
    param($PerRegion, [string[]]$Regions)
    if (-not $Regions -or $Regions.Count -eq 0) { return @{ status = 'depends'; total = $null } }
    $total = [decimal]0; $onceDone = $false
    foreach ($r in $Regions) {
        $cost = $PerRegion[$r].cost
        if ($cost.Status -eq 'none') { continue }
        if ($cost.Status -ne 'priced') { return @{ status = $cost.Status; total = $null } }
        foreach ($line in $cost.Lines) {
            if ($line.pricingRegion -match '^Zone \d$') { if (-not $onceDone) { $total += [decimal]$line.cost } }
            else { $total += [decimal]$line.cost }
        }
        $onceDone = $true
    }
    @{ status = 'priced'; total = $total }
}

Export-ModuleMember -Function Import-AvailabilityRecommendations, Assert-AvailabilityRecommendations, Get-AvailabilityDecision, Get-AvailabilityCostCarrier, Get-AvailabilityTrafficShare, Get-AvailabilityOption, Test-AvailabilityApplies, Get-AvailabilityVariables, Get-AvailabilityFormula, Measure-AvailabilityDecisionCost, Get-AvailabilityDependsReason, Get-AvailabilityBearingRegions, Get-AvailabilityTotal
