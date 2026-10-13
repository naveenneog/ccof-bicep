#Requires -Version 7.0
<#
.SYNOPSIS
    D3 assignment data (docs/DEPLOYMENT-STAGES.md, "D3 assignment data"): loads every package's
    ccof.assignments file named in infra/permissions/sources.json, resolves ${d1.<key>} and
    ${answers.<path>}, expands principal lists, evaluates `when`, and returns one concrete plan with a
    digest. Pure: no Azure call. A missing file, an unresolved placeholder, a duplicate id, an
    unknown role, or a `when` or `forEach` that reads a section with a PENDING decision refuses the
    whole plan.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.Schema.psm1')
Import-Module (Join-Path $PSScriptRoot 'Core.Answers.psm1')

$script:GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:CosmosBuiltIn = @{
    '00000000-0000-0000-0000-000000000001' = 'Cosmos DB Built-in Data Reader'
    '00000000-0000-0000-0000-000000000002' = 'Cosmos DB Built-in Data Contributor'
}

function New-CorePlanProblem { param([string]$Path, [string]$Code, [string]$Detail) [pscustomobject]@{ path = $Path; code = $Code; detail = $Detail } }

function Get-CoreValueAtPath {
    param($Root, [string]$Path)
    $node = $Root
    foreach ($part in $Path.Split('.')) {
        if ($node -is [System.Collections.IDictionary] -and $node.Contains($part)) { $node = $node[$part] }
        else { return [pscustomobject]@{ Found = $false; Value = $null } }
    }
    return [pscustomobject]@{ Found = $true; Value = $node }
}

function Resolve-CorePlaceholder {
    <#
    .SYNOPSIS
        Resolves ${d1.<key>}, ${answers.<path>} and, inside forEach, ${item.<field>} in Text. A text that
        is exactly one placeholder returns the value itself (a list stays a list). Returns Value and
        Problem (null when resolved).
    #>
    param([string]$Text, [System.Collections.IDictionary]$D1, [System.Collections.IDictionary]$Answers, [System.Collections.IDictionary]$Item)
    $roots = @{ d1 = $D1; answers = $Answers; item = $Item }
    $whole = [regex]::Match($Text, '^\$\{(d1|answers|item)\.([A-Za-z0-9_.]+)\}$')
    if ($whole.Success) {
        $hit = Get-CoreValueAtPath $roots[$whole.Groups[1].Value] $whole.Groups[2].Value
        if (-not $hit.Found -or $null -eq $hit.Value -or ($hit.Value -is [string] -and $hit.Value -eq '')) { return [pscustomobject]@{ Value = $null; Problem = "unresolved $($whole.Value)" } }
        return [pscustomobject]@{ Value = $hit.Value; Problem = $null }
    }
    $problem = $null
    $builder = [System.Text.StringBuilder]::new()
    $last = 0
    foreach ($m in [regex]::Matches($Text, '\$\{(d1|answers|item)\.([A-Za-z0-9_.]+)\}')) {
        [void]$builder.Append($Text.Substring($last, $m.Index - $last))
        $hit = Get-CoreValueAtPath $roots[$m.Groups[1].Value] $m.Groups[2].Value
        if (-not $hit.Found -or $hit.Value -isnot [string] -or $hit.Value -eq '') { $problem = "unresolved $($m.Value)" }
        else { [void]$builder.Append($hit.Value) }
        $last = $m.Index + $m.Length
    }
    [void]$builder.Append($Text.Substring($last))
    $value = $builder.ToString()
    if (-not $problem -and $value -match '\$\{') { $problem = 'unsupported placeholder' }
    return [pscustomobject]@{ Value = $value; Problem = $problem }
}

function Resolve-CorePrincipals {
    <#
    .SYNOPSIS
        `principal` resolves to one object id; `principals` must be exactly one placeholder naming a
        list, which may be empty (then the assignment makes none).
    #>
    param([System.Collections.IDictionary]$Assignment, [System.Collections.IDictionary]$D1, [System.Collections.IDictionary]$Answers, [System.Collections.IDictionary]$Item)
    if ($Assignment.Contains('principals')) {
        $m = [regex]::Match([string]$Assignment.principals, '^\$\{(d1|answers)\.([A-Za-z0-9_.]+)\}$')
        if (-not $m.Success) { return [pscustomobject]@{ List = @(); Problem = 'principals must be one placeholder naming a list' } }
        $root = if ($m.Groups[1].Value -eq 'd1') { $D1 } else { $Answers }
        $hit = Get-CoreValueAtPath $root $m.Groups[2].Value
        if (-not $hit.Found -or $hit.Value -isnot [array]) { return [pscustomobject]@{ List = @(); Problem = "unresolved list $($m.Value)" } }
        return [pscustomobject]@{ List = @($hit.Value); Problem = $null }
    }
    $r = Resolve-CorePlaceholder ([string]$Assignment.principal) $D1 $Answers $Item
    if ($r.Problem) { return [pscustomobject]@{ List = @(); Problem = $r.Problem } }
    return [pscustomobject]@{ List = @($r.Value); Problem = $null }
}

