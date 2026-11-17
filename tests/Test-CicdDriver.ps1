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
    # Graph contract beyond Stage 4: the pipeline identity makes no operator Graph read (Stage 0, Stage 7 delegated
    # snapshot) and standby Config never writes the admin app, whatever the restored Stage 4 record says.
    Check 'stage 0 graph mode refused' (Throws { Cmd 'staged-0' } 'graph_call_refused: staged-0')
    Check 'stage 7 graph mode refused' (Throws { Cmd 'staged-7' @{ Apply = $true } } 'graph_call_refused: staged-7')
    Check 'standby Config apply forces the manual Entra handoff with a Graph-mode config' ((Cmd 'standby-Config' @{ Apply = $true }).Arguments -contains '-ManualEntraHandoff')
    Check 'standby Config preview forces the manual Entra handoff' ((Line 'standby-Config') -ceq 'pwsh -NoProfile -File infra/dr/Invoke-DrStandby.ps1 -Phase Config -ConfigPath deploy/prod/dr-standby.config.json -ManualEntraHandoff')
    Check 'other standby phases take no handoff switch' ((Cmd 'standby-Grants' @{ Apply = $true }).Arguments -notcontains '-ManualEntraHandoff')
    Set-Entra @{ manualVerification = @{ confirmedBy = 'entra-team'; confirmedOn = '2026-11-01' } }
    Check 'stage 0 manual mode allowed' ((Line 'staged-0') -like '*-Stage 0 *')
    Check 'stage 7 manual mode allowed' ((Line 'staged-7' @{ Apply = $true }) -like '*-Stage 7 *-Apply')
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

    # Drift: tests/Test-CicdDrift.ps1.
} finally {
    Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
}
Write-Host "CICD driver: $($script:pass) passed, $($script:fail) failed."
if ($script:fail) { exit 1 }
