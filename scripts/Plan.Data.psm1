#Requires -Version 7.0
<#
.SYNOPSIS
    The stage data of the deployment plan report (WP-PLAN, config/stage-roles.json): loads and checks
    it, expands it into rows (one per stage, D2 step, project and backend), resolves its templates and
    conditions, and reads which checkpoint records of a row exist. Pure: no Azure call, no write.

.DESCRIPTION
    Read-PlanStageData refuses data that would make the report wrong: a schema problem, a duplicate
    stage id, a citation to a line that does not exist, a role that its cited line does not name
    (Owner excepted, by the data's ownerAccepted citation), D2 steps that differ from the D2 code
    (Get-CoreD2Steps) or come before a step they need, and a placeholder outside answers, d1 and item.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.Schema.psm1')
Import-Module (Join-Path $PSScriptRoot 'Core.Permissions.psm1')
Import-Module (Join-Path $PSScriptRoot 'Core.D2Stage.psm1')

function New-PlanProblem { param([string]$Path, [string]$Code, [string]$Detail) [pscustomobject]@{ path = $Path; code = $Code; detail = $Detail } }

function Get-PlanCitedLine {
    param([string]$Citation, [string]$RepositoryRoot, [hashtable]$Cache)
    $at = $Citation.LastIndexOf(':')
    $relative = $Citation.Substring(0, $at); $number = [int]$Citation.Substring($at + 1)
    if (-not $Cache.Contains($relative)) {
        $full = Join-Path $RepositoryRoot $relative
        $Cache[$relative] = if (Test-Path -LiteralPath $full -PathType Leaf) { @(Get-Content -LiteralPath $full) } else { $null }
    }
    $lines = $Cache[$relative]
    if ($null -eq $lines -or $number -gt $lines.Count) { return $null }
    return [string]$lines[$number - 1]
}

function Get-PlanPlaceholderProblems {
    param($Value, [string]$Path)
    if ($Value -is [string]) {
        foreach ($m in [regex]::Matches($Value, '\$\{([^}]*)\}')) {
            if ($m.Groups[1].Value -notmatch '^(answers|d1|item)\.[A-Za-z0-9_.]+$') { New-PlanProblem $Path 'unsupported_placeholder' "$($m.Value): placeholders read answers, d1 or item" }
        }
    }
    elseif ($Value -is [System.Collections.IDictionary]) { foreach ($k in @($Value.Keys)) { Get-PlanPlaceholderProblems $Value[$k] "$Path.$k" } }
    elseif ($Value -is [System.Collections.IList]) { for ($i = 0; $i -lt $Value.Count; $i++) { Get-PlanPlaceholderProblems $Value[$i] "$Path[$i]" } }
}

function Get-PlanStageDataProblems {
    <# The rules JSON Schema cannot state; see the module description. #>
    param([System.Collections.IDictionary]$Data, [string]$RepositoryRoot)
    $problems = [System.Collections.Generic.List[object]]::new()
    $stages = @($Data.stages)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $cache = @{}
    for ($i = 0; $i -lt $stages.Count; $i++) {
        $stage = $stages[$i]; $at = "stages[$i]"
        if (-not $seen.Add([string]$stage.id)) { $problems.Add((New-PlanProblem "$at.id" 'duplicate_stage_id' "$($stage.id) is listed twice")) }
        $citations = @(@($stage.sources) | ForEach-Object { @{ path = "$at.sources"; text = $_ } })
        $citations += @(@($stage.blockers) | Where-Object { $_ } | ForEach-Object { @{ path = "$at.blockers"; text = $_.source } })
        if ($stage.Contains('performedBy') -and $stage.performedBy -is [System.Collections.IDictionary]) { $citations += @{ path = "$at.performedBy.source"; text = $stage.performedBy.source } }
        $requirements = @($stage.requirements)
        for ($j = 0; $j -lt $requirements.Count; $j++) { $citations += @{ path = "$at.requirements[$j].source"; text = $requirements[$j].source } }
        foreach ($c in $citations) {
            if ($c.text -match '^[A-Za-z0-9_./-]+:[1-9][0-9]*$' -and $null -eq (Get-PlanCitedLine $c.text $RepositoryRoot $cache)) {
                $problems.Add((New-PlanProblem $c.path 'citation_missing' "$($c.text) does not exist"))
            }
        }
        for ($j = 0; $j -lt $requirements.Count; $j++) {
            $line = Get-PlanCitedLine ([string]$requirements[$j].source) $RepositoryRoot $cache
            if ($null -eq $line) { continue }
            foreach ($role in @($requirements[$j].anyOf)) {
                if ([string]::Equals($role, 'Owner', 'Ordinal') -and $Data.Contains('ownerAccepted')) { continue }
                if (-not $line.Contains([string]$role, [StringComparison]::Ordinal)) {
                    $problems.Add((New-PlanProblem "$at.requirements[$j].anyOf" 'role_not_in_source' "$role is not named at $($requirements[$j].source)"))
                }
            }
        }
        foreach ($p in @(Get-PlanPlaceholderProblems $stage $at)) { $problems.Add($p) }
    }
    $dataSteps = @($stages | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.Contains('steps') } | ForEach-Object { @($_.steps) })
    $codeSteps = @(Get-CoreD2Steps)
    if ((@($dataSteps | Sort-Object) -join ',') -cne (@($codeSteps | ForEach-Object { $_.id } | Sort-Object) -join ',')) {
        $problems.Add((New-PlanProblem 'stages[].steps' 'd2_steps_mismatch' "the data lists $($dataSteps -join ', '); the D2 code (Get-CoreD2Steps) has $(@($codeSteps | ForEach-Object { $_.id }) -join ', ')"))
    }
    else {
        foreach ($step in $codeSteps) {
            foreach ($need in @($step.needs)) {
                if ([array]::IndexOf($dataSteps, $need) -gt [array]::IndexOf($dataSteps, $step.id)) {
                    $problems.Add((New-PlanProblem 'stages[].steps' 'd2_step_order' "$($step.id) needs $need, which the data lists later"))
                }
            }
        }
    }
    return $problems.ToArray()
}