function Test-CoreWhen {
    param([string]$When, [System.Collections.IDictionary]$Answers)
    if ([string]::IsNullOrWhiteSpace($When)) { return [pscustomobject]@{ Applies = $true; Problem = $null } }
    $m = [regex]::Match($When, '^answers\.([A-Za-z0-9_.]+) == ([A-Za-z0-9_.-]+)$')
    if (-not $m.Success) { return [pscustomobject]@{ Applies = $false; Problem = 'when must read "answers.<path> == <value>"' } }
    $hit = Get-CoreValueAtPath $Answers $m.Groups[1].Value
    if (-not $hit.Found) { return [pscustomobject]@{ Applies = $false; Problem = "when names an answer that does not exist: $($m.Groups[1].Value)" } }
    return [pscustomobject]@{ Applies = [string]::Equals([string]$hit.Value, $m.Groups[2].Value, 'Ordinal'); Problem = $null }
}

function Get-CorePendingSection {
    <#
    .SYNOPSIS
        The answers section that the assignment's `when` or `forEach` reads, if it still holds a
        PENDING decision. A comparison with an undecided value would skip the grant without a word.
    #>
    param([System.Collections.IDictionary]$Assignment, [System.Collections.IDictionary]$Answers)
    foreach ($field in @('when', 'forEach')) {
        $m = [regex]::Match([string]$Assignment[$field], '^answers\.([A-Za-z0-9_]+)')
        if ($m.Success -and $Answers.Contains($m.Groups[1].Value) -and @(Find-CorePendingValues -Value $Answers[$m.Groups[1].Value] -Path $m.Groups[1].Value).Count) { return $m.Groups[1].Value }
    }
    return $null
}

function New-CoreDeterministicGuid {
    <#
    .SYNOPSIS
        A name-based GUID (SHA-256 of the parts, version 5 layout), so a repeat run addresses the same
        assignment instead of adding a duplicate.
    #>
    param([Parameter(Mandatory)] [string[]]$Parts)
    $bytes = [System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($Parts | ForEach-Object { $_.ToLowerInvariant() }) -join '|'))[0..15]
    $bytes[6] = ($bytes[6] -band 0x0f) -bor 0x50
    $bytes[8] = ($bytes[8] -band 0x3f) -bor 0x80
    $hex = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
    return "$($hex.Substring(0,8))-$($hex.Substring(8,4))-$($hex.Substring(12,4))-$($hex.Substring(16,4))-$($hex.Substring(20,12))"
}

function Read-CoreAssignmentSources {
    <#
    .SYNOPSIS
        Loads the files listed in a sources file (paths relative to the repository root).
    #>
    param([Parameter(Mandatory)] [string]$SourcesPath, [Parameter(Mandatory)] [string]$RepositoryRoot)
    $problems = [System.Collections.Generic.List[object]]::new()
    $documents = [System.Collections.Generic.List[object]]::new()
    $sources = ConvertFrom-CoreJson (Get-Content -LiteralPath $SourcesPath -Raw)
    foreach ($relative in @($sources.files)) {
        $path = Join-Path $RepositoryRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $problems.Add((New-CorePlanProblem $relative 'assignment_file_missing' 'the package has not delivered this file')); continue }
        try { $doc = ConvertFrom-CoreJson (Get-Content -LiteralPath $path -Raw) }
        catch { $problems.Add((New-CorePlanProblem $relative 'assignment_file_not_json' 'not valid JSON')); continue }
        if ($doc.schemaVersion -ne 1 -or $doc.kind -ne 'ccof.assignments' -or -not $doc.package) { $problems.Add((New-CorePlanProblem $relative 'assignment_file_invalid' 'needs schemaVersion 1, kind ccof.assignments and package')); continue }
        $documents.Add([pscustomobject]@{ File = $relative; Doc = $doc })
    }
    [pscustomobject]@{ Documents = $documents.ToArray(); Problems = $problems.ToArray() }
}

