# Scripted DR promotion and failback for infra/dr/Invoke-DrFailover.ps1 (docs/DR-ACTIVE-PASSIVE.md,
# docs/runbooks/DR-STANDBY-CLOUD-SHELL.md sections 11-12, ADR 0036). Every Azure call goes through
# $Ctx.Az, so tests/Test-DrFailover.ps1 replaces Azure with an in-memory fake.
# Invariant: at no point do both regions have a writer (sync or reconciler timer) enabled. A region is
# fenced before the other is enabled, and every change is read back before the next one.
Set-StrictMode -Version Latest

$script:Sync = 'AzureWebJobs.syncEntitlement.Disabled'
$script:Rec = 'AzureWebJobs.reconcileBudgets.Disabled'
$script:Gate = 'RECONCILER_CONTINUITY_GATE'
$script:Coverage = 'RECONCILER_LEDGER_COVERAGE_START_AT'
$script:Adopt = 'RECONCILER_LEDGER_BASELINE_ADOPT'
$script:Arm = 'https://management.azure.com'
$script:WorkspaceApi = '2025-02-01'
$script:DrillHost = 'dr-drill.invalid'  # infra/dr/frontdoor.bicep, simulatePrimaryFailure
$script:Inv = [Globalization.CultureInfo]::InvariantCulture

# az.cmd on Windows re-parses its arguments through cmd.exe, so these characters would be
# interpreted as shell syntax. Request bodies go in files (`--body @file`).
function Assert-DrAzArguments {
    param([string[]]$Arguments)
    foreach ($a in $Arguments) {
        if ("$a" -match '[()|&<>^"%\r\n]') { throw "az_argument_unsafe: '$a' holds a character that cmd.exe re-parses (az.cmd on Windows); use a body file instead." }
    }
}

function Invoke-DrFailoverAz {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)] [string[]]$Arguments)
    Assert-DrAzArguments $Arguments
    & $Ctx.Az $Arguments
}

function ConvertFrom-DrJson {
    param([string]$Text)
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return $Text | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String }
    return $Text | ConvertFrom-Json -AsHashtable -Depth 100
}

# The real Azure CLI. JSON output; date-like strings stay strings where PowerShell allows it.
function Invoke-DrAzCli {
    param([string[]]$Arguments)
    Assert-DrAzArguments $Arguments
    $out = & az @Arguments --output json --only-show-errors 2>&1
    $code = $LASTEXITCODE
    $err = (@($out | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) -join ' ').Trim()
    $text = (@($out | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) -join "`n").Trim()
    if ($code -ne 0) { throw "az $($Arguments[0..([Math]::Min(2, $Arguments.Count - 1))] -join ' ') failed: $($err.Substring(0, [Math]::Min(500, $err.Length)))" }
    if (-not $text) { return $null }
    return ConvertFrom-DrJson $text
}

# A UTC "Z" instant, with or without fractional seconds, in the reconciler's normalized millisecond
# form (src/reconciler/settings.ts parseUtcInstant); $null for anything else. App Service reads back
# "2026-10-20T15:41:34.000Z" as "2026-10-20T15:41:34Z" (ADR 0036 amendment).
function ConvertTo-DrUtcInstant {
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", $script:Inv) }
    $s = [string]$Value
    if ($s -cnotmatch '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?Z$') { return $null }
    $whole = $Matches[1]; $fraction = if ($Matches.Count -gt 2 -and $Matches[2]) { $Matches[2] } else { '' }
    $d = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [datetime]::TryParseExact($whole, "yyyy-MM-dd'T'HH:mm:ss", $script:Inv, $styles, [ref]$d)) { return $null }
    return "$whole.$($fraction.PadRight(3, '0').Substring(0, 3))Z"
}

