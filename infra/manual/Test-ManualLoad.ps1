#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$GatewayConfigPath,
    [string]$ClientConfigPath,
    [ValidateRange(1, 200)] [int]$Requests = 20,
    [ValidateRange(1, 16)] [int]$Concurrency = 4,
    [ValidateRange(1, 600000)] [int]$P95BudgetMilliseconds,
    [ValidateRange(30, 600)] [int]$MaximumDurationSeconds = 300,
    [switch]$Confirmed,
    [switch]$DotSourceOnly
)

function Get-ManualLoadSummary {
    param([AllowEmptyCollection()] [object[]]$Samples, [int]$ExpectedRequests, [int]$P95BudgetMilliseconds)
    $durations = @($Samples | ForEach-Object { [double]$_.elapsedMs } | Sort-Object)
    $p95 = if ($durations.Count) { $durations[[int][Math]::Ceiling($durations.Count * 0.95) - 1] } else { $null }
    $failed = @($Samples | Where-Object { $_.status -ne 200 }).Count
    [ordered]@{
        schema = 'ccof.manual-load.v1'; requested = $ExpectedRequests; completed = $Samples.Count
        failedRequests = $failed; p95Milliseconds = $p95; p95BudgetMilliseconds = $P95BudgetMilliseconds
        statusCounts = @($Samples | Group-Object status | ForEach-Object { @{ status = $_.Name; count = $_.Count } })
        passed = ($ExpectedRequests -gt 0 -and $Samples.Count -eq $ExpectedRequests -and
            $failed -eq 0 -and $null -ne $p95 -and $p95 -le $P95BudgetMilliseconds)
    }
}

if ($DotSourceOnly) { return }
$ErrorActionPreference = 'Stop'
if (-not $Confirmed) { throw 'manual_load_confirmation_required: synthetic Foundry requests incur cost; use -Confirmed after reviewing limits' }
if (-not $P95BudgetMilliseconds) { throw 'manual_load_budget_required: explicitly choose -P95BudgetMilliseconds' }
if ($Concurrency -gt $Requests) { throw 'manual_load_concurrency_exceeds_requests' }
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
# Preserve caller arguments: a dot-sourced script's parameter block otherwise resets same-name values.
. (Join-Path $root 'scripts\Test-OwnerSmoke.ps1') -GatewayConfigPath $GatewayConfigPath -ClientConfigPath $ClientConfigPath -DotSourceOnly
$settings = Read-OwnerSmokeSettings -GatewayConfigPath $GatewayConfigPath -ClientConfigPath $ClientConfigPath
$token = $null
try {
    $token = Get-OwnerSmokeToken -ClientConfigPath $settings.ClientConfigPath -TimeoutSeconds $settings.TokenTimeoutSeconds
    $url = $settings.Url
    $headers = @{}
    if ($settings.AnthropicVersion) { $headers['anthropic-version'] = $settings.AnthropicVersion }
    if ($settings.Project) { $headers[$settings.Project.header] = $settings.Project.id }
    $body = @{ model = $settings.Model; max_tokens = 8
        messages = @(@{ role = 'user'; content = 'Reply with OK' })
    } | ConvertTo-Json -Depth 5 -Compress
    $timeout = [Math]::Min(30, $settings.TimeoutSeconds)
    $samples = @(1..$Requests | ForEach-Object -Parallel {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $status = 0
        try {
            $response = Invoke-WebRequest -Uri $using:url -Method Post -Authentication Bearer -Token $using:token `
                -Headers $using:headers -Body $using:body -ContentType 'application/json' `
                -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec $using:timeout
            $status = [int]$response.StatusCode
            $response = $null
        } catch { $status = 0 }
        $clock.Stop()
        @{ status = $status; elapsedMs = [Math]::Round($clock.Elapsed.TotalMilliseconds, 2) }
    } -ThrottleLimit $Concurrency -TimeoutSeconds $MaximumDurationSeconds)
    $report = Get-ManualLoadSummary -Samples $samples -ExpectedRequests $Requests -P95BudgetMilliseconds $P95BudgetMilliseconds
    $report | ConvertTo-Json -Depth 5 -Compress | Write-Output
    if (-not $report.passed) { exit 1 }
} catch {
    @{ schema = 'ccof.manual-load.v1'; passed = $false; reason = 'token_transport_or_time_limit_failed' } |
        ConvertTo-Json -Compress | Write-Output
    exit 1
} finally { $token = $null }