function Get-CoreAssignmentIterations {
    <#
    .SYNOPSIS
        One iteration without forEach. With "forEach": "answers.<list>" (or "d1.<list>") and an
        optional "where": "<field> == <value>", one iteration per matching entry, exposed as
        ${item.<field>} and suffixing the id with the entry's id (or its index).
    #>
    param([System.Collections.IDictionary]$Assignment, [System.Collections.IDictionary]$D1, [System.Collections.IDictionary]$Answers)
    if (-not $Assignment.Contains('forEach')) { return [pscustomobject]@{ Items = @([pscustomobject]@{ Item = $null; Suffix = $null }); Problem = $null } }
    $m = [regex]::Match([string]$Assignment.forEach, '^(d1|answers)\.([A-Za-z0-9_.]+)$')
    if (-not $m.Success) { return [pscustomobject]@{ Items = @(); Problem = 'forEach must name a list as answers.<path> or d1.<path>' } }
    $root = if ($m.Groups[1].Value -eq 'd1') { $D1 } else { $Answers }
    $hit = Get-CoreValueAtPath $root $m.Groups[2].Value
    if (-not $hit.Found -or $hit.Value -isnot [array]) { return [pscustomobject]@{ Items = @(); Problem = "forEach list not found: $($Assignment.forEach)" } }
    $field = $null; $expected = $null
    if ($Assignment.Contains('where')) {
        $w = [regex]::Match([string]$Assignment.where, '^([A-Za-z0-9_]+) == ([A-Za-z0-9_.-]+)$')
        if (-not $w.Success) { return [pscustomobject]@{ Items = @(); Problem = 'where must read "<field> == <value>"' } }
        $field = $w.Groups[1].Value; $expected = $w.Groups[2].Value
    }
    $list = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $hit.Value.Count; $i++) {
        $entry = $hit.Value[$i]
        if ($entry -isnot [System.Collections.IDictionary]) { return [pscustomobject]@{ Items = @(); Problem = 'forEach entries must be objects' } }
        if ($field -and -not [string]::Equals([string]$entry[$field], $expected, 'Ordinal')) { continue }
        $suffix = if ($entry.Contains('id') -and $entry.id -is [string]) { $entry.id } else { [string]$i }
        $list.Add([pscustomobject]@{ Item = $entry; Suffix = $suffix })
    }
    return [pscustomobject]@{ Items = $list.ToArray(); Problem = $null }
}

