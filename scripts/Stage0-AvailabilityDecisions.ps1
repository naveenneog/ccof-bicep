#Requires -Version 7.0
<#
.SYNOPSIS
    Stage D0 (C-9): the deploying administrator's availability and sizing decisions (ADR-0014,
    decision 6). Each decision is shown with its recommendation, availability impact, list price per
    candidate region and live region checks; the administrator chooses explicitly. Read-only: it
    deploys nothing. It records the decisions through WP-ONB's decision contract and writes a
    sign-off sheet (Markdown and JSON) and the availability file that D1 to D3 consume.
.EXAMPLE
    pwsh -File scripts/Stage0-AvailabilityDecisions.ps1 -AnswersFile d0.answers.json -CheckpointPath .\state\deploy.json -DiscoverOnly
#>
[CmdletBinding()]
param([switch]$DotSourceOnly, [string]$AnswersFile, [string]$CheckpointPath, [switch]$Interactive, [switch]$DiscoverOnly,
    [string]$RecommendationsPath, [string]$BackendAzureConfigDir)
foreach ($m in @('Onboarding.Json', 'Onboarding.Decisions', 'Onboarding.Schemas', 'Onboarding.Azure', 'Availability.Common', 'Availability.Pricing', 'Availability.Regions', 'Availability.Decisions', 'Availability.Choices', 'Availability.SignOff', 'Availability.Stage0')) {
    Import-Module (Join-Path $PSScriptRoot "$m.psm1")
}

function New-Stage0ObjectSchema {
    <# Like New-OnboardingObjectSchema, keeping the property order so that prompts follow it. #>
    param([Parameter(Mandatory)] [Collections.Specialized.OrderedDictionary]$Properties)
    @{ type = 'object'; additionalProperties = $false; required = @($Properties.Keys); properties = $Properties }
}

