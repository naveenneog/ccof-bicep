# Offline tests for scripted DR promotion and failback (infra/dr/Invoke-DrFailover.ps1,
# infra/dr/DrFailover.psm1). Azure is replaced by an injected fake `az` that keeps app settings, the
# Cosmos write region, the workspace and the Front Door origin in memory; no Azure call is made.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:fail = 0; $script:pass = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'infra/dr/DrFailover.psm1') -Force

$coverage = '2026-10-20T15:41:34.000Z'
$sync = 'AzureWebJobs.syncEntitlement.Disabled'; $rec = 'AzureWebJobs.reconcileBudgets.Disabled'
$script:allCalls = [Collections.Generic.List[string]]::new()

# One in-memory Azure. Writers: a-sync, a-rec (region A), b-sync, b-rec (region B). Each app-setting
# change is recorded in `events`; `violations` counts moments when both regions had a writer enabled.
# App Service drops ".000" from a date value, as observed in the 2026-10-26 lab.
function New-World([string]$CosmosWrite = 'Central US') {
    $all = $script:allCalls
    $w = @{
        settings = @{ 'a-sync' = @{ $sync = 'true' }; 'a-rec' = @{ $rec = 'true' }; 'b-sync' = @{ $sync = 'true' }; 'b-rec' = @{ $rec = 'true' } }
        cosmos = $CosmosWrite; cosmosState = 'Succeeded'; calls = [Collections.Generic.List[string]]::new(); events = [Collections.Generic.List[string]]::new()
        violations = 0; failOn = $null; hook = $null; stuck = @(); fdHost = 'lab-a.azure-api.net'
        workspace = @{ properties = @{ failover = @{ state = 'Inactive' }; replication = @{ enabled = $true; location = 'centralus'; createdDate = '2026-10-25T07:09:00Z' } } }
    }
    $w.Az = {
        param([string[]]$Arguments)
        $line = $Arguments -join ' '
        $w.calls.Add($line); $all.Add($line)
        if ($w.failOn -and $line -match $w.failOn) { throw "fake_failure: $line" }
        $i = [array]::IndexOf($Arguments, '--name'); $app = if ($i -ge 0) { $Arguments[$i + 1] } else { $null }
        $on = { param($a, $k) "$($w.settings[$a][$k])" -ine 'true' }
        if ($line -match '^functionapp config appsettings list ') { return @($w.settings[$app].GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = $_.Value } }) }
        if ($line -match '^functionapp config appsettings (set|delete) ') {
            if ($w.stuck -contains $app) { return @() }
            if ($Matches[1] -eq 'set') {
                $k, $v = $Arguments[[array]::IndexOf($Arguments, '--settings') + 1].Split('=', 2)
                if ($v -match '^(.*:\d\d)\.000Z$') { $v = "$($Matches[1])Z" }
                $w.settings[$app][$k] = $v; $w.events.Add("$app $k=$v")
            } else {
                $k = $Arguments[[array]::IndexOf($Arguments, '--setting-names') + 1]
                $w.settings[$app].Remove($k); $w.events.Add("$app -$k")
            }
            if ($w.hook) { & $w.hook $w.events[-1] $w }
            if (((& $on 'a-sync' $sync) -or (& $on 'a-rec' $rec)) -and ((& $on 'b-sync' $sync) -or (& $on 'b-rec' $rec))) { $w.violations++ }
            return @()
        }
        if ($line -match '^cosmosdb show ') { return @{ name = 'lab-cosmos'; provisioningState = $w.cosmosState; writeLocations = @(@{ locationName = $w.cosmos }) } }
        if ($line -match '^cosmosdb failover-priority-change ') { $w.cosmos = 'East US 2'; $w.events.Add('cosmos eastus2=0'); return $null }
        if ($line -match '^rest --method get --url \S+/workspaces/lab-ws\?') { return $w.workspace }
        if ($line -match '^rest --method get --url \S+/origins/primary-(gateway|admin)\?') { return @{ properties = @{ originHostHeader = $w.fdHost } } }
        throw "unexpected az call: $line"
    }.GetNewClosure()
    $w.Ctx = @{
        Subscription = '00000000-0000-4000-8000-000000000000'; ResourceGroup = 'rg-lab'; CosmosAccount = 'lab-cosmos'; WorkspaceName = 'lab-ws'
        FrontDoorProfile = 'lab-fd'; CoverageStartAt = $coverage; Az = $w.Az; PollSeconds = 0; PollAttempts = 3; Log = { param($m) }
        Regions = @{ A = @{ Name = 'A'; Location = 'eastus2'; SyncApp = 'a-sync'; ReconcilerApp = 'a-rec' }; B = @{ Name = 'B'; Location = 'centralus'; SyncApp = 'b-sync'; ReconcilerApp = 'b-rec' } }
    }
    return $w
}
function Mutations($w) { @($w.calls | Where-Object { $_ -match '^(functionapp config appsettings (set|delete)|cosmosdb failover-priority-change) ' }) }
function Quiet([scriptblock]$Run) { try { & $Run | Out-Null } catch { Write-Host "error: $_" } }
function Refusal([scriptblock]$Run, [string]$Code) { try { & $Run | Out-Null; return $false } catch { return "$_" -match $Code } }
function Enabled($w, [string]$Region) { $r = $Region.ToLower(); ("$($w.settings["$r-sync"][$sync])" -ine 'true') -or ("$($w.settings["$r-rec"][$rec])" -ine 'true') }