# dr.config.json holds the coverage start in the canonical form the reconciler writes markers in.
function Test-DrCanonicalCoverage {
    param($Value)
    return ($Value -is [string]) -and ($Value -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$') -and ((ConvertTo-DrUtcInstant $Value) -ceq $Value)
}

# A string value from JSON text exactly as written (ConvertFrom-Json turns ISO dates into DateTime).
function Get-DrJsonText {
    param([Parameter(Mandatory)] [string]$Json, [Parameter(Mandatory)] [string]$Path)
    $e = [Text.Json.JsonDocument]::Parse($Json).RootElement
    foreach ($p in $Path.Split('.')) {
        if ($e.ValueKind -ne [Text.Json.JsonValueKind]::Object) { return $null }
        $next = [Text.Json.JsonElement]::new()
        if (-not $e.TryGetProperty($p, [ref]$next)) { return $null }
        $e = $next
    }
    if ($e.ValueKind -eq [Text.Json.JsonValueKind]::String) { return $e.GetString() }
    return $e.GetRawText()
}

function Get-DrFailoverProblems {
    param([Parameter(Mandatory)] $Config, [switch]$RequireCoverage)
    $f = if ($Config.PSObject.Properties['failover']) { $Config.failover } else { $null }
    $v = if ($f -and $f.PSObject.Properties['ledgerCoverageStartAt']) { $f.ledgerCoverageStartAt } else { $null }
    if ($null -eq $v -or "$v" -eq '') { if ($RequireCoverage) { return @('failover.ledgerCoverageStartAt:required') }; return @() }
    if ("$v" -match '^REPLACE') { return @('failover.ledgerCoverageStartAt:placeholder') }
    if (-not (Test-DrCanonicalCoverage $v)) { return @('failover.ledgerCoverageStartAt:canonical_utc_milliseconds') }
    return @()
}

function New-DrFailoverContext {
    param([Parameter(Mandatory)] $Dr, [Parameter(Mandatory)] [string]$Subscription, [Parameter(Mandatory)] [string]$ResourceGroup,
        [Parameter(Mandatory)] [Collections.IDictionary]$PrimaryStage1, [Parameter(Mandatory)] [Collections.IDictionary]$StandbyStage1,
        [string]$FrontDoorProfile, [string]$CoverageStartAt, [Parameter(Mandatory)] [scriptblock]$Az)
    $region = { param($n, $s1, $loc) @{ Name = $n; Location = [string]$loc; SyncApp = [string]$s1.names.apps.sync.functionApp; ReconcilerApp = [string]$s1.names.apps.reconciler.functionApp } }
    if (-not $CoverageStartAt -and $Dr.PSObject.Properties['failover'] -and $Dr.failover.PSObject.Properties['ledgerCoverageStartAt']) { $CoverageStartAt = [string]$Dr.failover.ledgerCoverageStartAt }
    return @{
        Subscription = $Subscription; ResourceGroup = $ResourceGroup; Az = $Az; PollSeconds = 15; PollAttempts = 80
        CosmosAccount = [string]$PrimaryStage1.names.cosmosAccount
        WorkspaceName = ([string]$PrimaryStage1.workspaceId).Split('/')[-1]
        FrontDoorProfile = $FrontDoorProfile; CoverageStartAt = $CoverageStartAt
        Regions = @{ A = (& $region 'A' $PrimaryStage1 $Dr.primary.location); B = (& $region 'B' $StandbyStage1 $Dr.secondary.location) }
    }
}

function Write-DrStep {
    param($Ctx, [string]$Message)
    if ($Ctx.ContainsKey('Steps') -and $null -ne $Ctx.Steps) { $Ctx.Steps.Add($Message) }
    if ($Ctx.ContainsKey('Log') -and $Ctx.Log) { & $Ctx.Log $Message } else { Write-Host $Message }
}

function Start-DrRun {
    param($Ctx, [string]$Phase, [bool]$Apply)
    $Ctx.Steps = [Collections.Generic.List[string]]::new()
    return [ordered]@{ phase = $Phase; apply = $Apply; startedAt = [DateTime]::UtcNow.ToString('o'); steps = $Ctx.Steps; result = $null }
}

function Get-DrAppArgs { param($Ctx, [string]$Verb, [string]$App) @('functionapp', 'config', 'appsettings', $Verb, '--subscription', $Ctx.Subscription, '--resource-group', $Ctx.ResourceGroup, '--name', $App) }

function Get-DrAppSettings {
    param($Ctx, [string]$App)
    $h = @{}
    foreach ($s in @(Invoke-DrFailoverAz $Ctx (Get-DrAppArgs $Ctx 'list' $App))) {
        if ($null -eq $s) { continue }
        $h[[string]$s.name] = if ($s.value -is [datetime]) { ConvertTo-DrUtcInstant $s.value } else { $s.value }
    }
    return $h
}

function Test-DrOff { param($Value) "$Value" -ieq 'true' }
function Test-DrSameRegion { param([string]$A, [string]$B) ($A -replace '\s', '').ToLowerInvariant() -ceq ($B -replace '\s', '').ToLowerInvariant() }

function Get-DrRegionState {
    param($Ctx, [string]$Region)
    $r = $Ctx.Regions[$Region]
    $sy = Get-DrAppSettings $Ctx $r.SyncApp
    $re = Get-DrAppSettings $Ctx $r.ReconcilerApp
    $norm = { param($v) if ($null -eq $v) { $null } else { $n = ConvertTo-DrUtcInstant $v; if ($n) { $n } else { "$v" } } }
    $sd = $sy[$script:Sync]; $rd = $re[$script:Rec]
    return [ordered]@{
        location = $r.Location; syncApp = $r.SyncApp; reconcilerApp = $r.ReconcilerApp
        syncDisabled = $sd; reconcilerDisabled = $rd
        writing = -not ((Test-DrOff $sd) -and (Test-DrOff $rd)); fenced = (Test-DrOff $sd) -and (Test-DrOff $rd)
        gate = $re[$script:Gate]; coverageStartAt = (& $norm $re[$script:Coverage]); baselineAdopt = (& $norm $re[$script:Adopt])
    }
}

function Get-DrCosmos {
    param($Ctx)
    $c = Invoke-DrFailoverAz $Ctx @('cosmosdb', 'show', '--subscription', $Ctx.Subscription, '--resource-group', $Ctx.ResourceGroup, '--name', $Ctx.CosmosAccount)
    return [ordered]@{ account = $Ctx.CosmosAccount; writeRegion = [string]@($c.writeLocations)[0].locationName; provisioningState = [string]$c.provisioningState }
}

function Get-DrCosmosMoveCommand {
    param($Ctx, [ValidateSet('A', 'B')] [string]$To)
    $from = if ($To -eq 'A') { 'B' } else { 'A' }
    return "az cosmosdb failover-priority-change --subscription $($Ctx.Subscription) --resource-group $($Ctx.ResourceGroup) --name $($Ctx.CosmosAccount) --failover-policies $($Ctx.Regions[$To].Location)=0 $($Ctx.Regions[$from].Location)=1"
}

# Not run by the driver (24-hour rule, owned by the monitoring team). Without a JSON body the service
# answers HTTP 415 (runbook section 11.4).
function Get-DrWorkspaceCommands {
    param($Ctx)
    $base = "$script:Arm/subscriptions/$($Ctx.Subscription)/resourceGroups/$($Ctx.ResourceGroup)/providers/Microsoft.OperationalInsights"
    $body = "Set-Content -Path ws-empty.json -Value '{}'"
    $rest = "az rest --method post --headers Content-Type=application/json --body '@ws-empty.json' --url"
    return [ordered]@{
        failover = "$body; $rest '$base/locations/$($Ctx.Regions.B.Location)/workspaces/$($Ctx.WorkspaceName)/failover?api-version=$script:WorkspaceApi'"
        failback = "$body; $rest '$base/workspaces/$($Ctx.WorkspaceName)/failback?api-version=$script:WorkspaceApi'"
    }
}

function Get-DrWorkspaceStatus {
    param($Ctx)
    $ws = Invoke-DrFailoverAz $Ctx @('rest', '--method', 'get', '--url', "$script:Arm/subscriptions/$($Ctx.Subscription)/resourceGroups/$($Ctx.ResourceGroup)/providers/Microsoft.OperationalInsights/workspaces/$($Ctx.WorkspaceName)?api-version=$script:WorkspaceApi")
    $p = $ws.properties
    $failover = if ($p -is [Collections.IDictionary] -and $p.Contains('failover')) { $p.failover } else { $null }
    $replication = if ($p -is [Collections.IDictionary] -and $p.Contains('replication')) { $p.replication } else { $null }
    $now = if ($Ctx.ContainsKey('Now') -and $Ctx.Now) { $Ctx.Now } else { [DateTime]::UtcNow }
    $coverage = Get-DrReplicationCoverage -Replication $replication -Now $now
    return [ordered]@{ name = $Ctx.WorkspaceName; failover = $failover; replication = $replication; switchoverAllowedAfter = $coverage.switchoverAllowedAfter; coverage = $coverage; commands = (Get-DrWorkspaceCommands $Ctx) }
}

# Workspace replication copies only data ingested after it is enabled, and tables can take up to one
# hour to start replicating (learn.microsoft.com/azure/azure-monitor/logs/workspace-replication). The
# reconciler's billing period is the UTC calendar month (src/reconciler/period.ts), so the replica holds
# whole periods from the first month start at least one hour after createdDate (ADR 0038).
function Get-DrReplicationCoverage {
    param($Replication, [datetime]$Now = [DateTime]::UtcNow)
    $c = [ordered]@{ enabled = $false; location = $null; provisioningState = $null; createdDate = $null; switchoverAllowedAfter = $null; fullMonthFrom = $null; fullMonthNow = $false }
    if (-not ($Replication -is [Collections.IDictionary]) -or $Replication['enabled'] -ne $true) { return $c }
    $c.enabled = $true; $c.location = $Replication['location']; $c.provisioningState = $Replication['provisioningState']
    $created = ConvertTo-DrUtcInstant $Replication['createdDate']
    if (-not $created) { return $c }
    $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
    $at = [datetime]::Parse($created, $script:Inv, $styles)
    $ready = $at.AddHours(1)
    $from = [datetime]::new($ready.Year, $ready.Month, 1, 0, 0, 0, [DateTimeKind]::Utc)
    if ($from -lt $ready) { $from = $from.AddMonths(1) }
    $c.createdDate = $created
    $c.switchoverAllowedAfter = ConvertTo-DrUtcInstant $at.AddHours(24)
    $c.fullMonthFrom = ConvertTo-DrUtcInstant $from
    $c.fullMonthNow = $Now.ToUniversalTime() -ge $from
    return $c
}

# 'enable', 'wait' (a change is in progress) or 'none'; throws when replication points elsewhere.
function Get-DrReplicationPlan {
    param([Parameter(Mandatory)] $Workspace, [Parameter(Mandatory)] [string]$Location)
    if (Test-DrSameRegion $Workspace.location $Location) { throw "replication_same_region: the workspace is in $($Workspace.location); replication needs a different region (the standby region)." }
    $p = $Workspace.properties
    $r = if ($p -is [Collections.IDictionary] -and $p.Contains('replication')) { $p.replication } else { $null }
    if (-not ($r -is [Collections.IDictionary]) -or $r['enabled'] -ne $true) { return 'enable' }
    if (-not (Test-DrSameRegion ([string]$r['location']) $Location)) { throw "replication_other_location: replication is enabled to $($r['location']), not $Location. Disable it first: infra/dr/Enable-WorkspaceReplication.ps1 -Disable -Apply." }
    if ([string]$r['provisioningState'] -ceq 'Succeeded') { return 'none' }
    return 'wait'
}

# The workspace REST PUT replaces the whole object, so the body carries every property read back.
function New-DrReplicationBody {
    param([Parameter(Mandatory)] $Workspace, [string]$Location, [switch]$Disable)
    if (-not $Disable -and -not $Location) { throw 'replication_location_missing: a location is needed to enable replication.' }
    $props = [ordered]@{}
    foreach ($k in $Workspace.properties.Keys) { if ($k -cne 'replication') { $props[$k] = $Workspace.properties[$k] } }
    $props.replication = if ($Disable) { [ordered]@{ enabled = $false } } else { [ordered]@{ enabled = $true; location = $Location } }
    return [ordered]@{ location = $Workspace.location; tags = $Workspace.tags; properties = $props }
}

function Get-DrFrontDoorStatus {
    param($Ctx)
    if (-not $Ctx.FrontDoorProfile) { return [ordered]@{ profile = $null; note = 'frontdoor-state.json has no profile; run Invoke-DrFrontDoor.ps1 -Phase Deploy -Apply first.' } }
    $fd = [ordered]@{ profile = $Ctx.FrontDoorProfile }
    foreach ($o in @(@{ k = 'primaryGateway'; g = 'apim'; n = 'primary-gateway' }, @{ k = 'primaryAdmin'; g = 'admin'; n = 'primary-admin' })) {
        $url = "$script:Arm/subscriptions/$($Ctx.Subscription)/resourceGroups/$($Ctx.ResourceGroup)/providers/Microsoft.Cdn/profiles/$($Ctx.FrontDoorProfile)/originGroups/$($o.g)/origins/$($o.n)?api-version=2024-02-01"
        $h = [string](Invoke-DrFailoverAz $Ctx @('rest', '--method', 'get', '--url', $url)).properties.originHostHeader
        $fd[$o.k] = [ordered]@{ originHostHeader = $h; faulted = ($h -ceq $script:DrillHost) }
    }
    return $fd
}

# Read-only. A read that fails is reported, except an unsafe argument, which stops the run.
function Get-DrFailoverStatus {
    param([Parameter(Mandatory)] $Ctx)
    $s = [ordered]@{ regions = [ordered]@{}; problems = [Collections.Generic.List[string]]::new(); warnings = [Collections.Generic.List[string]]::new() }
    $regions = $s.regions
    foreach ($k in 'A', 'B') {
        try { $regions[$k] = Get-DrRegionState $Ctx $k }
        catch {
            if ("$_" -match 'az_argument_unsafe') { throw }
            $regions[$k] = [ordered]@{ location = $Ctx.Regions[$k].Location; error = "$_"; syncDisabled = $null; reconcilerDisabled = $null; writing = $null; fenced = $null; gate = $null; coverageStartAt = $null; baselineAdopt = $null }
            $s.warnings.Add("region_${k}_unreadable")
        }
    }
    if ($regions.A.writing -and $regions.B.writing) { $s.problems.Add('split_brain') }
    foreach ($part in @(@{ k = 'cosmos'; f = 'Get-DrCosmos' }, @{ k = 'workspace'; f = 'Get-DrWorkspaceStatus' }, @{ k = 'frontDoor'; f = 'Get-DrFrontDoorStatus' })) {
        try { $s[$part.k] = & $part.f $Ctx } catch { if ("$_" -match 'az_argument_unsafe') { throw }; $s[$part.k] = [ordered]@{ error = "$_" }; $s.warnings.Add("$($part.k)_unreadable") }
    }
    foreach ($k in 'A', 'B') {
        $r = $regions[$k]
        if ($r.writing -and $r.gate -cne 'on') { $s.warnings.Add("region_${k}_writes_without_gate") }
        if ($r.baselineAdopt) { $s.warnings.Add("region_${k}_baseline_adopt_set") }
        if ($r.writing -and $s.cosmos -is [Collections.IDictionary] -and $s.cosmos.Contains('writeRegion') -and -not (Test-DrSameRegion $s.cosmos.writeRegion $r.location)) { $s.warnings.Add("region_${k}_writes_but_cosmos_writes_in_$($s.cosmos.writeRegion -replace '\s', '')") }
    }
    if ($s.workspace -is [Collections.IDictionary] -and $s.workspace.Contains('coverage')) {
        if (-not $s.workspace.coverage.enabled) { $s.warnings.Add('workspace_replication_off') }
        elseif (-not $s.workspace.coverage.fullMonthNow) { $s.warnings.Add('workspace_replication_partial_month') }
    }
    return $s
}

function Set-DrSetting {
    param($Ctx, [string]$App, [string]$Name, [string]$Value, [switch]$Instant)
    $same = { param($v) if ($Instant) { $n = ConvertTo-DrUtcInstant $v; $n -and $n -ceq (ConvertTo-DrUtcInstant $Value) } else { "$v" -ceq $Value } }
    $cur = (Get-DrAppSettings $Ctx $App)[$Name]
    if (& $same $cur) { Write-DrStep $Ctx "$App ${Name}: already $cur"; return }
    $null = Invoke-DrFailoverAz $Ctx ((Get-DrAppArgs $Ctx 'set' $App) + @('--settings', "$Name=$Value"))
    $cur = (Get-DrAppSettings $Ctx $App)[$Name]
    if (-not (& $same $cur)) { throw "readback_mismatch: $App $Name reads back '$cur', expected '$Value'." }
    Write-DrStep $Ctx "$App ${Name}=$Value (read back $cur)"
}

function Remove-DrSetting {
    param($Ctx, [string]$App, [string]$Name)
    if ($null -eq (Get-DrAppSettings $Ctx $App)[$Name]) { Write-DrStep $Ctx "$App ${Name}: absent"; return }
    $null = Invoke-DrFailoverAz $Ctx ((Get-DrAppArgs $Ctx 'delete' $App) + @('--setting-names', $Name))
    $cur = (Get-DrAppSettings $Ctx $App)[$Name]
    if ($null -ne $cur) { throw "readback_mismatch: $App $Name still reads '$cur' after delete." }
    Write-DrStep $Ctx "$App ${Name}: deleted (read back absent)"
}

# Enabling: reconciler, then sync. Disabling: sync, then reconciler.
function Set-DrWriters {
    param($Ctx, [string]$Region, [bool]$Enabled)
    $r = $Ctx.Regions[$Region]
    if ($Enabled) { Set-DrSetting $Ctx $r.ReconcilerApp $script:Rec 'false'; Set-DrSetting $Ctx $r.SyncApp $script:Sync 'false' }
    else { Set-DrSetting $Ctx $r.SyncApp $script:Sync 'true'; Set-DrSetting $Ctx $r.ReconcilerApp $script:Rec 'true' }
}

function Assert-DrFenced {
    param($Ctx, [string]$Region, [string]$Code)
    $s = Get-DrRegionState $Ctx $Region
    if ($s.writing) { throw "${Code}: region $Region has a writer enabled ($script:Sync=$($s.syncDisabled), $script:Rec=$($s.reconcilerDisabled)). Fence it first: -Phase Fence -Region $Region -Apply." }
}

function Assert-DrCoverage {
    param($Ctx)
    if (-not (Test-DrCanonicalCoverage $Ctx.CoverageStartAt)) { throw "coverage_invalid: failover.ledgerCoverageStartAt '$($Ctx.CoverageStartAt)' must be a canonical UTC instant with milliseconds, for example 2026-10-20T15:41:34.000Z." }
}

function Assert-DrCosmosIn {
    param($Ctx, [string]$Region, [string]$Advice)
    $c = Get-DrCosmos $Ctx
    if (-not (Test-DrSameRegion $c.writeRegion $Ctx.Regions[$Region].Location)) {
        throw "cosmos_write_region: Cosmos DB writes in $($c.writeRegion), not region $Region ($($Ctx.Regions[$Region].Location)). $Advice $(Get-DrCosmosMoveCommand $Ctx $Region)"
    }
    Write-DrStep $Ctx "Cosmos DB writes in $($c.writeRegion) (region $Region)"
}

# Gate on and coverage start on a region's reconciler; adoption only when asked for, else removed.
function Set-DrGate {
    param($Ctx, [string]$Region, [switch]$AdoptBaseline)
    $app = $Ctx.Regions[$Region].ReconcilerApp
    Set-DrSetting $Ctx $app $script:Gate 'on'
    Set-DrSetting $Ctx $app $script:Coverage $Ctx.CoverageStartAt -Instant
    if ($AdoptBaseline) { Set-DrSetting $Ctx $app $script:Adopt $Ctx.CoverageStartAt -Instant } else { Remove-DrSetting $Ctx $app $script:Adopt }
}

function Invoke-DrFence {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)] [ValidateSet('A', 'B')] [string]$Region, [switch]$Apply)
    $run = Start-DrRun $Ctx 'Fence' $Apply
    $s = Get-DrRegionState $Ctx $Region
    if (-not $Apply) { Write-DrStep $Ctx "preview: set $script:Sync and $script:Rec to true on region $Region (now $($s.syncDisabled), $($s.reconcilerDisabled))."; $run.result = 'preview'; return $run }
    Set-DrWriters $Ctx $Region $false
    Assert-DrFenced $Ctx $Region 'fence_failed'
    $run.result = 'fenced'; return $run
}