function Get-Stage0Schema {
    param($Data, [ValidateSet('required', 'optional', 'none')] [string]$ChoiceMode)
    $guid = { param($text) @{ type = 'string'; pattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; description = $text } }
    $num = { param($min, $text) @{ type = 'number'; minimum = $min; description = $text } }
    $positive = { param($text) @{ type = 'number'; exclusiveMinimum = 0; description = $text } }
    $zones = @($Data.conventions.edgeBillingZones | ForEach-Object { "$_ = $($Data.conventions.edgeBillingZoneLabels[$_])" }) -join '; '
    $sizing = [ordered]@{
        peakRequestsPerSecond = & $positive 'peak gateway requests per second across all stamps; no value is assumed'
        apimUnitCapacityRequestsPerSecond = & $positive 'requests per second one APIM unit serves for this workload'
        apimUnitCapacitySource = @{ enum = @('load-test', 'estimate'); description = 'load-test if the per-unit capacity was measured (P-12), estimate otherwise' }
        monthlyRequests = @{ type = 'integer'; minimum = 0; description = 'gateway requests per month' }
        edgeBillingZone = @{ enum = @($Data.conventions.edgeBillingZones); description = "Front Door billing zone of most users: $zones" }
        edgeEgressGBPerMonth = & $num 0 'Front Door data out to clients, GB per month'
        edgeToOriginGBPerMonth = & $num 0 'Front Door data from the edge to the gateway, GB per month'
        registryPeakReadsPerSecond = & $num 0 'peak registry reads per second'; registryRuPerRead = & $positive 'request units per registry read'
        registryPeakWritesPerSecond = & $num 0 'peak registry writes per second'; registryRuPerWrite = & $positive 'request units per registry write'
        registryStorageGB = & $num 0 'registry storage, GB'; registryMonthlyRequestUnits = & $num 0 'registry request units per month (serverless pricing)'
        resolverExecutionsPerMonth = @{ type = 'integer'; minimum = 0; description = 'resolver executions per month' }
        resolverAverageDurationMs = & $positive 'average resolver execution time, milliseconds'
        resolverConcurrentExecutionsPerInstance = @{ type = 'number'; minimum = 1; description = 'concurrent resolver executions one instance runs' }
        functionsStorageGB = & $num 0 'Functions storage account data, GB'; logIngestionGBPerMonth = & $num 0 'Log Analytics ingestion, GB per month'
        privateEndpointsPerStamp = @{ type = 'integer'; minimum = 0; description = 'private endpoints in each stamp' }
        privateEndpointIngressGBPerMonth = & $num 0 'private endpoint data in, GB per month in each stamp'; privateEndpointEgressGBPerMonth = & $num 0 'private endpoint data out, GB per month in each stamp'
    }
    $properties = [ordered]@{
        subscriptionId = & $guid 'gateway subscription (APIM, Cosmos DB, Functions), read only'; tenantId = & $guid 'tenant of the signed-in administrator'
        backendSubscriptionId = & $guid 'subscription holding the Claude deployments, read only'
        candidateRegions = @{ type = 'array'; minItems = 1; maxItems = 10; uniqueItems = $true; items = @{ type = 'string'; pattern = '^[a-z0-9]{2,40}$' }; description = 'Azure region names as Azure Resource Manager writes them: lowercase, no spaces' }
        referenceCurrency = @{ oneOf = @(@{ type = 'string'; pattern = '^[A-Z]{3}$' }, @{ type = 'null' }); description = 'a currency code such as INR for reference prices; for none, type none, or write null in an answers file' }
        sizing = (New-Stage0ObjectSchema $sizing)
    }
    $choices = [ordered]@{}
    foreach ($d in @($Data.decisions | Where-Object { $_.stage -eq '0' -and $_.type -ne 'info' })) {
        $choices[$d.id] = switch ($d.type) {
            'option' { @{ enum = @(@($d.options | ForEach-Object { $_.id }) + @($null)) } }
            'integer' { @{ type = @('integer', 'null') } }
            'decimal' { @{ type = @('string', 'number', 'null') } }
            'regions' { @{ type = @('array', 'null'); items = @{ type = 'string' }; description = 'a list of region names from candidateRegions, primary first' } }
            'region' { @{ type = @('string', 'null'); description = 'a region name from candidateRegions' } }
            'sku' { @{ type = @('string', 'null'); description = 'a SKU name such as B5 or M10' } }
            default { @{ type = @('string', 'null') } }
        }
    }
    if ($ChoiceMode -eq 'required') { $properties.choices = New-Stage0ObjectSchema $choices }
    $schema = New-Stage0ObjectSchema $properties
    if ($ChoiceMode -eq 'optional') { $schema.properties.choices = @{ type = 'object'; additionalProperties = $false; properties = $choices } }
    $schema
}

function Get-Stage0Digest {
    param($Snapshot, $Facts, $Data, [string[]]$Regions, [string]$RecommendationsSha256, $Answers)
    $sha = { param($v) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-OnboardingCanonical $v)))).ToLowerInvariant() }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $items = @($Snapshot.items | Sort-Object meterId, armRegionName, { [decimal]$_.tierMinimumUnits } | ForEach-Object {
            [ordered]@{ meterId = $_.meterId; armRegionName = $_.armRegionName; serviceName = $_.serviceName; productName = $_.productName; skuName = $_.skuName
                meterName = $_.meterName; unitOfMeasure = $_.unitOfMeasure; tierMinimumUnits = ([decimal]$_.tierMinimumUnits).ToString($inv)
                unitPrice = ([decimal]$_.unitPrice).ToString($inv); effectiveStartDate = [string]$_.effectiveStartDate; currencyCode = $_.currencyCode } })
    # The inputs are bound too: the review shows prices and sizing results for these values only.
    $inputs = [ordered]@{ subscriptionId = $Answers.subscriptionId; tenantId = $Answers.tenantId; backendSubscriptionId = $Answers.backendSubscriptionId; referenceCurrency = $Answers.referenceCurrency; sizing = $Answers.sizing }
    [ordered]@{ recommendationsVersion = $Data.dataVersion; recommendationsSha256 = $RecommendationsSha256; candidateRegions = @($Regions); inputsSha256 = & $sha $inputs; currency = $Snapshot.currency
        priceItems = $items.Count; pricesSha256 = & $sha $items; regionFactsSha256 = & $sha ([ordered]@{ reads = $Facts.reads; regions = $Facts.regions }) }
}

