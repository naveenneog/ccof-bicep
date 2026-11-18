#Requires -Version 7.0
# Cross-job regression: the DR standby Data preview writes .dr-state/cosmos-throughput-preview.json, and Data -Apply
# refuses region or throughput changes without that exact digest (cosmos_preview_required / cosmos_preview_stale).
# In deploy-environment.yml the preview and the apply are separate jobs with clean workspaces; only the state branch
# (Sync-CicdState) carries files between them. This test runs each job in its own clone of a local bare remote:
# restore, the real Invoke-DrStandby.ps1 Data (mocked Azure from tests/Test-DrInfosysShape.ps1 -Child, fictional
# customer-shaped fixture) and save exactly when the workflow job sets save_state. The mock Azure account
# (mock.json) is the only thing shared outside Git. No network, no credentials.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts\cicd\CicdState.psm1') -Force
$script:pass = 0; $script:fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name $Detail" -ForegroundColor Red } }

# The workflow decides whether a job saves: read save_state of the two jobs from deploy-environment.yml.
$wf = (Get-Content -LiteralPath (Join-Path $root '.github\workflows\deploy-environment.yml') -Raw) -replace "`r`n", "`n"
function Get-JobSaves([string]$Id) {
    $m = [regex]::Match($wf, "(?ms)^  $([regex]::Escape($Id)):\n(.*?)(?=^  [a-z0-9-]+:\n|\z)")
    if (-not $m.Success) { throw "job $Id not found in deploy-environment.yml" }
    return $m.Groups[1].Value -match '\bsave_state: true\b'
}
$previewSaves = Get-JobSaves 'standby-data-preview'
$applySaves = Get-JobSaves 'standby-data-apply'

