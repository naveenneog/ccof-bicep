#Requires -Version 7.0
<#
.SYNOPSIS
    Azure Retail Prices API client and cost arithmetic for the availability decisions (ADR-0014,
    decision 6). Unauthenticated HTTPS GET, NextPageLink paging on one host, exact decimal prices,
    tiered meters, currency labels and price freshness. No price is held in code.
#>
Import-Module (Join-Path $PSScriptRoot 'Availability.Common.psm1')

$script:FilterFields = @('serviceName', 'productName', 'skuName', 'meterName', 'armRegionName', 'priceType', 'meterId', 'serviceFamily')
$script:StringFields = @('currencyCode', 'armRegionName', 'location', 'effectiveStartDate', 'meterId', 'meterName', 'productName', 'skuName', 'serviceName', 'unitOfMeasure', 'type')
$script:NumberFields = @('tierMinimumUnits', 'unitPrice', 'retailPrice')
$script:MeterIndexes = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()

function Get-RetailPricesUrl {
    param(
        [Parameter(Mandatory)] [Collections.Specialized.OrderedDictionary]$Filter,
        [string]$Currency = 'USD',
        [string]$Endpoint = 'https://prices.azure.com/api/retail/prices',
        [string]$ApiVersion = '2023-01-01-preview'
    )
    if ($Currency -cnotmatch '^[A-Z]{3}$') { Stop-Availability 'currency_invalid' 'The currency must be a three-letter upper-case ISO code.' }
    $clauses = foreach ($key in $Filter.Keys) {
        if ($key -cnotin $script:FilterFields) { Stop-Availability 'filter_field_unknown' "Unknown Retail Prices filter field '$key'." }
        $value = [string]$Filter[$key]
        if ($value -cnotmatch '^[A-Za-z0-9 ._/()-]{1,120}$') { Stop-Availability 'filter_value_unsafe' "The filter value for '$key' contains a character outside the allowed set." }
        "$key eq '$value'"
    }
    Assert-RetailPricesUri $Endpoint 'url_rejected'
    "$Endpoint`?api-version=$ApiVersion&currencyCode='$Currency'&`$filter=" + [uri]::EscapeDataString(($clauses -join ' and '))
}

function Assert-RetailPricesUri {
    param([string]$Url, [string]$Code)
    $uri = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or
        -not [string]::Equals($uri.Host, 'prices.azure.com', 'OrdinalIgnoreCase') -or -not $uri.IsDefaultPort -or
        $uri.UserInfo -or $uri.Fragment -or -not [string]::Equals($uri.AbsolutePath, '/api/retail/prices', 'Ordinal')) {
        Stop-Availability $Code 'A Retail Prices URL must be HTTPS on prices.azure.com/api/retail/prices, with no credentials, fragment or custom port.'
    }
}

function ConvertFrom-RetailPricesPage {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Content)
    try { $doc = [Text.Json.JsonDocument]::Parse($Content) }
    catch { Stop-Availability 'retail_prices_malformed' 'The Retail Prices API returned a response that is not JSON.' }
    try {
        $root = $doc.RootElement
        $itemsElement = [Text.Json.JsonElement]::new()
        if ($root.ValueKind -ne 'Object' -or -not $root.TryGetProperty('Items', [ref]$itemsElement) -or $itemsElement.ValueKind -ne 'Array') {
            Stop-Availability 'retail_prices_malformed' 'The Retail Prices API response has no Items array.'
        }
        $items = [Collections.Generic.List[object]]::new()
        foreach ($element in $itemsElement.EnumerateArray()) { $items.Add((ConvertFrom-RetailPriceItem $element)) }
        $next = $null; $nextElement = [Text.Json.JsonElement]::new()
        if ($root.TryGetProperty('NextPageLink', [ref]$nextElement) -and $nextElement.ValueKind -eq 'String') { $next = $nextElement.GetString() }
        $count = $items.Count; $countElement = [Text.Json.JsonElement]::new()
        if ($root.TryGetProperty('Count', [ref]$countElement) -and $countElement.ValueKind -eq 'Number') { $count = $countElement.GetInt32() }
        [pscustomobject]@{ Items = $items.ToArray(); NextPageLink = $next; Count = $count }
    }
    finally { $doc.Dispose() }
}

