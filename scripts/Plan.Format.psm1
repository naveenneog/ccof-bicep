#Requires -Version 7.0
<#
.SYNOPSIS
    Output of the deployment plan report (WP-PLAN): a summary table with the next actions and each row's
    details, the same as a Markdown table, or the plan object as JSON for a later driver. -Redact
    shortens every object id (any GUID) to its first 8 characters, before any cell is shortened. The plan
    holds ids, role names, reason codes and commands: no token or secret enters it.
#>

$script:Guid = '\b([0-9a-fA-F]{8})-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'

function Hide-PlanIds { param([string]$Text) [regex]::Replace($Text, $script:Guid, '$1...') }

function Get-PlanCell {
    param([string]$Text, [int]$Width, [switch]$Redact)
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($Redact) { $t = Hide-PlanIds $t }
    if ($Width -gt 0 -and $t.Length -gt $Width) { $t = $t.Substring(0, $Width - 3) + '...' }
    $t
}

function Get-PlanRoleText {
    # One requirement: its roles, scope and state; met names the role or setting that met it.
    param($Requirement)
    $roles = "$(@($Requirement.anyOf) -join ' or ') at $($Requirement.scope)"
    switch ($Requirement.state) {
        'met' { "$roles`: met by $($Requirement.via)" }
        'missing' { "$roles`: missing$(if (@($Requirement.held).Count) { " (holds $(@($Requirement.held) -join ', '))" })$(if (-not $Requirement.blocking) { ', a handoff' })" }
        default { "$roles`: $($Requirement.state) ($($Requirement.detail))" }
    }
}

function Get-PlanSummary {
    <# The short cells of one row: records, findings by state, roles. #>
    param($Row)
    $counts = @(@($Row.present | ForEach-Object { [string]$_.state }) | Group-Object | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
    $blocking = @($Row.roles | Where-Object { $_.blocking })
    $missing = @($blocking | Where-Object { $_.state -eq 'missing' })
    $roles = if (-not @($Row.roles).Count) { '-' }
    elseif ($missing.Count) { "missing $(@($missing[0].anyOf)[0])" }
    elseif (@($blocking | Where-Object { $_.state -ne 'met' }).Count) { 'not read' }
    else { "ok ($(@($blocking | ForEach-Object { $_.via } | Where-Object { $_ } | Select-Object -Unique) -join ', '))" }
    [pscustomobject]@{ Records = "$(@($Row.records.present).Count)/$(@($Row.records.expected).Count)"; Present = $(if ($counts) { $counts } else { '-' }); Roles = $roles }
}

function Get-PlanNextText {
    param($Row)
    if ($Row.next.command) { return $Row.next.command }
    if ($Row.next.handoff) { return "handoff: $($Row.next.handoff)" }
    if ($Row.verdict.code -eq 'blocked') { return 'resolve the blocker first' }
    ''
}

function Get-PlanDetails {
    # Every fact of one row, one line each.
    param($Row)
    "$($Row.order) $($Row.id) ($($Row.title)): $($Row.verdict.text)"
    $present = @($Row.records.present | ForEach-Object { "$($_.stageId) by $($_.completedBy) at $($_.completedAt)" })
    "    Recorded: $(if ($present.Count) { $present -join '; ' } else { 'none' })$(if (@($Row.records.missing).Count) { "; missing $(@($Row.records.missing) -join ', ')" })"
    foreach ($f in @($Row.present)) { "    Present: $($f.label): $($f.state), $($f.detail)" }
    foreach ($r in @($Row.roles)) { "    Roles: $(Get-PlanRoleText $r)" }
    $next = Get-PlanNextText $Row
    if ($next) { "    Next: $next" }
    foreach ($h in @($Row.next.handoffs)) { "    Handoff: $h" }
}

function Format-DeploymentPlan {
    param([Parameter(Mandatory)] $Plan, [ValidateSet('Table', 'Markdown', 'Json')] [string]$Format = 'Table', [switch]$Redact)
    $text = switch ($Format) {
        'Json' { $Plan | ConvertTo-Json -Depth 30 }
        'Markdown' {
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add('| # | Stage | Recorded | Already present | Roles | Verdict | Next action |')
            $lines.Add('|---|---|---|---|---|---|---|')
            foreach ($r in $Plan.stages) {
                $recorded = "$((Get-PlanSummary $r).Records)$(if (@($r.records.missing).Count) { " (missing $(@($r.records.missing) -join ', '))" })"
                $present = @($r.present | ForEach-Object { "$($_.label): $($_.state), $($_.detail)" }) -join '; '
                $roles = @($r.roles | ForEach-Object { Get-PlanRoleText $_ }) -join '; '
                $cells = @($r.order, "$($r.id) ($($r.title))", $recorded, $(if ($present) { $present } else { '-' }), $(if ($roles) { $roles } else { '-' }), $r.verdict.text, (Get-PlanNextText $r)) |
                    ForEach-Object { (Get-PlanCell ([string]$_) 0 -Redact:$Redact).Replace('|', '\|') }
                $lines.Add("| $($cells -join ' | ') |")
            }
            $lines -join [Environment]::NewLine
        }
        default {
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add("Deployment plan (read-only). Operator $($Plan.operator.objectId), tenant $($Plan.operator.tenantId), subscription $($Plan.subscriptionId).")
            $lines.Add("Checkpoint $($Plan.checkpointPath). Answers $($Plan.answersPath).")
            $lines.Add('')
            $row = '{0,-3} {1,-28} {2,-7} {3,-22} {4,-36} {5}'
            $lines.Add(($row -f '#', 'Stage', 'Records', 'Already present', 'Roles', 'Verdict'))
            foreach ($r in $Plan.stages) {
                $s = Get-PlanSummary $r
                $lines.Add(($row -f $r.order, (Get-PlanCell $r.id 28 -Redact:$Redact), $s.Records, (Get-PlanCell $s.Present 22), (Get-PlanCell $s.Roles 36 -Redact:$Redact), $r.verdict.code))
            }
            $lines.Add('')
            $lines.Add('Next for you:')
            foreach ($n in @($Plan.next.forYou)) { $lines.Add("  $($n.id): $($n.command)") }
            if (-not @($Plan.next.forYou).Count) { $lines.Add('  nothing: no stage is ready for your roles.') }
            $lines.Add('Handoffs (a role you do not hold):')
            foreach ($n in @($Plan.next.handoffs)) { $lines.Add("  $($n.id): $($n.handoff)") }
            foreach ($r in @($Plan.stages | Where-Object { @($_.next.handoffs).Count })) { foreach ($h in @($r.next.handoffs)) { $lines.Add("  $($r.id): $h") } }
            $lines.Add('Blocked:')
            foreach ($n in @($Plan.next.blocked)) { $lines.Add("  $($n.id): $($n.reason -replace '^blocked: ', '')") }
            $lines.Add('')
            $lines.Add('Details:')
            foreach ($r in $Plan.stages) { foreach ($d in @(Get-PlanDetails $r)) { $lines.Add($d) } }
            $ro = $Plan.readOnly
            if ($ro.Count) { $lines.Add(''); $lines.Add("Read-only check: checkpoint $($ro.checkpoint), audit file $($ro.audit), answers $($ro.answers); $($ro.providerReads) provider read(s), all GET; $($ro.writesRefused) write(s) refused; temporary copy removed: $($ro.copyRemoved).") }
            $lines -join [Environment]::NewLine
        }
    }
    if ($Redact) { return Hide-PlanIds $text }
    $text
}

Export-ModuleMember -Function Format-DeploymentPlan, Hide-PlanIds