function Invoke-DrRemoveAdoption {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)] [ValidateSet('A', 'B')] [string]$Region, [switch]$Apply)
    $run = Start-DrRun $Ctx 'RemoveAdoption' $Apply
    $app = $Ctx.Regions[$Region].ReconcilerApp
    if (-not $Apply) { Write-DrStep $Ctx "preview: delete $script:Adopt from $app (now '$((Get-DrAppSettings $Ctx $app)[$script:Adopt])')."; $run.result = 'preview'; return $run }
    Remove-DrSetting $Ctx $app $script:Adopt
    $run.result = 'adoption_removed'; return $run
}

# Region A's writer state, or $null when region A's settings cannot be read and the operator has
# declared it unreachable (UNKNOWNS DR-18, ADR 0036). Without -SourceUnreachable an unreadable region
# A stops Promote. A region A that answers is always checked, with or without the declaration.
function Get-DrSourceState {
    param($Ctx, [string]$Unreachable, $Run)
    try { return Get-DrRegionState $Ctx 'A' }
    catch {
        if ("$_" -match 'az_argument_unsafe') { throw }
        if (-not $Unreachable) {
            throw "source_unreachable: region A's writer settings cannot be read ($_). Promote does not enable region B while region A's writers are unknown. If region A is down (Azure Service Health shows the outage), rerun with -SourceUnreachable '<incident ID and evidence>'; region A must be fenced before it is brought back (docs/DR-ACTIVE-PASSIVE.md failover step 6)."
        }
        if (-not $Run.Contains('sourceUnreachable')) { $Run.sourceUnreachable = [ordered]@{ reason = $Unreachable; error = "$_"; at = [DateTime]::UtcNow.ToString('o') } }
        Write-DrStep $Ctx "region A unreadable, declared unreachable: $Unreachable ($_)"
        return $null
    }
}