function ConvertFrom-RetailPriceItem {
    param([Text.Json.JsonElement]$Element)
    if ($Element.ValueKind -ne 'Object') { Stop-Availability 'retail_prices_malformed' 'A Retail Prices item is not an object.' }
    $item = [ordered]@{}
    $property = [Text.Json.JsonElement]::new()
    foreach ($name in $script:StringFields) {
        if (-not $Element.TryGetProperty($name, [ref]$property) -or $property.ValueKind -ne 'String') {
            Stop-Availability 'retail_prices_malformed' "A Retail Prices item has no string field '$name'."
        }
        $item[$name] = $property.GetString()
    }
    foreach ($name in $script:NumberFields) {
        if (-not $Element.TryGetProperty($name, [ref]$property) -or $property.ValueKind -ne 'Number') {
            Stop-Availability 'retail_prices_malformed' "A Retail Prices item has no number field '$name'."
        }
        $value = $property.GetDecimal()
        if ($value -lt 0) { Stop-Availability 'retail_prices_malformed' "A Retail Prices item has a negative '$name'." }
        $item[$name] = $value
    }
    if (-not $Element.TryGetProperty('isPrimaryMeterRegion', [ref]$property) -or $property.ValueKind -notin 'True', 'False') {
        Stop-Availability 'retail_prices_malformed' "A Retail Prices item has no boolean 'isPrimaryMeterRegion'."
    }
    $item['isPrimaryMeterRegion'] = $property.GetBoolean()
    $item
}

function Invoke-RetailPricesGet {
    <# One GET with a bounded retry on throttling and server errors, honouring Retry-After up to 30 seconds. #>
    param([Parameter(Mandatory)] [string]$Url, [int]$Attempts = 3, [scriptblock]$Sleep = { param($s) Start-Sleep -Seconds $s })
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try { $response = Invoke-WebRequest -Uri $Url -Method Get -MaximumRedirection 0 -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop }
        catch {
            if ($attempt -lt $Attempts) { & $Sleep ([Math]::Pow(2, $attempt)); continue }
            Stop-Availability 'retail_prices_unreachable' 'The Azure Retail Prices API (prices.azure.com) could not be reached. No availability decision was recorded; run D0 again when it answers.'
        }
        $code = [int]$response.StatusCode
        if ($code -eq 200) { return [string]$response.Content }
        if (($code -eq 429 -or $code -ge 500) -and $attempt -lt $Attempts) {
            $wait = [Math]::Pow(2, $attempt); $after = 0
            if ($response.Headers -and $response.Headers['Retry-After'] -and [int]::TryParse([string]@($response.Headers['Retry-After'])[0], [ref]$after)) { $wait = [Math]::Min(30, [Math]::Max(1, $after)) }
            & $Sleep $wait; continue
        }
        Stop-Availability 'retail_prices_http' "The Azure Retail Prices API (prices.azure.com) answered HTTP $code. No availability decision was recorded; run D0 again later."
    }
}

function Invoke-RetailPricesQuery {
    param([Parameter(Mandatory)] [string]$Url, [scriptblock]$Send, [int]$MaxPages = 100)
    if (-not $Send) { $Send = { param($u) Invoke-RetailPricesGet -Url $u } }
    Assert-RetailPricesUri $Url 'url_rejected'
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $items = [Collections.Generic.List[object]]::new(); $urls = [Collections.Generic.List[string]]::new()
    $current = $Url
    while ($current) {
        if ($urls.Count -ge $MaxPages) { Stop-Availability 'next_page_rejected' 'Retail Prices paging exceeded the page limit.' }
        if (-not $visited.Add($current)) { Stop-Availability 'next_page_rejected' 'Retail Prices paging repeated a page.' }
        $urls.Add($current)
        $page = ConvertFrom-RetailPricesPage -Content ([string](& $Send $current))
        foreach ($item in $page.Items) { $items.Add($item) }
        $current = $page.NextPageLink
        if ($current) {
            Assert-RetailPricesUri $current 'next_page_rejected'
            if ($visited.Contains($current)) { Stop-Availability 'next_page_rejected' 'Retail Prices paging returned a page already read.' }
        }
    }
    [pscustomobject]@{ Items = $items.ToArray(); Pages = $urls.Count; Urls = $urls.ToArray() }
}

