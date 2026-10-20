# Staged deployment: stage 5 (Entra registrations and groups through Microsoft Graph). Dot-sourced by Invoke-StagedDeployment.ps1; not run directly.

# ---------------------------------------------------------------- stage 5: Entra

function Get-StgApp { param([string]$DisplayName)
    # No `$select: az.cmd passes arguments through cmd.exe, which would treat & as a separator.
    $found = @((Get-StgGraph "applications?`$filter=displayName eq '$DisplayName'").value)
    if ($found.Count -gt 1) { throw "entra_ambiguous: $($found.Count) applications are named '$DisplayName'." }
    return $found | Select-Object -First 1
}
function Get-StgAppById { param([string]$AppId)
    $found = @((Get-StgGraph "applications?`$filter=appId eq '$AppId'").value)
    if ($found.Count -ne 1) { throw "entra_app_not_found: no application with appId $AppId is readable by the operator." }
    return $found[0]
}
function Resolve-StgApp {
    # entra.existing.<kind>AppId reuses a registration (changes are merged, never replaced); otherwise
    # the display name is looked up and created when absent.
    param($Cfg, [string]$Kind, [switch]$Apply)
    $id = ($Cfg.entra.existing ?? @{})["${Kind}AppId"]
    if ($id) { $a = Get-StgAppById $id; Write-Host "reuse existing $Kind application '$($a.displayName)' ($($a.appId))"; return $a }
    return New-StgApp $Cfg.entra["${Kind}AppDisplayName"] -Apply:$Apply
}
# The leading comma keeps a one-item list an array (PowerShell unrolls function output); Graph needs arrays.
function Join-StgUnique { param([object[]]$Current, [object[]]$Add) return , @(@($Current) + @($Add) | Where-Object { $_ } | Select-Object -Unique) }
function Merge-StgPreauthorized {
    # Keeps every other client's entry; adds the scope to each listed client.
    param($App, [string[]]$ClientIds, [string]$ScopeId)
    $list = [Collections.Generic.List[object]]::new()
    foreach ($p in @($App.api.preAuthorizedApplications)) { if ($p) { $list.Add(@{ appId = $p.appId; delegatedPermissionIds = @($p.delegatedPermissionIds) }) } }
    foreach ($cid in $ClientIds) {
        $e = @($list | Where-Object { $_.appId -ieq $cid })[0]
        if ($e) { $e.delegatedPermissionIds = Join-StgUnique $e.delegatedPermissionIds @($ScopeId) } else { $list.Add(@{ appId = $cid; delegatedPermissionIds = @($ScopeId) }) }
    }
    return , @($list)
}
function New-StgApp { param([string]$DisplayName, [switch]$Apply)
    $app = Get-StgApp $DisplayName
    if ($app) { Write-Host "reuse application '$DisplayName' ($($app.appId))"; return $app }
    if (-not $Apply) { Write-Host "preview: create application '$DisplayName' (single tenant)"; return $null }
    $null = Send-StgGraph 'post' 'applications' @{ displayName = $DisplayName; signInAudience = 'AzureADMyOrg' }
    for ($i = 0; $i -lt 10 -and -not $app; $i++) { Start-Sleep 3; $app = Get-StgApp $DisplayName }
    Write-Host "created application '$DisplayName' ($($app.appId))"
    return $app
}
function Get-StgServicePrincipal { param([string]$AppId, [switch]$Apply)
    $sp = @((Get-StgGraph "servicePrincipals?`$filter=appId eq '$AppId'").value) | Select-Object -First 1
    if (-not $sp -and $Apply) { $sp = Send-StgGraph 'post' 'servicePrincipals' @{ appId = $AppId } }
    return $sp
}
function Set-StgScope { param($App, [string]$Value, [string]$Type, [string]$Text)
    $scope = @($App.api.oauth2PermissionScopes | Where-Object { $_.value -ceq $Value }) | Select-Object -First 1
    $id = if ($scope) { $scope.id } else { [guid]::NewGuid().ToString() }
    $others = @($App.api.oauth2PermissionScopes | Where-Object { $_.value -cne $Value })
    return @{ id = $id; scopes = @($others) + @(@{ id = $id; value = $Value; type = $Type; isEnabled = $true; adminConsentDisplayName = $Text; adminConsentDescription = $Text; userConsentDisplayName = $Text; userConsentDescription = $Text }) }
}

