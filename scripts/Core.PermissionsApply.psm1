#Requires -Version 7.0
<#
.SYNOPSIS
    D3 apply (docs/DEPLOYMENT-STAGES.md): checks the caller's rights, then creates each planned
    assignment with a deterministic name, reads it back, and reports its state. Every call goes
    through -Send (Method, Url, Body -> Status, Content, ErrorCode), so tests use a fake.
    States: existing (already granted, same scope), inherited (granted at a parent scope), created,
    pending (a Graph permission the caller cannot grant), failed.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.Schema.psm1')
Import-Module (Join-Path $PSScriptRoot 'Core.Permissions.psm1')

$script:Arm = 'https://management.azure.com'
$script:Graph = 'https://graph.microsoft.com/v1.0'
$script:GraphAppId = '00000003-0000-0000-c000-000000000000'
# Directory role templates that can grant Microsoft Graph app roles (DEPLOYMENT-GUIDE, Step 7b).
$script:GraphGrantRoles = @{ 'e8611ab8-c189-46e8-94e1-60213ab1f814' = 'Privileged Role Administrator'; '62e90394-69f5-4237-9190-012177145e10' = 'Global Administrator' }
# The longest D3 waits, in all, for one Cosmos role definition or assignment to read back after its
# write before it refuses the item (role_definition_not_verified, not_verified). Ten tries 5 s apart
# were too short in Validation, 2026-10-13 (docs/status/WP-CORE-RUN.md).
$script:CosmosReadBackSeconds = 600

function Test-CoreActionAllowed {
    <#
    .SYNOPSIS
        ARM permission semantics: an action is allowed when an Actions pattern matches it and no
        NotActions pattern of the same entry does. Patterns use * as a wildcard; case-insensitive.
    #>
    param([object[]]$Permissions, [Parameter(Mandatory)] [string]$Action)
    foreach ($entry in @($Permissions)) {
        $allowed = @($entry.actions | Where-Object { $Action -like $_ }).Count -gt 0
        $denied = @($entry.notActions | Where-Object { $Action -like $_ }).Count -gt 0
        if ($allowed -and -not $denied) { return $true }
    }
    return $false
}

function Test-CoreSameId { param([string]$A, [string]$B) [string]::Equals($A.TrimEnd('/'), $B.TrimEnd('/'), [StringComparison]::OrdinalIgnoreCase) }
function Test-CoreScopeCovers { param([string]$Parent, [string]$Child) (Test-CoreSameId $Parent $Child) -or $Child.TrimEnd('/').StartsWith($Parent.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase) }