function New-AvailabilityPriceSnapshot {
    param(
        [Parameter(Mandatory)] [object[]]$Queries, [scriptblock]$Send,
        [Parameter(Mandatory)] [string]$Currency, [Parameter(Mandatory)] [DateTimeOffset]$RetrievedAt
    )
    $items = [Collections.Generic.List[object]]::new(); $records = @()
    foreach ($query in $Queries) {
        $result = Invoke-RetailPricesQuery -Url $query.url -Send $Send
        foreach ($item in $result.Items) {
            if (-not [string]::Equals($item.currencyCode, $Currency, 'Ordinal')) {
                Stop-Availability 'currency_mismatch' "The Retail Prices API returned $($item.currencyCode) where $Currency was requested."
            }
            $items.Add($item)
        }
        $records += [ordered]@{ key = $query.key; url = $query.url; pages = $result.Pages; itemCount = $result.Items.Count }
    }
    [ordered]@{
        currency = $Currency; referenceOnly = -not [string]::Equals($Currency, 'USD', 'Ordinal')
        retrievedAt = $RetrievedAt.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture); queries = $records; items = $items.ToArray()
    }
}

function Get-TieredCost {
    param([Parameter(Mandatory)] [object[]]$Tiers, [Parameter(Mandatory)] [decimal]$Quantity)
    if ($Quantity -lt 0) { Stop-Availability 'quantity_invalid' 'A priced quantity cannot be negative.' }
    $sorted = @($Tiers | Sort-Object { [decimal]$_.tierMinimumUnits })
    if ($sorted.Count -eq 0 -or [decimal]$sorted[0].tierMinimumUnits -ne 0) { Stop-Availability 'tier_invalid' 'A tiered meter must start at zero units.' }
    $total = [decimal]0
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $start = [decimal]$sorted[$i].tierMinimumUnits
        if ($Quantity -le $start) { break }
        $end = if ($i + 1 -lt $sorted.Count) { [Math]::Min($Quantity, [decimal]$sorted[$i + 1].tierMinimumUnits) } else { $Quantity }
        $total += ($end - $start) * [decimal]$sorted[$i].unitPrice
    }
    $total
}

function Get-RetailMeterIndex {
    <# Consumption items keyed by service, product, SKU, meter and pricing region (ordinal), built once per snapshot. #>
    param([Parameter(Mandatory)] $Snapshot)
    $items = $Snapshot.items
    $index = $null
    if ($null -ne $items -and $script:MeterIndexes.TryGetValue($items, [ref]$index)) { return $index }
    $index = [Collections.Generic.Dictionary[string, Collections.Generic.List[object]]]::new([StringComparer]::Ordinal)
    foreach ($item in @($items)) {
        if (-not [string]::Equals($item.type, 'Consumption', 'Ordinal')) { continue }
        $key = "$($item.serviceName)`0$($item.productName)`0$($item.skuName)`0$($item.meterName)`0$($item.armRegionName)"
        if (-not $index.ContainsKey($key)) { $index[$key] = [Collections.Generic.List[object]]::new() }
        $index[$key].Add($item)
    }
    if ($null -ne $items) { $script:MeterIndexes.AddOrUpdate($items, $index) }
    $index
}

