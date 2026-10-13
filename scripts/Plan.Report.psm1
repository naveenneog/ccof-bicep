#Requires -Version 7.0
<#
.SYNOPSIS
    The deployment plan report (WP-PLAN): for every row of config/stage-roles.json (stage, D2 step,
    project, backend), the checkpoint records present and missing, what already exists, the operator's
    roles against the stage's requirements, a verdict (done, ready, needs-role, blocked) and the next
    action. Read-only: every provider read goes through the guard's Send; the stages' own checks run
    through the Runners (Plan.Runners.psm1), against a copy of the checkpoint.
#>

Import-Module (Join-Path $PSScriptRoot 'Plan.Data.psm1')
Import-Module (Join-Path $PSScriptRoot 'Plan.Access.psm1')
Import-Module (Join-Path $PSScriptRoot 'Plan.Discovery.psm1')
Import-Module (Join-Path $PSScriptRoot 'Core.Answers.psm1')
Import-Module (Join-Path $PSScriptRoot 'Core.D2Stage.psm1')

function Get-PlanAnswersBlock {
    <# The PENDING decisions and other answers problems of the sections a row reads (Read-CoreAnswers). #>
    param([string]$AnswersPath, [string]$Stage, [string]$Step, [string]$RepositoryRoot)
    $arguments = @{ Path = $AnswersPath; Stage = $Stage; RepositoryRoot = $RepositoryRoot }
    if ($Stage -eq 'D2' -and $Step) { $sections = Get-CoreD2StepSections -Steps @($Step); if ($sections) { $arguments.Sections = $sections } }
    $problems = @((Read-CoreAnswers @arguments).Problems)
    [pscustomobject]@{
        Pending = @($problems | Where-Object code -eq 'pending_decision' | ForEach-Object path)
        Other = @($problems | Where-Object code -ne 'pending_decision' | ForEach-Object { "$($_.path) [$($_.code)]" })
    }
}

function Get-PlanD2Results {
    <#
    .SYNOPSIS
        D2's own Plan, once, for the D2 step rows that are not recorded, read every record they need and
        have complete answers; a step whose need is neither recorded nor planned is left out (its row
        reads blocked). Returns Selected, Refusal and Rows (by step).
    #>
    param([object[]]$Rows, [hashtable]$Runners, [string]$AnswersPath)
    $recorded = @{}; foreach ($r in $Rows) { if (-not $r.RecordState.Missing.Count) { $recorded[$r.Step] = $true } }
    $selected = [System.Collections.Generic.List[string]]::new()
    foreach ($step in Get-CoreD2Steps) {
        $row = @($Rows | Where-Object Step -eq $step.id)[0]
        if (-not $row -or $recorded[$step.id] -or $row.ReadsMissing.Count -or $row.AnswersBlock.Pending.Count -or $row.AnswersBlock.Other.Count) { continue }
        if (@($step.needs | Where-Object { -not $recorded[$_] -and $selected -cnotcontains $_ }).Count) { continue }
        $selected.Add($step.id)
    }
    if (-not $selected.Count) { return [pscustomobject]@{ Selected = @(); Refusal = $null; Rows = @{} } }
    $result = & $Runners.D2 $AnswersPath @($selected)
    $byStep = @{}; foreach ($s in @($result.Steps)) { $byStep[[string]$s.Id] = $s }
    [pscustomobject]@{ Selected = $selected.ToArray(); Refusal = $(if ($result.ReasonCode -ne 'planned') { $result } else { $null }); Rows = $byStep }
}

