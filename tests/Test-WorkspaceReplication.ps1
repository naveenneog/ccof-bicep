# Offline tests for Log Analytics workspace replication (ADR 0038 option 1): the replication body,
# the plan, ledger coverage dates, the failover Status warning and infra/dr/Enable-WorkspaceReplication.ps1
# with a stub `az` in a child pwsh. No Azure call is made.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:fail = 0; $script:pass = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
function Refusal([scriptblock]$Run, [string]$Code) { try { & $Run | Out-Null; return $false } catch { return "$_" -match $Code } }
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'infra/dr/DrFailover.psm1') -Force

function New-Ws([hashtable]$Replication) {
    $p = [ordered]@{ customerId = 'c0ffee00-0000-4000-8000-000000000000'; sku = @{ name = 'PerGB2018' }; retentionInDays = 90; features = @{ enableLogAccessUsingOnlyResourcePermissions = $true } }
    if ($Replication) { $p.replication = $Replication }
    return @{ location = 'eastus2'; tags = @{ workload = 'ccof' }; properties = $p }
}

# ---- body: a full-object PUT keeps every other setting
$ws = New-Ws $null
$body = New-DrReplicationBody -Workspace $ws -Location 'centralus'
Check 'body sets replication enabled with the standby location' ($body.properties.replication.enabled -eq $true -and $body.properties.replication.location -ceq 'centralus')
Check 'body keeps location, tags, SKU, retention and features' ($body.location -ceq 'eastus2' -and $body.tags.workload -ceq 'ccof' -and $body.properties.Contains('sku') -and $body.properties.Contains('retentionInDays') -and $body.properties.Contains('features') -and $body.properties.sku.name -ceq 'PerGB2018' -and $body.properties.retentionInDays -eq 90 -and $body.properties.features.enableLogAccessUsingOnlyResourcePermissions)
Check 'body does not change the workspace read from Azure' (-not $ws.properties.Contains('replication'))

# ---- plan
Check 'plan: off -> enable' ((Get-DrReplicationPlan -Workspace (New-Ws $null) -Location 'centralus') -ceq 'enable')
Check 'plan: disabled -> enable' ((Get-DrReplicationPlan -Workspace (New-Ws @{ enabled = $false }) -Location 'centralus') -ceq 'enable')
Check 'plan: enabled to the same region (any spelling) -> none' ((Get-DrReplicationPlan -Workspace (New-Ws @{ enabled = $true; location = 'Central US'; provisioningState = 'Succeeded' }) -Location 'centralus') -ceq 'none')
Check 'plan: enable requested -> wait' ((Get-DrReplicationPlan -Workspace (New-Ws @{ enabled = $true; location = 'centralus'; provisioningState = 'EnableRequested' }) -Location 'centralus') -ceq 'wait')
Check 'plan: enabled to another region is refused' (Refusal { Get-DrReplicationPlan -Workspace (New-Ws @{ enabled = $true; location = 'westus2'; provisioningState = 'Succeeded' }) -Location 'centralus' } 'replication_other_location')
Check 'plan: the primary region as target is refused' (Refusal { Get-DrReplicationPlan -Workspace (New-Ws $null) -Location 'East US 2' } 'replication_same_region')

