#Requires -Version 7.0
<#
.SYNOPSIS
    Text presentation, explicit interactive choice, the D0 sign-off sheet (Markdown and JSON) and
    the availability file the D1 to D3 stages consume (C-9; shape agreed with WP-CORE).
#>
Import-Module (Join-Path $PSScriptRoot 'Availability.Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'Availability.Decisions.psm1')

function Format-AvailabilityMoney {
    param($Cost)
    if ($null -eq $Cost) { return 'n/a' }
    if ($Cost.Status -eq 'none' -or $Cost.status -eq 'none') { return 'no direct cost' }
    $status = if ($Cost.Status) { $Cost.Status } else { $Cost.status }
    $total = if ($null -ne $Cost.Total) { $Cost.Total } else { $Cost.total }
    switch ($status) {
        'priced' { 'USD ' + ([decimal]$total).ToString('N2', [Globalization.CultureInfo]::InvariantCulture) + '/month' }
        'included' { "included in $($Cost.includedIn)" }
        'not-applicable' { 'not applicable to the choices made' }
        'unpublished' { 'price not published (see the unknowns)' }
        'depends' { if ($Cost.Reason) { [string]$Cost.Reason } else { 'priced once a later decision is made' } }
        default { "not priced ($status)" }
    }
}

function Format-AvailabilityPresentation {
    param([Parameter(Mandatory)] $Presentation, [Parameter(Mandatory)] [string]$PriceLabel)
    $p = $Presentation
    $refusalText = { param($e) 'REFUSED: ' + (@($e.refusals | ForEach-Object { "$($_.code): $($_.reason)" }) -join '; ') }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add(''); $lines.Add("[Row $($p.row)] $($p.id): $($p.title)"); $lines.Add("  Owner: $($p.owner)$(if ($p.setting) { "; setting: $($p.setting)" })")
    $r = $p.recommendation
    $what = if ($r.option) { "option '$($r.option)'" } elseif ($r.formula -and $r.formula -ne 'none') { 'the sizing formula result below' } else { [string]$r.rule }
    $reason = if ($r.rule -and [string]::Equals([string]$r.rule, [string]$r.reason, 'Ordinal')) { '' } else { [string]$r.reason }
    $head = if ([string]::IsNullOrWhiteSpace($what)) { '' } else { "$($what.TrimEnd('.'))." }
    $body = (@($head, $reason.Trim()) | Where-Object { $_ }) -join ' '
    $lines.Add("  Recommendation (advice, not a default): $body Sources: $(@($r.sources) -join ', ') (listed in docs/HA-DECISIONS.md).")
    if ($p.decidedIn) { $lines.Add("  Shown for information: this setting is decided in $($p.decidedIn), not in D0.") }
    if ($p.Contains('applies') -and -not $p.applies) { $lines.Add('  Does not apply to the choices made so far, so it is not asked and stays empty.'); return $lines -join [Environment]::NewLine }
    $priced = @(@($p.options | ForEach-Object { $_.perRegion.Values | ForEach-Object { $_.cost } }) + @($p.perRegion.Values | ForEach-Object { $_.cost; $_.costAtBasis; $_.costAtRecommendation }) |
            Where-Object { $_ -and $_.Status -eq 'priced' }).Count
    if ($p.costShownIn -and $priced) { $lines.Add("  Cost: the chosen value's cost is counted in $($p.costShownIn); the figures below compare the options on the basis shown.") }
    if ($p.costNote) { $lines.Add("  Cost note: $($p.costNote)") }
    foreach ($x in @($p.excluded)) { if ($x) { $lines.Add("  - $($x.option): not offered. $($x.reason)") } }
    foreach ($o in $p.options) {
        $lines.Add("  - $($o.id)$(if ($o.recommended) { ' [recommended]' }): $($o.label)")
        if ($o.notDeployableByCore) { $lines.Add("      Note: $($o.notDeployableByCore); this choice is recorded, and the availability file for D1 to D3 is not written.") }
        $lines.Add("      Covers: $($o.impact.covers)"); $lines.Add("      Uncovered, and whom it denies: $($o.impact.uncovered)"); $lines.Add("      SLA: $($o.impact.sla)")
        foreach ($region in $o.perRegion.Keys) {
            $e = $o.perRegion[$region]
            $state = if ($e.allowed) { 'allowed' } else { & $refusalText $e }
            $basis = if ($e.basis -and $e.cost.Status -eq 'priced') { " for $($e.basis)" } else { '' }
            $lines.Add("      $region : $(Format-AvailabilityMoney $e.cost)$basis; $state")
            if ($e.skus) { $lines.Add("        per SKU: " + (@($e.skus | ForEach-Object { "$($_.sku) $(Format-AvailabilityMoney @{ status = $_.status; total = $_.monthly })" }) -join ', ')) }
        }
        if ($o.total.status -eq 'priced') { $lines.Add("      Chosen regions ($(@($o.totalRegions) -join ', ')): USD $(([decimal]$o.total.total).ToString('N2', [Globalization.CultureInfo]::InvariantCulture))/month") }
    }
    foreach ($region in $p.perRegion.Keys) {
        $e = $p.perRegion[$region]
        $parts = @()
        if ($e.Contains('recommendedValue')) { $parts += "sizing result $($e.recommendedValue) ($($e.explanation))" } elseif ($e.explanation) { $parts += "no sizing result: $($e.explanation)" }
        if ($e.Contains('costAtRecommendation')) { $parts += "cost at that value $(Format-AvailabilityMoney $e.costAtRecommendation)" }
        if ($e.Contains('costAtBasis')) { $parts += "cost at $($e.basisLabel): $(Format-AvailabilityMoney $e.costAtBasis)" }
        if ($e.Contains('allowed')) { $parts += $(if ($e.allowed) { 'allowed' } else { & $refusalText $e }) }
        if ($e.Contains('cost')) { $parts += Format-AvailabilityMoney $e.cost }
        if ($e.Contains('skus')) { $parts += (@($e.skus | ForEach-Object { "$($_.sku) $(Format-AvailabilityMoney @{ status = $_.status; total = $_.monthly })" }) -join ', ') }
        if ($e.Contains('facts')) { $f = $e.facts; $parts += "zones [$(@($f.zones) -join ',')], pair $(@($f.pairedRegions) -join ','), geography $($f.geography), Claude $(if ($f.claude.status -eq 'ok') { "[$(@($f.claude.deploymentTypes) -join ',')] $(@($f.claude.models).Count) models" } else { 'unavailable' })" }
        if ($parts.Count) { $lines.Add("  $region : $($parts -join '; ')") }
    }
    if (-not $p.decidedIn) {
        $lines.Add("  Prices: $PriceLabel")
        $lines.Add('  Type the value exactly. Nothing is selected by default.')
    }
    $lines -join [Environment]::NewLine
}
function ConvertFrom-AvailabilityAnswerText {
    param($Decision, [string]$Text)
    switch ($Decision.type) {
        'regions' { return , @($Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        'integer' { $n = 0; if ([int]::TryParse($Text.Trim(), [ref]$n)) { return $n }; return $Text }
        default { return $Text.Trim() }
    }
}

function Read-AvailabilityChoice {
    param([Parameter(Mandatory)] $Decision, [Parameter(Mandatory)] [string]$Text, [Parameter(Mandatory)] [scriptblock]$Validate,
        [Parameter(Mandatory)] [scriptblock]$ReadLine, [int]$MaxAttempts = 5)
    Write-Host $Text
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $raw = [string](& $ReadLine "$($Decision.id) (explicit value; no default)")
        if ([string]::IsNullOrWhiteSpace($raw)) { Write-Host 'No value was typed. There is no default; type the value.'; continue }
        $check = & $Validate (ConvertFrom-AvailabilityAnswerText $Decision $raw)
        if ($check.Allowed) { return $check }
        Write-Host ('Not accepted: ' + (@($check.Refusals | ForEach-Object { $_.reason }) -join ' '))
    }
    Stop-Availability 'choice_missing' "No accepted value was given for $($Decision.id) after $MaxAttempts attempts. No availability decision, sign-off or availability file was written; the inputs given are recorded in the checkpoint as answers."
}

function Get-AvailabilitySchedule {
    param([int]$Minutes)
    if ($Minutes -eq 60) { return '0 0 * * * *' }
    "0 */$Minutes * * * *"
}

function New-AvailabilityCoreExport {
    <# Returns @{ file = <object> } or @{ refusal = <reason> }. The shape is WP-CORE's #/$defs/availability. #>
    param($Data, $Chosen, $Facts, $Context, $Evidence)
    $blockers = @(foreach ($d in @($Data.decisions | Where-Object { $_.type -eq 'option' })) {
            $o = Get-AvailabilityOption $d ([string]$Chosen[$d.id])
            if ($o -and $o.notDeployableByCore) { "$($d.id): $($o.notDeployableByCore)" } })
    if ($blockers.Count) { return @{ refusal = "The decisions are recorded, but no availability file for D1 to D3 was written: $($blockers -join '; ')." } }
    $primary = @($Chosen['gateway.regions'])[0]
    $capacity = [string]$Chosen['registry.capacity']
    $mode = if ($capacity -like 'serverless*') { 'serverless' } elseif ($capacity -like '*autoscale*') { 'provisioned-autoscale' } else { 'provisioned-manual' }
    $app = { param($n) [ordered]@{ alwaysReady = $Chosen["$n.alwaysReady"]; zoneRedundant = $Chosen["$n.zoneRedundancy"] -ceq 'zone-redundant'
            maximumInstanceCount = $Chosen["$n.maximumInstanceCount"]; instanceMemoryMB = [int]$Chosen["$n.instanceMemoryMB"] } }
    $file = [ordered]@{
        schemaVersion = 1; kind = 'ccof.stage0.availability'
        provenance = [ordered]@{ basis = 'stage0'; note = $Context.note; decidedBy = $Context.decidedBy; decidedAt = $Context.decidedAt; signOffSheet = $Context.signOffSheet }
        region = [ordered]@{ primary = $primary; mode = 'single-region' }
        apim = [ordered]@{ sku = $(if ($Chosen['gateway.mode'] -like 'premium*') { 'PremiumV2' } else { 'StandardV2' }); units = $Chosen['gateway.units']
            zones = @(if ($Chosen['gateway.mode'] -like '*zone-redundant') { $Facts.regions[$primary].apim.zones }) }
        registry = [ordered]@{ capacityMode = $mode
            manualThroughput = $(if ($mode -eq 'provisioned-manual') { $Chosen['registry.throughput'] } else { $null })
            autoscaleMaxThroughput = $(if ($mode -eq 'provisioned-autoscale') { $Chosen['registry.throughput'] } else { $null })
            zoneRedundant = $capacity -like '*zone-redundant'; regions = @($primary); multipleWriteLocations = $false }
        functions = [ordered]@{ resolver = & $app 'resolver'; sync = & $app 'sync'; reconciler = & $app 'reconciler' }
        storage = [ordered]@{ sku = $Chosen['functions.storage'] }
        entitlementCache = [ordered]@{ cachingType = 'internal'; allowTtlSeconds = $Chosen['entitlementCache.allowTtlSeconds']; refusalTtlSeconds = $Chosen['entitlementCache.refusalTtlSeconds']
            lastKnownGoodGraceSeconds = $Chosen['entitlementCache.lastKnownGoodGraceSeconds']; refreshBackoffSeconds = $Chosen['entitlementCache.refreshBackoffSeconds']; unavailableRetryAfterSeconds = $Chosen['entitlementCache.unavailableRetryAfterSeconds'] }
        budgetState = [ordered]@{ graceSeconds = $Chosen['budgetState.graceSeconds']; hardLimitSeconds = $Chosen['budgetState.hardLimitSeconds'] }
        telemetry = [ordered]@{ workspaceRegion = $Chosen['telemetry.workspaceRegion']; retentionDays = $Chosen['telemetry.retentionDays']
            replication = [ordered]@{ enabled = $Chosen['telemetry.replication'] -ceq 'workspace-replication'; secondaryRegion = $Chosen['telemetry.secondaryRegion'] } }
        sync = [ordered]@{ schedule = Get-AvailabilitySchedule ([int]$Chosen['sync.intervalMinutes']); leaseSeconds = $Chosen['sync.leaseSeconds']
            maxRemovalsPerRun = $Chosen['sync.maxRemovalsPerRun']; maxRemovalFraction = [decimal]::Parse([string]$Chosen['sync.maxRemovalFraction'], [Globalization.CultureInfo]::InvariantCulture) }
        evidence = $Evidence
    }
    @{ file = $file }
}

function ConvertTo-AvailabilitySignOffMarkdown {
    param([Parameter(Mandatory)] $SignOff)
    $s = $SignOff
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $cell = { param($v) ([string]$v).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ') }
    $md = [Collections.Generic.List[string]]::new()
    $md.Add('# D0 availability decisions: sign-off sheet'); $md.Add('')
    $md.Add("- Decided by (Entra object id): ``$($s.decidedBy)``, tenant ``$($s.tenantId)``, at $($s.decidedAt)")
    $md.Add("- Gateway subscription ``$($s.subscriptionId)``; backend subscription ``$($s.backendSubscriptionId)``")
    $md.Add("- Candidate regions: $(@($s.candidateRegions) -join ', '); stamp regions: $(@($s.stampRegions) -join ', ')")
    $md.Add("- Recommendations file version $($s.recommendationsVersion), SHA-256 ``$($s.recommendationsSha256)``")
    $md.Add("- Region facts read live at $($s.regionFactsReadAt) (read-only Azure Resource Manager and Azure CLI queries)")
    $md.Add("- Prices: $($s.prices.label)")
    if ($s.referencePrices) { $md.Add("- $($s.referencePrices.label)") }
    $md.Add("- $($s.explicitValues)")
    $md.Add(''); $md.Add('## Decisions'); $md.Add('')
    $md.Add('| Row | Decision | Owner | Chosen | Recommended | Follows the recommendation | Monthly list price | Impact: the uncovered failure and whom it denies, or the reason |'); $md.Add('|---|---|---|---|---|---|---|---|')
    foreach ($d in $s.decisions) {
        $rec = if ($d.recommendation.option) { $d.recommendation.option } elseif ($null -ne $d.recommendedValue) { [string]$d.recommendedValue } elseif ($d.recommendation.rule) { [string]$d.recommendation.rule } else { 'no single value; see the reason in the last column' }
        $impact = if ($d.uncovered) { $d.uncovered } else { [string]$d.recommendation.reason }
        $chosen = if ($null -eq $d.chosen) { '(not applicable)' } elseif ($d.chosen -is [array]) { $d.chosen -join ', ' } else { [string]$d.chosen }
        $follows = if ($d.follows -is [bool]) { $(if ($d.follows) { 'yes' } else { 'no' }) } else { 'rule' }
        $md.Add("| $($d.row) | $($d.id) | $(& $cell $d.owner) | $(& $cell $chosen) | $(& $cell $rec) | $follows | $(& $cell $d.monthly) | $(& $cell $impact) |")
    }
    $t = $s.totals
    $md.Add('')
    $md.Add("Total of the priced rows: USD $(([decimal]$t.monthly).ToString('N2', $inv))/month, each cost counted once, list prices before agreement discounts.")
    if (@($t.unpricedRows).Count) { $md.Add("Rows without a price ($(@($t.unpricedRows).Count)), not in the total: " + (@($t.unpricedRows | ForEach-Object { "$($_.id) ($($_.reason))" }) -join '; ') + '.') }
    else { $md.Add('Every row with a cost is priced.') }
    if ($t.reference) {
        if ($t.reference.complete) { $md.Add("Reference only: $($t.reference.currency) $(([decimal]$t.reference.monthly).ToString('N2', $inv))/month.") }
        else { $md.Add("Reference only: no $($t.reference.currency) total, because some rows have no $($t.reference.currency) price.") }
    }
    $md.Add(''); $md.Add('## Sizing inputs'); $md.Add(''); $md.Add('| Input | Value |'); $md.Add('|---|---|')
    foreach ($k in $s.sizing.Keys) { $md.Add("| $k | $(& $cell $s.sizing[$k]) |") }
    $md.Add(''); $md.Add('## Assumptions behind the prices'); $md.Add('')
    foreach ($line in @($s.assumptions)) { $md.Add("- $line") }
    $md.Add(''); $md.Add('## Decided in other stages (shown for information)'); $md.Add('')
    $md.Add('| Row | Setting | Owner | Decided in | Recommendation |'); $md.Add('|---|---|---|---|---|')
    foreach ($e in @($s.decidedElsewhere)) { $md.Add("| $($e.row) | $($e.id) | $(& $cell $e.owner) | $(& $cell $e.decidedIn) | $(& $cell $e.recommendation) |") }
    $md.Add(''); $md.Add('## Region checks (read live)'); $md.Add('')
    $md.Add('| Region | Zones | Pair | Geography | APIM v2 SKUs (max units) | Cosmos zone access | Flex zone redundancy | Azure Managed Redis | Log Analytics | Claude in backend subscription |'); $md.Add('|---|---|---|---|---|---|---|---|---|---|')
    foreach ($r in $s.regionFacts.Keys) {
        $f = $s.regionFacts[$r]
        $skus = @($f.apim.skus.Keys | Where-Object { $_ -like '*V2' } | Sort-Object | ForEach-Object { "$_ ($($f.apim.skus[$_]))" }) -join ', '
        $claude = if ($f.claude.status -ne 'ok') { 'unavailable' } elseif (@($f.claude.models).Count) { (@($f.claude.deploymentTypes) -join ', ') } else { 'none listed' }
        $md.Add("| $r | $(@($f.zones | Where-Object { $_ }).Count) | $(@($f.pairedRegions) -join ', ') | $($f.geography) | $skus | $($f.cosmos.zoneAccess) | $($f.flex.zoneRedundant) | $($f.redisEnterprise.available) | $($f.logAnalytics.available) | $claude |")
    }
    $md.Add(''); $md.Add("Availability file for D1 to D3: $($s.coreExport)"); $md.Add('')
    $md.Add('## Approval'); $md.Add(''); $md.Add('Approved by: ____________________  Role: ____________________  Date: __________')
    $md -join "`n"
}
Export-ModuleMember -Function Format-AvailabilityMoney, Format-AvailabilityPresentation, ConvertFrom-AvailabilityAnswerText, Read-AvailabilityChoice, Get-AvailabilitySchedule, New-AvailabilityCoreExport, ConvertTo-AvailabilitySignOffMarkdown
