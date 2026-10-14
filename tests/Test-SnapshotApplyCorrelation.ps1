#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'infra\sync\Invoke-SnapshotApplyThroughFunction.ps1') -DotSourceOnly
$passed = 0
function Assert([string]$Name, [bool]$Condition) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++; Write-Host "PASS: $Name"
}
$work = Join-Path $PSScriptRoot '.env.snapshot-correlation'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$path = Join-Path $work 'snapshot.json'
$text = '{"schema":"ccof.sync.snapshot.v1","tenantId":"t","groups":[]}'
[IO.File]::WriteAllText($path, $text)
$sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
$operation = 'current'
function Message([string]$Id, [string]$Outcome, [string]$Operation, [switch]$Hashless) {
    $line = @{ schema = 'ccof.sync.run.v1'; runId = $Id; outcome = $Outcome; snapshotOperationId = $Operation; reasons = @('snapshot_older_than_applied') }
    if (-not $Hashless) { $line.snapshotSha256 = $sha }
    $line | ConvertTo-Json -Compress
}
Assert 'previous success cannot satisfy this operation' ($null -eq (Select-SnapshotRunLine -Messages @(Message 'old' 'succeeded' 'previous') -Sha256 $sha -OperationId $operation))
Assert 'previous hashless failure cannot satisfy this operation' ($null -eq (Select-SnapshotRunLine -Messages @(Message 'old' 'failed' 'previous' -Hashless) -Sha256 $sha -OperationId $operation))
$selected = Select-SnapshotRunLine -Messages @((Message 'applied' 'succeeded' $operation), (Message 'replay' 'failed' $operation)) -Sha256 $sha -OperationId $operation
Assert 'current success survives its later replay refusal' ($selected.runId -eq 'applied')
Assert 'current hashless refusal is still reported' ((Select-SnapshotRunLine -Messages @(Message 'refused' 'failed' $operation -Hashless) -Sha256 $sha -OperationId $operation).runId -eq 'refused')

function Fake([int]$HostnameFailures = 0, [switch]$CleanupFailures, [switch]$Unlisted) {
    $state = @{ calls = [Collections.Generic.List[string]]::new(); operation = ''; reads = 0; queries = 0; wakes = 0 }
    $hash = $sha
    $az = {
        param([string[]]$Arguments)
        $joined = $Arguments -join ' '; $state.calls.Add($joined)
        if ($joined -match 'Microsoft.Web/sites/app\?') {
            $state.reads++
            if ($state.reads -le $HostnameFailures) { throw 'transient hostname read' }
            return @{ properties = @{ defaultHostName = 'example-app.azurewebsites.net' } }
        }
        if ($joined -match 'components') { return @{ properties = @{ AppId = '11111111-1111-4111-8111-111111111111' } } }
        if ($Arguments -contains 'get-access-token') { return @{ accessToken = 'fake' } }
        if ($joined -match '/functions\?') { return @{ value = $(if ($Unlisted) { @() } else { @(@{ name = 'app/snapshotApply' }) }) } }
        foreach ($arg in $Arguments) { if ($arg -like 'CCOF_SYNC_SNAPSHOT_OPERATION_ID=*') { $state.operation = $arg.Substring('CCOF_SYNC_SNAPSHOT_OPERATION_ID='.Length) } }
        if ($CleanupFailures -and ($joined -match 'Disabled=true|appsettings delete')) { throw 'cleanup unavailable' }
        return ''
    }.GetNewClosure()
    $query = {
        param($Uri, $Body, $Token)
        $state.queries++
        $messages = if ($Unlisted) { @() } else {
            @(
                (@{ schema = 'ccof.sync.run.v1'; runId = 'current-applied'; outcome = 'succeeded'; snapshotOperationId = $state.operation; snapshotSha256 = $hash } | ConvertTo-Json -Compress),
                (@{ schema = 'ccof.sync.run.v1'; runId = 'current-replay'; outcome = 'failed'; snapshotOperationId = $state.operation; snapshotSha256 = $hash; reasons = @('snapshot_older_than_applied') } | ConvertTo-Json -Compress)
            )
        }
        @{ tables = @(@{ columns = @(@{ name = 'message' }); rows = @($messages | ForEach-Object { ,@($_) }) }) }
    }.GetNewClosure()
    $wake = { param($Url) $state.wakes++ }.GetNewClosure()
    @{ State = $state; Az = $az; Query = $query; Wake = $wake }
}
$common = @{ Subscription = '11111111-1111-4111-8111-111111111111'; ResourceGroup = 'rg'; FunctionApp = 'app'; AppInsights = 'ai'; SnapshotPath = $path; ExpectedSnapshotSha256 = $sha; PollSeconds = 0; PollAttempts = 2 }
$fake = Fake -HostnameFailures 1
$result = Invoke-SnapshotApplyThroughFunction @common -Az $fake.Az -QueryRest $fake.Query -Wake $fake.Wake
Assert 'transient hostname failure retries and recovers' ($fake.State.reads -eq 2 -and $fake.State.wakes -eq 1 -and $result.outcome -eq 'succeeded')
Assert 'fresh operation is transported and deleted' ($fake.State.operation -match '^[0-9a-f]{32}$' -and ($fake.State.calls -join "`n") -match 'appsettings delete .*CCOF_SYNC_SNAPSHOT_OPERATION_ID')
$next = Fake
$null = Invoke-SnapshotApplyThroughFunction @common -Az $next.Az -QueryRest $next.Query -Wake $next.Wake
Assert 'each invocation receives a distinct operation' ($next.State.operation -ne $fake.State.operation)
$missing = Fake -HostnameFailures 100
$errorText = try { $null = Invoke-SnapshotApplyThroughFunction @common -Az $missing.Az -QueryRest $missing.Query -Wake $missing.Wake; '' } catch { $_.Exception.Message }
Assert 'permanent hostname failure refuses before settings change' ($errorText -like 'snapshot_hostname_unavailable*' -and $missing.State.reads -eq 3 -and -not (($missing.State.calls -join "`n") -match 'appsettings set'))
$unlisted = Fake -Unlisted
$errorText = try { $null = Invoke-SnapshotApplyThroughFunction @common -Az $unlisted.Az -QueryRest $unlisted.Query -Wake $unlisted.Wake; '' } catch { $_.Exception.Message }
Assert 'unlisted function retries trigger sync and wake' ($errorText -like 'snapshot_result_timeout*' -and $unlisted.State.wakes -eq 3)
$cleanup = Fake -CleanupFailures
$errorText = try { $null = Invoke-SnapshotApplyThroughFunction @common -Az $cleanup.Az -QueryRest $cleanup.Query -Wake $cleanup.Wake; '' } catch { $_.Exception.Message }
Assert 'both cleanup actions are attempted and failure is surfaced' ($errorText -like '*snapshot_cleanup_failed*' -and ($cleanup.State.calls -join "`n") -match 'Disabled=true' -and ($cleanup.State.calls -join "`n") -match 'appsettings delete')
Remove-Item $work -Recurse -Force
Write-Host "$passed passed"
