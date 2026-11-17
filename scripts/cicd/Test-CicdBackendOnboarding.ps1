#Requires -Version 7.0
<#
.SYNOPSIS
  Validates a Foundry backend onboarding change before any preview or apply (docs/runbooks/CICD-FOUNDRY-ONBOARDING.md).

.DESCRIPTION
  Offline: the head staged configuration passes Read-StgConfig; against -BaseConfigPath only backends
  are appended (no existing backend or other setting changed); each new backend's fields are complete;
  region B (dr-standby.config.json next to the configuration, if present) points at this configuration
  and has completed its standby build, so -Phase Backends can add the backend there.

  Azure (unless -SkipAzure, read-only): the Foundry account exists (AIServices, Succeeded), every
  deployment in deploymentInferenceGeo exists and succeeded, the private path (approved private
  endpoint and, with -ResolveDns, a private DNS answer from the runner), and the Cognitive Services
  User prerequisite for the APIM identities of both regions.

  Outputs (GITHUB_OUTPUT when set): backend-ids, needs-privatelink-gate, has-standby. Exit 0 = valid,
  3 = problems (listed), 2 = usage. -RequirePrivateLink turns a pending private link into a problem
  (used after the privatelink gate, before apply).

.EXAMPLE
  pwsh -File scripts/cicd/Test-CicdBackendOnboarding.ps1 -ConfigPath deploy/stg/staged.config.json -BaseConfigPath base.json -SkipAzure
  pwsh -File scripts/cicd/Test-CicdBackendOnboarding.ps1 -ConfigPath deploy/stg/staged.config.json -BackendIds foundry2 -ResolveDns
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ConfigPath,
    [string]$BaseConfigPath,
    [string[]]$BackendIds,
    [string]$DrConfigPath,
    [switch]$SkipAzure,
    [switch]$ResolveDns,
    [switch]$RequirePrivateLink,
    [string]$ApplyPrincipalId,
    [string]$EvidencePath,
    # Test seams: -Arm param($path) -> ARM GET body; -Resolve param($hostName) -> IP strings.
    [scriptblock]$Arm,
    [scriptblock]$Resolve
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$cicdArgs = @{ ConfigPath = $ConfigPath; BaseConfigPath = $BaseConfigPath; BackendIds = $BackendIds; DrConfigPath = $DrConfigPath; SkipAzure = $SkipAzure; ResolveDns = $ResolveDns
    RequirePrivateLink = $RequirePrivateLink; ApplyPrincipalId = $ApplyPrincipalId; EvidencePath = $EvidencePath; Arm = $Arm; Resolve = $Resolve }
