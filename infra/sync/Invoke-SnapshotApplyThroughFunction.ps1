#Requires -Version 7.0
<#
.SYNOPSIS
    Applies a delegated group snapshot (docs/SYNC.md) through the sync Function App's snapshotApply
    function, without a runner VM: for a tenant that allows no VM and whose Cosmos DB has public
    network access disabled, so neither the runner nor the workstation can reach Cosmos.

.DESCRIPTION
    Checks the snapshot file against -ExpectedSnapshotSha256 (the hash the snapshot command printed)
    before any az call, then sets on the sync app: CCOF_SYNC_SNAPSHOT (base64), CCOF_SYNC_SNAPSHOT_SHA256,
    the four SYNC_SNAPSHOT_MAX_* limits and AzureWebJobs.snapshotApply.Disabled=false (one restart).
    Asks for a trigger sync, and again while snapshotApply is not listed (an instance that started
    before the settings registers no snapshotApply; Flex Consumption wakes an app only for the
    triggers the last sync recorded). Polls the sync app's Application Insights for the run line
    (ccof.sync.run.v1) of this snapshot, and always disables the function and deletes the settings
    afterwards. The function (src/sync/snapshot-function.ts) checks the hash and the snapshot again
    and applies it through the same plan, lease and removal limits as the timer.
#>
[CmdletBinding()]
param(
    [string] $Subscription,
    [string] $ResourceGroup,
    [string] $FunctionApp,
    [string] $AppInsights,
    [string] $SnapshotPath,
    [string] $ExpectedSnapshotSha256,
    [int] $PollSeconds = 20,
    [int] $PollAttempts = 30,
    [int] $MaxAgeSeconds = 3600,
    [scriptblock] $Az,
    [scriptblock] $QueryRest,
    [switch] $DotSourceOnly
)

$SnapshotSettingNames = @('CCOF_SYNC_SNAPSHOT', 'CCOF_SYNC_SNAPSHOT_SHA256', 'SYNC_SNAPSHOT_MAX_AGE_SECONDS', 'SYNC_SNAPSHOT_MAX_BYTES', 'SYNC_SNAPSHOT_MAX_GROUPS', 'SYNC_SNAPSHOT_MAX_MEMBERS')

function Invoke-SnapshotAz {
    # az with arguments free of ( ) | & < > ^ and quotes (az.cmd re-parses them through cmd.exe on Windows).
    param([string[]]$Arguments)
    foreach ($a in $Arguments) { if ($a -match '[()|&<>^"]') { throw "refused az argument with a shell metacharacter: $($Arguments[0..1] -join ' ')" } }
    $out = az @Arguments --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments[0..1] -join ' ') failed: $(@($out) -join ' ')" }
    $text = @($out | Where-Object { $_ -is [string] }) -join "`n"
    if ($text.Trim().StartsWith('{') -or $text.Trim().StartsWith('[')) { return $text | ConvertFrom-Json -AsHashtable -Depth 100 }
    return $text
}

function New-SnapshotApplySettings {
    param([Parameter(Mandatory)] [string]$Text, [Parameter(Mandatory)] [string]$Sha256, [int]$Limit = $(if ($IsWindows) { 7000 } else { 98304 }), [int]$MaxAgeSeconds = 3600)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
    # cmd.exe, which runs az.cmd on Windows, takes at most 8,191 characters per command line.
    if ($b64.Length -gt $Limit) { throw "snapshot_too_large: the snapshot takes $($b64.Length) characters in base64, more than the $Limit this platform's az command line takes. Run from Azure Cloud Shell, or snapshot fewer groups." }
    return @(
        "CCOF_SYNC_SNAPSHOT=$b64",
        "CCOF_SYNC_SNAPSHOT_SHA256=$($Sha256.ToLowerInvariant())",
        "SYNC_SNAPSHOT_MAX_AGE_SECONDS=$MaxAgeSeconds",
        'SYNC_SNAPSHOT_MAX_BYTES=1048576',
        'SYNC_SNAPSHOT_MAX_GROUPS=1000',
        'SYNC_SNAPSHOT_MAX_MEMBERS=1000000',
        'AzureWebJobs.snapshotApply.Disabled=false'
    )
}

function Select-SnapshotRunLine {
    # The last run line of this snapshot; a refusal before the run carries no hash but names a
    # snapshot or configuration reason, and only snapshotApply runs while the sync timer is disabled.
    param([string[]]$Messages, [Parameter(Mandatory)] [string]$Sha256)
    $found = $null
    foreach ($m in @($Messages)) {
        if ([string]::IsNullOrWhiteSpace($m)) { continue }
        $line = try { $m | ConvertFrom-Json -AsHashtable -Depth 20 -ErrorAction Stop } catch { $null }
        if ($line -isnot [System.Collections.IDictionary] -or $line.schema -cne 'ccof.sync.run.v1') { continue }
        if ($line.snapshotSha256 -ceq $Sha256.ToLowerInvariant()) { $found = $line; continue }
        if (-not $line.snapshotSha256 -and $line.outcome -ceq 'failed' -and @($line.reasons | Where-Object { $_ -like 'snapshot_*' -or $_ -ceq 'sync_config_invalid' }).Count) { $found = $line }
    }
    return $found
}