# ---- ledger coverage: the replica holds a full UTC month only from the first month start one hour
# after replication was enabled (tables can take up to an hour to start replicating).
$now = [datetime]::new(2026, 10, 27, 9, 0, 0, [DateTimeKind]::Utc)
$c = Get-DrReplicationCoverage -Replication @{ enabled = $true; location = 'centralus'; provisioningState = 'Succeeded'; createdDate = '2026-10-25T07:09:00Z' } -Now $now
Check 'coverage: mid-month start -> full months from the next month' ($c.fullMonthFrom -ceq '2026-11-01T00:00:00.000Z' -and -not $c.fullMonthNow)
Check 'coverage: switchover allowed 24 hours after enabling' ($c.switchoverAllowedAfter -ceq '2026-10-26T07:09:00.000Z')
$c = Get-DrReplicationCoverage -Replication @{ enabled = $true; createdDate = '2026-09-30T23:30:00Z' } -Now $now
Check 'coverage: 30 minutes before a month start -> that month is not full (one-hour margin)' ($c.fullMonthFrom -ceq '2026-11-01T00:00:00.000Z')
$c = Get-DrReplicationCoverage -Replication @{ enabled = $true; createdDate = '2026-09-30T22:59:00Z' } -Now $now
Check 'coverage: more than an hour before a month start -> that month is full' ($c.fullMonthFrom -ceq '2026-10-01T00:00:00.000Z' -and $c.fullMonthNow)
$c = Get-DrReplicationCoverage -Replication @{ enabled = $true; createdDate = '2026-12-15T10:00:00Z' } -Now $now
Check 'coverage: December start -> January of the next year' ($c.fullMonthFrom -ceq '2027-01-01T00:00:00.000Z')
$c = Get-DrReplicationCoverage -Replication @{ enabled = $false } -Now $now
Check 'coverage: replication off -> no dates' (-not $c.enabled -and $null -eq $c.fullMonthFrom -and -not $c.fullMonthNow)
$c = Get-DrReplicationCoverage -Replication @{ enabled = $true; createdDate = [datetime]::new(2026, 10, 25, 7, 9, 0, [DateTimeKind]::Utc) } -Now $now
Check 'coverage: a parsed DateTime createdDate gives the same dates' ($c.fullMonthFrom -ceq '2026-11-01T00:00:00.000Z')

# ---- failover Status warnings
function New-StatusCtx($Workspace) {
    $az = {
        param([string[]]$Arguments)
        $line = $Arguments -join ' '
        if ($line -match '^functionapp config appsettings list ') { return @(@{ name = 'AzureWebJobs.syncEntitlement.Disabled'; value = 'true' }, @{ name = 'AzureWebJobs.reconcileBudgets.Disabled'; value = 'true' }) }
        if ($line -match '^cosmosdb show ') { return @{ provisioningState = 'Succeeded'; writeLocations = @(@{ locationName = 'East US 2' }) } }
        if ($line -match '/workspaces/lab-ws\?') { return $Workspace }
        return @{ properties = @{} }
    }.GetNewClosure()
    @{ Subscription = '00000000-0000-4000-8000-000000000000'; ResourceGroup = 'rg-lab'; CosmosAccount = 'lab-cosmos'; WorkspaceName = 'lab-ws'; FrontDoorProfile = $null
        CoverageStartAt = '2026-10-20T15:41:34.000Z'; Az = $az; Now = $now
        Regions = @{ A = @{ Location = 'eastus2'; SyncApp = 'a-sync'; ReconcilerApp = 'a-rec' }; B = @{ Location = 'centralus'; SyncApp = 'b-sync'; ReconcilerApp = 'b-rec' } } }
}
$s = Get-DrFailoverStatus (New-StatusCtx (New-Ws @{ enabled = $true; location = 'centralus'; provisioningState = 'Succeeded'; createdDate = '2026-10-25T07:09:00Z' }))
Check 'Status warns while the current month is only partly replicated' (@($s.warnings) -contains 'workspace_replication_partial_month' -and $s.workspace.coverage.fullMonthFrom -ceq '2026-11-01T00:00:00.000Z')
$s = Get-DrFailoverStatus (New-StatusCtx (New-Ws $null))
Check 'Status warns when replication is off' (@($s.warnings) -contains 'workspace_replication_off')
$s = Get-DrFailoverStatus (New-StatusCtx (New-Ws @{ enabled = $true; location = 'centralus'; provisioningState = 'Succeeded'; createdDate = '2026-08-01T00:00:00Z' }))
Check 'Status: a full month replicated gives no replication warning' (@($s.warnings | Where-Object { $_ -match 'workspace_replication' }).Count -eq 0)