function Assert-DrSourceFenced {
    param($Ctx, [string]$Unreachable, $Run)
    $s = Get-DrSourceState $Ctx $Unreachable $Run
    if ($s -and $s.writing) { throw "source_writers_enabled: region A has a writer enabled ($script:Sync=$($s.syncDisabled), $script:Rec=$($s.reconcilerDisabled)). Fence it first: -Phase Fence -Region A -Apply." }
}

# Region B becomes the writer. Cosmos DB must already write in region B; this phase never moves it.
function Invoke-DrPromote {
    param([Parameter(Mandatory)] $Ctx, [switch]$FenceSource, [switch]$AdoptBaseline, [string]$SourceUnreachable, [switch]$Apply)
    $run = Start-DrRun $Ctx 'Promote' $Apply
    Assert-DrCoverage $Ctx
    if ($PSBoundParameters.ContainsKey('SourceUnreachable') -and $SourceUnreachable.Trim().Length -lt 10) {
        throw "source_unreachable_reason: -SourceUnreachable needs a reason of at least 10 characters, for example the Azure Service Health incident ID. It is recorded in the evidence file."
    }
    $src = Get-DrSourceState $Ctx $SourceUnreachable $run
    if ($src -and $src.writing -and -not $FenceSource) { throw "source_writers_enabled: region A has a writer enabled ($script:Sync=$($src.syncDisabled), $script:Rec=$($src.reconcilerDisabled)). Fence it first: -Phase Fence -Region A -Apply, or add -FenceSource." }
    Assert-DrCosmosIn $Ctx 'B' 'Promote does not move Cosmos DB. After confirming the region A outage (docs/DR-ACTIVE-PASSIVE.md failover step 3), run:'
    $ws = Get-DrWorkspaceCommands $Ctx
    if (-not $Apply) {
        if (-not $src) { Write-DrStep $Ctx "preview: region A not fenced (unreadable). Reason recorded: $SourceUnreachable. Fence region A before it is brought back." }
        elseif ($src.writing) { Write-DrStep $Ctx 'preview: fence region A (sync, reconciler Disabled=true).' }
        Write-DrStep $Ctx "preview: region B reconciler $script:Gate=on, $script:Coverage=$($Ctx.CoverageStartAt)$(if ($AdoptBaseline) { ", $script:Adopt=$($Ctx.CoverageStartAt)" } else { ", delete $script:Adopt" })."
        Write-DrStep $Ctx 'preview: enable region B reconciler, then sync (Disabled=false). Rerun with -Apply.'
        Write-DrStep $Ctx "workspace switchover (not run here; 24 hours after replication was enabled): $($ws.failover)"
        $run.result = 'preview'; return $run
    }
    if ($src -and $src.writing) { Set-DrWriters $Ctx 'A' $false }
    Assert-DrSourceFenced $Ctx $SourceUnreachable $run
    Set-DrGate $Ctx 'B' -AdoptBaseline:$AdoptBaseline
    Assert-DrSourceFenced $Ctx $SourceUnreachable $run
    Assert-DrCosmosIn $Ctx 'B' 'Cosmos DB moved during Promote; region B writers stay off. Move it back with:'
    Set-DrWriters $Ctx 'B' $true
    if ($run.Contains('sourceUnreachable')) { Write-DrStep $Ctx 'region A was not fenced (unreadable). Before region A comes back: -Phase Fence -Region A -Apply, then -Phase Status.' }
    Write-DrStep $Ctx "workspace switchover (not run here; 24 hours after replication was enabled): $($ws.failover)"
    if ($AdoptBaseline) { Write-DrStep $Ctx 'after one written run with gate passed: -Phase RemoveAdoption -Region B -Apply.' }
    $run.result = 'promoted'; return $run
}