function Get-CoreD3Refusals {
    <#
    .SYNOPSIS
        Read-only checks before any write: role names match their ids, and the caller may write role
        assignments at every scope and Cosmos data-plane assignments on the account.
    #>
    param([Parameter(Mandatory)] $Plan, [Parameter(Mandatory)] [System.Collections.IDictionary]$D1, [Parameter(Mandatory)] [scriptblock]$Send)
    $refusals = [System.Collections.Generic.List[string]]::new()
    $sub = $D1.target.subscriptionId
    $azure = @($Plan.Items | Where-Object plane -eq 'azure-rbac')
    foreach ($group in ($azure | Group-Object roleDefinitionId)) {
        $r = & $Send 'GET' "$script:Arm/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions/$($group.Name)?api-version=2022-04-01" $null
        $name = if ($r.Status -eq 200) { [string]$r.Content.properties.roleName } else { $null }
        foreach ($item in $group.Group) {
            if (-not [string]::Equals($name, [string]$item.role, 'Ordinal')) { $refusals.Add("$($item.id): role '$($item.role)' does not match role definition $($group.Name)") }
        }
    }
    # Every action the grants need, per scope, checked from one permissions read of that scope. D3
    # creates the plan's custom Cosmos role definitions and rewrites them to match the data, before
    # their grants (Get-CoreCosmosDefinitionWrites), so those need sqlRoleDefinitions/write as well.
    # The sync timer's app-setting write after the grants is not checked here (advisory A-3).
    $needs = @{}
    function Add-Need([string]$Scope, [string]$Action) { if (-not $needs.Contains($Scope)) { $needs[$Scope] = [System.Collections.Generic.List[string]]::new() }; if (-not $needs[$Scope].Contains($Action)) { $needs[$Scope].Add($Action) } }
    foreach ($item in $azure) { Add-Need $item.scope 'Microsoft.Authorization/roleAssignments/write' }
    if (@($Plan.Items | Where-Object plane -eq 'cosmos-data').Count) {
        Add-Need ([string]$D1.cosmos.id) 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments/write'
        if (@($Plan.RoleDefinitions).Count) { Add-Need ([string]$D1.cosmos.id) 'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions/write' }
    }
    # A Graph app role is granted by its id, but reviewed by its name: the id must be the named
    # application permission in Microsoft Graph's own list, read live; an unreadable list refuses.
    $graphItems = @($Plan.Items | Where-Object plane -eq 'graph-app-role')
    if ($graphItems.Count) {
        $graph = & $Send 'GET' "$script:Graph/servicePrincipals(appId='$script:GraphAppId')?`$select=id,appRoles" $null
        foreach ($item in $graphItems) {
            if ($graph.Status -ne 200) { $refusals.Add("$($item.id): Microsoft Graph's application permissions could not be read (HTTP $($graph.Status)), so app role $($item.appRoleId) cannot be checked against '$($item.role)'."); continue }
            $match = @($graph.Content.appRoles | Where-Object { [string]::Equals([string]$_.id, [string]$item.appRoleId, 'OrdinalIgnoreCase') })[0]
            if (-not $match -or -not [string]::Equals([string]$match.value, [string]$item.role, 'Ordinal') -or @($match.allowedMemberTypes) -cnotcontains 'Application') {
                $refusals.Add("$($item.id): Graph app role $($item.appRoleId) is not the application permission '$($item.role)'. Correct the pair in the answers or the assignment data.")
            }
        }
    }
    foreach ($scope in $needs.Keys) {
        $r = & $Send 'GET' "$script:Arm$scope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" $null
        $lacking = @($needs[$scope] | Where-Object { $r.Status -ne 200 -or -not (Test-CoreActionAllowed -Permissions @($r.Content.value) -Action $_) })
        if ($lacking.Count) {
            $refusals.Add("the signed-in identity cannot perform $($lacking -join ', ') at $scope. Needs Role Based Access Control Administrator or User Access Administrator there (Contributor on the Cosmos account for data-plane role definitions and assignments).")
        }
    }
    return $refusals.ToArray()
}

function Invoke-CoreRetry {
    param([scriptblock]$Call, [scriptblock]$Sleep, [int]$Attempts = 6)
    for ($i = 1; $i -le $Attempts; $i++) {
        $r = & $Call
        # A new identity can take minutes to replicate before ARM accepts it as a principal.
        if ($r.ErrorCode -ne 'PrincipalNotFound' -or $i -eq $Attempts) { return $r }
        & $Sleep (15 * $i)
    }
}

