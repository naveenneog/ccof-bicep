#Requires -Version 7.0
<#
.SYNOPSIS
    Stage D3, permissions (docs/PILOT.md C-9; docs/DEPLOYMENT-STAGES.md).

.DESCRIPTION
    Applies every Azure role assignment, Cosmos data-plane assignment and Microsoft Graph application
    permission that the packages list as data (infra/permissions/sources.json), each with a
    deterministic name, read back and recorded as stage-D3:<id>. Nothing is deleted.
    -Action Plan: read-only; resolves the data against stage-D1 and the answers, checks the caller's
    rights, reads the Cosmos account's role definitions, and prints the plan and its digest: what D3
    would do to each custom role definition (create, update or unchanged), then each assignment with
    the role it grants, a Cosmos role resolved to its name and data actions. The digest also binds
    every rewrite of an existing role definition.
    -Action Apply -PlanDigest <first 12+ hex of the digest>: applies exactly that plan. Before any
    write it reads D1 again (Get-CoreD1Record, the answers' D1 sections) and refuses with
    d1_record_mismatch when a value in the stage-D1 record differs from what Azure and Microsoft Graph
    report: the record is a shared file, and its principal ids and scopes become grants (WP-SEC C1).
    The Graph permission is granted only when the caller holds an active Privileged Role Administrator
    or Global Administrator role; otherwise D3 prints docs/DEPLOYMENT-GUIDE.md Step 7 with the ids and
    records it pending. The sync timer is enabled only after the permission is verified, and only in
    sync.mode application-permission; if D3 cannot enable it and read it back, D3 fails
    (sync_timer_failed) and records no stage-D3.
    Roles: Role Based Access Control Administrator or User Access Administrator at each scope;
    Contributor on the Cosmos account for data-plane assignments.
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Apply')] [string]$Action,
    [string]$AnswersPath,
    [string]$CheckpointPath,
    [string]$PlanDigest,
    [string]$SourcesPath,
    [switch]$DotSourceOnly
)

foreach ($module in @('Core.Schema', 'Core.Answers', 'Core.Rest', 'Core.Prereqs', 'Core.Permissions', 'Core.PermissionsApply', 'Checkpoint', 'Onboarding.Decisions', 'Onboarding.Azure')) {
    Import-Module (Join-Path $PSScriptRoot "$module.psm1") -Force -DisableNameChecking
}

function Get-CoreStageEvidence {
    param($Record, [string]$StageId)
    $stage = @($Record.stages | Where-Object { $_.stageId -eq $StageId })[0]
    if ($stage) { return (ConvertFrom-CoreJson ($stage.evidence | ConvertTo-Json -Depth 40)) }
    return $null
}

function Set-CoreSyncTimer {
    <#
    .SYNOPSIS
        Enables the sync timer and reads the setting back. enabled is true only when the read-back
        shows it enabled; a failed or unreadable read is never taken as verified.
    #>
    param([System.Collections.IDictionary]$D1, [scriptblock]$Send)
    $site = "https://management.azure.com$($D1.apps.sync.functionAppId)"
    $list = & $Send 'POST' "$site/config/appsettings/list?api-version=2024-04-01" $null
    if ($list.Status -ne 200 -or $list.Content.properties -isnot [System.Collections.IDictionary]) { return @{ enabled = $false; reasonCode = 'settings_unreadable' } }
    $settings = [ordered]@{}
    foreach ($key in $list.Content.properties.Keys) { $settings[$key] = $list.Content.properties[$key] }
    if (-not $settings.Contains('SYNC_SCHEDULE')) { return @{ enabled = $false; reasonCode = 'sync_settings_missing' } }
    if ($settings['AzureWebJobs.syncEntitlement.Disabled'] -ne 'false') {
        $settings['AzureWebJobs.syncEntitlement.Disabled'] = 'false'
        $put = & $Send 'PUT' "$site/config/appsettings?api-version=2024-04-01" @{ properties = $settings }
        if ($put.Status -ne 200) { return @{ enabled = $false; reasonCode = "settings_write_$($put.Status)" } }
        $check = & $Send 'POST' "$site/config/appsettings/list?api-version=2024-04-01" $null
        if ($check.Status -ne 200 -or $check.Content.properties -isnot [System.Collections.IDictionary]) { return @{ enabled = $false; reasonCode = "settings_readback_$($check.Status)" } }
        if ($check.Content.properties['AzureWebJobs.syncEntitlement.Disabled'] -ne 'false') { return @{ enabled = $false; reasonCode = 'not_verified' } }
    }
    return @{ enabled = $true; reasonCode = 'graph_permission_verified' }
}

