#Requires -Version 7.0
<#
.SYNOPSIS
    Stage D0 helpers: the explicit interactive prompt for inputs and confirmations, and the decision
    records, sign-off sheet and evidence built from the administrator's choices.
#>
Import-Module (Join-Path $PSScriptRoot 'Availability.Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'Availability.Pricing.psm1')
Import-Module (Join-Path $PSScriptRoot 'Availability.Decisions.psm1')
Import-Module (Join-Path $PSScriptRoot 'Availability.SignOff.psm1')

function Read-Stage0Value {
    <# One explicit value: empty input is re-asked, never defaulted; a confirmation needs the word yes. #>
    param([Parameter(Mandatory)] [scriptblock]$ReadLine, [Parameter(Mandatory)] [string]$Id, $Shape, $Suggested)
    if ($Id -ceq 'confirm') {
        return [string]::Equals([string](& $ReadLine 'confirm - type yes to record these inputs and read live list prices and region facts (read-only); anything else stops'), 'yes', 'Ordinal')
    }
    if ($Id -ceq 'confirmedDiscovery') {
        if ($null -ne $Suggested) { Write-Host ($Suggested | ConvertTo-Json -Depth 8) }
        return [string]::Equals([string](& $ReadLine 'confirmedDiscovery - the digest above identifies the list prices and region facts just read; type yes to decide against them, anything else stops'), 'yes', 'Ordinal')
    }
    if ($Shape.description) { Write-Host "$($Id): $($Shape.description)" }
    if ($Shape.type -eq 'object') {
        $value = [ordered]@{}
        foreach ($name in @($Shape.required)) { $value[$name] = Read-Stage0Value -ReadLine $ReadLine -Id "$Id.$name" -Shape $Shape.properties[$name] }
        return $value
    }
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $hint = if ($Shape.enum) { " ($(@($Shape.enum) -join ' | '))" } elseif ($Shape.type -eq 'array') { ' (comma-separated)' } elseif ($Shape.oneOf) { ' (or the word none)' } else { '' }
        $text = [string](& $ReadLine "$Id$hint; no default")
        if ([string]::IsNullOrWhiteSpace($text)) { Write-Host 'No value was typed. There is no default.'; continue }
        $problem = $null; $value = $null
        $text = $text.Trim()
        $expected = if ($Shape.description) { " Expected: $($Shape.description)." } else { '' }
        if ($Shape.type -eq 'array') {
            $value = @($text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $pattern = $Shape.items.pattern
            if ($value.Count -lt [Math]::Max(1, [int]$Shape.minItems) -or ($Shape.maxItems -and $value.Count -gt $Shape.maxItems)) { $problem = 'Wrong number of values.' }
            elseif (@($value | Sort-Object -Unique).Count -ne $value.Count) { $problem = 'A value is repeated.' }
            elseif ($pattern -and @($value | Where-Object { $_ -cnotmatch $pattern }).Count) { $problem = "Not in the expected form: $(@($value | Where-Object { $_ -cnotmatch $pattern }) -join ', ')." }
            if (-not $problem) { return , $value }
        }
        elseif ($Shape.oneOf -and $text -ceq 'none') { return $null }
        elseif ($Shape.type -in @('integer', 'number')) {
            # No thousands separators and no exponent: '1,5' is not read as 15.
            $n = [decimal]0
            $styles = [Globalization.NumberStyles]::AllowDecimalPoint -bor [Globalization.NumberStyles]::AllowLeadingSign
            if (-not [decimal]::TryParse($text, $styles, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { $problem = 'Not a number (digits, with a decimal point if needed).' }
            elseif ($Shape.type -eq 'integer' -and $n -ne [decimal]::Truncate($n)) { $problem = 'Not a whole number.' }
            elseif ($null -ne $Shape.minimum -and $n -lt $Shape.minimum) { $problem = "Must be at least $($Shape.minimum)." }
            elseif ($null -ne $Shape.exclusiveMinimum -and $n -le $Shape.exclusiveMinimum) { $problem = "Must be above $($Shape.exclusiveMinimum)." }
            elseif ($Shape.type -eq 'integer' -and ($n -gt [long]::MaxValue -or $n -lt [long]::MinValue)) { $problem = 'Too large.' }
            if (-not $problem) { if ($Shape.type -eq 'integer') { return [long]$n }; return $n }
        }
        else {
            $pattern = if ($Shape.pattern) { $Shape.pattern } elseif ($Shape.oneOf) { @($Shape.oneOf | Where-Object { $_.pattern })[0].pattern } else { $null }
            if ($Shape.enum -and @($Shape.enum) -cnotcontains $text) { $problem = "Not one of: $(@($Shape.enum) -join ', ')." }
            elseif ($pattern -and $text -cnotmatch $pattern) { $problem = 'Not in the expected form.' }
            if (-not $problem) { return $text }
        }
        Write-Host "Not accepted: $problem$expected"
    }
    Stop-Availability 'choice_missing' "No accepted value was given for $Id. No answer or decision was recorded."
}
function New-Stage0Prompt {
    <# WP-ONB runner prompt: every value typed explicitly. #>
    param([Parameter(Mandatory)] [scriptblock]$ReadLine)
    $read = $ReadLine
    { param($id, $shape, $suggested) Read-Stage0Value -ReadLine $read -Id $id -Shape $shape -Suggested $suggested }.GetNewClosure()
}

function Measure-Stage0ChosenCost {
    param($Data, $Decision, $Value, $Chosen, $Sizing, $Snapshot)
    $spec = $null; $option = $null; $override = @{}
    if ($Decision.type -eq 'option') { $option = Get-AvailabilityOption $Decision ([string]$Value); $spec = $option.cost }
    elseif ($Decision.costOf) { $spec = @{ costOf = $Decision.costOf } }
    elseif ($Decision.cost -and $Decision.type -ne 'region') { $spec = $Decision.cost }
    if ($Decision.app -and $Decision.type -eq 'integer') { $override["alwaysReady:$($Decision.app)"] = $Value }
    $regions = @(Get-AvailabilityBearingRegions $Decision $option $Chosen)
    if ($Decision.type -eq 'region' -and $Decision.cost) { $spec = $Decision.cost; $regions = @($Value) }
    if (-not $spec -or -not $regions.Count) { return [ordered]@{ status = 'none'; total = [decimal]0; regions = $regions; lines = @() } }
    $perRegion = [ordered]@{}
    foreach ($r in $regions) { $perRegion[$r] = @{ cost = Measure-AvailabilityDecisionCost $Data $spec $r $Sizing $Chosen $Snapshot $override } }
    $total = Get-AvailabilityTotal $perRegion $regions
    $reason = @($regions | ForEach-Object { $perRegion[$_].cost.Reason } | Where-Object { $_ })[0]
    [ordered]@{ status = $total.status; total = $total.total; reason = $reason; regions = $regions
        lines = @(foreach ($r in $regions) { foreach ($l in $perRegion[$r].cost.Lines) { $x = [ordered]@{ region = $r }; foreach ($k in $l.Keys) { $x[$k] = $l[$k] }; $x } }) }
}

function Get-Stage0Assumptions {
    param($Data, $Sizing, $Chosen)
    $zone = [string]$Sizing.edgeBillingZone
    $list = @(
        "A month is $($Data.conventions.hoursPerMonth) hours (source $($Data.conventions.hoursPerMonthSource))."
        "APIM units are sized for a peak of $($Sizing.peakRequestsPerSecond) requests per second at $($Sizing.apimUnitCapacityRequestsPerSecond) per unit; that per-unit capacity is $(if ($Sizing.apimUnitCapacitySource -ceq 'load-test') { 'a load-test measurement' } else { 'an estimate, not a measurement (P-12 measures it; U-new-HADEC-6)' })."
        "Resolver execution time is an estimate at $($Sizing.resolverConcurrentExecutionsPerInstance) concurrent executions per active instance, not a bound (U-new-HADEC-5)."
        'The sync and the reconciler are priced for their always-ready instances only; their on-demand executions are not priced.'
    )
    $stamps = @($Chosen['gateway.regions'] | Where-Object { $_ })
    if ($stamps.Count -gt 1) {
        $primaryOnly = (Get-AvailabilityTrafficShare $Data $Chosen $stamps[1]) -eq 0
        $list += if ($primaryOnly) { "Requests and resolver executions are priced in the primary stamp region, $($stamps[0]), only; the standby stamps carry their fixed costs." }
        else { "Requests and resolver executions are split evenly across the $($stamps.Count) stamp regions, and the monthly free grants of the API Management call meter and of Flex Consumption are applied in each region." }
    }
    if ($null -ne $Chosen['edge.frontDoor'] -and [string]$Chosen['edge.frontDoor'] -cne 'none') { $list += "Front Door is priced in one billing zone for all traffic: $zone ($($Data.conventions.edgeBillingZoneLabels[$zone]))." }
    if ($null -ne $Chosen['cache.option'] -and [string]$Chosen['cache.option'] -cne 'built-in') { $list += 'Azure Managed Redis is priced as two nodes per cache for high availability (U-new-HADEC-2).' }
    $list
}

function New-Stage0SignOff {
    param($Data, $Records, $Chosen, $Facts, $Snapshot, $Reference, $Answers, $Context, [DateTimeOffset]$DecidedAt, $Freshness, [string]$PriceLabel,
        [string[]]$Regions, [string]$CheckpointPath, [string]$RecommendationsSha256)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $primary = @($Chosen['gateway.regions'])[0]
    $decisionRecords = @{}; $rows = @(); $shownChoice = [ordered]@{}
    $total = [decimal]0; $referenceTotal = [decimal]0; $referenceComplete = $true; $priced = 0; $unpriced = @()
    foreach ($r in $Records) {
        $d = $r[0]; $value = $r[1]
        $recommended = $null
        if ($d.type -in @('integer', 'decimal') -and $d.recommendation.formula -and $d.recommendation.formula -ne 'none') {
            $recommended = (Get-AvailabilityFormula $d.recommendation.formula $Data $Answers.sizing $Chosen $Facts $primary $null).value
        }
        $follows = if ($d.recommendation.option) { [string]::Equals([string]$value, $d.recommendation.option, 'Ordinal') } elseif ($null -ne $recommended) { [string]$value -eq [string]$recommended } else { 'not applicable (rule)' }
        $carrier = Get-AvailabilityCostCarrier $Data $d
        $refCost = $null
        if ($null -eq $value) { $cost = [ordered]@{ status = 'not-applicable'; total = $null; reason = $null; regions = @(); lines = @() } }
        elseif ($carrier -cne $d.id) { $cost = [ordered]@{ status = 'included'; includedIn = $carrier; total = $null; reason = $null; regions = @(); lines = @() } }
        else {
            $cost = Measure-Stage0ChosenCost $Data $d $value $Chosen $Answers.sizing $Snapshot
            if ($cost.status -eq 'priced') { $total += [decimal]$cost.total; $priced++ }
            elseif ($cost.status -ne 'none') { $unpriced += [ordered]@{ id = $d.id; status = $cost.status; reason = (Format-AvailabilityMoney $cost) } }
            if ($Reference -and $cost.status -ne 'none') {
                $refCost = Measure-Stage0ChosenCost $Data $d $value $Chosen $Answers.sizing $Reference
                if ($refCost.status -eq 'priced') { $referenceTotal += [decimal]$refCost.total } else { $referenceComplete = $false }
            }
        }
        $option = if ($d.type -eq 'option') { Get-AvailabilityOption $d ([string]$value) } else { $null }
        $decisionRecords[$d.id] = [ordered]@{
            decisionId = $d.id; row = $d.row; title = $d.title; owner = $d.owner; setting = $d.setting; chosen = $value
            recommendationShown = $d.recommendation; recommendedValue = $recommended; followsRecommendation = $follows
            impact = $(if ($option) { $option.impact } else { $null }); cost = $cost
            referenceCost = $(if ($refCost) { [ordered]@{ currency = $Reference.currency; label = (Get-AvailabilityCurrencyLabel $Reference.currency); status = $refCost.status; total = $refCost.total } } else { $null })
            pricesRetrievedAt = $Freshness.RetrievedAt; pricesStale = $Freshness.Stale; recommendationsVersion = $Data.dataVersion
        }
        $shownChoice[$d.id] = if ($d.recommendation.option) { $d.recommendation.option } else { $recommended }
        $monthly = Format-AvailabilityMoney $cost
        if ($refCost -and $refCost.status -eq 'priced') { $monthly += " ($($Reference.currency) $(([decimal]$refCost.total).ToString('N2', $inv)), reference only)" }
        $rows += [ordered]@{ id = $d.id; row = $d.row; owner = $d.owner; chosen = $value; recommendation = $d.recommendation; recommendedValue = $recommended
            follows = $follows; monthly = $monthly; uncovered = $(if ($option) { $option.impact.uncovered } else { '' }) }
    }
    $evidence = [ordered]@{
        decisionRecord = $CheckpointPath; recommendationsVersion = $Data.dataVersion; recommendationsSha256 = $RecommendationsSha256; recommendationsShown = $shownChoice
        priceSnapshot = [ordered]@{ retrievedAt = $Snapshot.retrievedAt; currency = $Snapshot.currency; stale = $Freshness.Stale
            items = @($Snapshot.items | ForEach-Object { [ordered]@{ meterId = $_.meterId; armRegionName = $_.armRegionName; meterName = $_.meterName; tierMinimumUnits = ([decimal]$_.tierMinimumUnits).ToString($inv)
                        unitPrice = ([decimal]$_.unitPrice).ToString($inv); unitOfMeasure = $_.unitOfMeasure; effectiveStartDate = [string]$_.effectiveStartDate } }) }
        regionFactsReadAt = $Facts.retrievedAt; regionFacts = $Facts.regions
    }
    $sheet = [ordered]@{
        schemaVersion = 1; kind = 'ccof.d0.signoff'; decidedBy = $Context.Actor.objectId; tenantId = $Context.Actor.tenantId
        decidedAt = $DecidedAt.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $inv)
        subscriptionId = $Answers.subscriptionId; backendSubscriptionId = $Answers.backendSubscriptionId; candidateRegions = $Regions; stampRegions = @($Chosen['gateway.regions'])
        recommendationsVersion = $Data.dataVersion; recommendationsSha256 = $RecommendationsSha256; regionFactsReadAt = $Facts.retrievedAt
        explicitValues = 'Every value was supplied explicitly by the administrator; no recommendation was applied by default.'
        prices = [ordered]@{ label = $PriceLabel; freshness = $Freshness.Label; retrievedAt = $Freshness.RetrievedAt; stale = $Freshness.Stale; currency = $Snapshot.currency }
        referencePrices = $(if ($Reference) { [ordered]@{ currency = $Reference.currency; label = (Get-AvailabilityCurrencyLabel $Reference.currency); retrievedAt = $Reference.retrievedAt } } else { $null })
        sizing = $Answers.sizing; assumptions = @(Get-Stage0Assumptions $Data $Answers.sizing $Chosen)
        decisions = $rows
        totals = [ordered]@{ currency = 'USD'; monthly = $total; pricedRows = $priced; unpricedRows = $unpriced
            reference = $(if ($Reference) { [ordered]@{ currency = $Reference.currency; monthly = $(if ($referenceComplete) { $referenceTotal } else { $null }); complete = $referenceComplete } } else { $null }) }
        decidedElsewhere = @($Data.decisions | Where-Object { $_.type -eq 'info' } | ForEach-Object {
                [ordered]@{ id = $_.id; row = $_.row; owner = $_.owner; decidedIn = $_.decidedIn; recommendation = $(if ($_.recommendation.rule) { $_.recommendation.rule } else { $_.recommendation.reason }) } })
        regionFacts = $Facts.regions; coreExport = $null
    }
    @{ sheet = $sheet; decisionRecords = $decisionRecords; evidence = $evidence }
}
Export-ModuleMember -Function Read-Stage0Value, New-Stage0Prompt, Measure-Stage0ChosenCost, Get-Stage0Assumptions, New-Stage0SignOff