function Find-RetailMeter {
    param([Parameter(Mandatory)] $Snapshot, [Parameter(Mandatory)] $Meter, [Parameter(Mandatory)] [string]$PricingRegion)
    $key = "$($Meter.serviceName)`0$($Meter.productName)`0$($Meter.skuName)`0$($Meter.meterName)`0$PricingRegion"
    $list = $null
    $matched = if ((Get-RetailMeterIndex $Snapshot).TryGetValue($key, [ref]$list)) { @($list) } else { @() }
    if ($matched.Count -eq 0) { return @{ Status = 'meter_not_found'; Tiers = @() } }
    if (@($matched | ForEach-Object meterId | Sort-Object -Unique).Count -ne 1) { return @{ Status = 'meter_ambiguous'; Tiers = $matched } }
    if (@($matched | Where-Object { -not [string]::Equals($_.unitOfMeasure, $Meter.unit, 'Ordinal') }).Count) { return @{ Status = 'unit_changed'; Tiers = $matched } }
    @{ Status = 'ok'; Tiers = @($matched | Sort-Object { [decimal]$_.tierMinimumUnits }) }
}

function Resolve-AvailabilityQuantity {
    param([object[]]$Terms, [hashtable]$Variables)
    $product = [decimal]1
    foreach ($term in $Terms) {
        if ([string]::Equals($term, 'unpublished', 'Ordinal')) { return $null }
        if ($term -is [string] -and $term.StartsWith('$')) {
            $name = $term.Substring(1)
            if (-not $Variables.ContainsKey($name) -or $null -eq $Variables[$name]) { Stop-Availability 'variable_undefined' "The cost formula needs '$name', which has no value." }
            $product *= ConvertTo-AvailabilityDecimal $Variables[$name] $name
        }
        else { $product *= ConvertTo-AvailabilityDecimal ([string]$term) 'cost factor' }
    }
    $product
}

function Measure-AvailabilityCost {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Model, [Parameter(Mandatory)] [string]$Region,
        [string]$BillingZone, [Parameter(Mandatory)] [hashtable]$Variables, [Parameter(Mandatory)] $Snapshot, [hashtable]$Substitutions = @{}
    )
    $lines = foreach ($component in $Model) {
        $meter = @{}
        foreach ($key in @('serviceName', 'productName', 'skuName', 'meterName', 'unit')) {
            $value = [string]$component.meter[$key]
            foreach ($name in $Substitutions.Keys) { $value = $value.Replace("{$name}", [string]$Substitutions[$name]) }
            if ($value.Contains('{')) { Stop-Availability 'variable_undefined' "The meter '$($component.meter[$key])' needs a value that has not been decided." }
            $meter[$key] = $value
        }
        $pricingRegion = switch ($component.scope) {
            'region' { $Region }
            'global' { 'Global' }
            'billingZone' { if (-not $BillingZone) { Stop-Availability 'billing_zone_missing' 'A Front Door cost needs the developers'' edge billing zone.' }; $BillingZone }
            default { Stop-Availability 'scope_unknown' "Unknown pricing scope '$($component.scope)'." }
        }
        $quantity = Resolve-AvailabilityQuantity $component.quantity $Variables
        $line = [ordered]@{ label = $component.label; meterName = $meter.meterName; pricingRegion = $pricingRegion; quantity = $quantity
            meterId = $null; unitPrice = $null; unitOfMeasure = $null; effectiveStartDate = $null; tiers = @(); cost = $null; status = 'unpublished' }
        if ($null -ne $quantity) {
            $found = Find-RetailMeter -Snapshot $Snapshot -Meter $meter -PricingRegion $pricingRegion
            $line.status = $found.Status
            if ($found.Status -eq 'ok') {
                $first = $found.Tiers[0]
                $line.meterId = $first.meterId; $line.unitPrice = $first.unitPrice; $line.unitOfMeasure = $first.unitOfMeasure
                $line.effectiveStartDate = $first.effectiveStartDate
                $line.tiers = @($found.Tiers | ForEach-Object { [ordered]@{ tierMinimumUnits = $_.tierMinimumUnits; unitPrice = $_.unitPrice } })
                $line.cost = Get-TieredCost -Tiers $found.Tiers -Quantity $quantity
                $line.status = 'priced'
            }
        }
        $line
    }
    $lines = @($lines)
    $status = if (@($lines | Where-Object { $_.status -notin 'priced', 'unpublished' }).Count) { 'unavailable' }
    elseif (@($lines | Where-Object { $_.status -eq 'unpublished' }).Count) { 'unpublished' } else { 'priced' }
    $total = $null
    if ($status -eq 'priced') { $total = [decimal]0; foreach ($l in $lines) { $total += [decimal]$l.cost } }
    [pscustomobject]@{ Status = $status; Total = $total; Lines = $lines }
}