# ---- the script end to end with a stub az
$dir = Join-Path $repo '.env.public-test-scratch/ws-replication'
Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$stub = @'
function global:az {
    $l = $args -join ' '; Add-Content -LiteralPath $env:FAKE_AZ_LOG -Value $l; $global:LASTEXITCODE = 0
    $state = Get-Content -LiteralPath $env:FAKE_WS -Raw
    if ($l -match '^monitor log-analytics workspace list') { return '[{"name":"lab-ws"},{"name":"other-ws"}]' }
    if ($l -match '^rest --method get .*/workspaces/lab-ws\?api-version=2025-02-01') { return $state }
    if ($l -match '^rest --method put .*/workspaces/lab-ws\?api-version=2025-02-01 .*--body @(\S+)') {
        $b = Get-Content -LiteralPath $Matches[1] -Raw | ConvertFrom-Json
        $b.properties.replication | Add-Member provisioningState 'Succeeded' -Force; $b.properties.replication | Add-Member createdDate '2026-10-27T03:00:00Z' -Force
        Copy-Item -LiteralPath $Matches[1] -Destination (Join-Path (Split-Path $env:FAKE_WS) 'put-body.json') -Force
        $b | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $env:FAKE_WS; return ($b.properties.replication | ConvertTo-Json) }
    $global:LASTEXITCODE = 1; Write-Error "stub: unexpected $l"
}
'@
$runScript = { param([string[]]$ScriptArgs, $Workspace)
    $env:FAKE_AZ_LOG = Join-Path $dir 'az.log'; Set-Content $env:FAKE_AZ_LOG ''
    $env:FAKE_WS = Join-Path $dir 'ws.json'; $Workspace | ConvertTo-Json -Depth 20 | Set-Content $env:FAKE_WS
    $cmd = "$stub; `$env:AZURE_CONFIG_DIR = '$dir'; & '$(Join-Path $repo 'infra/dr/Enable-WorkspaceReplication.ps1')' $($ScriptArgs -join ' ') -PollSeconds 0; exit `$LASTEXITCODE"
    $out = pwsh -NoProfile -Command $cmd 2>&1 | Out-String
    @{ code = $LASTEXITCODE; out = $out; log = @(Get-Content $env:FAKE_AZ_LOG | Where-Object { $_ }) } }
