#Requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$MutationChecks,
    [string]$SubscriptionId,
    [string]$WorkspaceId
)
$ErrorActionPreference = 'Stop'
if (-not $Execute) { throw 'Execute is required for this authenticated KQL fixture test. The default suite remains offline.' }
foreach ($entry in @{ SubscriptionId=$SubscriptionId; WorkspaceId=$WorkspaceId }.GetEnumerator()) {
    if ($entry.Value -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or
        [guid]$entry.Value -eq [guid]::Empty) { throw "$($entry.Key) must be a non-empty canonical GUID." }
}
$directory = (Get-Location).ProviderPath
if ($directory -match '[&|()<>^%!"\r\n]') { throw 'The KQL request-file directory contains unsafe az.cmd characters.' }
$source = Get-Content (Join-Path $PSScriptRoot 'ledger.kql') -Raw
$fixture = Get-Content (Join-Path $PSScriptRoot 'fixtures\ledger.kql') -Raw
$checkCount = 30
$cases = @(@{ Name='baseline'; Source=$source; ExpectedSuccess=$true })
if ($MutationChecks) {
    $mutations = @(
        @{ Name='ReadCount-zero'; Find='tolong(value), long(null))'; Replacement='tolong(value), 0)' },
        @{ Name='native-input-zero'; Find='nativeInput, long(null))'; Replacement='nativeInput, 0)' },
        @{ Name='native-output-zero'; Find='nativeOutput, long(null))'; Replacement='nativeOutput, 0)' },
        @{ Name='cache-read-zero'; Find='ReadCount(usage.cache_read_input_tokens), long(null))'; Replacement='ReadCount(usage.cache_read_input_tokens), 0)' },
        @{ Name='cache-5m-zero'; Find='ReadCount(usage.cache_creation.ephemeral_5m_input_tokens), long(null))'; Replacement='ReadCount(usage.cache_creation.ephemeral_5m_input_tokens), 0)' },
        @{ Name='cache-1h-zero'; Find='ReadCount(usage.cache_creation.ephemeral_1h_input_tokens), long(null))'; Replacement='ReadCount(usage.cache_creation.ephemeral_1h_input_tokens), 0)' },
        @{ Name='gateway-status-ignored'; Find='and ResponseCode between (200 .. 299)'; Replacement='and true' },
        @{ Name='backend-status-ignored'; Find='and BackendResponseCode between (200 .. 299)'; Replacement='and true' },
        @{ Name='error-reason-ignored'; Find='isempty(LastErrorReason)'; Replacement='true' },
        @{ Name='errors-ignored'; Find='(isnull(Errors) or array_length(Errors) == 0)'; Replacement='true' },
        @{ Name='refusal-priced'; Find='usageSource = iff(noBackendCall, "no-backend-call"'; Replacement='usageSource = iff(false, "no-backend-call"' },
        @{ Name='stream-cross-check-restored'; Find='and gettype(payload.streamed) == "bool"'; Replacement='and gettype(payload.streamed) == "bool" and tobool(payload.streamed) == nativeStreamed' },
        @{ Name='stream-cross-check-null-only'; Find='and gettype(payload.streamed) == "bool"'; Replacement='and gettype(payload.streamed) == "bool" and (isnull(nativeStreamed) or tobool(payload.streamed) == nativeStreamed)' },
        @{ Name='stream-from-log'; Find='streamed = iff(traceKnown, tobool(payload.streamed), nativeStreamed)'; Replacement='streamed = nativeStreamed' },
        @{ Name='trace-copies-split'; Find='traceVariants = make_set(traceMessage, 2) by gatewayResourceId, gatewayRequestId;'; Replacement='traceVariants = make_set(traceMessage, 2) by gatewayResourceId, gatewayRequestId, traceMessage;' },
        # WP-E2E G4: a gateway 5xx without a backend call is no usage; a backend or forwarding failure stays usage.
        @{ Name='gateway-5xx-as-usage'; Find='ResponseCode between (400 .. 599)'; Replacement='ResponseCode between (400 .. 499)' },
        @{ Name='operation-match-as-usage'; Find='or (observedErrorSource == "configuration" and LastErrorReason == "OperationNotFound")'; Replacement='or false' },
        @{ Name='not-found-any-source'; Find='observedErrorSource == "configuration" and LastErrorReason == "OperationNotFound"'; Replacement='LastErrorReason == "OperationNotFound"' },
        @{ Name='configuration-any-reason'; Find='observedErrorSource == "configuration" and LastErrorReason == "OperationNotFound"'; Replacement='observedErrorSource == "configuration"' },
        @{ Name='backend-url-ignored'; Find=' and isempty(observedBackendUrl)'; Replacement='' },
        @{ Name='forwarding-error-ignored'; Find='observedErrorSource !in ("forward-request", "set-backend-service")'; Replacement='true' },
        @{ Name='backend-status-unchecked'; Find='(isnull(BackendResponseCode) or BackendResponseCode == 0)'; Replacement='true' },
        @{ Name='any-error-section'; Find='observedErrorSection in ("", "inbound")'; Replacement='true' }
    )
    foreach ($mutation in $mutations) {
        if (-not $source.Contains($mutation.Find)) { throw "Mutation $($mutation.Name) no longer applies." }
        $cases += @{ Name=$mutation.Name; Source=$source.Replace($mutation.Find, $mutation.Replacement); ExpectedSuccess=$false }
    }
}
foreach ($case in $cases) {
    $file = Join-Path $directory ".env.tel-kql-$([guid]::NewGuid().ToString('N')).json"
    try {
        @{ query=$fixture.Replace('// __LEDGER_FUNCTION__', $case.Source) } |
            ConvertTo-Json | Set-Content -LiteralPath $file -Encoding utf8NoBOM
        $raw = & az rest --method post --subscription $SubscriptionId `
            --url "https://api.loganalytics.azure.com/v1/workspaces/$WorkspaceId/query" `
            --resource 'https://api.loganalytics.io' --body "@$file" --only-show-errors --output json
        if ($LASTEXITCODE -ne 0) { throw "KQL execution failed for $($case.Name); a broken query is not a caught mutation." }
        $result = $raw | ConvertFrom-Json
        if ($result.error) { throw "KQL returned an error for $($case.Name)." }
        $table = @($result.tables | Where-Object name -eq 'PrimaryResult')
        if ($table.Count -ne 1 -or $table[0].rows.Count -ne $checkCount -or
            $table[0].columns[0].name -ne 'test' -or $table[0].columns[1].name -ne 'passed') {
            throw "Unexpected fixture result shape for $($case.Name)."
        }
        $failed = @($table[0].rows | Where-Object { $_[1] -isnot [bool] -or $_[1] -ne $true })
        $rejected = $failed | ForEach-Object { $_[0] } | Join-String -Separator ', '
        if ($case.ExpectedSuccess -and $failed.Count -gt 0) {
            throw "Ledger fixture failed: $rejected."
        }
        if (-not $case.ExpectedSuccess -and $failed.Count -eq 0) { throw "Uncaught ledger mutation: $($case.Name)." }
        Write-Output "PASS: $($case.Name) ($checkCount checks; $($failed.Count) rejected rows$(if ($rejected) { ": $rejected" }))"
    }
    finally {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
}