function Get-PlanVerdict {
    <# done, blocked, needs-role or ready, with the reason; see docs/DEPLOYMENT-STAGES.md, Plan the deployment. #>
    param($Row)
    if ($Row.Complete) {
        $who = @($Row.RecordState.Present | ForEach-Object { "$($_.stageId) by $($_.completedBy) at $($_.completedAt)" }) -join '; '
        return [pscustomobject]@{ code = 'done'; text = "done: $who" }
    }
    $blocked = [System.Collections.Generic.List[string]]::new()
    foreach ($b in @($Row.Blockers)) { $blocked.Add("$($b.id): $($b.text)") }
    if ($Row.ReadsMissing.Count) { $blocked.Add("not recorded yet: $($Row.ReadsMissing -join ', ')") }
    foreach ($p in @($Row.Problems)) { $blocked.Add($p) }
    if ($Row.AnswersBlock.Pending.Count) { $blocked.Add("PENDING decisions in the answers: $($Row.AnswersBlock.Pending -join ', ')") }
    if ($Row.AnswersBlock.Other.Count) { $blocked.Add("answers problems: $($Row.AnswersBlock.Other -join ', ')") }
    if ($Row.NeedsBlocked) { $blocked.Add($Row.NeedsBlocked) }
    $refusal = $Row.StageRefusal
    if ($refusal -and $refusal.code -eq 'waits_for:stage-D3') { $blocked.Add('the code step waits for stage-D3 (runtime grants)') }
    foreach ($r in @($Row.Requirements | Where-Object { $_.blocking -and $_.state -in @('unreadable', 'unresolved') })) { $blocked.Add("roles not read at $($r.scope): $($r.detail)") }
    if ($blocked.Count) { return [pscustomobject]@{ code = 'blocked'; text = "blocked: $($blocked -join '; ')" } }
    $missing = @($Row.Requirements | Where-Object { $_.blocking -and $_.state -eq 'missing' })
    if ($missing.Count) {
        $text = @($missing | ForEach-Object { "$(@($_.anyOf) -join ' or ') at $($_.scope) (usually: $($_.heldBy))" }) -join '; and '
        return [pscustomobject]@{ code = 'needs-role'; text = "needs $text" }
    }
    if ($refusal -and $refusal.code -eq 'caller_rights_missing') { return [pscustomobject]@{ code = 'needs-role'; text = "needs: $($refusal.remedy)" } }
    if ($refusal) { return [pscustomobject]@{ code = 'blocked'; text = "blocked: the stage's own check refused ($($refusal.code)): $($refusal.remedy)" } }
    [pscustomobject]@{ code = 'ready'; text = 'ready for you' }
}

function Get-PlanNext {
    param($Row, [string]$Command, [string]$Verdict)
    $stage = $Row.Stage
    $handoffs = @($Row.Requirements | Where-Object { -not $_.blocking -and $_.state -ne 'met' } | ForEach-Object { "$($_.heldBy): $($_.purpose) ($(@($_.anyOf) -join ' or '))" })
    switch ($Verdict) {
        'done' { [ordered]@{ command = $null; handoff = $null; handoffs = @(); resolveFirst = $null } }
        'ready' { [ordered]@{ command = $Command; handoff = $null; handoffs = $handoffs; resolveFirst = $null } }
        'needs-role' {
            $who = @($Row.Requirements | Where-Object { $_.blocking -and $_.state -eq 'missing' } | ForEach-Object heldBy | Select-Object -Unique) -join '; '
            [ordered]@{ command = $null; handoff = "$(if ($who) { "$who. " })$($stage.handoff)$(if ($Command -and $Command -ne 'none') { " Command: $Command" })"; handoffs = $handoffs; resolveFirst = $null }
        }
        default { [ordered]@{ command = $null; handoff = $null; handoffs = @(); resolveFirst = $Row.VerdictText } }
    }
}

