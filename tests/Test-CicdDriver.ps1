#Requires -Version 7.0
# Offline tests of scripts/cicd/CicdDriver.psm1 and Invoke-CicdDriver.ps1 (command builder and guards; no Azure call).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts\cicd\CicdDriver.psm1') -Force
$script:pass = 0; $script:fail = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
function Throws([scriptblock]$Block, [string]$Pattern) { try { $null = & $Block; return $false } catch { return $_.Exception.Message -match $Pattern } }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('ccof-cicd-driver-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force (Join-Path $scratch 'deploy/prod') | Out-Null
$cfgPath = Join-Path $scratch 'deploy/prod/staged.config.json'
function Set-Entra($Entra) { @{ subscriptionId = 'x'; entra = $Entra } | ConvertTo-Json -Depth 5 | Set-Content $cfgPath }
function Cmd([string]$Step, [hashtable]$Extra = @{}) { Get-CicdDriverCommand -Step $Step -Environment prod -RepoRoot $scratch @Extra }
function Line([string]$Step, [hashtable]$Extra = @{}) { Format-CicdCommand (Cmd $Step $Extra) }

try {
    # Happy paths: exact commands the workflow runs.
    Check 'stage 1 preview' ((Line 'staged-1') -ceq 'pwsh -NoProfile -File infra/staged/Invoke-StagedDeployment.ps1 -Stage 1 -ConfigPath deploy/prod/staged.config.json')
    Check 'stage 3 apply' ((Line 'staged-3' @{ Apply = $true }) -ceq 'pwsh -NoProfile -File infra/staged/Invoke-StagedDeployment.ps1 -Stage 3 -ConfigPath deploy/prod/staged.config.json -Apply')
    Check 'stage log path' ((Cmd 'staged-3' @{ Apply = $true }).Log -ceq 'evidence/prod/staged-3-apply.log')
    Check 'dr prereq bootstrap evidence dir' ((Line 'drprereq-Bootstrap') -ceq 'pwsh -NoProfile -File infra/dr/Invoke-DrPrerequisites.ps1 -Phase Bootstrap -ConfigPath deploy/prod/dr-standby.config.json -EvidenceDirectory deploy/prod/.dr-evidence')
    Check 'bootstrap vnet approval' ((Line 'drprereq-Bootstrap' @{ Apply = $true; Approve = 'ExistingVnetUpdate' }) -like '* -Apply -ApproveExistingVnetUpdate')
    Check 'network approval' ((Line 'standby-Network' @{ Apply = $true; Approve = 'PrivateNetworkChanges' }) -ceq 'pwsh -NoProfile -File infra/dr/Invoke-DrStandby.ps1 -Phase Network -ConfigPath deploy/prod/dr-standby.config.json -Apply -ApprovePrivateNetworkChanges')
    Check 'shells approvals' ((Line 'standby-Shells' @{ Apply = $true; Approve = @('PublicApimBootstrap', 'PublicFunctionAccess') }) -like '*-Apply -ApprovePublicApimBootstrap -ApprovePublicFunctionAccess')
    Check 'code apply uses private publisher' ((Line 'standby-Code' @{ Apply = $true }) -like '*-Phase Code * -PrivatePublisher -Apply')
    Check 'code preview has no private publisher' ((Line 'standby-Code') -notlike '*PrivatePublisher*')
    Check 'fd primary deploy' ((Line 'frontdoor-Deploy' @{ Apply = $true; PrimaryOnly = $true }) -ceq 'pwsh -NoProfile -File infra/dr/Invoke-DrFrontDoor.ps1 -Phase Deploy -ConfigPath deploy/prod/dr-standby.config.json -PrimaryOnly -Apply')
    $pec = '/subscriptions/s/resourceGroups/r/providers/Microsoft.ApiManagement/service/a/privateEndpointConnections/c1'
    Check 'fd approve reviewed ids' ((Line 'frontdoor-Approve' @{ Apply = $true; PrimaryOnly = $true; ReviewedConnectionIds = " $pec , " }) -like "*-PrimaryOnly -ReviewedConnectionIds $pec -Apply")
    Check 'fd full deploy with standby ready' ((Line 'frontdoor-Deploy' @{ Apply = $true; Approve = 'StandbyReady' }) -like '*-Apply -ConfirmStandbyReady')
    Check 'health b preview state dir' ((Line 'health-b') -ceq 'pwsh -NoProfile -File infra/monitoring/Invoke-HealthAlerts.ps1 -ConfigPath deploy/prod/health-b.json -StateDirectory deploy/prod/.health-alerts-b')
    $t = Cmd 'health-a' @{ Apply = $true; TestNotification = $true }
    Check 'health test notification' ((Format-CicdCommand $t) -like '*-TestNotification' -and $t.Arguments -notcontains '-Apply' -and $t.Mode -eq 'test')
    Check 'failover status region' ((Line 'failover-Status' @{ Region = 'B' }) -like '*-Phase Status -ConfigPath deploy/prod/dr-standby.config.json -Region B')

    # Stage 4: only manual Entra verification.
    Set-Entra @{ manualVerification = @{ confirmedBy = 'entra-team'; confirmedOn = '2026-11-01' } }
    Check 'stage 4 manual mode allowed' ((Line 'staged-4' @{ Apply = $true }) -like '*-Stage 4 *-Apply')
    Set-Entra @{ adminGroupObjectId = 'g' }
    Check 'stage 4 graph mode refused' (Throws { Cmd 'staged-4' } 'stage4_graph_write_refused')
    Set-Entra @{ manualVerification = @{ confirmedBy = 'entra-team' } }
    Check 'stage 4 incomplete confirmation refused' (Throws { Cmd 'staged-4' @{ Apply = $true } } 'stage4_graph_write_refused')
    Set-Entra @{ manualVerification = @{ confirmedBy = 'entra-team'; confirmedOn = 'yesterday' } }
    Check 'stage 4 undated confirmation refused' (Throws { Cmd 'staged-4' } 'stage4_graph_write_refused')
    Set-Entra @{ manualVerification = 'yes' }
    Check 'stage 4 non-object confirmation refused' (Throws { Cmd 'staged-4' } 'stage4_graph_write_refused')
    Remove-Item $cfgPath
    Check 'stage 4 missing config refused' (Throws { Cmd 'staged-4' } 'config_missing')

    # Manual-only operations and guards.
    foreach ($s in 'staged-8', 'frontdoor-Lockdown', 'frontdoor-DrainPrimary', 'frontdoor-RestorePrimary', 'failover-Promote', 'failover-Fence', 'failover-Failback', 'standby-Discover') {
        Check "manual step refused $s" (Throws { Cmd $s } 'unknown_step')
    }
    Check 'failover apply refused' (Throws { Cmd 'failover-Status' @{ Apply = $true } } 'failover_apply_refused')
    Check 'approval without apply refused' (Throws { Cmd 'standby-Network' @{ Approve = 'PrivateNetworkChanges' } } 'approval_without_apply')
    Check 'approval on wrong step refused' (Throws { Cmd 'standby-Data' @{ Apply = $true; Approve = 'PrivateNetworkChanges' } } 'approval_not_for_step')
    Check 'unknown approval refused' (Throws { Cmd 'standby-Data' @{ Apply = $true; Approve = 'Everything' } } 'unknown_approval')
    Check 'full fd deploy without standby ready refused' (Throws { Cmd 'frontdoor-Deploy' @{ Apply = $true } } 'standby_ready_required')
    Check 'primary-only with standby ready refused' (Throws { Cmd 'frontdoor-Deploy' @{ Apply = $true; PrimaryOnly = $true; Approve = 'StandbyReady' } } 'standby_ready_not_primary_only')
    Check 'fd approve apply without ids refused' (Throws { Cmd 'frontdoor-Approve' @{ Apply = $true; PrimaryOnly = $true } } 'reviewed_ids_required')
    Check 'fd approve invalid id refused' (Throws { Cmd 'frontdoor-Approve' @{ Apply = $true; PrimaryOnly = $true; ReviewedConnectionIds = 'c1; rm -rf' } } 'reviewed_ids_invalid')
    Check 'reviewed ids on other step refused' (Throws { Cmd 'frontdoor-Deploy' @{ ReviewedConnectionIds = $pec } } 'reviewed_ids_not_for_step')
    Check 'primary only on other step refused' (Throws { Cmd 'staged-1' @{ PrimaryOnly = $true } } 'primary_only_not_for_step')
    Check 'test notification needs apply runner' (Throws { Cmd 'health-a' @{ TestNotification = $true } } 'test_notification_requires_apply_runner')
    Check 'test notification other step refused' (Throws { Cmd 'staged-1' @{ Apply = $true; TestNotification = $true } } 'test_notification_not_for_step')
    Check 'invalid environment refused' (Throws { Get-CicdDriverCommand -Step 'staged-1' -Environment '../prod' -RepoRoot $scratch } 'invalid_environment')
    Check 'uppercase environment refused' (Throws { Get-CicdDriverCommand -Step 'staged-1' -Environment 'Prod' -RepoRoot $scratch } 'invalid_environment')

    # Script: print-only, refusal exit code and runner role guard.
    $script = Join-Path $root 'scripts\cicd\Invoke-CicdDriver.ps1'
    $out = & pwsh -NoProfile -File $script -Environment prod -Step staged-2 -PrintOnly 2>&1
    Check 'script print-only exit 0' ($LASTEXITCODE -eq 0 -and "$out" -like '*Invoke-StagedDeployment.ps1 -Stage 2 *')
    $null = & pwsh -NoProfile -File $script -Environment prod -Step staged-8 -PrintOnly 2>&1
    Check 'script refusal exit 2' ($LASTEXITCODE -eq 2)
    $saved = @{ GITHUB_ACTIONS = $env:GITHUB_ACTIONS; CCOF_RUNNER_ROLE = $env:CCOF_RUNNER_ROLE }
    try {
        $env:GITHUB_ACTIONS = 'true'; $env:CCOF_RUNNER_ROLE = 'preview'
        $out = & pwsh -NoProfile -File $script -Environment prod -Step staged-2 -Apply -PrintOnly 2>&1
        Check 'apply on preview runner refused' ($LASTEXITCODE -eq 2 -and "$out" -match 'runner_role_mismatch')
        $null = & pwsh -NoProfile -File $script -Environment prod -Step staged-2 -PrintOnly 2>&1
        Check 'preview on preview runner allowed' ($LASTEXITCODE -eq 0)
        $env:CCOF_RUNNER_ROLE = 'apply'
        $null = & pwsh -NoProfile -File $script -Environment prod -Step staged-2 -Apply -PrintOnly 2>&1
        Check 'apply on apply runner allowed' ($LASTEXITCODE -eq 0)
    } finally {
        foreach ($k in $saved.Keys) { if ($null -eq $saved[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } else { Set-Item "env:$k" $saved[$k] } }
    }
    $names = Get-CicdStepNames
    Check 'step list has no manual-only operation' (-not ($names | Where-Object { $_ -match 'Lockdown|Drain|Restore|Promote|Fence|Failback|staged-8' }))

    # Drift detection from preview logs.
    $logs = Join-Path $scratch 'evidence'; New-Item -ItemType Directory -Force $logs | Out-Null
    @('what-if stage1-services : NoChange=3', '  NoChange INFSIM-STG-RG/providers/Microsoft.Web/sites/a', '  Ignore   INFSIM-STG-RG/providers/Microsoft.Web/sites/b') | Set-Content (Join-Path $logs 'staged-1-preview.log')
    @('NoChange=1', '  NoChange /subscriptions/s/resourceGroups/r/providers/Microsoft.Insights/actionGroups/x-health-ag') | Set-Content (Join-Path $logs 'health-a-preview.log')
    $drift = Join-Path $root 'scripts\cicd\Get-CicdDrift.ps1'
    $null = & pwsh -NoProfile -File $drift -LogDirectory $logs 2>&1
    Check 'no drift exit 0' ($LASTEXITCODE -eq 0 -and (Get-Content (Join-Path $logs 'drift.json') -Raw | ConvertFrom-Json).drift.Count -eq 0)
    $null = & pwsh -NoProfile -File $drift -LogDirectory $logs -ExpectedLog 'health-b-preview.log' 2>&1
    Check 'missing expected log is drift' ($LASTEXITCODE -eq 1)
    Add-Content (Join-Path $logs 'staged-1-preview.log') '  Modify   INFSIM-STG-RG/providers/Microsoft.Web/sites/a'
    Add-Content (Join-Path $logs 'health-a-preview.log') '  Deploy   /subscriptions/s/resourceGroups/r/providers/Microsoft.Resources/deployments/n'
    $r = Get-CicdDrift -LogPath (Get-ChildItem $logs -Filter '*-preview.log' | ForEach-Object FullName)
    Check 'modify is drift' ($r.Drift.Count -eq 1 -and $r.Drift[0].Change -eq 'Modify' -and $r.Drift[0].Id -like '*/sites/a')
    Check 'deploy is review only' ($r.Review.Count -eq 1 -and $r.Review[0].Change -eq 'Deploy')
    $null = & pwsh -NoProfile -File $drift -LogDirectory $logs 2>&1
    Check 'drift exit 1 with markdown' ($LASTEXITCODE -eq 1 -and (Get-Content (Join-Path $logs 'drift.md') -Raw) -match '\| staged-1-preview.log \| Modify \|')
    Check 'summary text is not drift' ((Get-CicdDrift -LogPath (Join-Path $logs 'staged-1-preview.log')).Drift.Count -eq 1)
    @('what-if: NoChange /subscriptions/s/x/y', 'what-if: Create /subscriptions/s/resourceGroups/b/providers/Microsoft.Network/virtualNetworks/v') | Set-Content (Join-Path $logs 'drprereq-Bootstrap-preview.log')
    Check 'dr prerequisites what-if format' ((Get-CicdDrift -LogPath (Join-Path $logs 'drprereq-Bootstrap-preview.log')).Drift.Change -ceq 'Create')
    $null = & pwsh -NoProfile -File $drift -LogDirectory (Join-Path $scratch 'none') 2>&1
    Check 'no logs exit 1' ($LASTEXITCODE -eq 1)
} finally {
    Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
}
Write-Host "CICD driver: $($script:pass) passed, $($script:fail) failed."
if ($script:fail) { exit 1 }