function Get-AvailabilityPriceQueries {
    <#
    .SYNOPSIS
        One Retail Prices query per (service, product, SKU, pricing region) used by the cost models.
        A templated SKU (for example the cache SKU) is queried at product level, so every SKU of
        that product is in the snapshot and the administrator sees each one priced.
    #>
    param([Parameter(Mandatory)] $CostModels, [Parameter(Mandatory)] [string[]]$Regions, [string]$BillingZone, [Parameter(Mandatory)] [string]$Currency)
    $queries = [ordered]@{}
    foreach ($modelName in @($CostModels.Keys | Sort-Object)) {
        foreach ($component in $CostModels[$modelName]) {
            $pricingRegions = switch ($component.scope) {
                'region' { $Regions }
                'global' { @('Global') }
                'billingZone' { if ($BillingZone) { @($BillingZone) } else { @() } }
                default { Stop-Availability 'scope_unknown' "Unknown pricing scope '$($component.scope)'." }
            }
            foreach ($region in $pricingRegions) {
                $filter = [ordered]@{ serviceName = $component.meter.serviceName; productName = $component.meter.productName }
                if (-not ([string]$component.meter.skuName).Contains('{')) { $filter.skuName = $component.meter.skuName }
                $filter.armRegionName = $region
                $filter.priceType = 'Consumption'
                $url = Get-RetailPricesUrl -Filter $filter -Currency $Currency
                if (-not $queries.Contains($url)) {
                    $queries[$url] = [ordered]@{ key = (@($filter.Values) -join '|'); url = $url }
                }
            }
        }
    }
    @($queries.Values)
}

function Get-AvailabilityCurrencyLabel {
    param([Parameter(Mandatory)] [string]$Currency)
    if ([string]::Equals($Currency, 'USD', 'Ordinal')) { return 'USD list price from the Azure Retail Prices API, before agreement discounts' }
    "$Currency reference only: the Retail Prices API states that non-USD prices are for reference to estimate budgets; decisions are recorded with USD list prices"
}

function Get-PriceFreshness {
    param([Parameter(Mandatory)] [DateTimeOffset]$RetrievedAt, [Parameter(Mandatory)] [DateTimeOffset]$DecidedAt)
    if ($RetrievedAt -gt $DecidedAt) { Stop-Availability 'clock_invalid' 'The price retrieval time is later than the decision time.' }
    $age = [decimal][Math]::Round(($DecidedAt - $RetrievedAt).TotalHours, 1)
    $retrieved = $RetrievedAt.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    $stale = $RetrievedAt.UtcDateTime.Date -ne $DecidedAt.UtcDateTime.Date
    $label = if ($stale) { "STALE: list prices retrieved $retrieved, $age hours before this decision, not on the day of the decision" }
    else { "List prices retrieved $retrieved, on the day of the decision" }
    [pscustomobject]@{ RetrievedAt = $retrieved; AgeHours = $age; Stale = $stale; Label = $label }
}

Export-ModuleMember -Function Get-RetailPricesUrl, ConvertFrom-RetailPricesPage, Invoke-RetailPricesGet, Invoke-RetailPricesQuery, New-AvailabilityPriceSnapshot, Get-TieredCost, Find-RetailMeter, Measure-AvailabilityCost, Get-AvailabilityPriceQueries, Get-AvailabilityCurrencyLabel, Get-PriceFreshness
