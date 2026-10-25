#Requires -Version 7.2
<#
.SYNOPSIS
    Staged CCOF deployment: one stage per run, each with its own permission boundary.

.DESCRIPTION
    Stage 0 read-only checks      Reader on the scopes; directory read
    Stage 1 resources only        RG Contributor (infra/staged/main.bicep)
    Stage 2 Cosmos schema         Cosmos database/container write (Contributor)
    Stage 3 runtime grants        Role Based Access Control Administrator (or Owner) + Cosmos SQL role writes
    Stage 4 Entra                 Application owner/administrator, group owner/Groups Administrator
    Stage 5 configuration         site config, APIM and workbook write
    Stage 6 network (last setup)  network.mode verify (default): Reader; the customer builds the network and
                                  scripts/manual/Test-NetworkConfiguration.ps1 checks it. Modes existing/create
                                  (opt-in): Network Contributor, private DNS zone write/link, site write
    Stage 7 code and data         Function publishing; settings write on the sync app (seed, snapshot).
                                  Needs Stage 6: the apps reach their private storage and Cosmos through the VNet
    Stage 8 acceptance            gateway caller identity; Log Analytics read

    Without -Apply a stage previews only: Bicep stages run `what-if`, script stages print their plan.
    With -Apply the stage changes Azure (or Entra), then verifies by reading back, and records its
    outputs in <StateDirectory>/state.json. A stage refuses to run before the stages it reads.
    Reuses the quickstart's tested functions (infra/quickstart/Deploy-Quickstart.ps1 -DotSourceOnly):
    gateway policy rendering, workbook build, packaging, registry seed and client export.

.EXAMPLE
    pwsh -File infra/staged/Invoke-StagedDeployment.ps1 -Stage 1 -ConfigPath .env.staged/staged.config.json
    pwsh -File infra/staged/Invoke-StagedDeployment.ps1 -Stage 1 -ConfigPath .env.staged/staged.config.json -Apply
#>
[CmdletBinding()]
param(
    [ValidateRange(0, 8)] [int]$Stage,
    [string]$ConfigPath,
    [string]$StateDirectory,
    [switch]$Apply,
    [switch]$DotSourceOnly
)

$ErrorActionPreference = 'Stop'
$script:StagedDir = $PSScriptRoot
$script:Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
# Dot-sourcing runs the quickstart's param block in this scope and sets $DotSourceOnly there: keep ours.
$script:StgLibraryOnly = [bool]$DotSourceOnly
. (Join-Path $script:Repo 'infra/quickstart/Deploy-Quickstart.ps1') -DotSourceOnly
$ErrorActionPreference = 'Stop'
$script:AzureCliClientId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
$script:Guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

foreach ($part in 'Staged.Common.ps1', 'Staged.Resources.ps1', 'Staged.Entra.ps1', 'Staged.Application.ps1') { . (Join-Path $PSScriptRoot $part) }

# ---------------------------------------------------------------- entry point

if ($script:StgLibraryOnly) { return }
if (-not $PSBoundParameters.ContainsKey('Stage') -or -not $ConfigPath) { throw 'Usage: -Stage <0-8> -ConfigPath <staged.config.json> [-Apply]' }
$cfg = Read-StgConfig $ConfigPath
$script:StateDir = if ($StateDirectory) { [IO.Path]::GetFullPath($StateDirectory) } else { Join-Path (Split-Path $cfg.__path -Parent) '.staged-state' }
New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
$mode = if ($Apply -and $Stage -ne 0) { 'apply' } else { 'preview' }
Write-Host "== stage $Stage ($mode) subscription $($cfg.subscriptionId) RG $($cfg.resourceGroup); state $script:StateDir"
$started = [DateTime]::UtcNow
$stage7Lock = $null
if ($Apply -and $Stage -eq 7) { $stage7Lock = Enter-StgStage7Lock (Join-Path $script:Repo '.staged-stage7.lock') }
try {
$outputs = switch ($Stage) {
    0 { Invoke-Stage0 $cfg }
    1 { Invoke-Stage1 $cfg -Apply:$Apply }
    2 { Invoke-Stage2 $cfg -Apply:$Apply }
    3 { Invoke-Stage3 $cfg -Apply:$Apply }
    4 { Invoke-Stage4 $cfg -Apply:$Apply }
    5 { Invoke-Stage5 $cfg -Apply:$Apply }
    6 { Invoke-Stage6 $cfg -Apply:$Apply }
    7 { Invoke-Stage7 $cfg -Apply:$Apply }
    8 { Invoke-Stage8 $cfg -Apply:$Apply }
}
if ($Stage -eq 0 -or $Apply) {
    if ($outputs -is [hashtable] -or $outputs -is [Collections.Specialized.OrderedDictionary]) { $outputs['durationSeconds'] = [int]([DateTime]::UtcNow - $started).TotalSeconds }
    Save-StgStage $cfg $Stage $outputs
    Write-Host "stage $Stage completed and verified in $([int]([DateTime]::UtcNow - $started).TotalSeconds) s; outputs in $(Get-StgStatePath $cfg)" -ForegroundColor Green
} else { Write-Host "stage $Stage preview only: nothing changed. Rerun with -Apply." }
} finally { if ($stage7Lock) { $stage7Lock.Dispose() } }
