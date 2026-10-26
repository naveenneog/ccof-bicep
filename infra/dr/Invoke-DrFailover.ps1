<#
.SYNOPSIS
  Scripted, guarded DR promotion (to region B) and failback (to region A) for a CCOF deployment with a
  standby region built by infra/dr/Invoke-DrStandby.ps1 (docs/DR-ACTIVE-PASSIVE.md, ADR 0033, ADR 0036).

.DESCRIPTION
  Reads the same dr.config.json, primary staged state and standby state as Invoke-DrStandby.ps1. Every
  phase except Status previews without -Apply and changes Azure only with -Apply; every change is read
  back. At no point do both regions have a writer (sync or reconciler timer) enabled.

  -Phase Status          Read-only: writer timers, continuity gate, coverage start and baseline adoption
                         per region; Cosmos DB write region; workspace failover state; Front Door primary
                         origin host header. Exit 4 on split-brain (both regions writing).
  -Phase Fence           Disable both writers of -Region (default A).
  -Phase Promote         Region B becomes the writer. Refuses while region A writes (unless -FenceSource)
                         or while Cosmos DB does not write in region B (it prints the move command; it
                         never runs it). Sets gate on and failover.ledgerCoverageStartAt on reconciler B,
                         -AdoptBaseline sets RECONCILER_LEDGER_BASELINE_ADOPT once, then enables B.
  -Phase Failback        Fences region B first, then Cosmos DB back to region A (printed; run with
                         -MoveCosmos), removes baseline adoption in both regions, sets gate and coverage
                         on reconciler A, then enables region A.
  -Phase RemoveAdoption  Delete RECONCILER_LEDGER_BASELINE_ADOPT from -Region's reconciler.

  Not done here: Front Door (Invoke-DrFrontDoor.ps1) and the Log Analytics workspace switchover and
  failback (24-hour rule, separate owner); the phases print the exact REST calls.
  Evidence: standby.stateDirectory/evidence/failover-<phase>-<UTC time>.json, also on failure.

.EXAMPLE
  pwsh -NoProfile -File infra/dr/Invoke-DrFailover.ps1 -Phase Status -ConfigPath dr.config.json
  pwsh -NoProfile -File infra/dr/Invoke-DrFailover.ps1 -Phase Promote -ConfigPath dr.config.json -FenceSource -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Status', 'Fence', 'Promote', 'Failback', 'RemoveAdoption')] [string]$Phase,
    [Parameter(Mandatory)] [string]$ConfigPath,
    [ValidateSet('A', 'B')] [string]$Region = 'A',
    [switch]$FenceSource,
    [switch]$AdoptBaseline,
    [switch]$MoveCosmos,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
function Stop-Dr([string]$Message, [int]$Code) { [Console]::Error.WriteLine($Message); exit $Code }
if (-not (Test-Path -LiteralPath $ConfigPath)) { Stop-Dr "No configuration file at ${ConfigPath}: copy infra/dr/dr.config.example.json and replace every REPLACE- value." 2 }
$drPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$drText = Get-Content -LiteralPath $drPath -Raw
$dr = $drText | ConvertFrom-Json
Import-Module (Join-Path $here 'DrPrerequisites.psm1') -Force
Import-Module (Join-Path $here 'DrStandby.psm1') -Force
Import-Module (Join-Path $here 'DrFailover.psm1') -Force
# ConvertFrom-Json turns the coverage start into a DateTime; check the text as written.
$coverage = Get-DrJsonText $drText 'failover.ledgerCoverageStartAt'
if ($null -ne $coverage) { $dr.failover.ledgerCoverageStartAt = $coverage }
$problems = @(Get-DrConfigProblems $dr) + @(Get-DrStandbyProblems $dr) + @(Get-DrFailoverProblems $dr -RequireCoverage:($Phase -in 'Promote', 'Failback'))
if ($problems.Count) { Stop-Dr "Configuration refused: $($problems -join ', ')" 2 }
$azProfile = Resolve-DrAzureProfile -ConfigDir $env:AZURE_CONFIG_DIR -CloudShell $env:ACC_CLOUD -HomePath $HOME
if (-not $azProfile.Ok) { Stop-Dr $azProfile.Message 2 }
$env:AZURE_CONFIG_DIR = $azProfile.ConfigDir

function Resolve-DrPath([string]$Path) { if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path (Split-Path $drPath -Parent) $Path } }
$primaryConfigPath = Resolve-DrPath $dr.standby.stagedConfigPath
$primaryStatePath = Join-Path (Resolve-DrPath $dr.standby.stagedStateDirectory) 'state.json'
$standbyStateDir = Resolve-DrPath $dr.standby.stateDirectory
$standbyStatePath = Join-Path $standbyStateDir 'state.json'
foreach ($p in $primaryConfigPath, $primaryStatePath, $standbyStatePath) { if (-not (Test-Path -LiteralPath $p)) { Stop-Dr "Not found: $p (the primary's staged configuration and state, and region B's state from Invoke-DrStandby.ps1 -Phase Shells)." 2 } }
$read = { param($f) Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable -Depth 100 }
$primaryCfg = & $read $primaryConfigPath
$aS1 = (& $read $primaryStatePath).stages['1'].outputs
$bS1 = (& $read $standbyStatePath).stages['1'].outputs
$fdPath = Join-Path $standbyStateDir 'frontdoor-state.json'
$fdProfile = if (Test-Path -LiteralPath $fdPath) { [string](& $read $fdPath).profileName } else { '' }

