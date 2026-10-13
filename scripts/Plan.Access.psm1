#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only access for the deployment plan report (WP-PLAN): a guard that lets only GET requests to
    Azure Resource Manager and Microsoft Graph through, and the signed-in operator's effective roles at
    a scope, compared with a stage's requirement. Nothing here writes.

.DESCRIPTION
    Sources (retrieved 2026-10-12):
    - Azure RBAC: GET {scope}/providers/Microsoft.Authorization/roleAssignments with
      $filter=atScope()+and+assignedTo('{objectId}'): the assignments at or above the scope, including
      those held through groups, transitively ("List Azure role assignments using the REST API",
      https://learn.microsoft.com/azure/role-based-access-control/role-assignments-list-rest;
      "Role Assignments - List For Scope", api-version 2022-04-01). Role names: "Role Definitions - Get
      By Id" (https://learn.microsoft.com/rest/api/authorization/role-definitions/get-by-id).
    - Entra directory roles: GET /v1.0/me/memberOf/microsoft.graph.directoryRole, the call the stages
      make (https://learn.microsoft.com/graph/api/user-list-memberof).
    - Tenant settings: GET /v1.0/policies/authorizationPolicy, defaultUserRolePermissions
      (https://learn.microsoft.com/graph/api/authorizationpolicy-get).
    - Cosmos data roles: Get-OnboardingCosmosRoles, Stage 3's own check (sqlRoleAssignments and
      sqlRoleDefinitions, https://learn.microsoft.com/rest/api/cosmos-db-resource-provider/sql-resources/list-sql-role-assignments).
#>

Import-Module (Join-Path $PSScriptRoot 'StagePrecondition.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Cosmos.psm1')

$script:Hosts = @('management.azure.com', 'graph.microsoft.com')

function New-PlanReadOnlySend {
    <#
    .SYNOPSIS
        Wraps Inner (Method, Url, Body -> Status, Content, ErrorCode). Only a GET without a body, over
        HTTPS, to management.azure.com or graph.microsoft.com is sent; its reply is cached by URL. Any
        other request is answered with Status 0 and ErrorCode write_refused_by_plan or
        host_refused_by_plan, without a call, and logged in Refused.
    #>
    param([Parameter(Mandatory)] [scriptblock]$Inner)
    $calls = [System.Collections.Generic.List[string]]::new()
    $refused = [System.Collections.Generic.List[string]]::new()
    $cache = @{}
    # A closure sees neither this module's script variables nor its functions: capture what it uses.
    $hosts = $script:Hosts
    $send = {
        param($Method, $Url, $Body)
        $uri = $null
        if (-not [uri]::TryCreate([string]$Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $hosts -notcontains $uri.Host -or $uri.UserInfo -or $uri.Fragment) {
            $refused.Add("$Method host"); return [pscustomobject]@{ Status = 0; Content = $null; ErrorCode = 'host_refused_by_plan' }
        }
        if ($Method -ne 'GET' -or $null -ne $Body) {
            $refused.Add("$Method $($uri.AbsolutePath)"); return [pscustomobject]@{ Status = 0; Content = $null; ErrorCode = 'write_refused_by_plan' }
        }
        if ($cache.Contains($Url)) { return $cache[$Url] }
        $calls.Add("GET $($uri.AbsolutePath)")
        $reply = & $Inner 'GET' $Url $null
        if ($reply.Status -ne 0) { $cache[$Url] = $reply }
        return $reply
    }.GetNewClosure()
    [pscustomobject]@{ Send = $send; Calls = $calls; Refused = $refused }
}

function Get-PlanPages {
    <# Every item of an ARM or Graph collection, following nextLink or @odata.nextLink on the same host. #>
    param([Parameter(Mandatory)] [scriptblock]$Send, [Parameter(Mandatory)] [string]$Url)
    $items = [System.Collections.Generic.List[object]]::new()
    $hostName = ([uri]$Url).Host
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($Url) {
        if (-not $seen.Add($Url) -or ([uri]$Url).Host -ne $hostName) { return [pscustomobject]@{ Status = -1; Items = @() } }
        $r = & $Send 'GET' $Url $null
        if ($r.Status -ne 200 -or $r.Content -isnot [System.Collections.IDictionary]) { return [pscustomobject]@{ Status = $r.Status; Items = @() } }
        foreach ($item in @($r.Content['value'] | Where-Object { $null -ne $_ })) { $items.Add($item) }
        $Url = [string]$r.Content['@odata.nextLink']
        if (-not $Url) { $Url = [string]$r.Content['nextLink'] }
    }
    [pscustomobject]@{ Status = 200; Items = $items.ToArray() }
}

function New-PlanAccessProvider {
    <#
    .SYNOPSIS
        The operator's effective roles through Send (normally New-PlanReadOnlySend's). Each lookup
        returns State (read or unreadable), Roles or Value, and Status. Repeated reads come from the
        guard's cache.
    #>
    param([Parameter(Mandatory)] [scriptblock]$Send, [Parameter(Mandatory)] [string]$ObjectId)
    # A closure sees neither this module's script variables nor its functions: capture what it uses.
    $getPages = ${function:Get-PlanPages}
    $cosmosRoles = Get-Command -Name 'Get-OnboardingCosmosRoles' -CommandType Function
    $azure = {
        param([string]$Scope)
        $url = "https://management.azure.com$Scope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()+and+assignedTo('$ObjectId')"
        $list = & $getPages -Send $Send -Url $url
        if ($list.Status -ne 200) { return [pscustomobject]@{ State = 'unreadable'; Roles = @(); Status = $list.Status } }
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($a in $list.Items) {
            $p = $a['properties']; $at = ([string]$p['scope']).TrimEnd('/')
            # atScope() returns the scope and its parents; a narrower assignment does not apply at the scope.
            if ($p['condition'] -or $at.StartsWith($Scope.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $definition = & $Send 'GET' "https://management.azure.com$($p['roleDefinitionId'])?api-version=2022-04-01" $null
            if ($definition.Status -eq 200 -and $definition.Content['properties']['roleName']) { $names.Add([string]$definition.Content['properties']['roleName']) }
        }
        [pscustomobject]@{ State = 'read'; Roles = @($names | Select-Object -Unique); Status = 200 }
    }.GetNewClosure()
    $directory = {
        $list = & $getPages -Send $Send -Url "https://graph.microsoft.com/v1.0/me/memberOf/microsoft.graph.directoryRole?`$select=displayName,roleTemplateId"
        if ($list.Status -ne 200) { return [pscustomobject]@{ State = 'unreadable'; Roles = @(); Status = $list.Status } }
        [pscustomobject]@{ State = 'read'; Roles = @($list.Items | ForEach-Object { [string]$_['displayName'] } | Where-Object { $_ }); Status = 200 }
    }.GetNewClosure()
    $setting = {
        param([string]$Name)
        $r = & $Send 'GET' 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy' $null
        $policy = if ($r.Status -eq 200 -and $r.Content -is [System.Collections.IDictionary] -and $r.Content.Contains('value')) { @($r.Content['value'])[0] } else { $r.Content }
        $value = if ($r.Status -eq 200 -and $policy -is [System.Collections.IDictionary]) { $policy['defaultUserRolePermissions'][$Name] } else { $null }
        if ($value -isnot [bool]) { return [pscustomobject]@{ State = 'unreadable'; Value = $null; Status = $r.Status } }
        [pscustomobject]@{ State = 'read'; Value = $value; Status = 200 }
    }.GetNewClosure()
    $cosmos = {
        param([string]$AccountId, [string]$Scope)
        # Stage 3's own Cosmos role check, over the read-only Send with Invoke-OnboardingRest's semantics.
        # A nested closure captures only the locals of the scope that makes it, hence $outer.
        $outer = $Send
        $adapter = { param($m, $u, $b) $x = & $outer $m $u $b; if ($x.Status -eq 404 -and $m -eq 'GET') { return $null }; if ($x.Status -lt 200 -or $x.Status -ge 300) { throw "HTTP $($x.Status)" }; $x.Content }.GetNewClosure()
        $context = @{ Decisions = @{ registry = @{ accountResourceId = $AccountId } }; Actor = @{ objectId = $ObjectId } }
        try { [pscustomobject]@{ State = 'read'; Roles = @(& $cosmosRoles -Context $context -Scope $Scope -Send $adapter | ForEach-Object { $_.roleDefinitionName }); Status = 200 } }
        catch { [pscustomobject]@{ State = 'unreadable'; Roles = @(); Status = $(if ($_.Exception.Message -match 'HTTP (-?[0-9]+)') { [int]$Matches[1] } else { 0 }) } }
    }.GetNewClosure()
    @{ AzureRoles = $azure; DirectoryRoles = $directory; TenantSetting = $setting; CosmosRoles = $cosmos }
}

function Test-PlanRequirement {
    <#
    .SYNOPSIS
        One resolved requirement (kind, scope, anyOf, optional tenantSetting) against the operator's
        roles. state: met (via a role, or a tenant setting), missing (held lists what the operator has
        there), or unreadable (never taken as met). The comparison is Test-StageRolePrecondition's.
    #>
    param([Parameter(Mandatory)] [System.Collections.IDictionary]$Requirement, [Parameter(Mandatory)] [hashtable]$Access)
    $scope = [string]$Requirement.scope
    $lookup = switch ($Requirement.kind) {
        'azure-rbac' { & $Access.AzureRoles $scope }
        'entra-directory' { & $Access.DirectoryRoles }
        'cosmos-data' { & $Access.CosmosRoles ($scope -replace '/dbs/.*$', '') $scope }
    }
    $result = [ordered]@{
        kind = $Requirement.kind; scope = $scope; anyOf = @($Requirement.anyOf); held = @($lookup.Roles); state = 'missing'; via = $null; detail = $null
        heldBy = $Requirement.heldBy; purpose = $Requirement.purpose; blocking = ($Requirement.blocking -ne $false); source = $Requirement.source
    }
    if ($lookup.State -ne 'read') { $result.state = 'unreadable'; $result.detail = "roles could not be read (HTTP $($lookup.Status))"; return [pscustomobject]$result }
    $roles = @($lookup.Roles)
    $check = Test-StageRolePrecondition -AcceptableRoles @($Requirement.anyOf) -Scope $scope -GetCurrentAssignments { param($s) $roles | ForEach-Object { [pscustomobject]@{ roleDefinitionName = $_ } } }.GetNewClosure()
    if ($check.Satisfied) { $result.state = 'met'; $result.via = $check.MatchedRole; return [pscustomobject]$result }
    if ($Requirement.Contains('tenantSetting') -and $Requirement.tenantSetting) {
        $s = & $Access.TenantSetting ([string]$Requirement.tenantSetting)
        if ($s.State -eq 'read' -and $s.Value) { $result.state = 'met'; $result.via = "tenant setting $($Requirement.tenantSetting)"; return [pscustomobject]$result }
        $result.detail = if ($s.State -eq 'read') { "tenant setting $($Requirement.tenantSetting) is off" } else { "tenant setting $($Requirement.tenantSetting) could not be read (HTTP $($s.Status))" }
    }
    return [pscustomobject]$result
}

Export-ModuleMember -Function New-PlanReadOnlySend, Get-PlanPages, New-PlanAccessProvider, Test-PlanRequirement