$fixture = Join-Path $PSScriptRoot 'fixtures\dr-customer-shape'
$shape = Join-Path $PSScriptRoot 'Test-DrInfosysShape.ps1'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('cp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$bare = Join-Path $scratch 'r.git'
$azure = Join-Path $scratch 'azure-mock.json'
$saved = @{ dir = $env:DR_SHAPE_DIR; log = $env:DR_SHAPE_LOG; phase = $env:DR_SHAPE_PHASE }
function tgit { git -c core.longpaths=true @args }
$script:n = 0
# A clean job workspace: the configuration as committed on main, nothing else.
function New-Job {
    $dir = Join-Path $scratch ('j' + (++$script:n))
    tgit init -q $dir; git -C $dir config user.email t@example.com; git -C $dir config user.name t; git -C $dir config core.autocrlf false
    git -C $dir remote add origin $bare
    $ed = Join-Path $dir 'deploy/prod'; New-Item -ItemType Directory -Force $ed | Out-Null
    Copy-Item -LiteralPath (Join-Path $fixture 'staged.config.json'), (Join-Path $fixture 'dr.config.json') -Destination $ed
    return $dir
}
# One ccof-step job: restore, driver (Data), save when the job saves and the driver started.
function Invoke-Job([string]$Dir, [switch]$Preview, [bool]$Save, [scriptblock]$AfterRestore) {
    $null = Restore-CicdState $Dir 'prod'
    $ed = Join-Path $Dir 'deploy/prod'
    if ($AfterRestore) { & $AfterRestore $ed }
    Copy-Item -LiteralPath $azure -Destination (Join-Path $ed 'mock.json') -Force
    $env:DR_SHAPE_DIR = $ed; $env:DR_SHAPE_LOG = Join-Path $Dir 'az.log'; $env:DR_SHAPE_PHASE = 'Data'
    $a = @('-NoProfile', '-File', $shape, '-Child', '-Phase', 'Data'); if ($Preview) { $a += '-PreviewRun' }
    $out = & pwsh @a 2>&1 | Out-String; $code = $LASTEXITCODE
    Copy-Item -LiteralPath (Join-Path $ed 'mock.json') -Destination $azure -Force
    $calls = if (Test-Path -LiteralPath $env:DR_SHAPE_LOG) { @(Get-Content -LiteralPath $env:DR_SHAPE_LOG | ForEach-Object { @($_ | ConvertFrom-Json) -join ' ' }) } else { @() }
    $s = if ($Save) { Save-CicdState $Dir 'prod' "Data $(if ($Preview) { 'preview' } else { 'apply' })" }
    return @{ Code = $code; Out = $out; Calls = $calls; Saved = $s; Preview = Join-Path $ed '.dr-state/cosmos-throughput-preview.json' }
}
function Writes($r) { @($r.Calls | Where-Object { $_ -match '^rest --method (patch|put|post|delete) ' -or $_ -match '^cosmosdb (update|sql (database|container) throughput (update|migrate))' }) }
function Get-BranchFiles { @(git --git-dir $bare ls-tree -r --name-only refs/heads/cicd-state/prod 2>$null) }
function Reset-World {
    if (Test-Path $bare) { Remove-Item -Recurse -Force $bare }
    tgit init -q --bare $bare; git --git-dir $bare config core.longpaths true
    '{"regionAdded":false,"failover":false}' | Set-Content -LiteralPath $azure
    # Earlier runs left the primary staged state and the Front Door state on the state branch.
    $seed = New-Job
    $null = Restore-CicdState $seed 'prod'
    $e = Join-Path $seed 'deploy/prod'
    New-Item -ItemType Directory -Force (Join-Path $e '.staged-state'), (Join-Path $e '.dr-state') | Out-Null
    Copy-Item -LiteralPath (Join-Path $fixture 'staged-state/state.json') -Destination (Join-Path $e '.staged-state')
    Copy-Item -LiteralPath (Join-Path $fixture 'dr-state/frontdoor-state.json') -Destination (Join-Path $e '.dr-state')
    $null = Save-CicdState $seed 'prod' 'seed'
}

try {
    New-Item -ItemType Directory -Force $scratch | Out-Null
    $pv = '.dr-state/cosmos-throughput-preview.json'

    # 1. The workflow as written: preview job, then apply job in a clean workspace.
    Reset-World
    $p = Invoke-Job (New-Job) -Preview -Save $previewSaves
    Check 'workflow: Data preview completes' ($p.Code -eq 0) "(exit $($p.Code)) $($p.Out -split "`n" | Select-Object -Last 3)"
    Check 'workflow: Data preview makes no Azure write' (-not (Writes $p).Count) ((Writes $p) -join ' | ')
    Check 'workflow: Data preview writes the digest' (Test-Path -LiteralPath $p.Preview)
    Check 'workflow: standby-data-preview saves state (the digest reaches the apply job)' $previewSaves
    Check 'workflow: state branch holds the preview digest before the apply job' ((Get-BranchFiles) -contains "deploy/prod/$pv")
    $a = Invoke-Job (New-Job) -Save $applySaves
    Check 'workflow: Data apply in a fresh workspace finds the reviewed preview and applies' ($a.Code -eq 0 -and $a.Out -notmatch 'cosmos_preview_required') "(exit $($a.Code)) $($a.Out -split "`n" | Where-Object { $_ -match 'cosmos_' } | Select-Object -First 2)"
    Check 'workflow: Data apply adds the standby region once' (@($a.Calls | Where-Object { $_ -match '^rest --method patch .*databaseAccounts/' }).Count -eq 1)
    Check 'workflow: the consumed digest is removed from the state branch' ($applySaves -and (Get-BranchFiles) -notcontains "deploy/prod/$pv" -and (Get-BranchFiles) -contains 'deploy/prod/.dr-state/standby.state.json')

    # 2. Negative: apply without a persisted preview (the defect): refused, no Azure write.
    Reset-World
    $null = Invoke-Job (New-Job) -Preview -Save $false
    $a = Invoke-Job (New-Job) -Save $true
    Check 'neg: apply without a persisted preview is refused (cosmos_preview_required)' ($a.Code -ne 0 -and $a.Out -match 'cosmos_preview_required')
    Check 'neg: refused apply makes no Azure write' (-not (Writes $a).Count) ((Writes $a) -join ' | ')

    # 3. Negative: stale preview (the account changed after review): refused, no write, digest kept for inspection.
    Reset-World
    $null = Invoke-Job (New-Job) -Preview -Save $true
    '{"regionAdded":false,"failover":true}' | Set-Content -LiteralPath $azure
    $a = Invoke-Job (New-Job) -Save $true
    Check 'neg: stale preview is refused (cosmos_preview_stale)' ($a.Code -ne 0 -and $a.Out -match 'cosmos_preview_stale')
    Check 'neg: stale apply makes no Azure write' (-not (Writes $a).Count) ((Writes $a) -join ' | ')

    # 4. Negative: tampered digest or schema after restore: refused, no write.
    foreach ($t in @(
            @{ Name = 'digest'; Edit = { param($e) $f = Join-Path $e '.dr-state/cosmos-throughput-preview.json'; $j = Get-Content $f -Raw | ConvertFrom-Json; $j.digest = ('0' * 64); $j | ConvertTo-Json | Set-Content $f } },
            @{ Name = 'schema'; Edit = { param($e) $f = Join-Path $e '.dr-state/cosmos-throughput-preview.json'; $j = Get-Content $f -Raw | ConvertFrom-Json; $j.schema = 'ccof.dr.cosmos.preview.v0'; $j | ConvertTo-Json | Set-Content $f } },
            @{ Name = 'unreadable'; Edit = { param($e) Set-Content (Join-Path $e '.dr-state/cosmos-throughput-preview.json') '{not json' } })) {
        Reset-World
        $null = Invoke-Job (New-Job) -Preview -Save $true
        $a = Invoke-Job (New-Job) -Save $true -AfterRestore $t.Edit
        Check "neg: tampered preview ($($t.Name)) is refused" ($a.Code -ne 0 -and $a.Out -match 'cosmos_preview_stale')
        Check "neg: tampered preview ($($t.Name)) makes no Azure write" (-not (Writes $a).Count)
    }

    # 5. A digest consumed by a successful apply cannot authorize a second change: the next apply needs a new preview.
    Reset-World
    $null = Invoke-Job (New-Job) -Preview -Save $true
    $null = Invoke-Job (New-Job) -Save $true
    Check 'consumed digest is not on the state branch after apply' ((Get-BranchFiles) -notcontains "deploy/prod/$pv")
} finally {
    $env:DR_SHAPE_DIR = $saved.dir; $env:DR_SHAPE_LOG = $saved.log; $env:DR_SHAPE_PHASE = $saved.phase
    if ($script:fail -eq 0) { Remove-Item -Recurse -Force -LiteralPath $scratch -ErrorAction SilentlyContinue } else { Write-Host "kept scratch: $scratch" }
}
Write-Host "Test-CicdCosmosPreviewHandoff: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0 -or $script:pass -lt 19) { exit 1 }
