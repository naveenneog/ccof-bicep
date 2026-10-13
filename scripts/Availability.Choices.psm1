#Requires -Version 7.0
<#
.SYNOPSIS
    Presents one availability decision (recommendation, impact, list price per candidate region and
    region checks) and validates the administrator's explicit choice against the live facts.
#>
Import-Module (Join-Path $PSScriptRoot 'Availability.Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'Availability.Pricing.psm1')
Import-Module (Join-Path $PSScriptRoot 'Availability.Regions.psm1')
Import-Module (Join-Path $PSScriptRoot 'Availability.Decisions.psm1')

function New-AvailabilityContext {
    param($Data, $Chosen, [string[]]$Candidates)
    @{ chosen = $Chosen; stampRegions = @($Chosen['gateway.regions'] | Where-Object { $_ }); candidateRegions = $Candidates; laReplication = $Data.logAnalyticsReplication.groups }
}

function Get-AvailabilityOverride {
    param($Data, $Decision, $Sizing, $Chosen, $Facts, [string]$Region, [string]$OptionId, $Value)
    $o = @{}
    switch -CaseSensitive ($Decision.id) {
        'gateway.mode' { if ($null -eq $Chosen['gateway.units']) { $o.apimUnits = (Get-AvailabilityFormula 'apimUnits' $Data $Sizing $Chosen $Facts $Region $OptionId).value } }
        'registry.capacity' { if ($null -eq $Chosen['registry.throughput'] -and $OptionId -notlike 'serverless*') { $o.throughput = (Get-AvailabilityFormula 'cosmosThroughput' $Data $Sizing $Chosen $Facts $Region $OptionId).value } }
        'gateway.units' { $o.apimUnits = $Value }
        'registry.throughput' { $o.throughput = $Value }
        'cache.sku' { $o['cache.sku'] = $Value }
        'telemetry.retentionDays' { $o.retentionDays = $Value }
    }
    if ($Decision.app) {
        $option = if ($OptionId -and $Decision.type -eq 'option') { Get-AvailabilityOption $Decision $OptionId } else { $null }
        if ($option -and $null -ne $option.alwaysReadyBasis) { $o["alwaysReady:$($Decision.app)"] = $option.alwaysReadyBasis }
        if ($option -and $Decision.id -ceq "$($Decision.app).instanceMemoryMB") { $o["memory:$($Decision.app)"] = $option.value }
        if ($option -and $null -ne $option.memoryBasisMB) { $o["memory:$($Decision.app)"] = $option.memoryBasisMB }
        if ($null -ne $Value) { $o["alwaysReady:$($Decision.app)"] = $Value }
    }
    $o
}

function Get-AvailabilityPresentation {
    param([Parameter(Mandatory)] $Data, [Parameter(Mandatory)] $Decision, [Parameter(Mandatory)] $Sizing, [Parameter(Mandatory)] $Chosen,
        [Parameter(Mandatory)] $Facts, [Parameter(Mandatory)] $Snapshot, [Parameter(Mandatory)] [string[]]$Candidates)
    $context = New-AvailabilityContext $Data $Chosen $Candidates
    $p = [ordered]@{ id = $Decision.id; row = $Decision.row; title = $Decision.title; owner = $Decision.owner; setting = $Decision.setting; type = $Decision.type
        applies = Test-AvailabilityApplies $Decision $Chosen; recommendation = $Decision.recommendation; decidedIn = $Decision.decidedIn; costShownIn = $Decision.costShownIn; costNote = $Decision.costNote; options = @(); perRegion = [ordered]@{}
        excluded = @($Data.excludedOptions | Where-Object { $_.decision -ceq $Decision.id } | ForEach-Object { [ordered]@{ option = $_.option; reason = $_.reason } }) }
    if (-not $p.applies) { return $p }
    $regions = $Candidates
    if ($Decision.type -eq 'option') {
        $p.options = @(foreach ($option in $Decision.options) {
                $perRegion = [ordered]@{}
                foreach ($region in $regions) {
                    $checks = @(foreach ($c in @($option.constraints)) { Test-AvailabilityConstraint -Constraint $c -Region $region -Facts $Facts -Context $context })
                    $override = Get-AvailabilityOverride $Data $Decision $Sizing $Chosen $Facts $region $option.id $null
                    $basis = $null
                    if ($override.ContainsKey('apimUnits')) { $basis = "$($override.apimUnits) units (sizing formula)" }
                    if ($override.ContainsKey('throughput')) { $basis = "$($override.throughput) RU/s (sizing formula)" }
                    if ($Decision.app -and $null -ne $override["alwaysReady:$($Decision.app)"]) {
                        $memoryBasis = $override["memory:$($Decision.app)"]
                        $basis = "$($override["alwaysReady:$($Decision.app)"]) always-ready instance(s)$(if ($null -ne $memoryBasis) { " of $memoryBasis MB" }) per region$(if ($Decision.app -ceq 'resolver') { ' plus the estimated on-demand executions' }) as the cost basis"
                    }
                    $cost = Measure-AvailabilityDecisionCost $Data $option.cost $region $Sizing $Chosen $Snapshot $override
                    $skus = if ($cost.Status -eq 'depends' -and $option.cost -is [string] -and ($Data.costModels[$option.cost] | Where-Object { ([string]$_.meter.skuName).Contains('{') })) { @(Get-AvailabilitySkuPrices $Data $option.cost $Chosen $Snapshot $region $Sizing) } else { $null }
                    $perRegion[$region] = [ordered]@{ allowed = -not @($checks | Where-Object { -not $_.Allowed }).Count
                        refusals = @($checks | Where-Object { -not $_.Allowed } | ForEach-Object { [ordered]@{ code = $_.ReasonCode; reason = $_.Reason } })
                        cost = $cost; basis = $basis; skus = $skus }
                }
                $bearing = Get-AvailabilityBearingRegions $Decision $option $Chosen
                [ordered]@{ id = $option.id; label = $option.label; impact = $option.impact; recommended = $option.id -ceq $Decision.recommendation.option; notDeployableByCore = $option.notDeployableByCore
                    perRegion = $perRegion; total = Get-AvailabilityTotal $perRegion $bearing; totalRegions = $bearing }
            })
        return $p
    }
    foreach ($region in $regions) {
        $entry = [ordered]@{}
        if ($Decision.type -in @('integer', 'decimal')) {
            $formula = Get-AvailabilityFormula $Decision.recommendation.formula $Data $Sizing $Chosen $Facts $region $null
            if ($null -ne $formula.value) { $entry.recommendedValue = $formula.value; $entry.explanation = $formula.explanation }
            elseif ($Decision.recommendation.formula -and $Decision.recommendation.formula -ne 'none') { $entry.explanation = $formula.explanation }
            $spec = if ($Decision.costOf) { @{ costOf = $Decision.costOf } } else { $Decision.cost }
            # Without a formula result, a stated basis (data: costBasis) still shows what the setting costs.
            $value = if ($null -ne $formula.value) { $formula.value } elseif ($Decision.costBasis) { $Decision.costBasis.value } else { $null }
            if ($spec -and $null -ne $value) {
                $override = Get-AvailabilityOverride $Data $Decision $Sizing $Chosen $Facts $region $null $value
                $cost = Measure-AvailabilityDecisionCost $Data $spec $region $Sizing $Chosen $Snapshot $override
                if ($null -ne $formula.value) { $entry.costAtRecommendation = $cost } else { $entry.costAtBasis = $cost; $entry.basisLabel = $Decision.costBasis.label }
            }
        }
        if ($Decision.type -eq 'region') {
            $checks = @(foreach ($c in @($Decision.constraints)) { Test-AvailabilityConstraint -Constraint $c -Region $region -Facts $Facts -Context $context })
            $entry.allowed = -not @($checks | Where-Object { -not $_.Allowed }).Count
            $entry.refusals = @($checks | Where-Object { -not $_.Allowed } | ForEach-Object { [ordered]@{ code = $_.ReasonCode; reason = $_.Reason } })
            if ($Decision.cost) { $entry.cost = Measure-AvailabilityDecisionCost $Data $Decision.cost $region $Sizing $Chosen $Snapshot @{} }
        }
        if ($Decision.type -eq 'regions' -or ($Decision.type -eq 'info' -and $Decision.showsRegionFacts)) { $entry.facts = $Facts.regions[$region] }
        if ($Decision.type -eq 'sku') { $entry.skus = Get-AvailabilitySkuPrices $Data (Get-AvailabilityChosenModel $Data $Chosen) $Chosen $Snapshot $region $Sizing }
        $p.perRegion[$region] = $entry
    }
    $p
}

function Get-AvailabilitySkuPrices {
    param($Data, [string]$Model, $Chosen, $Snapshot, [string]$Region, $Sizing)
    if (-not $Model -or -not $Data.costModels.Contains($Model)) { return @() }
    $product = $Data.costModels[$Model][0].meter.productName
    $skus = @($Snapshot.items | Where-Object { [string]::Equals($_.productName, $product, 'Ordinal') -and [string]::Equals($_.armRegionName, $Region, 'Ordinal') } | ForEach-Object skuName | Sort-Object -Unique)
    @(foreach ($sku in $skus) {
            $c = Measure-AvailabilityDecisionCost $Data $Model $Region $Sizing $Chosen $Snapshot @{ 'cache.sku' = $sku }
            [ordered]@{ sku = $sku; status = $c.Status; monthly = $c.Total }
        })
}

function Get-AvailabilityChosenModel {
    param($Data, $Chosen)
    $tier = Get-AvailabilityOption (Get-AvailabilityDecision $Data 'cache.option') ([string]$Chosen['cache.option'])
    if ($tier -and $tier.cost -is [string]) { $tier.cost }
}

function Test-AvailabilityChoice {
    param([Parameter(Mandatory)] $Data, [Parameter(Mandatory)] $Decision, [AllowNull()] $Value, [Parameter(Mandatory)] $Sizing, [Parameter(Mandatory)] $Chosen,
        [Parameter(Mandatory)] $Facts, [Parameter(Mandatory)] $Snapshot, [Parameter(Mandatory)] [string[]]$Candidates)
    $refuse = { param($code, $reason) [pscustomobject]@{ Allowed = $false; Value = $Value; Refusals = @([ordered]@{ code = $code; reason = $reason }) } }
    if (-not (Test-AvailabilityApplies $Decision $Chosen)) {
        if ($null -ne $Value) { return & $refuse 'not_applicable' "$($Decision.id) does not apply to the choices made; leave it null." }
        return [pscustomobject]@{ Allowed = $true; Value = $null; Refusals = @() }
    }
    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) { return & $refuse 'choice_missing' "$($Decision.id) needs an explicit answer; the recommendation is not applied by default." }
    $context = New-AvailabilityContext $Data $Chosen $Candidates
    $stamps = @($Chosen['gateway.regions'] | Where-Object { $_ })
    $checkIn = {
        param($constraints, $regions)
        @(foreach ($r in $regions) { foreach ($c in @($constraints)) {
                    $t = Test-AvailabilityConstraint -Constraint $c -Region $r -Facts $Facts -Context $context
                    if (-not $t.Allowed) { [ordered]@{ code = $t.ReasonCode; reason = $t.Reason; region = $r } } } })
    }
    switch -CaseSensitive ($Decision.type) {
        'option' {
            $option = if ($Value -is [string]) { Get-AvailabilityOption $Decision $Value } else { $null }
            if (-not $option) { return & $refuse 'unknown_option' "'$Value' is not an option of $($Decision.id). Options: $(@($Decision.options.id) -join ', ')." }
            $regions = Get-AvailabilityBearingRegions $Decision $option $Chosen
            if (-not $regions.Count) { $regions = @($Candidates[0]) }
            $refusals = @(& $checkIn $option.constraints $regions)
            if ($option.recheck) {
                $other = Get-AvailabilityOption (Get-AvailabilityDecision $Data $option.recheck) ([string]$Chosen[$option.recheck])
                if (-not $other) { $refusals += [ordered]@{ code = 'requires_other_choice'; reason = "$($option.recheck) has no accepted choice, so this option cannot be checked." } }
                else { $refusals += @(& $checkIn @($other.constraints | Where-Object { $_ }) $stamps) }
            }
            return [pscustomobject]@{ Allowed = $refusals.Count -eq 0; Value = $option.id; Refusals = $refusals }
        }
        'integer' {
            [long]$n = 0
            if (-not ($Value -is [int] -or $Value -is [long]) -and -not ($Value -is [string] -and [long]::TryParse($Value, [Globalization.NumberStyles]::AllowLeadingSign, [Globalization.CultureInfo]::InvariantCulture, [ref]$n))) { return & $refuse 'number_invalid' "$($Decision.id) must be a whole number." }
            $n = [long]$Value
            if ($n -lt [int]::MinValue -or $n -gt [int]::MaxValue) { return & $refuse 'out_of_range' "$($Decision.id) is outside the accepted range." }
            $max = $Decision.max
            if ($Decision.maxFact -ceq 'apimSkuCapacity') {
                $sku = if ([string]$Chosen['gateway.mode'] -like 'premium*') { 'PremiumV2' } else { 'StandardV2' }
                $max = (@($stamps | ForEach-Object { $Facts.regions[$_].apim.skus[$sku] }) | Measure-Object -Minimum).Minimum
            }
            if ($Decision.allowedValues -and @($Decision.allowedValues) -notcontains $n) { return & $refuse 'out_of_range' "$($Decision.id) must be one of $(@($Decision.allowedValues) -join ', ')." }
            if ($null -ne $Decision.min -and $n -lt $Decision.min) { return & $refuse 'out_of_range' "$($Decision.id) must be at least $($Decision.min)." }
            if ($null -ne $max -and $n -gt $max) { return & $refuse 'out_of_range' "$($Decision.id) must be at most $max." }
            if ($Decision.step -and ($n % $Decision.step) -ne 0) { return & $refuse 'out_of_range' "$($Decision.id) must be a multiple of $($Decision.step)." }
            if ($Decision.id -ceq 'registry.throughput' -and [string]$Chosen['registry.capacity'] -like '*autoscale*' -and ($n -lt 1000 -or $n % 1000)) { return & $refuse 'out_of_range' 'An autoscale maximum is at least 1,000 RU/s, in increments of 1,000.' }
            if ($Decision.atLeast -and $null -ne $Chosen[$Decision.atLeast] -and $n -lt [int]$Chosen[$Decision.atLeast]) { return & $refuse 'out_of_range' "$($Decision.id) must not be below $($Decision.atLeast)." }
            $cap = $Decision.atMostWhenPositive
            if ($cap -and [int]$Chosen[$cap] -gt 0 -and $n -gt [int]$Chosen[$cap]) { return & $refuse 'out_of_range' "$($Decision.id) must not exceed $cap ($($Chosen[$cap]) seconds)." }
            $zr = $Decision.minWhenZoneRedundant
            if ($zr -and [string]$Chosen[$zr.decision] -ceq $zr.option -and $n -lt $zr.min) { return & $refuse 'zone_redundancy_minimum' "Zone redundancy requires at least $($zr.min) always-ready instances." }
            return [pscustomobject]@{ Allowed = $true; Value = $n; Refusals = @() }
        }
        'decimal' {
            $x = [decimal]0; $text = ([string]$Value).Trim(); $inv = [Globalization.CultureInfo]::InvariantCulture
            $ok = [decimal]::TryParse($text, ([Globalization.NumberStyles]::AllowDecimalPoint -bor [Globalization.NumberStyles]::AllowLeadingSign), $inv, [ref]$x)
            $places = if ($text.Contains('.')) { $text.Split('.')[1].Length } else { 0 }
            if ((-not $ok) -or ($x -lt [decimal]::Parse($Decision.min, $inv)) -or ($x -gt [decimal]::Parse($Decision.max, $inv)) -or ($places -gt [int]$Decision.scale)) {
                return & $refuse 'out_of_range' "$($Decision.id) must be a number from $($Decision.min) to $($Decision.max) with a decimal point and at most $($Decision.scale) decimals."
            }
            return [pscustomobject]@{ Allowed = $true; Value = $x.ToString($inv); Refusals = @() }
        }
        'regions' {
            $list = @($Value | ForEach-Object { [string]$_ })
            if ($list.Count -eq 0 -or @($list | Sort-Object -Unique).Count -ne $list.Count -or @($list | Where-Object { $Candidates -cnotcontains $_ }).Count) { return & $refuse 'region_invalid' 'Stamp regions must be unique candidate regions.' }
            $single = [string]$Chosen['gateway.topology'] -ceq 'single-region'
            if ($single -and $list.Count -ne 1) { return & $refuse 'region_count' 'The single-region topology has exactly one stamp region.' }
            if (-not $single -and $list.Count -lt 2) { return & $refuse 'region_count' 'A multi-region topology needs at least two stamp regions.' }
            return [pscustomobject]@{ Allowed = $true; Value = $list; Refusals = @() }
        }
        'region' {
            if ($Value -isnot [string] -or $Candidates -cnotcontains $Value) { return & $refuse 'region_invalid' "$($Decision.id) must be one of the candidate regions." }
            $refusals = @(& $checkIn $Decision.constraints @($Value))
            return [pscustomobject]@{ Allowed = $refusals.Count -eq 0; Value = $Value; Refusals = $refusals }
        }
        'sku' {
            if ($Value -isnot [string] -or $Value -cnotmatch '^[A-Z][0-9]{1,4}$') { return & $refuse 'sku_invalid' 'A cache SKU looks like B5 or M10.' }
            $refusals = @(foreach ($r in $stamps) {
                    $prices = @(Get-AvailabilitySkuPrices $Data (Get-AvailabilityChosenModel $Data $Chosen) $Chosen $Snapshot $r $Sizing | Where-Object { $_.sku -ceq $Value -and $_.status -eq 'priced' })
                    if (-not $prices.Count) { [ordered]@{ code = 'sku_not_priced'; reason = "SKU $Value has no list price for the chosen tier in $r."; region = $r } } })
            return [pscustomobject]@{ Allowed = $refusals.Count -eq 0; Value = $Value; Refusals = $refusals }
        }
        'text' {
            if ($Value -isnot [string] -or $Value -cnotmatch $Decision.pattern) { return & $refuse 'text_invalid' "$($Decision.id) must match $($Decision.pattern)." }
            return [pscustomobject]@{ Allowed = $true; Value = $Value; Refusals = @() }
        }
        default { return [pscustomobject]@{ Allowed = $true; Value = $null; Refusals = @() } }
    }
}

Export-ModuleMember -Function Get-AvailabilityPresentation, Get-AvailabilitySkuPrices, Test-AvailabilityChoice
