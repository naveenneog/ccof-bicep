#Requires -Version 7.0
<#
.SYNOPSIS
    Stage D2, schema and apps (docs/PILOT.md C-9; docs/DEPLOYMENT-STAGES.md, D2 steps).

.DESCRIPTION
    Deploys, in order: the Cosmos database and containers; the three apps' settings; the resolver's
    App Service Authentication (WP-RES); the APIM API, operation and backend entities; diagnostics
    (WP-TEL); the apps' code by OneDeploy, once D3 has granted the runtime roles; the policy revision
    (WP-GW), smoke-tested on its revision URL and made current only when gateway.promoteAfterSmoke is
    true; the workbook content (WP-WB); and the smoke tests. Each step compares the live state and
    writes only what differs, and is recorded as stage-D2:<step>. The workbook step with an unchanged
    input digest runs WP-WB's verify.ps1 and deploys again unless the workbook verifies. In a new
    deployment D2 runs before D3 and again after it. The sync timer stays disabled; the resolver's
    budget mode is written only when absent.
    -Action Plan: read-only; shows each step's recorded state, what it waits for, and the database and
    containers the schema step would create.
    -Action Apply: runs the steps. Before any write it reads D1 again (Get-CoreD1Record, the answers'
    D1 sections) and refuses with d1_record_mismatch when a value in the stage-D1 record differs from
    what Azure and Microsoft Graph report: the record is a shared file, and its host names, app ids and
    principal ids reach the gateway policy and the apps' settings (WP-SEC C1). A run of the schema
    step alone, whose answers may hold only that step's sections, checks its one D1 input, cosmos.id,
    against the account the answers name.
    -Steps <id>[,<id>...]: runs only the named steps (Get-CoreD2Steps). The others are skipped, neither
    run nor recorded, and stage-D2 is recorded only by a run of every step. A selected step whose
    needs are neither selected nor recorded refuses. Each step a -Steps run records lists the steps it
    deferred, and a later run that would run a deferred step without naming it refuses. The answers
    are checked for the sections the selected steps read. An empty or unknown step refuses. Every
    refusal comes before any Azure call.
    Role: Contributor on the resource group. Every Azure CLI call names --subscription, and D2's own
    run only after Assert-OnboardingAzArguments accepts their arguments (az_arguments_refused).
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Apply')] [string]$Action,
    [string]$AnswersPath,
    [string]$CheckpointPath,
    [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Steps,
    [switch]$DotSourceOnly
)

foreach ($module in @('Core.Schema', 'Core.Answers', 'Core.Rest', 'Core.Prereqs', 'Core.Permissions', 'Core.PermissionsApply', 'Core.D2Steps', 'Core.D2Apim', 'Core.D2Code', 'Core.D2Stage', 'Checkpoint', 'Onboarding.Decisions', 'Onboarding.Azure')) {
    Import-Module (Join-Path $PSScriptRoot "$module.psm1") -Force -DisableNameChecking
}