# ---- argument safety: az.cmd re-parses its arguments through cmd.exe on Windows
Check 'cmd metacharacter refused: &' (Refusal { Assert-DrAzArguments @('functionapp', 'x&calc') } 'az_argument_unsafe')
Check 'cmd metacharacter refused: ( ) | < > ^' (@('a(b', 'a)b', 'a|b', 'a<b', 'a>b', 'a^b' | Where-Object { -not (Refusal { Assert-DrAzArguments @($_) } 'az_argument_unsafe') }).Count -eq 0)
Check 'URLs, @files and Name=Value pass' (-not (Refusal { Assert-DrAzArguments @('https://management.azure.com/x?api-version=2025-02-01', '@body.json', "$sync=true") } 'az_argument_unsafe'))
$w = New-World; $w.Ctx.Regions.A.SyncApp = 'a-sync&calc'
Check 'an unsafe app name stops before az is called' ((Refusal { Get-DrFailoverStatus $w.Ctx } 'az_argument_unsafe') -and $w.calls.Count -eq 0)

# ---- coverage start: canonical UTC milliseconds in dr.config; App Service read-back normalised
Check 'canonical coverage accepted' (Test-DrCanonicalCoverage $coverage)
Check 'coverage without milliseconds refused in config' (-not (Test-DrCanonicalCoverage '2026-10-20T15:41:34Z'))
Check 'coverage with an offset refused' (-not (Test-DrCanonicalCoverage '2026-10-20T15:41:34.000+00:00'))
Check 'impossible date refused' (-not (Test-DrCanonicalCoverage '2026-02-30T15:41:34.000Z'))
Check 'App Service form normalises to the same instant' ((ConvertTo-DrUtcInstant '2026-10-20T15:41:34Z') -ceq $coverage -and (ConvertTo-DrUtcInstant '2026-10-20T15:41:34.0001Z') -ceq $coverage)
Check 'read-back normaliser refuses offsets' ($null -eq (ConvertTo-DrUtcInstant '2026-10-20T15:41:34+05:30'))
$cfg = [pscustomobject]@{ failover = [pscustomobject]@{ ledgerCoverageStartAt = '2026-10-20T15:41:34Z' } }
Check 'config problem names the field' (@(Get-DrFailoverProblems $cfg) -contains 'failover.ledgerCoverageStartAt:canonical_utc_milliseconds')
$cfg.failover.ledgerCoverageStartAt = 'REPLACE-2026-01-01T00:00:00.000Z'
Check 'config placeholder refused' (@(Get-DrFailoverProblems $cfg) -contains 'failover.ledgerCoverageStartAt:placeholder')
Check 'coverage required for Promote/Failback, optional for Status' (@(Get-DrFailoverProblems ([pscustomobject]@{}) -RequireCoverage) -contains 'failover.ledgerCoverageStartAt:required' -and @(Get-DrFailoverProblems ([pscustomobject]@{})).Count -eq 0)
$cfg.failover.ledgerCoverageStartAt = $coverage
Check 'canonical config value has no problem' (@(Get-DrFailoverProblems $cfg -RequireCoverage).Count -eq 0)
$w = New-World; $w.Ctx.CoverageStartAt = '2026-10-20T15:41:34Z'
Check 'Promote refuses a non-canonical coverage before any change' ((Refusal { Invoke-DrPromote $w.Ctx -Apply } 'coverage_invalid') -and @(Mutations $w).Count -eq 0)

