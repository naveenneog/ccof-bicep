#Requires -Version 7.0
<#
.SYNOPSIS
    Tests infra/sync/Invoke-SnapshotApplyThroughFunction.ps1, the delegated snapshot apply without a
    runner VM (docs/SYNC.md; src/sync/snapshot-function.ts), with fakes for az and the Application
    Insights query API: the settings it sets, the hash it checks before any az call, the run line it
    waits for, and the cleanup it always does (after success, refusal and timeout).
#>

$ErrorActionPreference = 'Continue'
$script:Pass = 0
$script:Fail = 0
trap { Write-Host "FAIL: unexpected error: $_" -ForegroundColor Red; $script:Fail++; continue }
$root = Split-Path $PSScriptRoot -Parent

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green; $script:Pass++ }
    else { Write-Host "FAIL: $Name $Detail" -ForegroundColor Red; $script:Fail++ }
}

$scriptPath = Join-Path $root 'infra' 'sync' 'Invoke-SnapshotApplyThroughFunction.ps1'
Assert-True 'infra/sync/Invoke-SnapshotApplyThroughFunction.ps1 exists' (Test-Path $scriptPath)
. $scriptPath -DotSourceOnly

$work = Join-Path $PSScriptRoot ".env.snapshot-fn-test-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $work | Out-Null
$text = '{"schema":"ccof.sync.snapshot.v1","tenantId":"t","groups":[]}' + "`n"
$snapshotPath = Join-Path $work 'snapshot.json'
[IO.File]::WriteAllText($snapshotPath, $text, [Text.UTF8Encoding]::new($false))
$sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()

# --- 1. The settings ---
$settings = New-SnapshotApplySettings -Text $text -Sha256 $sha
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
Assert-True 'sets the snapshot as base64' ($settings -contains "CCOF_SYNC_SNAPSHOT=$b64")
Assert-True 'sets the SHA-256 the function checks' ($settings -contains "CCOF_SYNC_SNAPSHOT_SHA256=$sha")
Assert-True 'enables the snapshotApply function' ($settings -contains 'AzureWebJobs.snapshotApply.Disabled=false')
foreach ($n in 'SYNC_SNAPSHOT_MAX_AGE_SECONDS', 'SYNC_SNAPSHOT_MAX_BYTES', 'SYNC_SNAPSHOT_MAX_GROUPS', 'SYNC_SNAPSHOT_MAX_MEMBERS') {
    Assert-True "sets $n" (@($settings | Where-Object { $_ -match "^$n=\d+$" }).Count -eq 1)
}
Assert-True 'no setting carries a shell metacharacter' (-not @($settings | Where-Object { $_ -match '[()|&<>^"]' }).Count)
$big = 'x' * 6000
$threw = $null; try { $null = New-SnapshotApplySettings -Text $big -Sha256 $sha -Limit 7000 } catch { $threw = $_.Exception.Message }
Assert-True 'a snapshot longer than the command line takes is refused by name' ($threw -like 'snapshot_too_large*') $threw
Assert-True 'oversize remedy preserves the complete registry catalog' ($threw -like '*complete registered-group catalog*' -and $threw -notlike '*snapshot fewer groups*') $threw

# --- 2. The run line ---
$lines = @(
    ('{"schema":"ccof.sync.run.v1","runId":"a","outcome":"succeeded","snapshotSha256":"' + ('0' * 64) + '"}'),
    'unrelated text',
    ('{"schema":"ccof.sync.run.v1","runId":"b","outcome":"succeeded","source":"snapshot","snapshotSha256":"' + $sha + '"}')
)
$line = Select-SnapshotRunLine -Messages $lines -Sha256 $sha
Assert-True 'picks the run line of this snapshot' ($line.runId -eq 'b')
$refused = Select-SnapshotRunLine -Messages @('{"schema":"ccof.sync.run.v1","runId":"c","outcome":"failed","reasons":["snapshot_hash_mismatch"]}') -Sha256 $sha
Assert-True 'a refusal before the run (no hash in the line) counts' ($refused.runId -eq 'c')
$none = Select-SnapshotRunLine -Messages @('{"schema":"ccof.sync.run.v1","runId":"d","outcome":"succeeded","source":"graph"}') -Sha256 $sha
Assert-True 'a graph run is not this snapshot' ($null -eq $none)