function Read-PlanStageData {
    <#
    .SYNOPSIS
        Loads config/stage-roles.json. Returns Stages, Problems (path, code, detail) and Digest (SHA-256
        of the canonical data, so a later driver can bind to the data it planned with).
    #>
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$RepositoryRoot,
        [string]$SchemaPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config/stage-roles.schema.json')
    )
    $empty = [pscustomobject]@{ Stages = @(); Problems = @(); Digest = $null }
    try { $data = ConvertFrom-CoreJson (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) }
    catch { $empty.Problems = @(New-PlanProblem 'stage data' 'stage_data_not_json' "$Path is not readable JSON"); return $empty }
    $schema = ConvertFrom-CoreJson (Get-Content -LiteralPath $SchemaPath -Raw)
    $problems = @(Test-CoreSchema -Value $data -Schema $schema)
    # The rules run on data the schema refused too, so one read lists every problem.
    if ($data -is [System.Collections.IDictionary] -and @($data.stages | Where-Object { $_ -isnot [System.Collections.IDictionary] }).Count -eq 0) {
        try { $problems += @(Get-PlanStageDataProblems -Data $data -RepositoryRoot $RepositoryRoot) }
        catch { $problems += New-PlanProblem 'stages' 'stage_data_invalid' 'the stage data could not be checked' }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-CoreCanonicalJson $data))
    [pscustomobject]@{
        Stages = @($data.stages); Problems = $problems
        Digest = ([System.Security.Cryptography.SHA256]::HashData($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    }
}

function Resolve-PlanTemplate {
    <# ${answers.<path>}, ${d1.<key>} and ${item.<field>} through D3's resolver (Resolve-CorePlaceholder). #>
    param([string]$Text, [System.Collections.IDictionary]$Answers, [System.Collections.IDictionary]$D1, [System.Collections.IDictionary]$Item)
    if ($null -eq $D1) { $D1 = @{} }
    if ($null -eq $Item) { $Item = @{} }
    $r = Resolve-CorePlaceholder -Text $Text -D1 $D1 -Answers $Answers -Item $Item
    [pscustomobject]@{ Value = $r.Value; Problem = $r.Problem }
}

function Test-PlanCondition {
    <#
    .SYNOPSIS
        "<answers|item>.<path> == <value>", compared ordinally. A value that is not set, or still
        PENDING, is a problem: comparing an undecided value would drop a requirement without a word.
    #>
    param([string]$When, [System.Collections.IDictionary]$Answers, [System.Collections.IDictionary]$Item)
    if ([string]::IsNullOrWhiteSpace($When)) { return [pscustomobject]@{ Applies = $true; Problem = $null } }
    $m = [regex]::Match($When, '^(answers|item)\.([A-Za-z0-9_.]+) == ([A-Za-z0-9_.-]+)$')
    if (-not $m.Success) { return [pscustomobject]@{ Applies = $false; Problem = "condition '$When' must read '<answers|item>.<path> == <value>'" } }
    $name = "$($m.Groups[1].Value).$($m.Groups[2].Value)"
    $hit = Resolve-PlanTemplate -Text "`${$name}" -Answers $Answers -D1 @{} -Item $Item
    if ($hit.Problem) { return [pscustomobject]@{ Applies = $false; Problem = "condition reads $name, which is not set" } }
    if ($hit.Value -is [string] -and $hit.Value.StartsWith('PENDING:', [StringComparison]::Ordinal)) { return [pscustomobject]@{ Applies = $false; Problem = "condition reads $name, which is still PENDING" } }
    [pscustomobject]@{ Applies = [string]::Equals([string]$hit.Value, $m.Groups[3].Value, 'Ordinal'); Problem = $null }
}

function Expand-PlanStageRows {
    <#
    .SYNOPSIS
        One row per stage, per D2 step (steps), and per project or backend (forEach). Each row has Id,
        Stage, Step, Key, Item (the entry's fields, itemDerive values, step, answersPath,
        checkpointPath and, for an onboarding stage, onboardingAnswersPath), Records, Reads, Problems.
        -Run: answersPath, checkpointPath, onboarding = @{ '<stage>' = @{ '<item key>' = '<path>' } }.
    #>
    param([Parameter(Mandatory)] [object[]]$Stages, [Parameter(Mandatory)] [System.Collections.IDictionary]$Answers, [System.Collections.IDictionary]$D1, [hashtable]$Run = @{})
    foreach ($stage in $Stages) {
        $entries = @($null); $listProblem = $null
        if ($stage.Contains('forEach')) {
            $list = Resolve-PlanTemplate -Text "`${$($stage.forEach)}" -Answers $Answers -D1 $D1 -Item @{}
            $entries = @(@($list.Value) | Where-Object { $_ -is [System.Collections.IDictionary] })
            if ($list.Problem -or -not $entries.Count) { $entries = @($null); $listProblem = "no entries in $($stage.forEach)" }
        }
        $steps = [System.Collections.Generic.List[object]]::new()
        if ($stage.Contains('steps')) { foreach ($s in $stage.steps) { $steps.Add($s) } } else { $steps.Add($null) }
        foreach ($entry in $entries) {
            foreach ($step in $steps) {
                $item = [ordered]@{}
                if ($entry) { foreach ($k in $entry.Keys) { $item[$k] = $entry[$k] } }
                foreach ($derive in @($stage.itemDerive | Where-Object { $_ })) {
                    $parts = ([string]$item[$derive.from]).Split('/')
                    if ($parts.Count -gt $derive.segment -and $parts[$derive.segment]) { $item[$derive.name] = $parts[$derive.segment] }
                }
                if ($step) { $item.step = $step }
                $item.answersPath = $Run.answersPath; $item.checkpointPath = $Run.checkpointPath
                $key = if ($stage.Contains('itemKey') -and $entry) { [string]$item[$stage.itemKey] } else { $null }
                if ($stage.Contains('onboardingStage')) {
                    $given = if ($Run.onboarding) { $Run.onboarding[[string]$stage.onboardingStage] } else { $null }
                    $item.onboardingAnswersPath = if ($given -and $key -and $given.Contains($key)) { $given[$key] } else { "<stage $($stage.onboardingStage) answers for $key>" }
                }
                $problems = [System.Collections.Generic.List[string]]::new()
                if ($listProblem) { $problems.Add($listProblem) }
                $resolve = { param($list) foreach ($t in @($list)) { $r = Resolve-PlanTemplate -Text $t -Answers $Answers -D1 $D1 -Item $item; if ($r.Problem) { $problems.Add("$t`: $($r.Problem)") } else { $r.Value } } }
                [pscustomobject]@{
                    Id = (@($stage.id, $step, $key) | Where-Object { $_ }) -join ':'
                    Stage = $stage; Step = $step; Key = $key; Item = $item
                    Records = @(& $resolve $stage.records); Reads = @(& $resolve $stage.reads); Problems = $problems
                }
            }
        }
    }
}

function Get-PlanRecordState {
    <# Which of StageIds the checkpoint record holds (stageId, completedBy, completedAt, evidence), and which it lacks. #>
    param([Parameter(Mandatory)] $Record, [string[]]$StageIds = @())
    $present = [System.Collections.Generic.List[object]]::new(); $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $StageIds) {
        $s = @($Record.stages | Where-Object { [string]::Equals([string]$_.stageId, $id, 'Ordinal') })[0]
        if ($s) { $present.Add([pscustomobject]@{ stageId = $id; completedBy = [string]$s.completedBy; completedAt = [string]$s.completedAt; evidence = $s.evidence }) }
        else { $missing.Add($id) }
    }
    [pscustomobject]@{ Present = $present.ToArray(); Missing = $missing.ToArray() }
}

Export-ModuleMember -Function Read-PlanStageData, Resolve-PlanTemplate, Test-PlanCondition, Expand-PlanStageRows, Get-PlanRecordState