# ---- Status
$w = New-World; $w.settings['a-rec'][$rec] = 'false'; $w.settings['b-sync'][$sync] = 'false'
$s = Get-DrFailoverStatus $w.Ctx
Check 'Status flags split-brain when both regions have a writer enabled' (@($s.problems) -contains 'split_brain')
Check 'Status changes nothing' (@(Mutations $w).Count -eq 0)
$w = New-World; $w.settings['b-rec'][$rec] = 'false'; $w.settings['b-rec']['RECONCILER_CONTINUITY_GATE'] = 'on'; $w.settings['b-rec']['RECONCILER_LEDGER_COVERAGE_START_AT'] = '2026-10-20T15:41:34Z'; $w.fdHost = 'dr-drill.invalid'
$w.workspace.properties.failover.state = 'Active'
$s = Get-DrFailoverStatus $w.Ctx
Check 'Status: one writer region is not split-brain' (@($s.problems) -notcontains 'split_brain')
Check 'Status reports writers, gate and normalised coverage per region' ($s.regions.B.reconcilerDisabled -ceq 'false' -and $s.regions.B.writing -and -not $s.regions.A.writing -and $s.regions.B.gate -ceq 'on' -and $s.regions.B.coverageStartAt -ceq $coverage)
Check 'Status reports Cosmos write region, workspace failover and Front Door drill fault' ($s.cosmos.writeRegion -ceq 'Central US' -and $s.workspace.failover.state -ceq 'Active' -and $s.frontDoor.primaryGateway.faulted -and $s.workspace.switchoverAllowedAfter -ceq '2026-10-26T07:09:00.000Z')

$w = New-World; $w.settings['b-rec']['RECONCILER_LEDGER_COVERAGE_START_AT'] = [datetime]::new(2026, 10, 20, 15, 41, 34, [DateTimeKind]::Utc)
Check 'a date value parsed by ConvertFrom-Json is read as the same instant' ((Get-DrFailoverStatus $w.Ctx).regions.B.coverageStartAt -ceq $coverage)
Check 'config coverage is read as written, not as a parsed date' ((Get-DrJsonText '{"failover":{"ledgerCoverageStartAt":"2026-10-20T15:41:34Z"}}' 'failover.ledgerCoverageStartAt') -ceq '2026-10-20T15:41:34Z' -and $null -eq (Get-DrJsonText '{}' 'failover.ledgerCoverageStartAt'))