$base = @('-Subscription', '00000000-0000-4000-8000-000000000002', '-ResourceGroup', 'rg-lab', '-Workspace', 'lab-ws', '-Location', 'centralus')
$r = & $runScript $base (New-Ws $null)
Check 'script preview: no PUT, exit 0, names the plan' ($r.code -eq 0 -and @($r.log | Where-Object { $_ -match '--method put' }).Count -eq 0 -and $r.out -match 'preview: enable replication to centralus')
$r = & $runScript ($base + '-Apply') (New-Ws $null)
$put = if (Test-Path (Join-Path $dir 'put-body.json')) { Get-Content (Join-Path $dir 'put-body.json') -Raw | ConvertFrom-Json } else { $null }
Check 'script apply: one PUT with a JSON body file and content type' ($r.code -eq 0 -and @($r.log | Where-Object { $_ -match '^rest --method put .*--headers Content-Type=application/json .*--body @' }).Count -eq 1)
$okPut = try { $put -and $put.properties.sku.name -ceq 'PerGB2018' -and $put.properties.retentionInDays -eq 90 -and $put.properties.replication.enabled -and $put.properties.replication.location -ceq 'centralus' } catch { $false }
Check 'script apply: the PUT body keeps SKU and retention and sets replication' $okPut
Check 'script apply: reads back Succeeded and prints the first full month' ($r.out -match 'replication: enabled, centralus, Succeeded' -and $r.out -match 'full billing months in the replica from 2026-11-01T00:00:00.000Z')
Remove-Item (Join-Path $dir 'put-body.json') -ErrorAction SilentlyContinue
$r = & $runScript ($base + '-Apply') (New-Ws @{ enabled = $true; location = 'centralus'; provisioningState = 'Succeeded'; createdDate = '2026-10-25T07:09:00Z' })
Check 'script: already enabled -> no PUT, exit 0' ($r.code -eq 0 -and @($r.log | Where-Object { $_ -match '--method put' }).Count -eq 0 -and $r.out -match 'already enabled')
$r = & $runScript ($base + '-Apply') (New-Ws @{ enabled = $true; location = 'westus2'; provisioningState = 'Succeeded' })
Check 'script: enabled to another region -> exit 3, no PUT' ($r.code -eq 3 -and $r.out -match 'replication_other_location' -and @($r.log | Where-Object { $_ -match '--method put' }).Count -eq 0)
$r = & $runScript @('-Subscription', '00000000-0000-4000-8000-000000000002', '-ResourceGroup', 'rg-lab', '-Location', 'centralus') (New-Ws $null)
Check 'script: two workspaces and no -Workspace -> exit 2 listing them, no read of either' ($r.code -eq 2 -and $r.out -match 'lab-ws' -and $r.out -match 'other-ws' -and @($r.log | Where-Object { $_ -match '^rest ' }).Count -eq 0)
Remove-Item (Join-Path $dir 'put-body.json') -ErrorAction SilentlyContinue
$r = & $runScript @('-Subscription', '00000000-0000-4000-8000-000000000002', '-ResourceGroup', 'rg-lab', '-Workspace', 'lab-ws', '-Disable', '-Apply') (New-Ws @{ enabled = $true; location = 'centralus'; provisioningState = 'Succeeded'; createdDate = '2026-10-25T07:09:00Z' })
$put = if (Test-Path (Join-Path $dir 'put-body.json')) { Get-Content (Join-Path $dir 'put-body.json') -Raw | ConvertFrom-Json } else { $null }
$okOff = try { $put -and $put.properties.replication.enabled -eq $false -and $put.properties.sku.name -ceq 'PerGB2018' -and $put.properties.retentionInDays -eq 90 } catch { $false }
Check 'script -Disable -Apply: one PUT with enabled false, SKU and retention kept' ($r.code -eq 0 -and $okOff -and @($r.log | Where-Object { $_ -match '--method put' }).Count -eq 1)
$r = & $runScript @('-Subscription', '00000000-0000-4000-8000-000000000002', '-ResourceGroup', 'rg-lab', '-Workspace', 'lab-ws', '-Disable') (New-Ws @{ enabled = $true; location = 'centralus'; provisioningState = 'Succeeded' })
Check 'script -Disable without -Apply: preview, no PUT' ($r.code -eq 0 -and $r.out -match 'preview: disable replication' -and @($r.log | Where-Object { $_ -match '--method put' }).Count -eq 0)
$r = & $runScript @('-Subscription', '00000000-0000-4000-8000-000000000002', '-ResourceGroup', 'rg-lab', '-Workspace', 'lab-ws', '-Disable', '-Apply') (New-Ws $null)
Check 'script -Disable when already off: no PUT, exit 0' ($r.code -eq 0 -and $r.out -match 'already off' -and @($r.log | Where-Object { $_ -match '--method put' }).Count -eq 0)
$r = & $runScript @('-Subscription', '00000000-0000-4000-8000-000000000002', '-ResourceGroup', 'rg-lab', '-Workspace', 'lab-ws') (New-Ws $null)
Check 'script: -Location is required unless -Disable (exit 2, no az call)' ($r.code -eq 2 -and $r.log.Count -eq 0)
$r = & $runScript @('-Subscription', 'not-a-guid', '-ResourceGroup', 'rg-lab', '-Workspace', 'lab-ws', '-Location', 'centralus') (New-Ws $null)
Check 'script: a malformed subscription ID stops before any az call (exit 2)' ($r.code -eq 2 -and $r.log.Count -eq 0)

Write-Host "Test-WorkspaceReplication: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0 -or $script:pass -lt 31) { exit 1 }