function ConvertTo-CorePlanItem {
    <#
    .SYNOPSIS
        One concrete plan item for a resolved principal and scope, or a problem (code, detail).
    #>
    param([System.Collections.IDictionary]$Assignment, [string]$Id, [string]$Package, [string]$PrincipalId, [string]$Scope, [string]$CosmosId, $Definitions)
    function Problem([string]$Code, [string]$Detail) { [pscustomobject]@{ Item = $null; Problem = [pscustomobject]@{ code = $Code; detail = $Detail } } }
    $a = $Assignment
    if ($PrincipalId -notmatch $script:GuidPattern) { return Problem 'invalid_principal' 'a principal must resolve to an object id' }
    $item = [ordered]@{ id = $Id; package = $Package; plane = $a.plane; principalId = $PrincipalId.ToLowerInvariant(); principalType = $a.principalType; role = $a.role; runtime = [bool]$a.runtime; why = $a.why; scope = $null; roleDefinitionId = $null; appRoleId = $null }
    if ($a.plane -eq 'azure-rbac') {
        if ([string]$a.roleDefinitionId -notmatch $script:GuidPattern -or -not $a.role) { return Problem 'invalid_role' 'azure-rbac needs role and a roleDefinitionId GUID' }
        if ($Scope -notmatch '^/subscriptions/') { return Problem 'invalid_scope' 'azure-rbac scope must be a resource id' }
        $item.scope = $Scope; $item.roleDefinitionId = ([string]$a.roleDefinitionId).ToLowerInvariant()
    }
    elseif ($a.plane -eq 'cosmos-data') {
        $relative = if ($Scope -like "$CosmosId*") { $Scope.Substring($CosmosId.Length) } else { $Scope }
        if ($relative -eq '') { $relative = '/' }
        if ($relative -notmatch '^/(dbs/[A-Za-z0-9_-]+(/colls/[A-Za-z0-9_-]+)?)?$') { return Problem 'invalid_scope' 'Cosmos scope must be /, /dbs/<db> or /dbs/<db>/colls/<container>' }
        $roleId = [string]$a.roleDefinitionId
        if ($roleId -like 'custom:*') {
            if (-not $Definitions.Contains($roleId.Substring(7))) { return Problem 'unknown_role' "no Cosmos role definition $($roleId.Substring(7))" }
            $item.roleDefinitionId = $roleId
        }
        elseif ($roleId -eq '00000000-0000-0000-0000-000000000002') { return Problem 'role_too_broad' 'Cosmos DB Built-in Data Contributor allows every container and item action, delete included; declare a custom role in cosmosRoleDefinitions with only the data actions needed' }
        elseif ($script:CosmosBuiltIn.Contains($roleId)) {
            # The plan prints the role by name; the name must be the one Cosmos DB gives this id.
            if (-not [string]::Equals([string]$a.role, $script:CosmosBuiltIn[$roleId], 'Ordinal')) { return Problem 'role_mismatch' "role must be '$($script:CosmosBuiltIn[$roleId])', the name of $roleId" }
            $item.roleDefinitionId = $roleId
        }
        else { return Problem 'unknown_role' 'Cosmos role must be a built-in data role or custom:<key>' }
        $item.scope = $relative
    }
    elseif ($a.plane -eq 'graph-app-role') {
        if ([string]$a.appRoleId -notmatch $script:GuidPattern -or -not $a.role) { return Problem 'invalid_role' 'graph-app-role needs role and appRoleId' }
        $item.appRoleId = ([string]$a.appRoleId).ToLowerInvariant(); $item.scope = 'microsoft-graph'
    }
    else { return Problem 'invalid_plane' 'plane must be azure-rbac, cosmos-data or graph-app-role' }
    return [pscustomobject]@{ Item = [pscustomobject]$item; Problem = $null }
}