# ---- Promote (region B)
$w = New-World; $w.settings['a-sync'][$sync] = 'false'
Check 'Promote refuses while region A has a writer enabled' ((Refusal { Invoke-DrPromote $w.Ctx -Apply } 'source_writers_enabled') -and @(Mutations $w).Count -eq 0)
$w = New-World 'East US 2'
$msg = ''; try { Invoke-DrPromote $w.Ctx -Apply | Out-Null } catch { $msg = "$_" }
Check 'Promote refuses when Cosmos does not write in region B' ($msg -match 'cosmos_write_region' -and @(Mutations $w).Count -eq 0)
Check 'refusal prints the Cosmos command and Promote never runs it' ($msg -match 'cosmosdb failover-priority-change .*--failover-policies centralus=0 eastus2=1' -and @($w.calls | Where-Object { $_ -match 'failover-priority-change' }).Count -eq 0)
$w = New-World
$r = Invoke-DrPromote $w.Ctx
Check 'Promote preview changes nothing and lists the plan' (@(Mutations $w).Count -eq 0 -and -not $r.apply -and @($r.steps | Where-Object { $_ -match 'preview' }).Count -gt 0)
$w = New-World
$r = $null; try { $r = Invoke-DrPromote $w.Ctx -Apply } catch { Write-Host "Promote: $_" }
$ev = @($w.events)
$firstEnable = [array]::FindIndex([string[]]$ev, [Predicate[string]] { param($e) $e -match 'Disabled=false' })
$gateAt = [array]::FindIndex([string[]]$ev, [Predicate[string]] { param($e) $e -ceq 'b-rec RECONCILER_CONTINUITY_GATE=on' })
$covAt = [array]::FindIndex([string[]]$ev, [Predicate[string]] { param($e) $e -match '^b-rec RECONCILER_LEDGER_COVERAGE_START_AT=' })
Check 'Promote sets gate and coverage before enabling any writer' ($gateAt -ge 0 -and $covAt -ge 0 -and $firstEnable -gt $gateAt -and $firstEnable -gt $covAt)
Check 'Promote enables both region B writers and leaves A fenced' (-not (Enabled $w 'A') -and $w.settings['b-sync'][$sync] -ceq 'false' -and $w.settings['b-rec'][$rec] -ceq 'false' -and $w.violations -eq 0)
Check 'App Service-normalised coverage read-back is accepted' ($w.settings['b-rec']['RECONCILER_LEDGER_COVERAGE_START_AT'] -ceq '2026-10-20T15:41:34Z' -and $r -and $r.result -ceq 'promoted')
Check 'no adoption without -AdoptBaseline' (-not $w.settings['b-rec'].ContainsKey('RECONCILER_LEDGER_BASELINE_ADOPT'))
Check 'Promote prints the workspace switchover call, does not run it' ($r -and ($r.steps -join "`n") -match '/locations/centralus/workspaces/lab-ws/failover\?api-version=2025-02-01' -and @($w.calls | Where-Object { $_ -match '/failover\?' }).Count -eq 0)
$w = New-World; Quiet { Invoke-DrPromote $w.Ctx -Apply -AdoptBaseline }
Check '-AdoptBaseline sets adoption equal to the coverage start' ((ConvertTo-DrUtcInstant $w.settings['b-rec']['RECONCILER_LEDGER_BASELINE_ADOPT']) -ceq $coverage)
$adoptAt = [array]::FindIndex([string[]]@($w.events), [Predicate[string]] { param($e) $e -match 'BASELINE_ADOPT=' })
$enAt = [array]::FindIndex([string[]]@($w.events), [Predicate[string]] { param($e) $e -match 'Disabled=false' })
Check 'adoption is set before the writers are enabled' ($adoptAt -ge 0 -and $adoptAt -lt $enAt)
$w = New-World; $w.settings['b-rec']['RECONCILER_LEDGER_BASELINE_ADOPT'] = '2026-01-01T00:00:00Z'; Quiet { Invoke-DrPromote $w.Ctx -Apply }
Check 'a stale adoption is removed when -AdoptBaseline is not given' (-not $w.settings['b-rec'].ContainsKey('RECONCILER_LEDGER_BASELINE_ADOPT'))
$w = New-World; $w.settings['a-sync'][$sync] = 'false'; $w.settings['a-rec'][$rec] = 'false'
Quiet { Invoke-DrPromote $w.Ctx -Apply -FenceSource }
$aOff = [array]::FindIndex([string[]]@($w.events), [Predicate[string]] { param($e) $e -match '^a-(sync|rec) .*Disabled=true' })
$bOn = [array]::FindIndex([string[]]@($w.events), [Predicate[string]] { param($e) $e -match '^b-.*Disabled=false' })
Check '-FenceSource fences region A before region B is touched' ($aOff -eq 0 -and $bOn -gt $aOff -and -not (Enabled $w 'A') -and (Enabled $w 'B') -and $w.violations -eq 0)
$w = New-World; $w.stuck = @('b-rec')
Check 'a setting that does not read back stops Promote' ((Refusal { Invoke-DrPromote $w.Ctx -Apply } 'readback_mismatch') -and -not (Enabled $w 'B'))

$w = New-World; $w.hook = { param($e, $w) if ($e -match '^b-rec RECONCILER_LEDGER_COVERAGE_START_AT') { $w.settings['a-sync'][$sync] = 'false' } }
Check 'region A re-enabled during Promote: region B is not enabled' ((Refusal { Invoke-DrPromote $w.Ctx -Apply } 'source_writers_enabled') -and -not (Enabled $w 'B'))
$w = New-World; $w.hook = { param($e, $w) if ($e -match '^b-rec RECONCILER_LEDGER_COVERAGE_START_AT') { $w.cosmos = 'East US 2' } }
Check 'Cosmos moved during Promote: region B is not enabled' ((Refusal { Invoke-DrPromote $w.Ctx -Apply } 'cosmos_write_region') -and -not (Enabled $w 'B'))