function Format-CoreD3Plan {
    <#
    .SYNOPSIS
        The plan as the operator reviews it: what D3 would do to each custom Cosmos role definition,
        then each assignment with the role it grants. A Cosmos role is shown resolved: a built-in's
        name and id, or the custom key with its role name and data actions.
    #>
    param($Plan, [object[]]$DefinitionWrites)
    $definitions = @{}
    foreach ($def in @($Plan.RoleDefinitions)) { $definitions["custom:$($def.key)"] = $def }
    foreach ($w in @($DefinitionWrites)) {
        $head = "  Cosmos role definition custom:$($w.key) '$($w.roleName)': "
        switch ($w.op) {
            'create' { $head + "create $($w.definitionId) with ($($w.dataActions -join ', '))" }
            'update' { $head + "update $($w.definitionId) from ($($w.currentActions -join ', ')) to ($($w.dataActions -join ', '))" + $(if ($w.currentName -cne $w.roleName) { ", renamed from '$($w.currentName)'" }) + "; $($w.heldBy) assignment(s) hold it now and change with it" }
            default { $head + "unchanged $($w.definitionId)" }
        }
    }
    foreach ($item in @($Plan.Items)) {
        $role = if ($item.plane -ne 'cosmos-data') { $item.role }
        elseif ($definitions.Contains([string]$item.roleDefinitionId)) { $d = $definitions[[string]$item.roleDefinitionId]; "$($item.roleDefinitionId) '$($d.roleName)' ($($d.dataActions -join ', '))" }
        else { "$($item.role) ($($item.roleDefinitionId))" }
        "  $($item.id): $($item.plane) $role for $($item.principalId) at $($item.scope)$(if ($item.appRoleId) { " appRoleId $($item.appRoleId)" })"
    }
}