function Set-CoreAzureAssignment {
    param($Item, [System.Collections.IDictionary]$D1, [scriptblock]$Send, [scriptblock]$Sleep)
    $sub = $D1.target.subscriptionId
    $list = & $Send 'GET' "$script:Arm$($Item.scope)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=assignedTo('$($Item.principalId)')" $null
    foreach ($a in @($list.Content.value)) {
        if (-not ([string]$a.properties.roleDefinitionId).EndsWith("/$($Item.roleDefinitionId)", [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (Test-CoreSameId $a.properties.scope $Item.scope) { return @{ state = 'existing'; assignmentId = $a.id } }
        if (Test-CoreScopeCovers $a.properties.scope $Item.scope) { return @{ state = 'inherited'; assignmentId = $a.id } }
    }
    $name = New-CoreDeterministicGuid @($Item.scope, $Item.principalId, $Item.roleDefinitionId)
    $url = "$script:Arm$($Item.scope)/providers/Microsoft.Authorization/roleAssignments/$name`?api-version=2022-04-01"
    $properties = [ordered]@{ roleDefinitionId = "/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions/$($Item.roleDefinitionId)"; principalId = $Item.principalId }
    if ($Item.principalType) { $properties.principalType = $Item.principalType }
    $put = Invoke-CoreRetry -Sleep $Sleep -Call { & $Send 'PUT' $url @{ properties = $properties } }.GetNewClosure()
    if ($put.Status -notin @(200, 201)) { return @{ state = 'failed'; reasonCode = "arm_$($put.Status)_$($put.ErrorCode)" } }
    $check = & $Send 'GET' $url $null
    if ($check.Status -ne 200 -or -not [string]::Equals([string]$check.Content.properties.principalId, $Item.principalId, 'OrdinalIgnoreCase')) { return @{ state = 'failed'; reasonCode = 'not_verified' } }
    return @{ state = 'created'; assignmentId = $check.Content.id }
}

function Wait-CoreCosmosResource {
    <#
    .SYNOPSIS
        Reads a Cosmos role definition or assignment back after its write, which Cosmos DB accepts with
        202 and finishes later: in Validation (2026-10-13) 1 to 3 minutes after the PUT. Waits 5 s, doubling
        to at most 30 s, for $script:CosmosReadBackSeconds in all; returns the last read.
    #>
    param([string]$Url, [scriptblock]$Send, [scriptblock]$Sleep)
    $waited = 0; $pause = 5
    while ($true) {
        $r = & $Send 'GET' $Url $null
        if ($r.Status -eq 200 -or $waited -ge $script:CosmosReadBackSeconds) { return $r }
        $pause = [Math]::Min($pause, $script:CosmosReadBackSeconds - $waited)
        & $Sleep $pause
        $waited += $pause
        $pause = [Math]::Min($pause * 2, 30)
    }
}

function Get-CoreCosmosDefinitionWrites {
    <#
    .SYNOPSIS
        Read-only: what Apply would do to each custom Cosmos role definition of the plan. A definition
        is found by its role name, else by the id D3 would give it. op is create (none found), update
        (found, with other data actions or another name) or unchanged. An update also counts the
        assignments that hold the role now (heldBy): a rewrite changes their access too. Refusals,
        with Code: the definitions or assignments cannot be read, or two definitions have the name.
    #>
    param([Parameter(Mandatory)] $Plan, [Parameter(Mandatory)] [System.Collections.IDictionary]$D1, [Parameter(Mandatory)] [scriptblock]$Send)
    function Refused([string]$Code, [string]$Text) { [pscustomobject]@{ Writes = @(); Refusals = @($Text); Code = $Code } }
    $writes = [System.Collections.Generic.List[object]]::new()
    if (-not @($Plan.RoleDefinitions).Count -or -not @($Plan.Items | Where-Object plane -eq 'cosmos-data').Count) { return [pscustomobject]@{ Writes = @(); Refusals = @(); Code = $null } }
    $account = [string]$D1.cosmos.id
    $list = & $Send 'GET' "$script:Arm$account/sqlRoleDefinitions?api-version=2024-11-15" $null
    if ($list.Status -ne 200) { return Refused 'role_definitions_unreadable' "the Cosmos role definitions of $account could not be read (HTTP $($list.Status)), so D3 cannot show what it would write." }
    $existing = @($list.Content.value | Where-Object { $_ })
    foreach ($def in @($Plan.RoleDefinitions)) {
        $named = @($existing | Where-Object { [string]::Equals([string]$_.properties.roleName, $def.roleName, 'Ordinal') })
        if ($named.Count -gt 1) { return Refused 'role_definition_ambiguous' "custom:$($def.key): $($named.Count) Cosmos role definitions are named '$($def.roleName)', so D3 cannot tell which one to manage." }
        $match = if ($named.Count) { $named[0] } else { @($existing | Where-Object { [string]::Equals([string]$_.name, $def.definitionId, 'OrdinalIgnoreCase') })[0] }
        $current = if ($match) { @(@($match.properties.permissions) | ForEach-Object { @($_.dataActions) } | Where-Object { $_ } | Sort-Object) } else { @() }
        $op = if (-not $match) { 'create' }
        elseif ([string]::Equals([string]$match.properties.roleName, $def.roleName, 'Ordinal') -and ($current -join ',') -eq ($def.dataActions -join ',')) { 'unchanged' }
        else { 'update' }
        $writes.Add([pscustomobject]@{ key = $def.key; roleName = $def.roleName; dataActions = $def.dataActions; op = $op; definitionId = $(if ($match) { [string]$match.name } else { $def.definitionId }); currentName = $(if ($match) { [string]$match.properties.roleName } else { $null }); currentActions = $current; heldBy = 0 })
    }
    if (@($writes | Where-Object op -eq 'update').Count) {
        $held = & $Send 'GET' "$script:Arm$account/sqlRoleAssignments?api-version=2024-11-15" $null
        if ($held.Status -ne 200) { return Refused 'role_assignments_unreadable' "the Cosmos role assignments of $account could not be read (HTTP $($held.Status)), so D3 cannot show who holds a role it would rewrite." }
        foreach ($w in @($writes | Where-Object op -eq 'update')) { $w.heldBy = @($held.Content.value | Where-Object { ([string]$_.properties.roleDefinitionId).EndsWith("/sqlRoleDefinitions/$($w.definitionId)", [StringComparison]::OrdinalIgnoreCase) }).Count }
    }
    return [pscustomobject]@{ Writes = $writes.ToArray(); Refusals = @(); Code = $null }
}

function ConvertTo-CoreDefinitionUpdate {
    # The facts of a rewrite that a plan shows and its digest binds.
    param($Write)
    ConvertTo-CoreCanonicalJson ([ordered]@{ key = $Write.key; definitionId = $Write.definitionId; currentName = $Write.currentName; currentActions = @($Write.currentActions); roleName = $Write.roleName; dataActions = @($Write.dataActions); heldBy = $Write.heldBy })
}

function Set-CoreCosmosDefinitions {
    <#
    .SYNOPSIS
        Writes the custom role definitions, and rewrites an existing one only as the plan showed it
        (-Planned, from Get-CoreCosmosDefinitionWrites at plan time): it reads them again, and if any
        would now be rewritten otherwise, it writes none. Each write is reported to -OnWrite for the
        audit. Returns Resolved (custom:<key> -> definition id) and Failure (a reason code or null).
    #>
    param($Plan, [System.Collections.IDictionary]$D1, [scriptblock]$Send, [scriptblock]$Sleep, [object[]]$Planned, [scriptblock]$OnWrite)
    $account = [string]$D1.cosmos.id
    $resolved = @{}
    $live = Get-CoreCosmosDefinitionWrites -Plan $Plan -D1 $D1 -Send $Send
    if ($live.Code) { return @{ Resolved = $resolved; Failure = $live.Code } }
    $shown = @(@($Planned) | Where-Object { $_.op -eq 'update' } | ForEach-Object { ConvertTo-CoreDefinitionUpdate $_ })
    foreach ($w in @($live.Writes | Where-Object op -eq 'update')) {
        if ($shown -cnotcontains (ConvertTo-CoreDefinitionUpdate $w)) { return @{ Resolved = $resolved; Failure = 'role_definition_not_planned' } }
    }
    foreach ($w in @($live.Writes)) {
        $id = "$account/sqlRoleDefinitions/$($w.definitionId)"
        if ($w.op -ne 'unchanged') {
            $url = "$script:Arm$id`?api-version=2024-11-15"
            $body = @{ properties = @{ roleName = $w.roleName; type = 'CustomRole'; assignableScopes = @($account); permissions = @(@{ dataActions = $w.dataActions }) } }
            $put = & $Send 'PUT' $url $body
            if ($put.Status -notin @(200, 201, 202)) { return @{ Resolved = $resolved; Failure = "cosmos_definition_$($put.Status)_$($put.ErrorCode)" } }
            & $OnWrite "$($w.op)_cosmos_role_definition" "custom:$($w.key)" $id
            $check = Wait-CoreCosmosResource -Url $url -Send $Send -Sleep $Sleep
            if ($check.Status -ne 200) { return @{ Resolved = $resolved; Failure = 'role_definition_not_verified' } }
        }
        $resolved["custom:$($w.key)"] = $id
    }
    return @{ Resolved = $resolved; Failure = $null }
}

function Set-CoreCosmosAssignment {
    param($Item, [System.Collections.IDictionary]$D1, [hashtable]$Definitions, [string]$DefinitionFailure, [object[]]$Existing, [scriptblock]$Send, [scriptblock]$Sleep)
    $account = [string]$D1.cosmos.id
    $roleId = if ($Item.roleDefinitionId -like 'custom:*') { $Definitions[$Item.roleDefinitionId] } else { "$account/sqlRoleDefinitions/$($Item.roleDefinitionId)" }
    if (-not $roleId) { return @{ state = 'failed'; reasonCode = $(if ($DefinitionFailure) { $DefinitionFailure } else { 'role_definition_missing' }) } }
    $scope = if ($Item.scope -eq '/') { $account } else { "$account$($Item.scope)" }
    foreach ($a in @($Existing)) {
        if (-not [string]::Equals([string]$a.properties.principalId, $Item.principalId, 'OrdinalIgnoreCase') -or -not (Test-CoreSameId $a.properties.roleDefinitionId $roleId)) { continue }
        if (Test-CoreSameId $a.properties.scope $scope) { return @{ state = 'existing'; assignmentId = $a.id } }
        if (Test-CoreScopeCovers $a.properties.scope $scope) { return @{ state = 'inherited'; assignmentId = $a.id } }
    }
    $name = New-CoreDeterministicGuid @($scope, $Item.principalId, $roleId)
    $url = "$script:Arm$account/sqlRoleAssignments/$name`?api-version=2024-11-15"
    $put = Invoke-CoreRetry -Sleep $Sleep -Call { & $Send 'PUT' $url @{ properties = @{ roleDefinitionId = $roleId; principalId = $Item.principalId; scope = $scope } } }.GetNewClosure()
    if ($put.Status -notin @(200, 201, 202)) { return @{ state = 'failed'; reasonCode = "cosmos_$($put.Status)_$($put.ErrorCode)" } }
    $check = Wait-CoreCosmosResource -Url $url -Send $Send -Sleep $Sleep
    if ($check.Status -ne 200) { return @{ state = 'failed'; reasonCode = 'not_verified' } }
    return @{ state = 'created'; assignmentId = $check.Content.id }
}

function Format-CoreGraphStep7 {
    param($Item, [string]$GraphSpId)
    $body = "{`"principalId`":`"$($Item.principalId)`",`"resourceId`":`"$GraphSpId`",`"appRoleId`":`"$($Item.appRoleId)`"}"
    @(
        "PENDING $($Item.id): Microsoft Graph application permission $($Item.role) for principal $($Item.principalId) needs a Privileged Role Administrator (docs/DEPLOYMENT-GUIDE.md, Step 7b, after a PIM activation and a new sign-in). In Cloud Shell:"
        "  az rest --method post --url $script:Graph/servicePrincipals/$($Item.principalId)/appRoleAssignments --headers Content-Type=application/json --body '$body'"
        "  Verify (Step 7c): az rest --method get --url $script:Graph/servicePrincipals/$($Item.principalId)/appRoleAssignments"
        '  Then run D3 again; the sync timer stays disabled until the permission is verified.'
    )
}

function Set-CoreGraphAssignment {
    param($Item, [scriptblock]$Send, [string]$GraphSpId, [bool]$CallerCanGrant)
    $list = & $Send 'GET' "$script:Graph/servicePrincipals/$($Item.principalId)/appRoleAssignments" $null
    if (@($list.Content.value | Where-Object { $_.appRoleId -eq $Item.appRoleId -and $_.resourceId -eq $GraphSpId }).Count) { return @{ state = 'existing' } }
    if (-not $CallerCanGrant) { return @{ state = 'pending'; instructions = @(Format-CoreGraphStep7 -Item $Item -GraphSpId $GraphSpId) } }
    $post = & $Send 'POST' "$script:Graph/servicePrincipals/$($Item.principalId)/appRoleAssignments" @{ principalId = $Item.principalId; resourceId = $GraphSpId; appRoleId = $Item.appRoleId }
    if ($post.Status -notin @(200, 201)) { return @{ state = 'failed'; reasonCode = "graph_$($post.Status)_$($post.ErrorCode)" } }
    $list = & $Send 'GET' "$script:Graph/servicePrincipals/$($Item.principalId)/appRoleAssignments" $null
    if (@($list.Content.value | Where-Object { $_.appRoleId -eq $Item.appRoleId -and $_.resourceId -eq $GraphSpId }).Count) { return @{ state = 'created' } }
    return @{ state = 'failed'; reasonCode = 'not_verified' }
}

function Get-CoreD3Digest {
    <#
    .SYNOPSIS
        The digest that Apply must be given: the desired state's (Get-CoreAssignmentPlan), extended by
        every rewrite of an existing Cosmos role definition that the plan shows, so a rewrite that
        appears after the review changes the digest and Apply refuses.
    #>
    param([Parameter(Mandatory)] [string]$PlanDigest, [object[]]$DefinitionWrites)
    $updates = @(@($DefinitionWrites) | Where-Object { $_.op -eq 'update' } | Sort-Object key | ForEach-Object { ConvertTo-CoreDefinitionUpdate $_ })
    if (-not $updates.Count) { return $PlanDigest }
    $text = ConvertTo-CoreCanonicalJson ([ordered]@{ plan = $PlanDigest; definitionUpdates = $updates })
    return ([System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Invoke-CoreD3Apply {
    <#
    .SYNOPSIS
        Applies the plan in order: Cosmos role definitions, then each assignment. Returns one result
        per item: id, plane, principalId, scope, runtime and state. Never deletes anything. A role
        definition is rewritten only as -DefinitionWrites (the plan's) shows it, and every definition
        write is reported to -OnWrite for the audit.
    #>
    param([Parameter(Mandatory)] $Plan, [Parameter(Mandatory)] [System.Collections.IDictionary]$D1, [Parameter(Mandatory)] [scriptblock]$Send, [scriptblock]$Sleep = { param($s) Start-Sleep -Seconds $s }, [object[]]$DefinitionWrites = @(), [Parameter(Mandatory)] [scriptblock]$OnWrite)
    $results = [System.Collections.Generic.List[object]]::new()
    $definitions = @{}
    $definitionFailure = $null
    $cosmosItems = @($Plan.Items | Where-Object plane -eq 'cosmos-data')
    $existingCosmos = @()
    if ($cosmosItems.Count) {
        $set = Set-CoreCosmosDefinitions -Plan $Plan -D1 $D1 -Send $Send -Sleep $Sleep -Planned $DefinitionWrites -OnWrite $OnWrite
        $definitions = $set.Resolved; $definitionFailure = $set.Failure
        $existingCosmos = @((& $Send 'GET' "$script:Arm$($D1.cosmos.id)/sqlRoleAssignments?api-version=2024-11-15" $null).Content.value)
    }
    $graphItems = @($Plan.Items | Where-Object plane -eq 'graph-app-role')
    $graphSpId = $null; $callerCanGrant = $false
    if ($graphItems.Count) {
        $graphSpId = (& $Send 'GET' "$script:Graph/servicePrincipals(appId='$script:GraphAppId')?`$select=id" $null).Content.id
        $roles = & $Send 'GET' "$script:Graph/me/memberOf/microsoft.graph.directoryRole?`$select=roleTemplateId" $null
        $callerCanGrant = @($roles.Content.value | Where-Object { $script:GraphGrantRoles.Contains([string]$_.roleTemplateId) }).Count -gt 0
    }
    foreach ($item in @($Plan.Items)) {
        $outcome = switch ($item.plane) {
            'azure-rbac' { Set-CoreAzureAssignment -Item $item -D1 $D1 -Send $Send -Sleep $Sleep }
            'cosmos-data' { Set-CoreCosmosAssignment -Item $item -D1 $D1 -Definitions $definitions -DefinitionFailure $definitionFailure -Existing $existingCosmos -Send $Send -Sleep $Sleep }
            'graph-app-role' { Set-CoreGraphAssignment -Item $item -Send $Send -GraphSpId $graphSpId -CallerCanGrant $callerCanGrant }
        }
        $results.Add([pscustomobject]@{ id = $item.id; package = $item.package; plane = $item.plane; principalId = $item.principalId; scope = $item.scope; runtime = $item.runtime; state = $outcome.state; assignmentId = $outcome.assignmentId; reasonCode = $outcome.reasonCode; instructions = $outcome.instructions })
    }
    return $results.ToArray()
}

Export-ModuleMember -Function Test-CoreActionAllowed, Get-CoreD3Refusals, Get-CoreCosmosDefinitionWrites, Get-CoreD3Digest, Invoke-CoreD3Apply