# ---- Fence and RemoveAdoption
$w = New-World; $w.settings['a-rec'][$rec] = 'false'
Quiet { Invoke-DrFence $w.Ctx -Region A }
Check 'Fence preview changes nothing' (@(Mutations $w).Count -eq 0)
Quiet { Invoke-DrFence $w.Ctx -Region A -Apply }
Check 'Fence disables both writers of the region' (-not (Enabled $w 'A'))
$w = New-World; $w.settings['b-rec']['RECONCILER_LEDGER_BASELINE_ADOPT'] = '2026-10-20T15:41:34Z'; $w.settings['a-rec']['RECONCILER_LEDGER_BASELINE_ADOPT'] = '2026-10-20T15:41:34Z'
Quiet { Invoke-DrRemoveAdoption $w.Ctx -Region B }
Check 'RemoveAdoption preview changes nothing' (@(Mutations $w).Count -eq 0)
Quiet { Invoke-DrRemoveAdoption $w.Ctx -Region B -Apply }
Check 'RemoveAdoption deletes only the named region''s setting' (-not $w.settings['b-rec'].ContainsKey('RECONCILER_LEDGER_BASELINE_ADOPT') -and $w.settings['a-rec'].ContainsKey('RECONCILER_LEDGER_BASELINE_ADOPT') -and @($w.calls | Where-Object { $_ -match 'appsettings delete .*--setting-names RECONCILER_LEDGER_BASELINE_ADOPT' }).Count -eq 1)

# ---- Failback (region A)
function New-Promoted { $w = New-World; $w.settings['b-sync'][$sync] = 'false'; $w.settings['b-rec'][$rec] = 'false'
    $w.settings['b-rec']['RECONCILER_LEDGER_BASELINE_ADOPT'] = '2026-10-20T15:41:34Z'; $w.settings['a-rec']['RECONCILER_LEDGER_BASELINE_ADOPT'] = '2026-10-20T15:41:34Z'; $w }
$w = New-Promoted
$r = $null; try { $r = Invoke-DrFailback $w.Ctx -Apply -MoveCosmos } catch { Write-Host "Failback: $_" }
$m = @(Mutations $w)
Check 'Failback disables both region B writers before any other change' ($m.Count -ge 2 -and @($m[0..1] | Where-Object { $_ -match "--name b-(sync|rec) --settings AzureWebJobs\.\w+\.Disabled=true" }).Count -eq 2)
Check 'Failback never has both regions writing' ($w.violations -eq 0)
Check '-MoveCosmos moves the write region to A (A=0, B=1) after B is fenced' ($w.cosmos -ceq 'East US 2' -and @($w.calls | Where-Object { $_ -match 'failover-priority-change .*--failover-policies eastus2=0 centralus=1' }).Count -eq 1 -and [array]::IndexOf([string[]]@($w.events), 'cosmos eastus2=0') -gt 1)
Check 'Failback sets the A gate and coverage, then enables A' ($w.settings['a-rec']['RECONCILER_CONTINUITY_GATE'] -ceq 'on' -and (ConvertTo-DrUtcInstant $w.settings['a-rec']['RECONCILER_LEDGER_COVERAGE_START_AT']) -ceq $coverage -and (Enabled $w 'A') -and -not (Enabled $w 'B') -and $r -and $r.result -ceq 'failed_back')
$ev = @($w.events)
Check 'A writers are enabled last' (@($ev[-2..-1] | Where-Object { $_ -match '^a-(sync|rec) .*Disabled=false' }).Count -eq 2)
Check 'Failback removes adoption in both regions' (-not $w.settings['a-rec'].ContainsKey('RECONCILER_LEDGER_BASELINE_ADOPT') -and -not $w.settings['b-rec'].ContainsKey('RECONCILER_LEDGER_BASELINE_ADOPT'))
Check 'Failback prints the workspace failback call' ($r -and ($r.steps -join "`n") -match '/workspaces/lab-ws/failback\?api-version=2025-02-01')
$w = New-Promoted
$msg = ''; try { Invoke-DrFailback $w.Ctx -Apply | Out-Null } catch { $msg = "$_" }
Check 'without -MoveCosmos Failback stops at Cosmos with both regions fenced' ($msg -match 'cosmos_write_region' -and $msg -match 'eastus2=0 centralus=1' -and -not (Enabled $w 'A') -and -not (Enabled $w 'B') -and $w.cosmos -ceq 'Central US')
$w = New-Promoted; $w.failOn = 'failover-priority-change'
Check 'a failed Cosmos move leaves both regions fenced' ((Refusal { Invoke-DrFailback $w.Ctx -Apply -MoveCosmos } 'fake_failure') -and -not (Enabled $w 'A') -and -not (Enabled $w 'B'))
$w = New-Promoted; $w.failOn = '--name a-rec --settings RECONCILER_CONTINUITY_GATE'
Check 'a failure while configuring A leaves both regions fenced' ((Refusal { Invoke-DrFailback $w.Ctx -Apply -MoveCosmos } 'fake_failure') -and -not (Enabled $w 'A') -and -not (Enabled $w 'B') -and $w.violations -eq 0)
$w = New-Promoted; $w.stuck = @('b-sync')
Check 'region B that does not fence stops Failback before region A or Cosmos' ((Refusal { Invoke-DrFailback $w.Ctx -Apply -MoveCosmos } 'readback_mismatch') -and @($w.calls | Where-Object { $_ -match '--name a-|failover-priority-change' }).Count -eq 0)
$w = New-Promoted; $w.cosmosState = 'Updating'
Check 'a Cosmos move that does not finish stops with both regions fenced' ((Refusal { Invoke-DrFailback $w.Ctx -Apply -MoveCosmos } 'cosmos_move_timeout') -and -not (Enabled $w 'A') -and -not (Enabled $w 'B'))
$w = New-Promoted; $w.hook = { param($e, $w) if ($e -match '^a-rec RECONCILER_LEDGER_COVERAGE_START_AT') { $w.settings['b-sync'][$sync] = 'false' } }
Check 'region B re-enabled during Failback: region A is not enabled' ((Refusal { Invoke-DrFailback $w.Ctx -Apply -MoveCosmos } 'standby_writers_enabled') -and -not (Enabled $w 'A'))
$w = New-Promoted; Quiet { Invoke-DrFailback $w.Ctx }
Check 'Failback preview changes nothing' (@(Mutations $w).Count -eq 0)

