#Requires -Version 7.0
<#
.SYNOPSIS
    The read-only probes of the deployment plan report (WP-PLAN): what already exists for a stage, as
    config/stage-roles.json lists it per stage ("discovery"). Every Azure and Graph read goes through the
    context's Send (the read-only guard); results are label, state (present, absent, differs,
    unreadable, unknown or info) and detail.

.DESCRIPTION
    Reused readers: Get-CoreD1Record (D1's own check of every prerequisite against the decisions),
    Get-CoreCurrentRevision (D2's policy step), and the results of the stages' own Plan and
    -DiscoverOnly runs (Plan.Runners.psm1), passed in the context. Sources, retrieved 2026-10-12:
    "Api Revision - List By Service" and "Backend - Get" (API Management REST, 2024-05-01,
    https://learn.microsoft.com/rest/api/apimanagement/api-revision/list-by-service,
    https://learn.microsoft.com/rest/api/apimanagement/backend/get); Microsoft Graph v1.0 "Get group"
    (https://learn.microsoft.com/graph/api/group-get) and "List appRoleAssignments granted to a service
    principal" (https://learn.microsoft.com/graph/api/serviceprincipal-list-approleassignments).
#>

Import-Module (Join-Path $PSScriptRoot 'Plan.Data.psm1')
Import-Module (Join-Path $PSScriptRoot 'Core.Answers.psm1')
Import-Module (Join-Path $PSScriptRoot 'Core.Prereqs.psm1')
Import-Module (Join-Path $PSScriptRoot 'Core.D2Apim.psm1')

function New-PlanFinding { param([string]$Label, [string]$State, [string]$Detail, $Value = $null) [pscustomobject]@{ label = $Label; state = $State; detail = $Detail; value = $Value } }

function Get-PlanShort { param([string]$Text) if ($Text -and $Text.Length -gt 12) { $Text.Substring(0, 12) } else { $Text } }

function Get-PlanRecordedEvidence {
    # The evidence of a record as ordered dictionaries (the checkpoint reader returns objects).
    param($Record, [string]$StageId)
    $stage = @($Record.stages | Where-Object { [string]::Equals([string]$_.stageId, $StageId, 'Ordinal') })[0]
    if (-not $stage -or $null -eq $stage.evidence) { return $null }
    ConvertFrom-CoreJson ($stage.evidence | ConvertTo-Json -Depth 40)
}

function Get-PlanArmFinding {
    param([string]$Label, [string]$Url, [scriptblock]$Send, [switch]$Count)
    $r = & $Send 'GET' $Url $null
    if ($r.Status -eq 200) {
        $detail = if ($Count) { "$(@($r.Content['value']).Count) item(s)" } else { 'exists' }
        return New-PlanFinding $Label 'present' $detail
    }
    if ($r.Status -eq 404) { return New-PlanFinding $Label 'absent' 'not found' }
    New-PlanFinding $Label 'unreadable' "HTTP $($r.Status)"
}

function Get-PlanDiscoveryFindings {
    # A stage's own -DiscoverOnly result, summarised: what it found and what it would create.
    param($Result, [string]$Stage)
    if (-not $Result.Satisfied) { return New-PlanFinding "Stage $Stage discovery" 'info' "refused: $($Result.ReasonCode)" }
    $d = $Result.Discovery
    switch ($Stage) {
        '1' { foreach ($g in @($d.groups)) { New-PlanFinding "group $($g.classification)" $(if ($g.groupId) { 'present' } else { 'absent' }) $(if ($g.groupId) { "$($g.groupName) exists ($($g.groupId))" } else { "$($g.groupName) would be created" }) } }
        '2' { New-PlanFinding 'backend' $(if ($d.backendExists -or $d.backendUrl) { 'present' } else { 'absent' }) "$($d.backendUrl)" }
        '3' {
            foreach ($k in @($d.dependencies.groups.Keys)) { New-PlanFinding "group $k" 'present' "$($d.dependencies.groups[$k].displayName): $($d.dependencies.groups[$k].memberCount) member(s)" }
            New-PlanFinding 'backend' 'present' "$($d.dependencies.backend.id) $($d.dependencies.backend.url)"
        }
    }
}

function Invoke-PlanProbe {
    <#
    .SYNOPSIS
        Runs one probe of a row. Context: Send, Answers, AnswersPath, D1, Item, Record, CheckpointPath,
        RepositoryRoot, Step (the row's D2 step), StageResults (D2, D3, Discovery of this row).
    #>
    param([Parameter(Mandatory)] [System.Collections.IDictionary]$Probe, [Parameter(Mandatory)] [hashtable]$Context)
    if ($Probe.Contains('step') -and $Probe.step -ne $Context.Step) { return }
    if ($Probe.Contains('when')) {
        $when = Test-PlanCondition -When $Probe.when -Answers $Context.Answers -Item $Context.Item
        if ($when.Problem) { return New-PlanFinding $Probe.kind 'unknown' $when.Problem }
        if (-not $when.Applies) { return }
    }
    $resolved = @{}
    foreach ($field in @('label', 'url', 'api', 'principal', 'appRoleId', 'record')) {
        if (-not $Probe.Contains($field)) { continue }
        $r = Resolve-PlanTemplate -Text $Probe[$field] -Answers $Context.Answers -D1 $Context.D1 -Item $Context.Item
        if ($r.Problem) { return New-PlanFinding $(if ($field -eq 'label') { $Probe.kind } else { [string]$Probe.label }) 'unknown' "not read: $($r.Problem)" }
        $resolved[$field] = $r.Value
    }
    $send = $Context.Send
    switch ($Probe.kind) {
        'checkpoint-file' { New-PlanFinding $resolved.label $(if (Test-Path -LiteralPath "$($Context.CheckpointPath)$($Probe.suffix)" -PathType Leaf) { 'present' } else { 'absent' }) "$($Probe.suffix) next to the checkpoint" }
        'answers-section' {
            $found = @($Probe.anyOf | Where-Object { $Context.Answers.Contains($_) })[0]
            New-PlanFinding $resolved.label $(if ($found) { 'present' } else { 'absent' }) $(if ($found) { "answers.$found" } else { "none of $($Probe.anyOf -join ', ')" })
        }
        'd1-record' {
            $read = Read-CoreAnswers -Path $Context.AnswersPath -Stage D1 -RepositoryRoot $Context.RepositoryRoot
            if ($read.Problems.Count) { return New-PlanFinding 'D1 prerequisites' 'unknown' "not read: the answers have $($read.Problems.Count) problem(s) for D1" }
            $get = { param($Url) $x = & $send 'GET' $Url $null; if ($x.Status -eq 200) { $x.Content } else { $null } }.GetNewClosure()
            $check = Get-CoreD1Record -Answers $read.Answers -Get $get
            if (-not $check.Problems.Count) { return New-PlanFinding 'D1 prerequisites' 'present' 'every prerequisite reads back and matches the decisions' }
            $listed = @($check.Problems | Select-Object -First 6 | ForEach-Object { "$($_.path) [$($_.code)]" }) -join ', '
            New-PlanFinding 'D1 prerequisites' 'differs' "$($check.Problems.Count) differ or cannot be read: $listed"
        }
        'd2-plan' {
            $d2 = $Context.StageResults.D2
            if (-not $d2 -or -not $d2.Rows -or -not $d2.Rows.Contains([string]$Context.Step)) { return }
            $row = $d2.Rows[[string]$Context.Step]
            foreach ($line in @($row.Lines | Where-Object { $_ })) { New-PlanFinding "D2 $($Context.Step) plan" 'info' $line }
        }
        'd3-plan' {
            $d3 = $Context.StageResults.D3
            if (-not $d3) { return }
            if ($d3.ReasonCode -ne 'planned') { return New-PlanFinding 'D3 plan' 'info' "refused: $($d3.ReasonCode)" }
            $recorded = Get-PlanRecordedEvidence $Context.Record 'stage-D3'
            $detail = "$(@($d3.Summary).Count) line(s), digest $(Get-PlanShort $d3.Digest)"
            if ($recorded -and $recorded['digest'] -and $recorded['digest'] -ne $d3.Digest) { return New-PlanFinding 'D3 plan' 'differs' "$detail; stage-D3 recorded digest $(Get-PlanShort ([string]$recorded['digest']))" }
            New-PlanFinding 'D3 plan' 'present' $detail
        }
        'arm-get' { Get-PlanArmFinding -Label $resolved.label -Url "https://management.azure.com$($resolved.url)" -Send $send -Count:([bool]$Probe['count']) }
        'api-revisions' {
            $list = & $send 'GET' "https://management.azure.com$($resolved.api)/revisions?api-version=2024-05-01" $null
            if ($list.Status -eq 404) { return New-PlanFinding 'API revisions' 'absent' 'the API does not exist' }
            if ($list.Status -ne 200) { return New-PlanFinding 'API revisions' 'unreadable' "HTTP $($list.Status)" }
            $current = Get-CoreCurrentRevision @{ Send = $send; D1 = $Context.D1; Answers = $Context.Answers }
            $all = @($list.Content['value'] | ForEach-Object { [string]$_['apiRevision'] } | Sort-Object { [int]$_ })
            New-PlanFinding 'API revisions' 'present' "revisions $($all -join ', '); current $current" $current
        }
        'graph-app-role' {
            $r = & $send 'GET' "https://graph.microsoft.com/v1.0/servicePrincipals/$($resolved.principal)/appRoleAssignments" $null
            if ($r.Status -ne 200) { return New-PlanFinding $resolved.label 'unreadable' "HTTP $($r.Status)" }
            $held = @($r.Content['value'] | Where-Object { [string]::Equals([string]$_['appRoleId'], [string]$resolved.appRoleId, 'OrdinalIgnoreCase') }).Count -gt 0
            New-PlanFinding $resolved.label $(if ($held) { 'present' } else { 'absent' }) "app role $($resolved.appRoleId)"
        }
        'recorded-groups' {
            $evidence = Get-PlanRecordedEvidence $Context.Record $resolved.record
            if ($evidence -isnot [System.Collections.IDictionary]) { return }
            foreach ($g in @($evidence['groups'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['groupId'] })) {
                $r = & $send 'GET' "https://graph.microsoft.com/v1.0/groups/$($g['groupId'])?`$select=id,displayName" $null
                $state = switch ($r.Status) { 200 { 'present' } 404 { 'absent' } default { 'unreadable' } }
                New-PlanFinding "group $($g['classification'])" $state "$($g['groupName']) ($($g['groupId']))"
            }
        }
        'record' {
            $evidence = Get-PlanRecordedEvidence $Context.Record $resolved.record
            if ($null -eq $evidence -and -not @($Context.Record.stages | Where-Object { [string]$_.stageId -eq $resolved.record }).Count) { return New-PlanFinding $resolved.record 'absent' 'not recorded' }
            $parts = foreach ($field in @($Probe.fields)) {
                $v = if ($evidence -is [System.Collections.IDictionary]) { [string]$evidence[$field] } else { '' }
                if ($field -eq 'validUntil' -and $v) { $until = [DateTimeOffset]::MinValue; if ([DateTimeOffset]::TryParse($v, [ref]$until) -and $until -le [DateTimeOffset]::UtcNow) { "$field $v (passed)" } else { "$field $v" } }
                elseif ($v) { "$field $(Get-PlanShort $v)" }
            }
            New-PlanFinding $resolved.record 'present' $(if ($parts) { @($parts) -join '; ' } else { 'recorded' })
        }
        'note' { New-PlanFinding 'note' 'info' ([string]$Probe.text) }
        'onboarding-discover' {
            $result = $Context.StageResults.Discovery
            if ($result) { Get-PlanDiscoveryFindings -Result $result -Stage ([string]$Context.OnboardingStage) }
        }
    }
}

Export-ModuleMember -Function Invoke-PlanProbe, Get-PlanRecordedEvidence, New-PlanFinding