function Get-CoreAssignmentPlan {
    <#
    .SYNOPSIS
        Concrete assignments and Cosmos role definitions from the loaded documents. Returns Items,
        RoleDefinitions, Problems and Digest (over the resolved desired state only).
    #>
    param([object[]]$Documents, [Parameter(Mandatory)] [System.Collections.IDictionary]$D1, [Parameter(Mandatory)] [System.Collections.IDictionary]$Answers)
    $problems = [System.Collections.Generic.List[object]]::new()
    $items = [System.Collections.Generic.List[object]]::new()
    $definitions = [ordered]@{}
    $cosmosId = [string]$D1.cosmos.id
    foreach ($entry in @($Documents)) {
        foreach ($def in @($entry.Doc.cosmosRoleDefinitions | Where-Object { $_ })) {
            $name = Resolve-CorePlaceholder ([string]$def.roleName) $D1 $Answers
            if ($name.Problem) { $problems.Add((New-CorePlanProblem "$($entry.File):$($def.key)" 'unresolved' $name.Problem)); continue }
            if ($definitions.Contains($def.key)) { $problems.Add((New-CorePlanProblem "$($entry.File):$($def.key)" 'duplicate_role_key' 'custom role keys must be unique across files')); continue }
            # One role name would make two roles one (D3 finds a definition by its name, and derives a
            # new one's id from the lower-cased name), so the grants of each would widen to both.
            $twin = @($definitions.Values | Where-Object { [string]::Equals($_.roleName, [string]$name.Value, 'OrdinalIgnoreCase') })[0]
            if ($twin -or @($script:CosmosBuiltIn.Values | Where-Object { [string]::Equals($_, [string]$name.Value, 'OrdinalIgnoreCase') }).Count) {
                $problems.Add((New-CorePlanProblem "$($entry.File):$($def.key)" 'duplicate_role_name' $(if ($twin) { "its role name is the role name of custom:$($twin.key), compared without case; give each custom role its own name" } else { 'its role name is the name of a Cosmos DB built-in role' }))); continue
            }
            $actions = @($def.dataActions | Where-Object { $_ -match '^Microsoft\.DocumentDB/databaseAccounts/' })
            if ($actions.Count -eq 0 -or $actions.Count -ne @($def.dataActions).Count) { $problems.Add((New-CorePlanProblem "$($entry.File):$($def.key)" 'invalid_data_actions' 'Cosmos data actions only')); continue }
            $definitions[$def.key] = [pscustomobject]@{ key = $def.key; roleName = $name.Value; dataActions = @($actions | Sort-Object); definitionId = (New-CoreDeterministicGuid @($cosmosId, $name.Value)) }
        }
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($Documents)) {
        foreach ($a in @($entry.Doc.assignments | Where-Object { $_ })) {
            $where = "$($entry.File):$($a.id)"
            if (-not $seen.Add([string]$a.id)) { $problems.Add((New-CorePlanProblem $where 'duplicate_id' 'assignment ids must be unique across files')); continue }
            $pendingSection = Get-CorePendingSection -Assignment $a -Answers $Answers
            if ($pendingSection) { $problems.Add((New-CorePlanProblem $where 'pending_decision' "reads answers.$pendingSection, which still holds a PENDING decision; decide it, then run D3 again")); continue }
            $when = Test-CoreWhen ([string]$a.when) $Answers
            if ($when.Problem) { $problems.Add((New-CorePlanProblem $where 'invalid_when' $when.Problem)); continue }
            if (-not $when.Applies) { continue }
            $iterations = Get-CoreAssignmentIterations -Assignment $a -D1 $D1 -Answers $Answers
            if ($iterations.Problem) { $problems.Add((New-CorePlanProblem $where 'invalid_for_each' $iterations.Problem)); continue }
            foreach ($iteration in @($iterations.Items)) {
                $principals = Resolve-CorePrincipals $a $D1 $Answers $iteration.Item
                if ($principals.Problem) { $problems.Add((New-CorePlanProblem $where 'unresolved' $principals.Problem)); continue }
                $scope = Resolve-CorePlaceholder ([string]$a.scope) $D1 $Answers $iteration.Item
                if ($scope.Problem) { $problems.Add((New-CorePlanProblem $where 'unresolved' $scope.Problem)); continue }
                # Role fields may name an answer too (WP-SYNC: answers.sync.graphPermission); they are
                # checked after resolution, so an unresolved one is refused like any other placeholder.
                $effective = $a
                $roleProblem = $null
                foreach ($field in @('role', 'roleDefinitionId', 'appRoleId')) {
                    if (-not $a.Contains($field) -or -not ([string]$a[$field]).Contains('${')) { continue }
                    $value = Resolve-CorePlaceholder ([string]$a[$field]) $D1 $Answers $iteration.Item
                    if ($value.Problem) { $roleProblem = $value.Problem; break }
                    if ([object]::ReferenceEquals($effective, $a)) { $effective = [ordered]@{}; foreach ($k in $a.Keys) { $effective[$k] = $a[$k] } }
                    $effective[$field] = [string]$value.Value
                }
                if ($roleProblem) { $problems.Add((New-CorePlanProblem $where 'unresolved' $roleProblem)); continue }
                foreach ($p in @($principals.List | Where-Object { $_ })) {
                    $id = [string]$a.id
                    if ($iteration.Suffix) { $id = "${id}:$($iteration.Suffix)" }
                    if ($a.Contains('principals')) { $id = "${id}:$p" }
                    $converted = ConvertTo-CorePlanItem -Assignment $effective -Id $id -Package $entry.Doc.package -PrincipalId ([string]$p) -Scope ([string]$scope.Value) -CosmosId $cosmosId -Definitions $definitions
                    if ($converted.Problem) { $problems.Add((New-CorePlanProblem $where $converted.Problem.code $converted.Problem.detail)) }
                    else { $items.Add($converted.Item) }
                }
            }
        }
    }
    $desired = @($items | Sort-Object id | ForEach-Object { [ordered]@{ id = $_.id; plane = $_.plane; principalId = $_.principalId; roleDefinitionId = $_.roleDefinitionId; appRoleId = $_.appRoleId; scope = $_.scope } }) + @($definitions.Values | ForEach-Object { [ordered]@{ key = $_.key; roleName = $_.roleName; dataActions = $_.dataActions } })
    $digest = ([System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-CoreCanonicalJson $desired))) | ForEach-Object { $_.ToString('x2') }) -join ''
    [pscustomobject]@{ Items = $items.ToArray(); RoleDefinitions = @($definitions.Values); Problems = $problems.ToArray(); Digest = $digest }
}

Export-ModuleMember -Function Read-CoreAssignmentSources, Get-CoreAssignmentPlan, Resolve-CorePlaceholder, New-CoreDeterministicGuid, Test-CoreWhen