. (Join-Path $repo 'infra/staged/Invoke-StagedDeployment.ps1') -DotSourceOnly
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CicdOnboarding.psm1') -Force
$a = $cicdArgs
function Read-CicdJson([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 100 }

$problems = [Collections.Generic.List[string]]::new(); $warnings = [Collections.Generic.List[string]]::new()
$report = [ordered]@{ checkedAt = [DateTime]::UtcNow.ToString('o'); config = $a.ConfigPath; backends = @() }
if (-not (Test-Path -LiteralPath $a.ConfigPath)) { [Console]::Error.WriteLine("onboarding_config_missing: $($a.ConfigPath)"); exit 2 }
$configFull = (Resolve-Path -LiteralPath $a.ConfigPath).Path
$configDir = Split-Path $configFull -Parent
try { $null = Read-StgConfig $configFull } catch { $problems.Add("config_invalid: $($_.Exception.Message)") }
$head = Read-CicdJson $configFull

$requested = @($a.BackendIds | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$ids = $requested
if ($a.BaseConfigPath) {
    $change = Get-CicdBackendChange -Base (Read-CicdJson $a.BaseConfigPath) -Head $head
    foreach ($p in $change.problems) { $problems.Add($p) }
    $ids = @($change.added)
    if ($requested.Count -and (@($requested | Sort-Object) -join ',') -cne (@($ids | Sort-Object) -join ',')) { $problems.Add("backend_ids_mismatch: -BackendIds $($requested -join ',') but the change adds $($ids -join ',').") }
} elseif (-not $ids.Count) { [Console]::Error.WriteLine('onboarding_ids_required: pass -BaseConfigPath or -BackendIds.'); exit 2 }
$report.backendIds = $ids

$byId = @{}; foreach ($b in @($head['backends'])) { if ($b -is [Collections.IDictionary]) { $byId[[string]$b['id']] = $b } }
$new = @(foreach ($id in $ids) { if ($byId.ContainsKey($id)) { $byId[$id] } else { $problems.Add("backend_unknown: $id is not in backends[].") } })
foreach ($b in $new) { foreach ($p in @(Get-CicdBackendFieldProblems $b)) { $problems.Add("backend_field: $p") } }

# Region B: the DR configuration next to the staged configuration.
$drPath = if ($a.DrConfigPath) { $a.DrConfigPath } else { Join-Path $configDir 'dr-standby.config.json' }
$dr = $null; $standbyState = $null
if (Test-Path -LiteralPath $drPath) {
    $dr = Read-CicdJson $drPath
    $drDir = Split-Path (Resolve-Path -LiteralPath $drPath).Path -Parent
    $resolveDr = { param($p) if ([IO.Path]::IsPathRooted($p)) { $p } else { [IO.Path]::GetFullPath((Join-Path $drDir $p)) } }
    $sb = $dr['standby']
    if ($sb -isnot [Collections.IDictionary] -or -not $sb['stagedConfigPath'] -or -not $sb['stateDirectory']) { $problems.Add('standby_config_invalid: dr-standby.config.json needs standby.stagedConfigPath and standby.stateDirectory.') }
    else {
        if ((& $resolveDr $sb['stagedConfigPath']) -ine $configFull) { $problems.Add("standby_config_mismatch: $drPath standby.stagedConfigPath is not $configFull; region B would be built from another configuration.") }
        $standbyFile = Join-Path (& $resolveDr $sb['stateDirectory']) 'standby.state.json'
        if (Test-Path -LiteralPath $standbyFile) { $standbyState = Read-CicdJson $standbyFile }
    }
}
$coverage = Get-CicdStandbyCoverage -DrConfig $dr -StandbyState $standbyState
foreach ($p in $coverage.problems) { $problems.Add($p) }
$report.regionB = [ordered]@{ hasStandby = $coverage.hasStandby; note = $coverage.note }

# APIM identities that Stage 3 grants Cognitive Services User (region A, region B).
$principals = @()
$stateFile = Join-Path $configDir '.staged-state/state.json'
if (Test-Path -LiteralPath $stateFile) {
    # Stage 3 records the APIM principal for both a new and an existing (apim.existing) APIM.
    $stages = (Read-CicdJson $stateFile)['stages']
    $apimPrincipal = @(foreach ($n in '3', '1') { if ($stages[$n] -and $stages[$n]['outputs']['apimPrincipalId']) { [string]$stages[$n]['outputs']['apimPrincipalId'] } })
    if ($apimPrincipal.Count) { $principals += $apimPrincipal[0] }
} else { $warnings.Add("primary_state_missing: $stateFile (restore the driver state first); the region A role prerequisite is not checked.") }
if ($standbyState -and $standbyState['phases'].Contains('Shells')) { $principals += [string]$standbyState['phases']['Shells']['outputs']['apimPrincipalId'] }

$gate = $false
if (-not $a.SkipAzure -and $new.Count) {
    $arm = if ($a.Arm) { $a.Arm } else { { param($p) Invoke-QsAz @('rest', '--method', 'get', '--url', "https://management.azure.com$p") } }
    $resolver = if ($a.Resolve) { $a.Resolve } elseif ($a.ResolveDns) { { param($h) @([Net.Dns]::GetHostAddresses($h) | ForEach-Object { $_.ToString() }) } } else { $null }
    foreach ($b in $new) {
        $f = Get-CicdBackendAzureFindings -Backend $b -Arm $arm -ApimPrincipalIds $principals -ApplyPrincipalId $a.ApplyPrincipalId -Resolve $resolver
        foreach ($p in $f.problems) { $problems.Add($p) }
        foreach ($w in $f.warnings) { $warnings.Add($w) }
        if ($f.facts.needsPrivateLinkGate) {
            $gate = $true
            if ($a.RequirePrivateLink) { $problems.Add("private_link_pending: $($b['id']) still has no approved private endpoint reachable from the runner.") }
        }
        $report.backends += $f.facts
    }
} elseif ($a.SkipAzure) { $warnings.Add('azure_skipped: Foundry account, deployments, private link and roles were not checked (-SkipAzure).') }

$report.needsPrivateLinkGate = $gate
$report.warnings = @($warnings); $report.problems = @($problems)
foreach ($w in $warnings) { Write-Host "WARNING: $w" -ForegroundColor Yellow }
if ($a.EvidencePath) {
    New-Item -ItemType Directory -Force -Path (Split-Path $a.EvidencePath -Parent) | Out-Null
    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $a.EvidencePath -Encoding utf8NoBOM
}
if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8NoBOM -Value @("backend-ids=$($ids -join ',')", "needs-privatelink-gate=$($gate.ToString().ToLowerInvariant())", "has-standby=$($coverage.hasStandby.ToString().ToLowerInvariant())")
}
if ($problems.Count) { [Console]::Error.WriteLine("onboarding_invalid:`n  - $($problems -join "`n  - ")"); exit 3 }
Write-Host "onboarding valid: $($ids -join ', ')$(if ($coverage.hasStandby) { ' (regions A and B)' } else { ' (region A only)' }); private link gate $(if ($gate) { 'needed' } else { 'not needed' })." -ForegroundColor Green
exit 0