function Invoke-StageD3 {
    param(
        [Parameter(Mandatory)] [ValidateSet('Plan', 'Apply')] [string]$Action,
        [Parameter(Mandatory)] [string]$AnswersPath,
        [Parameter(Mandatory)] [string]$CheckpointPath,
        [string]$PlanDigest,
        [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
        [string]$SourcesPath,
        [scriptblock]$Send,
        [scriptblock]$GetIdentity = { param($SubscriptionId) Get-OnboardingIdentity -SubscriptionId $SubscriptionId },
        [scriptblock]$Sleep = { param($s) Start-Sleep -Seconds $s },
        [scriptblock]$ReadD1
    )
    if (-not $SourcesPath) { $SourcesPath = Join-Path $RepositoryRoot 'infra/permissions/sources.json' }
    function Refuse([string]$Code, [string[]]$Lines) { [pscustomobject]@{ Satisfied = $false; ReasonCode = $Code; Remedy = $Lines } }
    $read = Read-CoreAnswers -Path $AnswersPath -Stage D3 -RepositoryRoot $RepositoryRoot
    if ($read.Problems.Count) { return Refuse 'answers_incomplete' @(Format-CoreProblems -Problems $read.Problems) }
    $answers = $read.Answers
    if ($Action -eq 'Apply') {
        # WP-SEC C1: Apply reads stage-D1 again before it writes, so the answers need D1's sections.
        $d1Read = Read-CoreAnswers -Path $AnswersPath -Stage D1 -RepositoryRoot $RepositoryRoot
        if ($d1Read.Problems.Count) { return Refuse 'answers_incomplete' (@('REFUSED: Apply reads stage-D1 again before it writes, so the answers need the D1 sections too. Nothing was changed.') + @(Format-CoreProblems -Problems $d1Read.Problems)) }
    }
    $record = Get-CheckpointRecord -Path $CheckpointPath
    $d1Evidence = Get-CoreStageEvidence $record 'stage-D1'
    if (-not $d1Evidence) { return Refuse 'stage_D1_missing' @('REFUSED: stage-D1 is not in the checkpoint record. Run scripts/Record-Prerequisites.ps1 -Action Record first. Nothing was changed.') }
    if (-not (Get-CoreStageEvidence $record 'stage-D2:schema')) { return Refuse 'stage_D2_schema_missing' @('REFUSED: stage-D2:schema is not recorded; the Cosmos containers that D3 grants on come from D2. Run D2 first. Nothing was changed.') }
    $d1 = $d1Evidence.outputs
    $sources = Read-CoreAssignmentSources -SourcesPath $SourcesPath -RepositoryRoot $RepositoryRoot
    $plan = Get-CoreAssignmentPlan -Documents $sources.Documents -D1 $d1 -Answers $answers
    $planProblems = @($sources.Problems) + @($plan.Problems)
    if ($planProblems.Count) { return Refuse 'assignment_data_invalid' (@("REFUSED: the assignment data has $($planProblems.Count) problem(s). Nothing was changed.") + @($planProblems | ForEach-Object { "  - $($_.path) [$($_.code)]: $($_.detail)" })) }

    $sub = $answers.target.subscriptionId
    $actor = & $GetIdentity $sub
    if (-not $actor.objectId -or -not [string]::Equals([string]$actor.tenantId, [string]$answers.target.tenantId, 'OrdinalIgnoreCase')) {
        return Refuse 'wrong_tenant' @('REFUSED: the signed-in Azure CLI identity is not in target.tenantId. Nothing was changed.')
    }
    if (-not $Send) { $Send = { param($Method, $Url, $Body) Invoke-CoreRest -SubscriptionId $sub -Method $Method -Url $Url -Body $Body }.GetNewClosure() }
    $context = @{ RunId = [guid]::NewGuid().ToString(); StageId = 'stage-D3'; CheckpointPath = $CheckpointPath; Actor = $actor }
    $refusals = @(Get-CoreD3Refusals -Plan $plan -D1 $d1 -Send $Send)
    $definitionWrites = Get-CoreCosmosDefinitionWrites -Plan $plan -D1 $d1 -Send $Send
    # Missing rights come first: they may also be why the role definitions could not be read.
    $refusalCode = if ($refusals.Count) { 'caller_rights_missing' } elseif ($definitionWrites.Code) { [string]$definitionWrites.Code } else { $null }
    $refusals += @($definitionWrites.Refusals)
    if ($refusals.Count) {
        Write-OnboardingAudit $context 'precondition_refused' @{ reasonCode = $refusalCode }
        return Refuse $refusalCode (@('REFUSED before any write:') + @($refusals | ForEach-Object { "  - $_" }))
    }
    $summary = @(Format-CoreD3Plan -Plan $plan -DefinitionWrites $definitionWrites.Writes)
    # The digest binds the desired state and every role definition rewrite the plan shows.
    $digest = Get-CoreD3Digest -PlanDigest $plan.Digest -DefinitionWrites $definitionWrites.Writes
    if ($Action -eq 'Plan') {
        return [pscustomobject]@{ Satisfied = $true; ReasonCode = 'planned'; Digest = $digest; Summary = $summary; Remedy = $null }
    }
    if ([string]::IsNullOrEmpty($PlanDigest) -or $PlanDigest.Length -lt 12 -or -not $digest.StartsWith($PlanDigest.ToLowerInvariant(), [StringComparison]::Ordinal)) {
        return Refuse 'plan_digest_mismatch' @("REFUSED: -PlanDigest must be the first 12 or more characters of the current plan digest; run -Action Plan and review it. Nothing was changed.")
    }
    if (-not $ReadD1) { $ReadD1 = { param($D1Answers) Get-CoreD1Live -Answers $D1Answers -Send $Send }.GetNewClosure() }
    $stale = Test-CoreD1RecordCurrent -Recorded $d1 -Answers $d1Read.Answers -ReadD1 $ReadD1
    if ($stale) {
        Write-OnboardingAudit $context 'precondition_refused' @{ reasonCode = 'd1_record_mismatch' }
        return Refuse 'd1_record_mismatch' $stale
    }
    Write-OnboardingAudit $context 'stage_start'
    $onWrite = { param($Operation, $Target, $ResourceId) Write-OnboardingAudit $context 'write_performed' @{ operation = $Operation; target = $Target; resourceId = $ResourceId } }.GetNewClosure()
    $results = @(Invoke-CoreD3Apply -Plan $plan -D1 $d1 -Send $Send -Sleep $Sleep -DefinitionWrites $definitionWrites.Writes -OnWrite $onWrite)
    foreach ($r in $results) {
        if ($r.state -in @('existing', 'inherited', 'created')) {
            Set-CheckpointStageComplete -Path $CheckpointPath -StageId "stage-D3:$($r.id)" -CompletedBy $actor.objectId -Evidence @{ plane = $r.plane; principalId = $r.principalId; scope = $r.scope; state = $r.state; runtime = $r.runtime }
            if ($r.state -eq 'created') { Write-OnboardingAudit $context 'write_performed' @{ operation = "grant_$($r.plane)"; target = $r.id } }
        }
    }
    $pending = @($results | Where-Object state -eq 'pending')
    $failed = @($results | Where-Object state -eq 'failed')
    $graph = @($results | Where-Object plane -eq 'graph-app-role')
    Set-CheckpointStageComplete -Path $CheckpointPath -StageId 'stage-D3:graph' -CompletedBy $actor.objectId -Evidence @{ items = @($graph | ForEach-Object { @{ id = $_.id; state = $_.state } }) }
    $syncGraphOk = $answers.sync.mode -eq 'application-permission' -and @($graph | Where-Object { $_.principalId -eq $d1.apps.sync.principalId }).Count -gt 0 -and @($graph | Where-Object { $_.principalId -eq $d1.apps.sync.principalId -and $_.state -notin @('existing', 'created') }).Count -eq 0
    $timerAttempted = $syncGraphOk -and [bool](Get-CoreStageEvidence $record 'stage-D2:settings')
    $timer = if ($timerAttempted) { Set-CoreSyncTimer -D1 $d1 -Send $Send }
    elseif ($answers.sync.mode -ne 'application-permission') { @{ enabled = $false; reasonCode = 'delegated_snapshot_mode' } }
    elseif (-not $syncGraphOk) { @{ enabled = $false; reasonCode = 'graph_permission_not_verified' } }
    else { @{ enabled = $false; reasonCode = 'stage_D2_settings_missing' } }
    # D3 tried to enable the timer and could not: the step failed, so it records nothing.
    $timerFailed = $timerAttempted -and -not $timer.enabled
    if (-not $timerFailed) { Set-CheckpointStageComplete -Path $CheckpointPath -StageId 'stage-D3:sync-timer' -CompletedBy $actor.objectId -Evidence $timer }
    if ($timer.enabled -and $timer.reasonCode -eq 'graph_permission_verified') { Write-OnboardingAudit $context 'write_performed' @{ operation = 'enable_sync_timer'; target = 'sync' } }
    $runtime = [ordered]@{}
    foreach ($app in @('resolver', 'sync', 'reconciler')) {
        $mine = @($results | Where-Object { $_.runtime -and $_.principalId -eq $d1.apps[$app].principalId })
        $runtime[$app] = $mine.Count -gt 0 -and @($mine | Where-Object { $_.state -notin @('existing', 'inherited', 'created') }).Count -eq 0
    }
    if ($failed.Count -or $timerFailed) {
        $code = if ($failed.Count) { 'assignments_failed' } else { 'sync_timer_failed' }
        Write-OnboardingAudit $context 'failed' @{ reasonCode = $code }
        $lines = @(if ($failed.Count) { "FAILED: $($failed.Count) assignment(s) were not applied; verified ones are recorded. Run D3 again after fixing:" } else { 'FAILED: the assignments are verified and recorded, but the sync timer is not enabled:' }) + @($failed | ForEach-Object { "  - $($_.id) [$($_.reasonCode)]" })
        if ($timerFailed) { $lines += "  - sync timer [$($timer.reasonCode)]: the Graph permission is verified, but D3 could not enable AzureWebJobs.syncEntitlement.Disabled=false on the sync app and read it back. Check the app's settings and your rights on it, then run D3 again. stage-D3 is not recorded." }
        return Refuse $code $lines
    }
    Set-CheckpointStageComplete -Path $CheckpointPath -StageId 'stage-D3' -CompletedBy $actor.objectId -Evidence @{ digest = $digest; verified = @($results | Where-Object state -ne 'pending' | ForEach-Object id); pending = @($pending | ForEach-Object id); runtimeGrants = $runtime; syncTimerEnabled = [bool]$timer.enabled }
    Write-OnboardingAudit $context 'completed'
    $lines = @($results | ForEach-Object { "  $($_.id): $($_.state)" }) + @($pending | ForEach-Object { $_.instructions })
    return [pscustomobject]@{ Satisfied = $true; ReasonCode = if ($pending.Count) { 'applied_with_pending' } else { 'applied' }; Results = $results; RuntimeGrants = $runtime; SyncTimer = $timer; Summary = $lines; Remedy = $null }
}

if (-not $DotSourceOnly) {
    if (-not $Action -or -not $AnswersPath -or -not $CheckpointPath) {
        Write-Error 'Usage: Stage-D3-GrantPermissions.ps1 -Action Plan|Apply -AnswersPath <answers.json> -CheckpointPath <checkpoint.json> [-PlanDigest <hex>]'
        exit 2
    }
    $arguments = @{ Action = $Action; AnswersPath = $AnswersPath; CheckpointPath = $CheckpointPath; PlanDigest = $PlanDigest }
    if ($SourcesPath) { $arguments.SourcesPath = $SourcesPath }
    $result = Invoke-StageD3 @arguments
    if (-not $result.Satisfied) { $result.Remedy | ForEach-Object { Write-Output $_ }; exit 1 }
    if ($Action -eq 'Plan') {
        Write-Output "Plan digest: $($result.Digest)"
        $result.Summary | ForEach-Object { Write-Output $_ }
        Write-Output "Apply with: -Action Apply -PlanDigest $($result.Digest.Substring(0, 12))"
    }
    else { $result.Summary | ForEach-Object { Write-Output $_ }; Write-Output "stage-D3 recorded ($($result.ReasonCode)). Next: D2's remaining steps (docs/DEPLOYMENT-STAGES.md). If an earlier D2 run used -Steps, name the deferred steps with -Steps: a run that does not name them refuses." }
    exit 0
}