function Invoke-Stage5 {
    param($Cfg, [switch]$Apply)
    $e = $Cfg.entra; $s1 = Get-StgStage $Cfg 1
    $me = Get-StgGraph 'me?$select=id'
    $resolve = { param($x) if ($x -ceq '@me') { $me.id } else { $x } }
    # Gateway API + developer sign-in (one application, ADR-0009 single-app contract).
    $gw = Resolve-StgApp $Cfg 'gateway' -Apply:$Apply
    $res = Resolve-StgApp $Cfg 'resolver' -Apply:$Apply
    $adm = if ($Cfg.stage1.includeAdmin) { Resolve-StgApp $Cfg 'admin' -Apply:$Apply }
    if (-not $Apply) {
        Write-Host ('preview: gateway app: api://<appId>, access_as_user, v2 tokens, public client (localhost, WAM), self preauthorized' + $(if ($e.allowAzureCliClient) { ' and Azure CLI' } else { '' }))
        Write-Host 'preview: resolver app: api://<appId>, v2 tokens, no redirects or secrets'
        if ($Cfg.stage1.includeAdmin) { Write-Host 'preview: admin app: Projects.Manage scope, CCOF.Projects.Read/Write roles, SPA redirects /api/console and /api/console-v3, assignment required' }
        foreach ($g in $Cfg.groups) { Write-Host "preview: group $($g.projectId)/$($g.classification): $(if ($g.groupId) { "use $($g.groupId)" } else { "create or reuse '$($g.groupDisplayName)'" }), members $(@($g.members) -join ',')" }
        Write-Host 'not done here: Microsoft Graph application permission for the sync identity (sync.mode delegated-snapshot needs none); a Privileged Role Administrator runs infra/quickstart/Grant-SyncGraphPermissions.ps1 if approved.'
        return $null
    }
    $gwScope = Set-StgScope $gw 'access_as_user' 'User' 'Access the Claude gateway as the signed-in user'
    $clients = @($gw.appId) + $(if ($e.allowAzureCliClient) { @($script:AzureCliClientId) } else { @() })
    $null = Send-StgGraph 'patch' "applications/$($gw.id)" @{
        identifierUris = (Join-StgUnique $gw.identifierUris @("api://$($gw.appId)")); isFallbackPublicClient = $true
        api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = $gwScope.scopes }
        publicClient = @{ redirectUris = (Join-StgUnique $gw.publicClient.redirectUris @('http://localhost', "ms-appx-web://microsoft.aad.brokerplugin/$($gw.appId)")) } }
    $null = Send-StgGraph 'patch' "applications/$($gw.id)" @{ api = @{ preAuthorizedApplications = (Merge-StgPreauthorized $gw $clients $gwScope.id) } }
    $null = Send-StgGraph 'patch' "applications/$($res.id)" @{ identifierUris = (Join-StgUnique $res.identifierUris @("api://$($res.appId)")); api = @{ requestedAccessTokenVersion = 2 } }
    $gwSp = Get-StgServicePrincipal $gw.appId -Apply; $resSp = Get-StgServicePrincipal $res.appId -Apply
    $registrations = @{ gatewayApi = @{ appId = $gw.appId; scope = 'access_as_user'; accessTokenVersion = 2 }; developerSignIn = @{ appId = $gw.appId }; resolverApi = @{ appId = $res.appId } }
    $admin = @{}
    if ($adm) {
        $adm = Get-StgAppById $adm.appId
        $scope = Set-StgScope $adm 'Projects.Manage' 'Admin' 'Manage CCOF projects'
        $roles = @($adm.appRoles)
        foreach ($r in @(@{ v = 'CCOF.Projects.Read'; n = 'CCOF project reader' }, @{ v = 'CCOF.Projects.Write'; n = 'CCOF project editor' })) {
            if (-not ($roles | Where-Object { $_.value -ceq $r.v })) { $roles += @{ id = [guid]::NewGuid().ToString(); value = $r.v; displayName = $r.n; description = $r.n; allowedMemberTypes = @('User'); isEnabled = $true } }
        }
        $hostName = "$($s1.names.apps.admin.functionApp).azurewebsites.net"
        $null = Send-StgGraph 'patch' "applications/$($adm.id)" @{ identifierUris = (Join-StgUnique $adm.identifierUris @("api://$($adm.appId)")); appRoles = $roles
            api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = $scope.scopes }
            spa = @{ redirectUris = (Join-StgUnique $adm.spa.redirectUris @("https://$hostName/api/console", "https://$hostName/api/console-v3")) } }
        $null = Send-StgGraph 'patch' "applications/$($adm.id)" @{ api = @{ preAuthorizedApplications = (Merge-StgPreauthorized $adm @($adm.appId) $scope.id) } }
        $admSp = Get-StgServicePrincipal $adm.appId -Apply
        $null = Send-StgGraph 'patch' "servicePrincipals/$($admSp.id)" @{ appRoleAssignmentRequired = $true }
        $adm = Get-StgAppById $adm.appId
        $assigned = @((Get-StgGraph "servicePrincipals/$($admSp.id)/appRoleAssignedTo").value)
        foreach ($pair in @(@{ ids = $e.adminEditors; role = 'CCOF.Projects.Write' }, @{ ids = $e.adminReaders; role = 'CCOF.Projects.Read' })) {
            $roleId = @($adm.appRoles | Where-Object { $_.value -ceq $pair.role })[0].id
            foreach ($u in @($pair.ids | Where-Object { $_ })) {
                $uid = & $resolve $u
                if (-not ($assigned | Where-Object { $_.principalId -ieq $uid -and $_.appRoleId -ieq $roleId })) {
                    $null = Send-StgGraph 'post' "servicePrincipals/$($admSp.id)/appRoleAssignedTo" @{ principalId = $uid; resourceId = $admSp.id; appRoleId = $roleId }
                }
            }
        }
        $admin = @{ appId = $adm.appId; servicePrincipalId = $admSp.id; redirects = @("https://$hostName/api/console", "https://$hostName/api/console-v3") }
    }
    $groups = @{}
    foreach ($g in $Cfg.groups) {
        $key = "$($g.projectId)/$($g.classification)"
        $grp = if ($g.groupId) { Get-StgGraph "groups/$($g.groupId)?`$select=id,displayName,securityEnabled" }
               else { @((Get-StgGraph "groups?`$filter=displayName eq '$($g.groupDisplayName)'").value) | Select-Object -First 1 }
        if (-not $grp) {
            $nick = ($g.groupDisplayName -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
            $grp = Send-StgGraph 'post' 'groups' @{ displayName = $g.groupDisplayName; mailEnabled = $false; mailNickname = $nick; securityEnabled = $true; description = "CCOF $key access group" }
            Write-Host "created group $($g.groupDisplayName) ($($grp.id))"
        }
        $members = @((Get-StgGraph "groups/$($grp.id)/members?`$select=id").value | ForEach-Object { $_.id })
        foreach ($m in @($g.members | Where-Object { $_ })) {
            $uid = & $resolve $m
            if ($members -notcontains $uid) { $null = Send-StgGraph 'post' "groups/$($grp.id)/members/`$ref" @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$uid" } }
        }
        $groups[$key] = @{ id = $grp.id; displayName = $grp.displayName; members = @((Get-StgGraph "groups/$($grp.id)/members?`$select=id").value | ForEach-Object { $_.id }) }
    }
    # Verify.
    $gwNow = Get-StgAppById $gw.appId
    Assert-Stg (@($gwNow.identifierUris) -contains "api://$($gw.appId)") 'gateway identifier URI missing'
    Assert-Stg ($gwNow.api.requestedAccessTokenVersion -eq 2) 'gateway tokens are not v2'
    Assert-Stg (@($gwNow.api.oauth2PermissionScopes | Where-Object { $_.value -ceq 'access_as_user' -and $_.isEnabled }).Count -eq 1) 'access_as_user scope missing'
    $result = @{ registrations = $registrations; gatewayIdentifierUri = "api://$($gw.appId)"; gatewayServicePrincipalId = $gwSp.id
        resolverServicePrincipalId = $resSp.id; admin = $admin; groups = $groups; azureCliClientAllowed = [bool]$e.allowAzureCliClient
        graphApplicationPermission = 'not granted (sync.mode delegated-snapshot)' }
    $null = Write-StgEvidence 'stage5.verify.json' $result
    return $result
}