$script:RequiredActions = @('Microsoft.Resources/deployments/write', 'Microsoft.Web/sites/config/write', 'Microsoft.ApiManagement/service/apis/write', 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/write')

function Get-CoreRecordedEvidence {
    param($Record, [string]$StageId)
    $stage = @($Record.stages | Where-Object { $_.stageId -eq $StageId })[0]
    if ($stage) { return (ConvertFrom-CoreJson ($stage.evidence | ConvertTo-Json -Depth 40)) }
    return $null
}

function Invoke-StageD2 {
    param(
        [Parameter(Mandatory)] [ValidateSet('Plan', 'Apply')] [string]$Action,
        [Parameter(Mandatory)] [string]$AnswersPath,
        [Parameter(Mandatory)] [string]$CheckpointPath,
        [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
        [scriptblock]$Send,
        [hashtable]$Pieces,
        [scriptblock]$GetIdentity = { param($SubscriptionId) Get-OnboardingIdentity -SubscriptionId $SubscriptionId },
        [scriptblock]$Sleep = { param($s) Start-Sleep -Seconds $s },
        [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Steps,
        [scriptblock]$ReadD1
    )
    function Refuse([string]$Code, [string[]]$Lines) { [pscustomobject]@{ Satisfied = $false; ReasonCode = $Code; Remedy = $Lines; Steps = @() } }
    $selected = $null
    $readArguments = @{ Path = $AnswersPath; Stage = 'D2'; RepositoryRoot = $RepositoryRoot }
    if ($PSBoundParameters.ContainsKey('Steps')) {
        $known = @(Get-CoreD2Steps | ForEach-Object { $_.id })
        $names = @($Steps | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() })
        if (-not $names.Count -or @($names | Where-Object { -not $_ }).Count) { return Refuse 'steps_empty' @("REFUSED: -Steps names no step, or has a blank one. Give one or more of: $($known -join ', '). Nothing was changed.") }
        $unknown = @($names | Where-Object { $known -cnotcontains $_ })
        if ($unknown.Count) { return Refuse 'unknown_step' @("REFUSED: unknown D2 step(s): $($unknown -join ', '). Known steps: $($known -join ', '). Nothing was changed.") }
        $selected = @($names | Select-Object -Unique)
        $sections = Get-CoreD2StepSections -Steps $selected
        if ($sections) { $readArguments.Sections = $sections }
    }
    $read = Read-CoreAnswers @readArguments
    if ($read.Problems.Count) { return Refuse 'answers_incomplete' @(Format-CoreProblems -Problems $read.Problems) }
    $answers = $read.Answers
    # WP-SEC C1: Apply reads stage-D1 again before it writes, so the answers need D1's sections. A run
    # of the schema step alone may hold only its own sections; its one D1 input is cosmos.id.
    $schemaOnly = $selected -and -not @($selected | Where-Object { $_ -cne 'schema' }).Count
    if ($Action -eq 'Apply' -and -not $schemaOnly) {
        $d1Read = Read-CoreAnswers -Path $AnswersPath -Stage D1 -RepositoryRoot $RepositoryRoot
        if ($d1Read.Problems.Count) { return Refuse 'answers_incomplete' (@('REFUSED: Apply reads stage-D1 again before it writes, so the answers need the D1 sections too. Nothing was changed.') + @(Format-CoreProblems -Problems $d1Read.Problems)) }
    }
    $record = Get-CheckpointRecord -Path $CheckpointPath
    $d1Evidence = Get-CoreRecordedEvidence $record 'stage-D1'
    if (-not $d1Evidence) { return Refuse 'stage_D1_missing' @('REFUSED: stage-D1 is not in the checkpoint record. Run scripts/Record-Prerequisites.ps1 -Action Record first. Nothing was changed.') }
    $d1 = $d1Evidence.outputs
    # Resume rule for -Steps runs (docs/DEPLOYMENT-STAGES.md): a selected step's needs must be selected
    # or recorded, and the steps an earlier -Steps run deferred run only when a later run names them.
    $recorded = [ordered]@{}
    foreach ($step in Get-CoreD2Steps) { $e = Get-CoreRecordedEvidence $record "stage-D2:$($step.id)"; if ($e) { $recorded[$step.id] = $e } }
    $deferred = @($recorded.Values | ForEach-Object { @($_.deferred) } | Where-Object { $_ -and -not $recorded.Contains([string]$_) } | Select-Object -Unique)
    if ($selected) {
        $missingNeeds = @(Get-CoreD2Steps | Where-Object { $selected -ccontains $_.id } | ForEach-Object { $s = $_; @($s.needs | Where-Object { $selected -cnotcontains $_ -and -not $recorded.Contains($_) }) | ForEach-Object { "$($s.id) needs $_" } })
        if ($missingNeeds.Count) { return Refuse 'needs_not_recorded' @("REFUSED: $($missingNeeds -join '; '), neither selected nor recorded. Add it to -Steps. Nothing was changed.") }
    }
    elseif ($deferred.Count) {
        return Refuse 'deferred_steps_not_named' @("REFUSED: an earlier D2 run used -Steps and deferred: $($deferred -join ', '). A run without -Steps would run them. Name the steps to run with -Steps once they are reviewed (docs/DEPLOYMENT-STAGES.md). Nothing was changed.")
    }
    $deferNow = if ($selected) { @(Get-CoreD2Steps | ForEach-Object { $_.id } | Where-Object { $selected -cnotcontains $_ -and -not $recorded.Contains($_) }) } else { @() }
    # az.cmd passes every argument through cmd.exe on Windows: the arguments of the az calls the
    # selected steps make are checked with the onboarding guard, as each call checks them again.
    $outDir = Resolve-CoreAnswerPath $read.AnswersDirectory $answers.output.directory
    $unsafe = @(Get-CoreD2UnsafeAzArguments -Answers $answers -D1 $d1 -RepositoryRoot $RepositoryRoot -OutDir $outDir -Steps $(if ($selected) { $selected } else { @(Get-CoreD2Steps | ForEach-Object { $_.id }) }))
    if ($unsafe.Count) {
        return Refuse 'az_arguments_refused' (@("REFUSED before any Azure call: az.cmd passes every argument through cmd.exe on Windows, and these D2 Azure CLI arguments hold a character it re-parses (& | < > ^ ( ) % ' `" `` or a line break):") + @($unsafe | ForEach-Object { "  - $_" }) + @('Use an output.directory, a checkout folder and a TEMP folder without them. Nothing was changed.'))
    }
    $sub = $answers.target.subscriptionId
    $actor = & $GetIdentity $sub
    if (-not $actor.objectId -or -not [string]::Equals([string]$actor.tenantId, [string]$answers.target.tenantId, 'OrdinalIgnoreCase')) {
        return Refuse 'wrong_tenant' @('REFUSED: the signed-in Azure CLI identity is not in target.tenantId. Nothing was changed.')
    }
    if (-not $Send) { $Send = { param($Method, $Url, $Body) Invoke-CoreRest -SubscriptionId $sub -Method $Method -Url $Url -Body $Body }.GetNewClosure() }
    if (-not $Pieces) { $Pieces = New-CoreDefaultPieces -RepositoryRoot $RepositoryRoot -Answers $answers -D1 $d1 -Send $Send }
    $rgScope = "/subscriptions/$sub/resourceGroups/$($answers.target.resourceGroup.name)"
    $rights = & $Send 'GET' "https://management.azure.com$rgScope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" $null
    $lacking = @($script:RequiredActions | Where-Object { $rights.Status -ne 200 -or -not (Test-CoreActionAllowed -Permissions @($rights.Content.value) -Action $_) })
    if ($lacking.Count) { return Refuse 'caller_rights_missing' @("REFUSED before any write: the signed-in identity lacks $($lacking -join ', ') on $rgScope. D2 needs Contributor on the resource group (docs/DEPLOYMENT-GUIDE.md, People and roles).") }

    $previous = @{}
    foreach ($step in Get-CoreD2Steps) { $e = Get-CoreRecordedEvidence $record "stage-D2:$($step.id)"; if ($e) { $previous[$step.id] = $e.outputs } }
    $d3 = Get-CoreRecordedEvidence $record 'stage-D3'
    if ($Action -eq 'Plan') {
        $rows = @(Get-CoreD2Steps | ForEach-Object {
                if ($selected -and $selected -cnotcontains $_.id) { return [pscustomobject]@{ Id = $_.id; State = 'skipped'; ReasonCode = 'not_selected'; Lines = @() } }
                [pscustomobject]@{
                    Id = $_.id; State = $(if ($previous.Contains($_.id)) { 'recorded' } else { 'pending' }); ReasonCode = $(if ($_.id -eq 'code' -and -not $d3) { 'waits_for:stage-D3' } else { $null })
                    Lines = $(if ($_.id -eq 'schema') { @(Get-CoreD2SchemaPlan -D1 $d1 -Answers $answers -Send $Send) } else { @() })
                }
            })
        return [pscustomobject]@{ Satisfied = $true; ReasonCode = 'planned'; Steps = $rows; Remedy = $null }
    }
    $audit = @{ RunId = [guid]::NewGuid().ToString(); StageId = 'stage-D2'; CheckpointPath = $CheckpointPath; Actor = $actor }
    if ($schemaOnly) {
        $expectedCosmos = (Get-CoreD1ExpectedIds -Answers $answers).cosmos
        $stale = if (-not (Test-CoreIdEqual ([string]$d1.cosmos.id) $expectedCosmos)) { @("REFUSED before any write: the stage-D1 record names the Cosmos account '$($d1.cosmos.id)', and the answers name '$expectedCosmos'. Nothing was changed.") }
    }
    else {
        if (-not $ReadD1) { $ReadD1 = { param($D1Answers) Get-CoreD1Live -Answers $D1Answers -Send $Send }.GetNewClosure() }
        $stale = Test-CoreD1RecordCurrent -Recorded $d1 -Answers $d1Read.Answers -ReadD1 $ReadD1
    }
    if ($stale) {
        Write-OnboardingAudit $audit 'precondition_refused' @{ reasonCode = 'd1_record_mismatch' }
        return Refuse 'd1_record_mismatch' $stale
    }
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $ctx = @{
        Answers = $answers; D1 = $d1; Send = $Send; Pieces = $Pieces; Sleep = $Sleep; OutDir = $outDir; RepositoryRoot = $RepositoryRoot
        AnswersDirectory = $read.AnswersDirectory; Previous = $previous; D3Runtime = $(if ($d3) { $d3.runtimeGrants } else { $null }); Actor = $actor
    }
    Write-OnboardingAudit $audit 'stage_start' $(if ($selected) { @{ operation = 'd2_selected_steps'; target = ($selected -join ',') } } else { @{} })
    $onStep = {
        param($Row)
        if ($Row.State -in @('applied', 'unchanged')) {
            $evidence = @{ state = $Row.State; outputs = $Row.Outputs }
            if ($selected) { $evidence.selectedSteps = @($selected); $evidence.deferred = @($deferNow) }
            Set-CheckpointStageComplete -Path $CheckpointPath -StageId "stage-D2:$($Row.Id)" -CompletedBy $actor.objectId -Evidence $evidence
            if ($Row.State -eq 'applied') { Write-OnboardingAudit $audit 'write_performed' @{ operation = "d2_$($Row.Id)"; target = $Row.Id } }
            Write-OnboardingAudit $audit 'step_completed' @{ operation = "d2_$($Row.Id)"; target = $Row.Id; reasonCode = [string]$Row.State }
        }
        else { Write-OnboardingAudit $audit 'step_not_completed' @{ operation = "d2_$($Row.Id)"; reasonCode = [string]$Row.ReasonCode } }
    }.GetNewClosure()
    $rows = @(Invoke-CoreD2Steps -Ctx $ctx -OnStep $onStep -Only $selected)
    $done = @($rows | Where-Object { $_.State -notin @('applied', 'unchanged') }).Count -eq 0
    if ($done) {
        Set-CheckpointStageComplete -Path $CheckpointPath -StageId 'stage-D2' -CompletedBy $actor.objectId -Evidence @{ steps = @($rows | ForEach-Object { @{ id = $_.Id; state = $_.State } }); answersDigest = $read.Digest }
        Write-OnboardingAudit $audit 'completed'
    }
    $failed = @($rows | Where-Object State -eq 'failed')
    $open = @($rows | Where-Object { $_.State -notin @('applied', 'unchanged', 'skipped') })
    $code = if ($failed.Count) { 'steps_failed' } elseif ($done) { 'completed' } elseif ($selected -and -not $open.Count) { 'selected_steps_completed' } else { 'waiting' }
    [pscustomobject]@{ Satisfied = ($failed.Count -eq 0); ReasonCode = $code; Steps = $rows; Remedy = @($open | ForEach-Object { "  $($_.Id): $($_.State) $($_.ReasonCode)"; $_.Lines | ForEach-Object { "    $_" } }) }
}

if (-not $DotSourceOnly) {
    if (-not $Action -or -not $AnswersPath -or -not $CheckpointPath) {
        Write-Error 'Usage: Stage-D2-DeploySchemaAndApps.ps1 -Action Plan|Apply -AnswersPath <answers.json> -CheckpointPath <checkpoint.json> [-Steps <step>[,<step>...]]'
        exit 2
    }
    $arguments = @{ Action = $Action; AnswersPath = $AnswersPath; CheckpointPath = $CheckpointPath }
    if ($PSBoundParameters.ContainsKey('Steps')) { $arguments.Steps = $Steps }
    $result = Invoke-StageD2 @arguments
    $result.Steps | ForEach-Object {
        Write-Output ("{0,-14} {1,-10} {2}" -f $_.Id, $_.State, $_.ReasonCode)
        if ($Action -eq 'Plan') { @($_.Lines) | Where-Object { $_ } | ForEach-Object { Write-Output "    $_" } }
    }
    if ($result.Remedy) { $result.Remedy | ForEach-Object { Write-Output $_ } }
    switch ($result.ReasonCode) {
        'completed' { Write-Output 'stage-D2 recorded. Next: D4 groups (onboarding Stage 1), then onboarding Stages 2, 3 and 5 (docs/DEPLOYMENT-STAGES.md).' }
        'selected_steps_completed' { Write-Output 'The selected steps are recorded as stage-D2:<step>. stage-D2 itself is recorded only by a run of every step.' }
        'waiting' { Write-Output 'Some steps wait: run D3 (scripts/Stage-D3-GrantPermissions.ps1), then this stage again, with the same -Steps if this run used them.' }
    }
    if (-not $result.Satisfied) { exit 1 }
    exit 0
}