# ---- context from dr.config and the staged state; workspace commands
$dr = [pscustomobject]@{ primary = [pscustomobject]@{ location = 'eastus2' }; secondary = [pscustomobject]@{ location = 'centralus' }; failover = [pscustomobject]@{ ledgerCoverageStartAt = $coverage } }
$apps = { param($p) @{ sync = @{ functionApp = "$p-sync" }; reconciler = @{ functionApp = "$p-reconciler" } } }
$pa = @{ names = @{ apps = (& $apps 'lab'); cosmosAccount = 'lab-cosmos' }; workspaceId = '/subscriptions/x/resourceGroups/rg-lab/providers/Microsoft.OperationalInsights/workspaces/lab-ws' }
$pb = @{ names = @{ apps = (& $apps 'lab-b'); cosmosAccount = 'lab-cosmos' } }
$ctx = New-DrFailoverContext -Dr $dr -Subscription 'sub' -ResourceGroup 'rg-lab' -PrimaryStage1 $pa -StandbyStage1 $pb -FrontDoorProfile 'lab-fd' -Az { }
Check 'context: apps per region, shared Cosmos and workspace, coverage from config' ($ctx.Regions.A.ReconcilerApp -ceq 'lab-reconciler' -and $ctx.Regions.B.SyncApp -ceq 'lab-b-sync' -and $ctx.CosmosAccount -ceq 'lab-cosmos' -and $ctx.WorkspaceName -ceq 'lab-ws' -and $ctx.CoverageStartAt -ceq $coverage -and $ctx.Regions.B.Location -ceq 'centralus')
$wc = Get-DrWorkspaceCommands $ctx
Check 'workspace commands: JSON content type and a body file (no body = HTTP 415)' ($wc.failover -match 'Content-Type=application/json' -and $wc.failover -match "--body '@ws-empty.json'" -and $wc.failback -match '/providers/Microsoft\.OperationalInsights/workspaces/lab-ws/failback\?api-version=2025-02-01')