$ctx = New-DrFailoverContext -Dr $dr -Subscription ([string]$primaryCfg.subscriptionId) -ResourceGroup ([string]$primaryCfg.resourceGroup) `
    -PrimaryStage1 $aS1 -StandbyStage1 $bS1 -FrontDoorProfile $fdProfile -CoverageStartAt $coverage -Az { param([string[]]$Arguments) Invoke-DrAzCli $Arguments }
foreach ($k in 'A', 'B') { if (-not $ctx.Regions[$k].SyncApp -or -not $ctx.Regions[$k].ReconcilerApp) { Stop-Dr "state_incomplete: region $k Stage 1 state names no sync or reconciler app." 2 } }
$mode = if ($Phase -eq 'Status') { 'read-only' } elseif ($Apply) { 'apply' } else { 'preview' }
Write-Host "== DR failover phase $Phase ($mode): $($primaryCfg.resourceGroup), region A $($ctx.Regions.A.Location), region B $($ctx.Regions.B.Location)"

$evidenceDir = Join-Path $standbyStateDir 'evidence'
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null
$evidence = [ordered]@{ schema = 'ccof.dr.failover.v1'; phase = $Phase; apply = [bool]$Apply; region = $Region
    switches = [ordered]@{ fenceSource = [bool]$FenceSource; adoptBaseline = [bool]$AdoptBaseline; moveCosmos = [bool]$MoveCosmos }
    startedAt = [DateTime]::UtcNow.ToString('o'); commit = (git -C (Split-Path (Split-Path $here -Parent) -Parent) rev-parse HEAD 2>$null) }
$code = 0
try {
    switch ($Phase) {
        'Status' { $evidence.status = Get-DrFailoverStatus $ctx }
        'Fence' { $evidence.run = Invoke-DrFence $ctx -Region $Region -Apply:$Apply }
        'Promote' { $evidence.run = Invoke-DrPromote $ctx -FenceSource:$FenceSource -AdoptBaseline:$AdoptBaseline -Apply:$Apply }
        'Failback' { $evidence.run = Invoke-DrFailback $ctx -MoveCosmos:$MoveCosmos -Apply:$Apply }
        'RemoveAdoption' { $evidence.run = Invoke-DrRemoveAdoption $ctx -Region $Region -Apply:$Apply }
    }
    if ($Phase -ne 'Status' -and $Apply) { $evidence.after = Get-DrFailoverStatus $ctx }
} catch {
    $evidence.error = "$_"
    if ($ctx.ContainsKey('Steps') -and $null -ne $ctx.Steps) { $evidence.stepsBeforeError = @($ctx.Steps) }
    try { $evidence.after = Get-DrFailoverStatus $ctx } catch { $evidence.afterError = "$_" }
    $code = 3
}
$evidence.completedAt = [DateTime]::UtcNow.ToString('o')
$status = if ($evidence.Contains('after')) { $evidence.after } elseif ($evidence.Contains('status')) { $evidence.status } else { $null }
if ($status -and @($status.problems) -contains 'split_brain' -and $code -eq 0) { $code = 4 }
$file = Join-Path $evidenceDir ("failover-$($Phase.ToLower())-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')).json")
$evidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file -Encoding utf8NoBOM
if ($status) {
    foreach ($k in 'A', 'B') {
        $r = $status.regions[$k]
        Write-Host ("region {0} ({1}): writing={2} sync.Disabled={3} reconcile.Disabled={4} gate={5} coverage={6} adopt={7}" -f $k, $r.location, $r.writing, $r.syncDisabled, $r.reconcilerDisabled, $r.gate, $r.coverageStartAt, $r.baselineAdopt)
    }
    if ($status.Contains('cosmos') -and $status.cosmos.Contains('writeRegion')) { Write-Host "Cosmos DB $($status.cosmos.account): write region $($status.cosmos.writeRegion) ($($status.cosmos.provisioningState))" }
    if ($status.Contains('workspace') -and $status.workspace.Contains('name')) { Write-Host "workspace $($status.workspace.name): failover $(($status.workspace.failover | ConvertTo-Json -Compress -Depth 5)); switchover allowed after $($status.workspace.switchoverAllowedAfter)" }
    if ($status.Contains('frontDoor') -and $status.frontDoor.Contains('primaryGateway')) { Write-Host "Front Door $($status.frontDoor.profile): primary gateway host header $($status.frontDoor.primaryGateway.originHostHeader) (drill fault: $($status.frontDoor.primaryGateway.faulted))" }
    foreach ($w in @($status.warnings)) { Write-Host "warning: $w" -ForegroundColor Yellow }
    foreach ($p in @($status.problems)) { Write-Host "ERROR: $p (both regions have a writer enabled; fence one: -Phase Fence -Region <A|B> -Apply)" -ForegroundColor Red }
}
Write-Host "evidence: $file"
if ($evidence.Contains('error')) { Stop-Dr "refused or failed: $($evidence.error)" $code }
if ($code) { exit $code }
if ($evidence.Contains('run')) { Write-Host "result: $($evidence.run.result)" -ForegroundColor Green }
