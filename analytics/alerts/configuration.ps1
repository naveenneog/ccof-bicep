#Requires -Version 7.0
function Assert-AlertFields($Value, [string[]]$Fields, [string]$Name) {
    if ($Value -isnot [System.Collections.IDictionary]) { throw "$Name must be a JSON object." }
    foreach ($field in $Fields) {
        if (-not $Value.Contains($field)) { throw "$Name requires $field." }
    }
    foreach ($field in $Value.Keys) {
        if ($Fields -cnotcontains $field) { throw "$Name contains an unknown field." }
    }
}

function Assert-AlertInteger($Value, [long]$Minimum, [long]$Maximum, [string]$Name) {
    if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt $Minimum -or $Value -gt $Maximum) {
        throw "$Name must be an integer between $Minimum and $Maximum."
    }
}

function Assert-AlertName($Value, [string]$Name, [int]$MaximumLength = 80) {
    if ($Value -isnot [string] -or $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' -or
        $Value.Length -gt $MaximumLength) { throw "$Name must be a safe identifier of 1-$MaximumLength characters." }
}

function Assert-TelemetryAlertConfiguration($Configuration) {
    $c = $Configuration
    Assert-AlertFields $c @('schemaVersion', 'configurationId', 'actionGroup', 'evaluationFrequencyMinutes',
        'windowMinutes', 'resolverLatencyPercentile', 'failingPeriods', 'rules') 'AlertConfigurationPath'
    Assert-AlertInteger $c.schemaVersion 1 1 'schemaVersion'
    Assert-AlertName $c.configurationId 'configurationId'
    Assert-AlertInteger $c.evaluationFrequencyMinutes 1 1440 'evaluationFrequencyMinutes'
    Assert-AlertInteger $c.windowMinutes $c.evaluationFrequencyMinutes 2880 'windowMinutes'
    Assert-AlertInteger $c.resolverLatencyPercentile 1 100 'resolverLatencyPercentile'
    Assert-AlertFields $c.failingPeriods @('minFailingPeriodsToAlert', 'numberOfEvaluationPeriods') 'failingPeriods'
    Assert-AlertInteger $c.failingPeriods.numberOfEvaluationPeriods 1 ([int]::MaxValue) 'numberOfEvaluationPeriods'
    Assert-AlertInteger $c.failingPeriods.minFailingPeriodsToAlert 1 $c.failingPeriods.numberOfEvaluationPeriods 'failingPeriods.minFailingPeriodsToAlert'

    $group = $c.actionGroup
    Assert-AlertFields $group @('name', 'shortName', 'location', 'emailReceivers') 'actionGroup'
    Assert-AlertName $group.name 'actionGroup.name'
    Assert-AlertName $group.shortName 'actionGroup.shortName' 12
    Assert-AlertName $group.location 'actionGroup.location'
    if ($group.emailReceivers -isnot [array] -or $group.emailReceivers.Count -eq 0) {
        throw 'actionGroup.emailReceivers must contain administrator-selected recipients.'
    }
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $addresses = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($receiver in $group.emailReceivers) {
        Assert-AlertFields $receiver @('name', 'emailAddress', 'useCommonAlertSchema') 'emailReceivers'
        Assert-AlertName $receiver.name 'emailReceivers.name'
        if (-not $names.Add($receiver.name)) { throw 'emailReceivers names must be unique.' }
        if ($receiver.emailAddress -isnot [string] -or
            $receiver.emailAddress -notmatch '^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$') {
            throw 'emailReceivers.emailAddress must be an email address without a display name.'
        }
        try { $parsed = [System.Net.Mail.MailAddress]::new($receiver.emailAddress) }
        catch { throw 'emailReceivers.emailAddress is invalid.' }
        if ($parsed.Address -cne $receiver.emailAddress) { throw 'emailReceivers.emailAddress must be a plain address.' }
        if (-not $addresses.Add($receiver.emailAddress)) { throw 'emailReceivers addresses must be unique.' }
        if ($receiver.useCommonAlertSchema -isnot [bool] -or -not $receiver.useCommonAlertSchema) {
            throw 'emailReceivers.useCommonAlertSchema must be true.'
        }
    }

    $signals = @('gateway-5xx', 'gateway-429', 'backend-failures', 'resolver-failures',
        'resolver-latency', 'budget-degraded', 'missing-telemetry')
    if ($c.rules -isnot [array] -or $c.rules.Count -ne $signals.Count) {
        throw 'rules must contain all seven operational signals.'
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($rule in $c.rules) {
        Assert-AlertFields $rule @('signal', 'threshold', 'minimumSamples', 'severity') 'rules'
        if ($signals -cnotcontains $rule.signal) { throw 'rules.signal is not a supported operational signal.' }
        if (-not $seen.Add($rule.signal)) { throw 'rules.signal values must be unique.' }
        Assert-AlertInteger $rule.threshold 1 ([int]::MaxValue) 'rules.threshold'
        Assert-AlertInteger $rule.severity 0 4 'rules.severity'
        if ($rule.signal -eq 'missing-telemetry') {
            Assert-AlertInteger $rule.threshold 1 $c.windowMinutes 'missing-telemetry.threshold'
            Assert-AlertInteger $rule.minimumSamples 0 0 'missing-telemetry.minimumSamples'
        }
        else {
            Assert-AlertInteger $rule.minimumSamples 1 ([int]::MaxValue) 'rules.minimumSamples'
            if ($rule.signal -in @('gateway-5xx', 'gateway-429', 'backend-failures', 'resolver-failures')) {
                Assert-AlertInteger $rule.threshold 1 10000 'rate threshold (basis points)'
            }
        }
    }
}

function Read-TelemetryAlertConfiguration([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'AlertConfigurationPath must name an existing administrator-supplied JSON file.'
    }
    try { $text = Get-Content -LiteralPath $Path -Raw; $values = $text | ConvertFrom-Json -AsHashtable }
    catch { throw 'AlertConfigurationPath could not be read as JSON.' }
    Assert-TelemetryAlertConfiguration $values
    @{
        Values = $values
        Digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
    }
}