function New-DeploymentPlan {
    <#
    .SYNOPSIS
        The plan object (kind ccof.deployment-plan). Runners: D2 { param($AnswersPath, $Steps) },
        D3 { param($AnswersPath) } and Discover { param($Stage, $AnswersFile) }, each a stage's own
        read-only check. Onboarding: @{ '<stage>' = @{ '<project or backend id>' = '<answers file>' } }.
    #>
    param(
        [Parameter(Mandatory)] $StageData, [Parameter(Mandatory)] [string]$AnswersPath, [Parameter(Mandatory)] [System.Collections.IDictionary]$Answers,
        [Parameter(Mandatory)] $Record, [Parameter(Mandatory)] [string]$CheckpointPath, [hashtable]$Onboarding = @{},
        [Parameter(Mandatory)] [hashtable]$Identity, [Parameter(Mandatory)] [hashtable]$Access, [Parameter(Mandatory)] [scriptblock]$Send,
        [Parameter(Mandatory)] [hashtable]$Runners, [Parameter(Mandatory)] [string]$RepositoryRoot
    )
    $d1Evidence = Get-PlanRecordedEvidence $Record 'stage-D1'
    $d1 = if ($d1Evidence -and $d1Evidence['outputs'] -is [System.Collections.IDictionary]) { $d1Evidence['outputs'] } else { [ordered]@{} }
    $policy = Get-PlanRecordedEvidence $Record 'stage-D2:policy'
    $outDir = Resolve-CoreAnswerPath (Split-Path $AnswersPath -Parent) ([string]$Answers.output.directory)
    $rows = @(Expand-PlanStageRows -Stages $StageData.Stages -Answers $Answers -D1 $d1 -Run @{ answersPath = $AnswersPath; checkpointPath = $CheckpointPath; onboarding = $Onboarding })
    foreach ($row in $rows) {
        $row | Add-Member -NotePropertyMembers @{
            RecordState = (Get-PlanRecordState -Record $Record -StageIds $row.Records)
            ReadsMissing = @((Get-PlanRecordState -Record $Record -StageIds $row.Reads).Missing)
            AnswersBlock = $(if ($row.Stage.Contains('answersStage')) { Get-PlanAnswersBlock -AnswersPath $AnswersPath -Stage $row.Stage.answersStage -Step $row.Step -RepositoryRoot $RepositoryRoot } else { [pscustomobject]@{ Pending = @(); Other = @() } })
            StageRefusal = $null; NeedsBlocked = $null; Complete = $false; VerdictText = $null
        }
        $row.Item.outputDirectory = $outDir
        if ($policy -and $policy['outputs']) { $row.Item.revision = [string]$policy['outputs']['revision'] }
    }
    # D2's own Plan for the steps that can be planned now.
    $d2Rows = @($rows | Where-Object { $_.Step })
    $d2 = Get-PlanD2Results -Rows $d2Rows -Runners $Runners -AnswersPath $AnswersPath
    $deferred = @($d2Rows | ForEach-Object { @($_.RecordState.Present) } | ForEach-Object { $e = ConvertFrom-CoreJson ($_.evidence | ConvertTo-Json -Depth 20); @($e['deferred']) } | Where-Object { $_ })
    $useSteps = @($deferred | Where-Object { $step = $_; @($d2Rows | Where-Object { $_.Step -eq $step -and $_.RecordState.Missing.Count }).Count }).Count -gt 0
    foreach ($row in $d2Rows) {
        $row.Item.steps = @($d2Rows | Where-Object { $_.Stage.id -eq $row.Stage.id -and $_.RecordState.Missing.Count } | ForEach-Object Step) -join ','
        if (-not $row.RecordState.Missing.Count) { continue }
        if ($d2.Refusal -and $d2.Selected -ccontains $row.Step) { $row.StageRefusal = [pscustomobject]@{ code = $d2.Refusal.ReasonCode; remedy = (@($d2.Refusal.Remedy) -join ' ') } }
        elseif ($d2.Selected -ccontains $row.Step -and $d2.Rows.Contains($row.Step) -and $d2.Rows[$row.Step].ReasonCode) { $row.StageRefusal = [pscustomobject]@{ code = [string]$d2.Rows[$row.Step].ReasonCode; remedy = '' } }
        elseif (-not $row.ReadsMissing.Count -and -not $row.AnswersBlock.Pending.Count -and -not $row.AnswersBlock.Other.Count -and $d2.Selected -cnotcontains $row.Step) {
            $needs = @((Get-CoreD2Steps | Where-Object id -eq $row.Step).needs | Where-Object { $n = $_; @($d2Rows | Where-Object { $_.Step -eq $n -and $_.RecordState.Missing.Count }).Count })
            $row.NeedsBlocked = "D2 $($needs -join ', ') cannot run yet"
        }
    }
    # D3's own Plan, once, when its records and answers allow it (also for a recorded D3: its digest shows drift).
    $d3Row = @($rows | Where-Object { $_.Stage.id -eq 'D3' })[0]
    $d3 = $null
    if ($d3Row -and -not $d3Row.ReadsMissing.Count -and -not $d3Row.AnswersBlock.Pending.Count -and -not $d3Row.AnswersBlock.Other.Count) {
        $d3 = & $Runners.D3 $AnswersPath
        if ($d3.ReasonCode -ne 'planned' -and $d3Row.RecordState.Missing.Count) { $d3Row.StageRefusal = [pscustomobject]@{ code = $d3.ReasonCode; remedy = (@($d3.Remedy) -join ' ') } }
    }
    $results = [System.Collections.Generic.List[object]]::new()
    $order = 0
    foreach ($row in $rows) {
        $order++
        $stage = $row.Stage
        $discovery = $null
        if ($stage.Contains('onboardingStage') -and $row.RecordState.Missing.Count -and -not $row.ReadsMissing.Count -and $row.Item.onboardingAnswersPath -notlike '<*') {
            $discovery = & $Runners.Discover ([string]$stage.onboardingStage) ([string]$row.Item.onboardingAnswersPath)
            if (-not $discovery.Satisfied) { $row.StageRefusal = [pscustomobject]@{ code = [string]$discovery.ReasonCode; remedy = [string]$discovery.Remedy } }
        }
        $requirements = foreach ($req in @($stage.requirements)) {
            $when = Test-PlanCondition -When ([string]$req.when) -Answers $Answers -Item $row.Item
            if ($when.Problem) { [pscustomobject]@{ kind = $req.kind; scope = $req.scope; anyOf = @($req.anyOf); held = @(); state = 'unresolved'; via = $null; detail = $when.Problem; heldBy = $req.heldBy; purpose = $req.purpose; blocking = ($req.blocking -ne $false); source = $req.source }; continue }
            if (-not $when.Applies) { continue }
            $scope = Resolve-PlanTemplate -Text $req.scope -Answers $Answers -D1 $d1 -Item $row.Item
            if ($scope.Problem) { [pscustomobject]@{ kind = $req.kind; scope = $req.scope; anyOf = @($req.anyOf); held = @(); state = 'unresolved'; via = $null; detail = "scope not known yet ($($scope.Problem))"; heldBy = $req.heldBy; purpose = $req.purpose; blocking = ($req.blocking -ne $false); source = $req.source }; continue }
            $resolved = [ordered]@{} ; foreach ($k in $req.Keys) { $resolved[$k] = $req[$k] }; $resolved.scope = [string]$scope.Value
            Test-PlanRequirement -Requirement $resolved -Access $Access
        }
        if ($stage.Contains('performedBy')) {
            # The stage runs as the private runner only: another operator hands it off, whatever roles they hold.
            $by = $stage.performedBy
            $list = Resolve-PlanTemplate -Text $by.principals -Answers $Answers -D1 $d1 -Item $row.Item
            $ids = if ($list.Problem) { @() } else { @($list.Value | Where-Object { $_ }) }
            $requirements = @($requirements) + [pscustomobject]@{ kind = 'runner'; scope = 'the private runner, inside the VNet'; anyOf = @($ids); held = @()
                state = $(if (@($ids) -contains $Identity.objectId) { 'met' } elseif ($list.Problem) { 'unresolved' } else { 'missing' }); via = $(if (@($ids) -contains $Identity.objectId) { $Identity.objectId } else { $null })
                detail = $(if ($list.Problem) { $list.Problem } else { $null }); heldBy = $by.heldBy; purpose = 'runs this stage'; blocking = $true; source = $by.source }
        }
        $row | Add-Member -NotePropertyName Requirements -NotePropertyValue @($requirements)
        $row | Add-Member -NotePropertyName Blockers -NotePropertyValue @(@($stage.blockers) | Where-Object { $_ } | Where-Object { $w = Test-PlanCondition -When ([string]$_.when) -Answers $Answers -Item $row.Item; $w.Applies -or $w.Problem })
        $context = @{ Send = $Send; Answers = $Answers; AnswersPath = $AnswersPath; D1 = $d1; Item = $row.Item; Record = $Record; CheckpointPath = $CheckpointPath; RepositoryRoot = $RepositoryRoot
            Step = $row.Step; OnboardingStage = $stage.onboardingStage; StageResults = @{ D2 = $d2; D3 = $d3; Discovery = $discovery } }
        $findings = @(foreach ($probe in @($stage.discovery)) { Invoke-PlanProbe -Probe $probe -Context $context })
        $drift = @($findings | Where-Object { $_.state -eq 'differs' -and $_.label -eq 'D3 plan' }).Count -gt 0
        $complete = $row.Records.Count -gt 0 -and -not $row.RecordState.Missing.Count -and -not $drift
        if ($complete -and $stage.completion -eq 'revision-current') {
            $current = @($findings | Where-Object label -eq 'API revisions')[0]
            $complete = $current -and $current.value -and [string]$current.value -eq [string]$row.Item.revision
        }
        $row.Complete = $complete
        $verdict = Get-PlanVerdict -Row $row
        $row.VerdictText = $verdict.text
        $template = if ($useSteps -and $stage.Contains('commandSteps')) { $stage.commandSteps } else { $stage.command }
        $command = Resolve-PlanTemplate -Text $template -Answers $Answers -D1 $d1 -Item $row.Item
        $results.Add([pscustomobject][ordered]@{
                order = $order; id = $row.Id; stage = $stage.id; mapRow = $stage.mapRow; title = $stage.title; form = $stage.form; performer = $stage.performer; key = $row.Key
                records = [ordered]@{ expected = @($row.Records); present = @($row.RecordState.Present | ForEach-Object { [ordered]@{ stageId = $_.stageId; completedBy = $_.completedBy; completedAt = $_.completedAt } }); missing = @($row.RecordState.Missing) }
                reads = [ordered]@{ expected = @($row.Reads); missing = @($row.ReadsMissing) }
                present = @($findings | ForEach-Object { [ordered]@{ label = $_.label; state = $_.state; detail = $_.detail } })
                roles = @($row.Requirements); blockers = @($row.Blockers | ForEach-Object { [ordered]@{ id = $_.id; text = $_.text; source = $_.source } })
                verdict = $verdict; next = (Get-PlanNext -Row $row -Command $(if ($command.Problem) { $null } else { [string]$command.Value }) -Verdict $verdict.code)
                sources = @($stage.sources)
            })
    }
    [pscustomobject][ordered]@{
        schemaVersion = 1; kind = 'ccof.deployment-plan'; generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        operator = [ordered]@{ objectId = $Identity.objectId; tenantId = $Identity.tenantId }; subscriptionId = [string]$Answers.target.subscriptionId
        answersPath = $AnswersPath; checkpointPath = $CheckpointPath; stageRolesDigest = $StageData.Digest
        stages = $results.ToArray()
        next = [ordered]@{
            forYou = @($results | Where-Object { $_.verdict.code -eq 'ready' } | ForEach-Object { [ordered]@{ id = $_.id; title = $_.title; command = $_.next.command } })
            handoffs = @($results | Where-Object { $_.verdict.code -eq 'needs-role' } | ForEach-Object { [ordered]@{ id = $_.id; handoff = $_.next.handoff } })
            blocked = @($results | Where-Object { $_.verdict.code -eq 'blocked' } | ForEach-Object { [ordered]@{ id = $_.id; reason = $_.verdict.text } })
        }
        readOnly = [ordered]@{}
    }
}

Export-ModuleMember -Function New-DeploymentPlan, Get-PlanVerdict
