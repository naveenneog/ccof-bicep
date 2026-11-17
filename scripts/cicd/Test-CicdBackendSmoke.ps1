#Requires -Version 7.0
<#
.SYNOPSIS
  Read-only smoke checks after a Foundry backend onboarding apply (docs/runbooks/CICD-FOUNDRY-ONBOARDING.md).

.DESCRIPTION
  For each backend id, in region A and (when dr-standby.config.json is next to the configuration)
  region B: the APIM backend entity exists with the configured URL, and the API policy names the id
  (%%BACKEND_IDS%%). Then the Cosmos `backends` descriptor is present and equal to the expected one
  (Set-CicdBackendDescriptor.ps1 without -Apply; needs the in-VNet runner and Cosmos read).
  Exit 0 = all present, 3 = something missing (listed). Nothing is changed.

.EXAMPLE
  pwsh -File scripts/cicd/Test-CicdBackendSmoke.ps1 -ConfigPath deploy/stg/staged.config.json -BackendIds foundry2 -EvidencePath evidence/smoke.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ConfigPath,
    [Parameter(Mandatory)] [string[]]$BackendIds,
    [string]$DrConfigPath,
    [switch]$SkipDescriptor,
    [string]$EvidencePath,
    # Test seams: -Arm param($path) -> ARM GET body; -Descriptor param($configPath, $ids, $evidencePath) -> exit code.
    [scriptblock]$Arm,
    [scriptblock]$Descriptor
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'CicdOnboarding.psm1') -Force
function Read-CicdJson([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 100 }
function Stop-Smoke([string]$Message, [int]$Code) { [Console]::Error.WriteLine($Message); exit $Code }

if (-not (Test-Path -LiteralPath $ConfigPath)) { Stop-Smoke "smoke_config_missing: $ConfigPath" 2 }
$configFull = (Resolve-Path -LiteralPath $ConfigPath).Path
$configDir = Split-Path $configFull -Parent
$cfg = Read-CicdJson $configFull
$ids = @($BackendIds | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $ids.Count) { Stop-Smoke 'smoke_ids_required: name at least one backend id.' 2 }
if (-not $Arm) { $Arm = { param($p) $o = az rest --method get --url "https://management.azure.com$p" --only-show-errors 2>&1; if ($LASTEXITCODE) { throw (@($o) -join ' ') }; @($o) -join "`n" | ConvertFrom-Json -AsHashtable -Depth 100 } }

$stateFile = Join-Path $configDir '.staged-state/state.json'
if (-not (Test-Path -LiteralPath $stateFile)) { Stop-Smoke "smoke_state_missing: $stateFile" 2 }
$stages = (Read-CicdJson $stateFile)['stages']
$apiId = if ($cfg['apim'] -is [Collections.IDictionary] -and $cfg['apim']['apiId']) { [string]$cfg['apim']['apiId'] } else { 'claude-messages' }
$apimA = [string]$stages['1']['outputs']['apimId']
if (-not $apimA -and $cfg['apim'] -is [Collections.IDictionary] -and $cfg['apim']['existing'] -is [Collections.IDictionary]) {
    $e = $cfg['apim']['existing']; $apimA = "/subscriptions/$($e['subscriptionId'])/resourceGroups/$($e['resourceGroup'])/providers/Microsoft.ApiManagement/service/$($e['name'])"
}
$regions = [ordered]@{ A = $apimA }
$drPath = if ($DrConfigPath) { $DrConfigPath } else { Join-Path $configDir 'dr-standby.config.json' }
if (Test-Path -LiteralPath $drPath) {
    $dr = Read-CicdJson $drPath
    $dir = $dr['standby']['stateDirectory']
    $standbyFile = Join-Path $(if ([IO.Path]::IsPathRooted($dir)) { $dir } else { Join-Path (Split-Path (Resolve-Path -LiteralPath $drPath).Path -Parent) $dir }) 'standby.state.json'
    if (-not (Test-Path -LiteralPath $standbyFile)) { Stop-Smoke "smoke_standby_state_missing: $standbyFile" 2 }
    $regions.B = [string](Read-CicdJson $standbyFile)['phases']['Shells']['outputs']['apimId']
}

$problems = [Collections.Generic.List[string]]::new()
$report = [ordered]@{ checkedAt = [DateTime]::UtcNow.ToString('o'); backendIds = $ids; regions = [ordered]@{} }
foreach ($r in $regions.Keys) {
    if (-not $regions[$r]) { $problems.Add("smoke_apim_unknown: region $r APIM id is not in the driver state."); continue }
    $report.regions[$r] = [ordered]@{ apimId = $regions[$r]; backends = [ordered]@{} }
    foreach ($id in $ids) {
        $backend = @($cfg['backends'] | Where-Object { $_ -is [Collections.IDictionary] -and [string]$_['id'] -ceq $id })
        if ($backend.Count -ne 1) { $problems.Add("smoke_backend_unknown: $id"); continue }
        $found = @(Get-CicdApimBackendFindings -ApimId $regions[$r] -ApiId $apiId -Backend $backend[0] -Arm $Arm)
        $report.regions[$r].backends[$id] = if ($found.Count) { $found } else { 'ok' }
        foreach ($p in $found) { $problems.Add("region ${r}: $p") }
    }
}
if (-not $SkipDescriptor) {
    $descriptorEvidence = if ($EvidencePath) { Join-Path (Split-Path $EvidencePath -Parent) 'descriptor-smoke.json' } else { $null }
    if (-not $Descriptor) { $Descriptor = { param($c, $i, $e) $x = @{ ConfigPath = $c; BackendIds = $i }; if ($e) { $x.EvidencePath = $e }; & (Join-Path $PSScriptRoot 'Set-CicdBackendDescriptor.ps1') @x; $LASTEXITCODE } }
    $code = & $Descriptor $configFull $ids $descriptorEvidence | Select-Object -Last 1
    $report.descriptor = [ordered]@{ exitCode = $code; evidence = $descriptorEvidence }
    if ($code -ne 0) { $problems.Add("smoke_descriptor: Set-CicdBackendDescriptor.ps1 exited $code.") }
    elseif ($descriptorEvidence -and (Test-Path -LiteralPath $descriptorEvidence)) {
        $missing = @((Read-CicdJson $descriptorEvidence)['results'] | Where-Object { $_['outcome'] -cne 'present' } | ForEach-Object { "$($_['backendId'])=$($_['outcome'])" })
        if ($missing.Count) { $problems.Add("smoke_descriptor: not present: $($missing -join ', ').") }
    }
}
$report.problems = @($problems)
if ($EvidencePath) {
    New-Item -ItemType Directory -Force -Path (Split-Path $EvidencePath -Parent) | Out-Null
    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $EvidencePath -Encoding utf8NoBOM
}
if ($problems.Count) { Stop-Smoke "smoke_failed:`n  - $($problems -join "`n  - ")" 3 }
Write-Host "smoke ok: $($ids -join ', ') in region(s) $(@($regions.Keys) -join ', ')$(if (-not $SkipDescriptor) { ', descriptor present' })." -ForegroundColor Green
exit 0
