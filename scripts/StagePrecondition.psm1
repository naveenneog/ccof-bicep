#Requires -Version 7.0
<#
.SYNOPSIS
    The "does the signed-in identity hold the role this stage declares, before any write" check
    docs/CHECKPOINT-SETUP.md requires for every stage: "a stage refuses, with a named remedy, if the
    signed-in identity lacks the role it declares - before any az/Graph call, not deep inside one."

.DESCRIPTION
    Deliberately generic across role *types* (Azure RBAC, Entra directory roles, Cosmos data-plane
    roles all shape as "name + scope + who holds what") by taking a -GetCurrentAssignments
    scriptblock - each stage script supplies the real lookup appropriate to its own role type
    (`az role assignment list`, a Microsoft Graph directory-role call, or
    `az cosmosdb sql role assignment list`), this module only compares the result against what the
    stage declared acceptable. This is what keeps the precondition check itself testable without a
    live tenant, and reusable across stages whose role *type* genuinely differs.
#>

function Test-StageRolePrecondition {
    <#
    .SYNOPSIS
        Returns @{ Satisfied; MatchedRole; Remedy; CurrentRoles } for whether the signed-in identity
        holds at least one of AcceptableRoles at Scope, per GetCurrentAssignments's lookup.
    .PARAMETER GetCurrentAssignments
        A scriptblock taking one positional parameter (Scope) and returning objects with at least a
        `roleDefinitionName` property - e.g. `{ param($Scope) az role assignment list --scope $Scope
        --query "[?principalName=='$(az account show --query user.name -o tsv)']" | ConvertFrom-Json }`
        for a real Azure RBAC check. Defaults to that real Azure RBAC lookup if not supplied.
    #>
    param(
        [Parameter(Mandatory)] [string[]]$AcceptableRoles,
        [Parameter(Mandatory)] [string]$Scope,
        [scriptblock]$GetCurrentAssignments = {
            param($Scope)
            $currentUser = az account show --query user.name -o tsv
            az role assignment list --scope $Scope --query "[?principalName=='$currentUser']" -o json | ConvertFrom-Json
        }
    )

    $assignments = @(& $GetCurrentAssignments $Scope)
    $currentRoles = @($assignments | ForEach-Object { $_.roleDefinitionName })

    $matched = $currentRoles | Where-Object {
        $current = $_
        @($AcceptableRoles | Where-Object { [string]::Equals($_, $current, 'Ordinal') }).Count -gt 0
    } | Select-Object -First 1

    if ($matched) {
        return [PSCustomObject]@{
            Satisfied    = $true
            MatchedRole  = $matched
            CurrentRoles = $currentRoles
            Remedy       = $null
        }
    }

    $acceptableList = $AcceptableRoles -join ' or '
    $heldList = if ($currentRoles.Count -gt 0) { $currentRoles -join ', ' } else { 'no role at all' }
    $remedy = "This stage needs $acceptableList at scope '$Scope'. The signed-in identity currently holds: $heldList. Ask an administrator to grant one of the acceptable roles, then retry."

    return [PSCustomObject]@{
        Satisfied    = $false
        MatchedRole  = $null
        CurrentRoles = $currentRoles
        Remedy       = $remedy
    }
}

Export-ModuleMember -Function Test-StageRolePrecondition