function Get-Stage0Prerequisites {
    <# Decisions whose refusal leaves this one unverifiable: it is then reported as not checked instead of checked against a wrong context. #>
    param($Decision)
    $ids = [Collections.Generic.List[string]]::new()
    if ($Decision.appliesTo) { foreach ($k in $Decision.appliesTo.Keys) { $ids.Add($k) } }
    foreach ($k in @($Decision.costOf, $Decision.bearingFrom, $Decision.atLeast, $Decision.atMostWhenPositive, $Decision.minWhenZoneRedundant.decision)) { if ($k) { $ids.Add($k) } }
    # @($null).Count is 1: drop the null that an absent options list yields before counting.
    $options = @($Decision.options | Where-Object { $null -ne $_ })
    foreach ($o in $options) { if ($o.recheck) { $ids.Add($o.recheck) } }
    # Constraint tokens that read another decision's choice (Test-AvailabilityConstraint).
    $reads = @{ skuNot = 'cache.sku'; topology = 'gateway.topology'; notServerless = 'registry.capacity'; laReplicationSecondary = 'telemetry.workspaceRegion'; minStampRegions = 'gateway.regions' }
    foreach ($c in @($options | ForEach-Object { $_.constraints }) + @($Decision.constraints)) { if ($c) { $name = ([string]$c).Split(':')[0]; if ($reads.ContainsKey($name)) { $ids.Add($reads[$name]) } } }
    $constrained = @($options | Where-Object { @($_.constraints | Where-Object { $_ }).Count -or $_.bearing -or $_.recheck }).Count
    $regional = $Decision.type -in @('region', 'sku') -or $Decision.maxFact -or $constrained -or $Decision.cost -or $Decision.bearing -or $Decision.bearingFrom
    if ($Decision.id -ceq 'gateway.regions') { $ids.Add('gateway.topology') } elseif ($regional -and $Decision.id -cne 'gateway.topology') { $ids.Add('gateway.regions') }
    @($ids | Where-Object { $_ -cne $Decision.id } | Sort-Object -Unique)
}

function Format-Stage0NextSteps {
    param($Digest)
    @(
        '', 'Discovery only: no decision was recorded, and no sign-off or availability file was written; the audit file records the run.'
        'Rows that wait for an earlier choice are priced when the review is run again with those choices filled in under decisions.choices.'
        'To decide unattended, put this digest at the top level of the answers file as "confirmedDiscovery", next to "decisions", add "confirm": true there, give a value for every choice under decisions.choices, and run again without -DiscoverOnly:'
        ($Digest | ConvertTo-Json -Depth 8)
        'To decide at the keyboard, run again with -Interactive instead of -AnswersFile.'
        'The digest changes when an input, a list price, a region fact or the recommendations file changes; D0 then refuses and a new review is needed. The answers shape is in docs/HA-DECISIONS.md section 7.'
    ) -join [Environment]::NewLine
}

function Get-Stage0ShapeText {
    <# What a value must be, in words, from its schema. The choice schemas admit null for every choice; D0 accepts
       it only for a choice that does not apply (Test-AvailabilityChoice), so the caller says when to offer it. #>
    param($Shape, [switch]$NullWhereNotApplicable)
    $types = @($Shape.type)
    $rules = [Collections.Generic.List[string]]::new()
    if ($Shape.description) { $rules.Add([string]$Shape.description) }
    if ([string]$Shape.pattern -like '^`[0-9a-fA-F`]{8}*') { $rules.Add('a GUID') }
    if ($types -contains 'integer') { $rules.Add('a whole number') } elseif ($types -contains 'number') { $rules.Add('a number') }
    if ($null -ne $Shape.minimum) { $rules.Add("at least $($Shape.minimum)") }
    if ($null -ne $Shape.exclusiveMinimum) { $rules.Add("above $($Shape.exclusiveMinimum)") }
    if ($Shape.enum) { $rules.Add('one of ' + (@($Shape.enum | Where-Object { $null -ne $_ }) -join ', ')) }
    $text = $rules -join '; '
    if ($NullWhereNotApplicable) { $text += ', or null where it does not apply' }
    $text
}