# --- 3. The whole apply with fakes ---
function New-Fake {
    param([string[]]$Messages)
    $calls = [System.Collections.Generic.List[string]]::new()
    $operation = @{ id = '' }
    $az = { param([string[]]$Arguments) $calls.Add($Arguments -join ' '); foreach ($arg in $Arguments) { if ($arg -like 'CCOF_SYNC_SNAPSHOT_OPERATION_ID=*') { $operation.id = $arg.Substring('CCOF_SYNC_SNAPSHOT_OPERATION_ID='.Length) } }; if ($Arguments -contains 'get-access-token') { return @{ accessToken = 'tok' } }; if ($Arguments[0] -eq 'rest' -and $Arguments -contains 'get' -and ($Arguments -join ' ') -match 'components') { return @{ properties = @{ AppId = '11111111-1111-4111-8111-111111111111' } } }; if ($Arguments[0] -eq 'rest' -and ($Arguments -join ' ') -match '/functions\?') { return @{ value = @(@{ name = 'app/snapshotApply' }) } }; if ($Arguments[0] -eq 'rest' -and ($Arguments -join ' ') -match 'Microsoft.Web/sites/app\?') { return @{ properties = @{ defaultHostName = 'example-app.azurewebsites.net' } } }; return '' }.GetNewClosure()
    $query = { param($Uri, $Body, $Token) @{ tables = @(@{ columns = @(@{ name = 'timestamp' }, @{ name = 'message' }); rows = @($Messages | ForEach-Object { $line = $_ | ConvertFrom-Json -AsHashtable; $line.snapshotOperationId = $operation.id; , @('t', ($line | ConvertTo-Json -Compress -Depth 20)) }) }) } }.GetNewClosure()
    [pscustomobject]@{ Calls = $calls; Az = $az; Query = $query }
}
$common = @{ Subscription = '00000000-0000-0000-0000-000000000001'; ResourceGroup = 'rg'; FunctionApp = 'app'; AppInsights = 'ai'; SnapshotPath = $snapshotPath; ExpectedSnapshotSha256 = $sha; PollSeconds = 0; PollAttempts = 2; Wake = { param($Url) } }

$ok = New-Fake @('{"schema":"ccof.sync.run.v1","runId":"r","outcome":"succeeded","source":"snapshot","snapshotSha256":"' + $sha + '","counts":{"added":1}}')
$woken = [System.Collections.Generic.List[string]]::new()
$wake = { param($Url) $woken.Add($Url) }.GetNewClosure()
$okArgs = $common.Clone(); $okArgs.Wake = $wake
$result = Invoke-SnapshotApplyThroughFunction @okArgs -Az $ok.Az -QueryRest $ok.Query
Assert-True 'wakes the app over HTTP after setting the snapshot (Flex Consumption scaled to zero)' ($woken.Count -ge 1 -and $woken[0] -eq 'https://example-app.azurewebsites.net/') ($woken -join ',')
Assert-True 'a succeeded run is returned' ($result.outcome -eq 'succeeded')
$joined = $ok.Calls -join "`n"
Assert-True 'sets the settings on the sync app' ($joined -match 'appsettings set .*CCOF_SYNC_SNAPSHOT=')
Assert-True 'asks for a trigger sync' ($joined -match 'syncfunctiontriggers')
Assert-True 'disables the function afterwards' ($joined -match 'AzureWebJobs\.snapshotApply\.Disabled=true')
Assert-True 'deletes the snapshot settings afterwards' ($joined -match 'appsettings delete .*CCOF_SYNC_SNAPSHOT .*CCOF_SYNC_SNAPSHOT_SHA256')

$timeout = New-Fake @()
$threw = $null; try { $null = Invoke-SnapshotApplyThroughFunction @common -Az $timeout.Az -QueryRest $timeout.Query } catch { $threw = $_.Exception.Message }
Assert-True 'no run line is a named timeout' ($threw -like 'snapshot_result_timeout*') $threw
Assert-True 'cleans up after a timeout' (($timeout.Calls -join "`n") -match 'appsettings delete')

$failed = New-Fake @('{"schema":"ccof.sync.run.v1","runId":"r","outcome":"failed","reasons":["snapshot_older_than_applied"],"snapshotSha256":"' + $sha + '"}')
$threw = $null; try { $null = Invoke-SnapshotApplyThroughFunction @common -Az $failed.Az -QueryRest $failed.Query } catch { $threw = $_.Exception.Message }
Assert-True 'a failed run throws with its reasons' ($threw -like 'snapshot_apply_failed*snapshot_older_than_applied*') $threw
Assert-True 'cleans up after a failed run' (($failed.Calls -join "`n") -match 'Disabled=true')

$wrong = New-Fake @()
$threw = $null; try { $null = Invoke-SnapshotApplyThroughFunction @common -ExpectedSnapshotSha256 ('a' * 64) -Az $wrong.Az -QueryRest $wrong.Query } catch { $threw = $_.Exception.Message }
Assert-True 'a file whose hash differs is refused before any az call' ($threw -like 'snapshot_hash_mismatch*' -and $wrong.Calls.Count -eq 0) $threw

Remove-Item -Recurse -Force $work
Write-Host "`n$script:Pass passed, $script:Fail failed"
if ($script:Fail) { exit 1 }