function Invoke-SnapshotApplyThroughFunction {
    param(
        [Parameter(Mandatory)] [string]$Subscription, [Parameter(Mandatory)] [string]$ResourceGroup,
        [Parameter(Mandatory)] [string]$FunctionApp, [Parameter(Mandatory)] [string]$AppInsights,
        [Parameter(Mandatory)] [string]$SnapshotPath, [Parameter(Mandatory)] [string]$ExpectedSnapshotSha256,
        [int]$PollSeconds = 20, [int]$PollAttempts = 30, [int]$MaxAgeSeconds = 3600, [scriptblock]$Az, [scriptblock]$QueryRest
    )
    if ($ExpectedSnapshotSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'snapshot_hash_missing: -ExpectedSnapshotSha256 takes the 64 hex characters the snapshot command printed.' }
    $text = [IO.File]::ReadAllText($SnapshotPath, [Text.UTF8Encoding]::new($false))
    $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
    if ($sha -cne $ExpectedSnapshotSha256.ToLowerInvariant()) { throw "snapshot_hash_mismatch: $SnapshotPath has SHA-256 $sha, not the expected $ExpectedSnapshotSha256; nothing was changed." }
    $settings = New-SnapshotApplySettings -Text $text -Sha256 $sha -MaxAgeSeconds $MaxAgeSeconds
    $azCall = if ($Az) { $Az } else { ${function:Invoke-SnapshotAz} }
    $query = if ($QueryRest) { $QueryRest } else { { param($Uri, $Body, $Token) Invoke-RestMethod -Method Post -Uri $Uri -Body $Body -ContentType 'application/json' -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 60 } }
    $site = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$FunctionApp"
    $syncUrl = "$site/syncfunctiontriggers?api-version=2024-04-01"
    $target = @('--subscription', $Subscription, '--resource-group', $ResourceGroup, '--name', $FunctionApp)
    $component = & $azCall @('rest', '--method', 'get', '--url', "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/components/$($AppInsights)?api-version=2020-02-02")
    $appId = [string]$component.properties.AppId
    if (-not $appId) { throw "snapshot_app_insights_missing: $AppInsights has no Application Insights app id." }
    $started = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
    $result = $null; $failure = $null
    try {
        $null = & $azCall (@('functionapp', 'config', 'appsettings', 'set') + $target + @('--settings') + $settings + @('--output', 'none'))
        try { $null = & $azCall @('rest', '--method', 'post', '--url', $syncUrl) } catch { Write-Host "WARNING: trigger sync failed ($($_.Exception.Message))." -ForegroundColor Yellow }
        $kql = "traces | where timestamp > datetime($started) | where message contains 'ccof.sync.run.v1' | project timestamp, message | order by timestamp asc | take 50"
        $body = @{ query = $kql; timespan = 'PT2H' } | ConvertTo-Json -Compress
        for ($attempt = 1; $attempt -le $PollAttempts -and -not $result; $attempt++) {
            $token = [string](& $azCall @('account', 'get-access-token', '--resource', 'https://api.applicationinsights.io')).accessToken
            try {
                $response = & $query "https://api.applicationinsights.io/v1/apps/$appId/query" $body $token
                $table = @($response.tables)[0]
                $column = [array]::IndexOf(@($table.columns | ForEach-Object { [string]$_.name }), 'message')
                $messages = if ($column -ge 0) { @($table.rows | ForEach-Object { [string]@($_)[$column] }) } else { @() }
                $result = Select-SnapshotRunLine -Messages $messages -Sha256 $sha
            }
            catch { Write-Host "WARNING: query failed ($($_.Exception.Message)); polling on." -ForegroundColor Yellow }
            if (-not $result) {
                try {
                    $listed = @((& $azCall @('rest', '--method', 'get', '--url', "$site/functions?api-version=2024-04-01")).value | ForEach-Object { [string]$_.name })
                    if (-not ($listed | Where-Object { $_ -like '*/snapshotApply' })) { $null = & $azCall @('rest', '--method', 'post', '--url', $syncUrl) }
                }
                catch { Write-Host "WARNING: checking snapshotApply failed ($($_.Exception.Message))." -ForegroundColor Yellow }
                if ($attempt -lt $PollAttempts) { Start-Sleep -Seconds $PollSeconds }
            }
        }
        if (-not $result) { $failure = "snapshot_result_timeout: no ccof.sync.run.v1 line for snapshot $sha after $PollAttempts polls $PollSeconds seconds apart." }
    }
    catch { $failure = $_.Exception.Message }
    finally {
        $cleanup = @()
        try { $null = & $azCall (@('functionapp', 'config', 'appsettings', 'set') + $target + @('--settings', 'AzureWebJobs.snapshotApply.Disabled=true', '--output', 'none')) } catch { $cleanup += 'AzureWebJobs.snapshotApply.Disabled=true' }
        try { $null = & $azCall (@('functionapp', 'config', 'appsettings', 'delete') + $target + @('--setting-names') + $SnapshotSettingNames + @('--output', 'none')) } catch { $cleanup += 'delete settings' }
        if ($cleanup.Count) { $failure = "$failure snapshot_cleanup_failed: $($cleanup -join ', ') on $FunctionApp; set/delete them by hand.".Trim() }
    }
    if ($failure) { throw $failure }
    if ($result.outcome -cne 'succeeded') { throw "snapshot_apply_failed: the run $($result.runId) ended $($result.outcome) ($(@($result.reasons) -join ', '))$(if ($result.problems) { ': ' + (@($result.problems) -join ', ') })." }
    return $result
}

if ($DotSourceOnly) { return }
$result = Invoke-SnapshotApplyThroughFunction -Subscription $Subscription -ResourceGroup $ResourceGroup -FunctionApp $FunctionApp -AppInsights $AppInsights -SnapshotPath $SnapshotPath -ExpectedSnapshotSha256 $ExpectedSnapshotSha256 -PollSeconds $PollSeconds -PollAttempts $PollAttempts -MaxAgeSeconds $MaxAgeSeconds -Az $Az -QueryRest $QueryRest
$result | ConvertTo-Json -Depth 20 -Compress