function Test-Stage0AnswersFile {
    <# Names each problem of a D0 answers file by its path before WP-ONB's runner reads it. Missing values
       are left to the runner, which lists them together. #>
    param($Data, [string]$Path, [hashtable]$Schema)
    try { $answers = ConvertFrom-OnboardingJson (Get-Content -LiteralPath $Path -Raw) } catch { return @() }
    if ($answers -isnot [Collections.IDictionary]) { return @() }
    $problems = [Collections.Generic.List[string]]::new()
    foreach ($key in @($answers.Keys)) { if (@('schemaVersion', 'decisions', 'confirm', 'confirmedDiscovery', 'provenance') -cnotcontains $key) { $problems.Add("$($key): not an answers-file key; remove it") } }
    if ($answers.Contains('schemaVersion') -and -not ($answers.schemaVersion -is [long] -and $answers.schemaVersion -eq 1)) { $problems.Add('schemaVersion: expected 1') }
    if ($answers.Contains('confirm') -and $answers.confirm -isnot [bool]) { $problems.Add('confirm: expected true, to record the decisions') }
    if ($answers.Contains('confirmedDiscovery') -and $answers.confirmedDiscovery -isnot [Collections.IDictionary]) { $problems.Add('confirmedDiscovery: expected the digest object that the -DiscoverOnly review prints') }
    if ($answers.Contains('provenance')) {
        $problems.Add("provenance: D0 records the deploying administrator's own decisions, so an answers file marked as defaults is refused; remove provenance once the administrator has set every value")
    }
    if (-not $answers.Contains('decisions')) { return @($problems) }
    if ($answers.decisions -isnot [Collections.IDictionary]) { $problems.Add('decisions: expected an object with the inputs and the choices'); return @($problems) }
    $info = @{}; foreach ($d in @($Data.decisions | Where-Object { $_.type -eq 'info' })) { $info[$d.id] = $d.decidedIn }
    $conditional = @($Data.decisions | Where-Object { $_.appliesTo } | ForEach-Object { $_.id })
    $errors = $null
    $null = Test-Json -Json (ConvertTo-Json -InputObject $answers.decisions -Depth 64 -Compress) -Schema (ConvertTo-Json -InputObject $Schema -Depth 64 -Compress) -ErrorVariable errors -ErrorAction SilentlyContinue
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($e in @($errors)) {
        $m = [regex]::Match([string]$e.Exception.Message, "^(?:The JSON is not valid with the schema: )?(?<what>.*) at '(?<path>[^']*)'$")
        if (-not $m.Success) { continue }
        $what = $m.Groups['what'].Value
        if ($what -like 'Required properties*') { continue }
        # An error inside a list is reported on the list, with what the list must hold.
        $segments = [Collections.Generic.List[string]]::new()
        foreach ($s in @($m.Groups['path'].Value.Split('/') | Where-Object { $_ })) { if ($s -match '^\d+$') { break }; $segments.Add($s) }
        $path = (@('decisions') + $segments) -join '.'
        if (-not $seen.Add($path)) { continue }
        $shape = $Schema; $value = $answers.decisions
        foreach ($s in $segments) {
            $shape = if ($shape -and $shape.properties -and $shape.properties.Contains($s)) { $shape.properties[$s] } else { $null }
            # Assigned in each branch: an if expression would unwrap a one-item list into its item, and the re-check below would pass the item.
            if ($value -is [Collections.IDictionary] -and $value.Contains($s)) { $value = $value[$s] } else { $value = $null }
        }
        $choiceId = if ($segments.Count -eq 2 -and $segments[0] -ceq 'choices') { $segments[1] } else { $null }
        if ($choiceId -and $info.ContainsKey($choiceId)) { $problems.Add("$($path): decided in $($info[$choiceId]), not in D0; remove it"); continue }
        if (-not $shape) { $problems.Add("$($path): not a D0 input; remove it"); continue }
        # A failing document also reports the failed branches of a passing oneOf; re-check the value alone.
        if (Test-Json -Json (ConvertTo-Json -InputObject $value -Depth 64 -Compress) -Schema (ConvertTo-Json -InputObject $shape -Depth 64 -Compress) -ErrorAction SilentlyContinue) { continue }
        $expected = Get-Stage0ShapeText $shape -NullWhereNotApplicable:($conditional -ccontains $choiceId)
        $problems.Add("$($path): expected $(if ($expected) { $expected } else { $what })")
    }
    @($problems)
}
function Invoke-Stage0AvailabilityDecisions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$CheckpointPath, [string]$AnswersFile, [switch]$Interactive, [switch]$DiscoverOnly, [string]$RecommendationsPath,
        [scriptblock]$Prompt, [scriptblock]$ReadLine, [scriptblock]$GetIdentity, [scriptblock]$GetCurrentAssignments, [hashtable]$RegionOperations,
        [scriptblock]$PriceSend, [scriptblock]$Clock, [string]$BackendAzureConfigDir
    )
    # [IO.File] resolves relative paths against the process directory; resolve them against the current location.
    $CheckpointPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CheckpointPath)
    if ($AnswersFile) { $AnswersFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($AnswersFile) }
    if (-not $RecommendationsPath) { $RecommendationsPath = Join-Path $PSScriptRoot '../config/ha-recommendations.json' }
    $RecommendationsPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RecommendationsPath)
    $data = Import-AvailabilityRecommendations $RecommendationsPath
    $recommendationsSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($RecommendationsPath))).ToLowerInvariant()
    if (-not $Clock) { $Clock = { [DateTimeOffset]::UtcNow } }
    if (-not $ReadLine) { $ReadLine = { param($label) Read-Host $label } }
    if (-not $RegionOperations) { $RegionOperations = New-AvailabilityRegionOperations -BackendAzureConfigDir $BackendAzureConfigDir }
    $run = @{ Stage = 'D0'; Schema = (Get-Stage0Schema $data -ChoiceMode $(if ($Interactive) { 'none' } elseif ($DiscoverOnly) { 'optional' } else { 'required' })); CheckpointPath = $CheckpointPath
        AnswersFile = $AnswersFile; Interactive = $Interactive; DiscoverOnly = $DiscoverOnly }
    $run.Prompt = if ($Prompt) { $Prompt } else { New-Stage0Prompt $ReadLine }
    if ($GetIdentity) { $run.GetIdentity = $GetIdentity }
    $body = {
        param($c)
        $c.StageId = 'stage-D0'
        $a = $c.Decisions
        Assert-OnboardingRole $c "/subscriptions/$($a.subscriptionId)" @('Reader', 'Contributor', 'Owner') $GetCurrentAssignments
        $regions = @($a.candidateRegions)
        $facts = Get-AvailabilityRegionFacts -SubscriptionId $a.subscriptionId -BackendSubscriptionId $a.backendSubscriptionId -Regions $regions -Operations $RegionOperations
        $queries = Get-AvailabilityPriceQueries -CostModels $data.costModels -Regions $regions -BillingZone $a.sizing.edgeBillingZone -Currency 'USD'
        $snapshot = New-AvailabilityPriceSnapshot -Queries $queries -Send $PriceSend -Currency 'USD' -RetrievedAt (& $Clock)
        $reference = $null
        if ($a.referenceCurrency) {
            $refQueries = Get-AvailabilityPriceQueries -CostModels $data.costModels -Regions $regions -BillingZone $a.sizing.edgeBillingZone -Currency $a.referenceCurrency
            $reference = New-AvailabilityPriceSnapshot -Queries $refQueries -Send $PriceSend -Currency $a.referenceCurrency -RetrievedAt (& $Clock)
        }
        $digest = Get-Stage0Digest $snapshot $facts $data $regions $recommendationsSha $a
        $retrievedAt = [DateTimeOffset]::Parse([string]$snapshot.retrievedAt, [Globalization.CultureInfo]::InvariantCulture)
        $freshness = Get-PriceFreshness -RetrievedAt $retrievedAt -DecidedAt (& $Clock)
        $priceLabel = "$(Get-AvailabilityCurrencyLabel 'USD'). $($freshness.Label)"
        $shownDecisions = @($data.decisions | Where-Object { $_.stage -eq '0' -or $_.type -eq 'info' })
        $answerChoices = if ($a.Contains('choices')) { $a.choices } else { @{} }
        if (-not (Confirm-OnboardingDiscovery $c $digest)) {
            $chosen = [ordered]@{}; $shown = @()
            foreach ($d in $shownDecisions) {
                $shown += Get-AvailabilityPresentation -Data $data -Decision $d -Sizing $a.sizing -Chosen $chosen -Facts $facts -Snapshot $snapshot -Candidates $regions
                if ($d.type -ne 'info' -and $answerChoices.Contains($d.id) -and $null -ne $answerChoices[$d.id]) {
                    $t = Test-AvailabilityChoice -Data $data -Decision $d -Value $answerChoices[$d.id] -Sizing $a.sizing -Chosen $chosen -Facts $facts -Snapshot $snapshot -Candidates $regions
                    if ($t.Allowed) { $chosen[$d.id] = $t.Value }
                }
            }
            foreach ($p in $shown) { Write-Host (Format-AvailabilityPresentation $p $priceLabel) }
            Write-Host (Format-Stage0NextSteps $digest)
            $c.Discovery = [ordered]@{ confirmedDiscovery = $digest; prices = $priceLabel; stale = $freshness.Stale; presentations = $shown; regionFacts = $facts.regions }
            return
        }
        $chosen = [ordered]@{}; $records = @(); $refused = @(); $refusedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $present = { param($d) Get-AvailabilityPresentation -Data $data -Decision $d -Sizing $a.sizing -Chosen $chosen -Facts $facts -Snapshot $snapshot -Candidates $regions }
        foreach ($d in $shownDecisions) {
            # Unattended runs were reviewed with -DiscoverOnly, so only the interactive run presents each decision again.
            if ($d.type -eq 'info') { if ($c.Interactive) { Write-Host (Format-AvailabilityPresentation (& $present $d) $priceLabel) }; continue }
            $blockedBy = @(Get-Stage0Prerequisites $d | Where-Object { $refusedIds.Contains($_) })
            if ($blockedBy.Count) { $refused += "$($d.id): not checked, because $($blockedBy -join ', ') was refused"; [void]$refusedIds.Add($d.id); continue }
            $validate = { param($v) Test-AvailabilityChoice -Data $data -Decision $d -Value $v -Sizing $a.sizing -Chosen $chosen -Facts $facts -Snapshot $snapshot -Candidates $regions }
            if (-not (Test-AvailabilityApplies $d $chosen)) { $check = & $validate $(if ($c.Interactive) { $null } else { $answerChoices[$d.id] }) }
            elseif ($c.Interactive) { $check = Read-AvailabilityChoice -Decision $d -Text (Format-AvailabilityPresentation (& $present $d) $priceLabel) -Validate $validate -ReadLine $ReadLine }
            else { $check = & $validate $answerChoices[$d.id] }
            if (-not $check.Allowed) {
                $refused += "$($d.id): " + (@($check.Refusals | ForEach-Object { "$(if ($_.region) { "$($_.region) " })$($_.code) ($($_.reason))" }) -join '; ')
                [void]$refusedIds.Add($d.id); continue
            }
            $chosen[$d.id] = $check.Value
            $records += , @($d, $check.Value)
        }
        if ($refused.Count) {
            Stop-Availability 'choice_refused' "These choices were refused: $($refused -join ' | '). No availability decision, sign-off or availability file was written; the inputs given are recorded in the checkpoint as answers."
        }
        $decidedAt = (& $Clock).ToUniversalTime()
        $atDecision = Get-PriceFreshness -RetrievedAt $retrievedAt -DecidedAt $decidedAt
        $decisionLabel = "$(Get-AvailabilityCurrencyLabel 'USD'). $($atDecision.Label)"
        if ($atDecision.Stale) { Write-Host $atDecision.Label }
        $signOff = New-Stage0SignOff -Data $data -Records $records -Chosen $chosen -Facts $facts -Snapshot $snapshot -Reference $reference -Answers $a -Context $c -DecidedAt $decidedAt `
            -Freshness $atDecision -PriceLabel $decisionLabel -Regions $regions -CheckpointPath $CheckpointPath -RecommendationsSha256 $recommendationsSha
        foreach ($r in $records) {
            Add-OnboardingDecision $c "availability.$($r[0].id)" $signOff.decisionRecords[$r[0].id] $c.Source
        }
        Add-OnboardingDecision $c 'availability.priceSnapshot' $snapshot 'confirmed_discovery'
        if ($reference) { Add-OnboardingDecision $c 'availability.referencePriceSnapshot' $reference 'confirmed_discovery' }
        Add-OnboardingDecision $c 'availability.regionFacts' $facts 'confirmed_discovery'
        $paths = @{ md = "$CheckpointPath.d0-signoff.md"; json = "$CheckpointPath.d0-signoff.json"; core = "$CheckpointPath.d0-availability.json" }
        $export = New-AvailabilityCoreExport $data $chosen $facts @{ note = "D0 decisions; recommendations $($data.dataVersion); list prices retrieved $($atDecision.RetrievedAt)"
            decidedBy = $c.Actor.objectId; decidedAt = $signOff.sheet.decidedAt; signOffSheet = $paths.md } $signOff.evidence
        $signOff.sheet.coreExport = if ($export.file) { $paths.core } else { $export.refusal }
        Invoke-OnboardingWrite $c 'write_signoff' 'd0-signoff' {
            [IO.File]::WriteAllText($paths.json, ($signOff.sheet | ConvertTo-Json -Depth 64), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($paths.md, (ConvertTo-AvailabilitySignOffMarkdown $signOff.sheet), [Text.UTF8Encoding]::new($false))
        }.GetNewClosure() | Out-Null
        if ($export.file) {
            Invoke-OnboardingWrite $c 'write_availability_file' 'd0-availability' { [IO.File]::WriteAllText($paths.core, ($export.file | ConvertTo-Json -Depth 64), [Text.UTF8Encoding]::new($false)) }.GetNewClosure() | Out-Null
        }
        @{ signOffMarkdown = $paths.md; signOffJson = $paths.json; availabilityFile = $(if ($export.file) { $paths.core } else { $null }); availabilityFileRefusal = $export.refusal
            decisions = $records.Count; monthlyListPriceUSD = $signOff.sheet.totals.monthly; unpricedRows = @($signOff.sheet.totals.unpricedRows).Count
            pricesRetrievedAt = $atDecision.RetrievedAt; pricesStale = $atDecision.Stale; pricesSha256 = $digest.pricesSha256; regionFactsSha256 = $digest.regionFactsSha256; recommendationsSha256 = $recommendationsSha }
    }.GetNewClosure()
    if ($AnswersFile -and -not $Interactive -and (Test-Path -LiteralPath $AnswersFile)) {
        $problems = @(Test-Stage0AnswersFile $data $AnswersFile $run.Schema)
        if ($problems.Count) {
            $context = @{ RunId = [guid]::NewGuid().ToString(); StageId = 'stage-D0'; CheckpointPath = $CheckpointPath; Actor = $null }
            Write-OnboardingAudit $context 'stage_start'
            Write-OnboardingAudit $context 'precondition_refused' @{ reasonCode = 'answers_invalid' }
            return [pscustomobject]@{ Satisfied = $false; StageId = 'stage-D0'; ReasonCode = 'answers_invalid'
                Remedy = "The answers file was refused before any Azure read and before any decision was recorded (the audit file records the refusal): $($problems -join '; '). The answers shape is in docs/HA-DECISIONS.md section 7." }
        }
    }
    Invoke-OnboardingRun @run -Body $body
}

if (-not $DotSourceOnly) {
    if (-not $CheckpointPath) { Write-Host 'D0 needs -CheckpointPath: the deployment record file that the later stages read. Nothing was read or written.'; exit 2 }
    $params = @{ AnswersFile = $AnswersFile; CheckpointPath = $CheckpointPath; Interactive = $Interactive; DiscoverOnly = $DiscoverOnly; RecommendationsPath = $RecommendationsPath; BackendAzureConfigDir = $BackendAzureConfigDir }
    $result = Invoke-Stage0AvailabilityDecisions @params
    if ($result.DiscoveryOnly) { [ordered]@{ Satisfied = $result.Satisfied; DiscoveryOnly = $true; confirmedDiscovery = $result.Discovery.confirmedDiscovery; prices = $result.Discovery.prices } | ConvertTo-Json -Depth 16 }
    else { $result | ConvertTo-Json -Depth 64 }
    if (-not $result.Satisfied) { exit 1 }
}