# Region A becomes the writer again. Region B is fenced first; a failure after that leaves both
# regions fenced, never both writing.
function Invoke-DrFailback {
    param([Parameter(Mandatory)] $Ctx, [switch]$MoveCosmos, [switch]$Apply)
    $run = Start-DrRun $Ctx 'Failback' $Apply
    Assert-DrCoverage $Ctx
    $ws = Get-DrWorkspaceCommands $Ctx
    $move = Get-DrCosmosMoveCommand $Ctx 'A'
    if (-not $Apply) {
        $c = Get-DrCosmos $Ctx
        Write-DrStep $Ctx "workspace failback (not run here; before or after this phase): $($ws.failback)"
        Write-DrStep $Ctx 'preview: 1. fence region B (sync, reconciler Disabled=true), read back.'
        Write-DrStep $Ctx "preview: 2. Cosmos DB writes in $($c.writeRegion); $(if (Test-DrSameRegion $c.writeRegion $Ctx.Regions.A.Location) { 'no move needed' } elseif ($MoveCosmos) { "run: $move" } else { "stop and print: $move (add -MoveCosmos to run it)" })."
        Write-DrStep $Ctx "preview: 3. delete $script:Adopt in both regions; region A $script:Gate=on, $script:Coverage=$($Ctx.CoverageStartAt)."
        Write-DrStep $Ctx 'preview: 4. enable region A reconciler, then sync. Rerun with -Apply.'
        $run.result = 'preview'; return $run
    }
    Set-DrWriters $Ctx 'B' $false
    Assert-DrFenced $Ctx 'B' 'standby_writers_enabled'
    $c = Get-DrCosmos $Ctx
    if (-not (Test-DrSameRegion $c.writeRegion $Ctx.Regions.A.Location)) {
        if (-not $MoveCosmos) { throw "cosmos_write_region: Cosmos DB writes in $($c.writeRegion), not region A ($($Ctx.Regions.A.Location)). Region B is fenced and region A stays fenced. Move it and rerun Failback, or rerun with -MoveCosmos: $move" }
        $null = Invoke-DrFailoverAz $Ctx @('cosmosdb', 'failover-priority-change', '--subscription', $Ctx.Subscription, '--resource-group', $Ctx.ResourceGroup, '--name', $Ctx.CosmosAccount,
            '--failover-policies', "$($Ctx.Regions.A.Location)=0", "$($Ctx.Regions.B.Location)=1")
        Write-DrStep $Ctx "Cosmos DB failover priority requested: $($Ctx.Regions.A.Location)=0, $($Ctx.Regions.B.Location)=1"
        $done = $false
        for ($i = 0; $i -lt $Ctx.PollAttempts -and -not $done; $i++) {
            if ($Ctx.PollSeconds) { Start-Sleep -Seconds $Ctx.PollSeconds }
            $c = Get-DrCosmos $Ctx
            $done = ($c.provisioningState -ceq 'Succeeded') -and (Test-DrSameRegion $c.writeRegion $Ctx.Regions.A.Location)
        }
        if (-not $done) { throw "cosmos_move_timeout: Cosmos DB reads $($c.writeRegion) / $($c.provisioningState); both regions stay fenced. Rerun Failback when it reads Succeeded." }
    }
    Write-DrStep $Ctx "Cosmos DB writes in $($c.writeRegion) (region A)"
    Remove-DrSetting $Ctx $Ctx.Regions.B.ReconcilerApp $script:Adopt
    Set-DrGate $Ctx 'A'
    Assert-DrFenced $Ctx 'B' 'standby_writers_enabled'
    Set-DrWriters $Ctx 'A' $true
    Write-DrStep $Ctx "workspace failback (not run here): $($ws.failback)"
    $run.result = 'failed_back'; return $run
}

Export-ModuleMember -Function Assert-DrAzArguments, Invoke-DrFailoverAz, Invoke-DrAzCli, ConvertFrom-DrJson, ConvertTo-DrUtcInstant, Test-DrCanonicalCoverage, Get-DrJsonText,
    Get-DrFailoverProblems, New-DrFailoverContext, Get-DrRegionState, Get-DrCosmos, Get-DrCosmosMoveCommand, Get-DrWorkspaceCommands, Get-DrFailoverStatus,
    Get-DrReplicationCoverage, Get-DrReplicationPlan, New-DrReplicationBody,
    Invoke-DrFence, Invoke-DrRemoveAdoption, Invoke-DrPromote, Invoke-DrFailback