# ---- the driver end to end, with a stub `az` function in a child pwsh (no Azure call)
$dir = Join-Path $repo '.env.public-test-scratch/dr-failover'
Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $dir 'primary/.staged-state'), (Join-Path $dir 'standby-state') | Out-Null
$c = (Get-Content (Join-Path $repo 'infra/dr/dr.config.example.json') -Raw) -replace 'REPLACE-', '' | ConvertFrom-Json
$c.standby.stagedConfigPath = 'primary/staged.config.json'; $c.standby.stagedStateDirectory = 'primary/.staged-state'; $c.standby.stateDirectory = 'standby-state'
$writeCfg = { param($cov) $c.failover.ledgerCoverageStartAt = $cov; $c | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $dir 'dr.config.json') }
@{ subscriptionId = '00000000-0000-4000-8000-000000000002'; resourceGroup = 'rg-lab' } | ConvertTo-Json | Set-Content (Join-Path $dir 'primary/staged.config.json')
@{ stages = @{ '1' = @{ outputs = $pa } } } | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $dir 'primary/.staged-state/state.json')
@{ stages = @{ '1' = @{ outputs = $pb } } } | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $dir 'standby-state/state.json')
$stub = @'
function global:az {
    $l = $args -join ' '; Add-Content -LiteralPath $env:FAKE_AZ_LOG -Value $l; $global:LASTEXITCODE = 0
    if ($l -match 'appsettings list .*--name (\S+)') { $off = if ($Matches[1] -match 'reconciler') { 'false' } else { 'true' }
        return (@(@{ name = 'AzureWebJobs.syncEntitlement.Disabled'; value = $off }, @{ name = 'AzureWebJobs.reconcileBudgets.Disabled'; value = $off }) | ConvertTo-Json) }
    if ($l -match '^cosmosdb show') { return '{"provisioningState":"Succeeded","writeLocations":[{"locationName":"Central US"}]}' }
    if ($l -match '^rest --method get') { return '{"properties":{}}' }
    $global:LASTEXITCODE = 1; Write-Error "stub: unexpected $l"
}
'@
$runDriver = { param([string[]]$DriverArgs)
    $env:FAKE_AZ_LOG = Join-Path $dir 'az.log'; Set-Content $env:FAKE_AZ_LOG ''
    $cmd = "$stub; `$env:AZURE_CONFIG_DIR = '$dir'; & '$(Join-Path $repo 'infra/dr/Invoke-DrFailover.ps1')' $($DriverArgs -join ' ') -ConfigPath '$(Join-Path $dir 'dr.config.json')'; exit `$LASTEXITCODE"
    $out = pwsh -NoProfile -Command $cmd 2>&1 | Out-String
    @{ code = $LASTEXITCODE; out = $out; log = @(Get-Content $env:FAKE_AZ_LOG | Where-Object { $_ }) } }
& $writeCfg '2026-10-20T15:41:34Z'
$d = & $runDriver @('-Phase', 'Promote')
Check 'driver refuses a non-canonical coverage start before any az call (exit 2)' ($d.code -eq 2 -and $d.out -match 'failover\.ledgerCoverageStartAt:canonical_utc_milliseconds' -and $d.log.Count -eq 0)
& $writeCfg $coverage
$d = & $runDriver @('-Phase', 'Status')
$ev = @(Get-ChildItem (Join-Path $dir 'standby-state/evidence') -Filter 'failover-status-*.json')
Check 'driver Status: split-brain exits 4 and writes evidence' ($d.code -eq 4 -and $d.out -match 'ERROR: split_brain' -and $ev.Count -eq 1 -and (Get-Content $ev[0].FullName -Raw) -match 'split_brain')
$d = & $runDriver @('-Phase', 'Promote')
Check 'driver Promote refuses while region A writes, exit 3, no change' ($d.code -eq 3 -and $d.out -match 'source_writers_enabled' -and @($d.log | Where-Object { $_ -match 'appsettings (set|delete)' }).Count -eq 0)

# Every az argument recorded across all scenarios is free of cmd.exe metacharacters.
Check "no recorded az argument holds ( ) | & < > ^ ($($script:allCalls.Count) calls)" ($script:allCalls.Count -gt 50 -and @($script:allCalls | Where-Object { $_ -match '[()|&<>^]' }).Count -eq 0)

Write-Host "Test-DrFailover: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0 -or $script:pass -lt 62) { exit 1 }
