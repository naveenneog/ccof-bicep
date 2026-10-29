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
function Test-StgHasAll { param([object[]]$Current, [object[]]$Want) return -not @($Want | Where-Object { @($Current) -notcontains $_ }).Count }
function Test-StgPreauthorized { param($App, [string[]]$ClientIds, [string]$ScopeId)
    foreach ($cid in $ClientIds) { if (-not @($App.api.preAuthorizedApplications | Where-Object { $_.appId -ieq $cid -and @($_.delegatedPermissionIds) -contains $ScopeId }).Count) { return $false } }
    return $true
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

function Invoke-StgStage4Manual {
    param($Cfg, $Stage1, [switch]$Apply)
    $e = $Cfg.entra
    $problems = @(Get-StgManualEntraProblems $Cfg)
    if ($problems.Count) { throw "manual_verification: $($problems -join '; ')" }
    $gwId = $e.existing.gatewayAppId; $resId = $e.existing.resolverAppId; $admId = $e.existing.adminAppId
    $hostName = "$($Stage1.names.apps.admin.functionApp).azurewebsites.net"
    $cli = $script:AzureCliClientId
    $gwRedirects = @("ms-appx-web://microsoft.aad.brokerplugin/$gwId") + $(if ($e.browserSignIn -ne $false) { @('http://localhost') } else { @() })
    $check = [Collections.Generic.List[string]]::new()
    $check.Add("gateway app $gwId - Expose an API: Application ID URI api://$gwId; scope access_as_user enabled; authorized client applications $gwId" + $(if ($e.allowAzureCliClient) { " and $cli (Azure CLI)" } else { '' }) + ' for access_as_user')
    $check.Add("gateway app $gwId - Authentication: Mobile and desktop redirect URIs $($gwRedirects -join ', '); Allow public client flows Yes. Manifest: requestedAccessTokenVersion 2")
    $check.Add("resolver app $resId - Expose an API: Application ID URI api://$resId. Manifest: requestedAccessTokenVersion 2")
    if ($Cfg.stage1.includeAdmin) {
        $adminClients = @($admId) + @($Cfg.admin.extraAllowedClientIds | Where-Object { $_ -match $script:Guid })
        $check.Add("admin app $admId - Expose an API: Application ID URI api://$admId; scope Projects.Manage; authorized client applications $($adminClients -join ', ') for Projects.Manage")
        $check.Add("admin app $admId - App roles CCOF.Projects.Read and CCOF.Projects.Write (Users/Groups). Authentication: Single-page application redirect URIs https://$hostName/api/console and https://$hostName/api/console-v3. Manifest: requestedAccessTokenVersion 2")
        $check.Add("admin enterprise application $admId - Properties: Assignment required Yes; Users and groups: console editors CCOF project editor, readers CCOF project reader")
    }
    foreach ($g in $Cfg.groups) { $check.Add("group $($g.projectId)/$($g.classification) $($g.groupId) - security group exists; group owners manage its direct members") }
    Write-Host "Stage 4 manual verification (no Microsoft Graph call). Confirmed by $($e.manualVerification.confirmedBy) on $($e.manualVerification.confirmedOn). Settings to confirm in the Entra admin center:"
    foreach ($c in $check) { Write-Host "  - $c" }
    if (-not $Apply) { return $null }
    $groups = @{}
    foreach ($g in $Cfg.groups) {
        $groups["$($g.projectId)/$($g.classification)"] = @{ id = $g.groupId; displayName = $(if ($g.groupDisplayName) { $g.groupDisplayName } else { $null }); members = @() }
    }
    $admin = if ($Cfg.stage1.includeAdmin) { @{ appId = $admId; servicePrincipalId = $null; redirects = @("https://$hostName/api/console", "https://$hostName/api/console-v3") } } else { @{} }
    $result = @{
        registrations = @{ gatewayApi = @{ appId = $gwId; scope = 'access_as_user'; accessTokenVersion = 2 }; developerSignIn = @{ appId = $gwId }; resolverApi = @{ appId = $resId } }
        gatewayIdentifierUri = "api://$gwId"; gatewayServicePrincipalId = $null; resolverServicePrincipalId = $null
        admin = $admin; groups = $groups; azureCliClientAllowed = [bool]$e.allowAzureCliClient
        verification = 'manual'; manualVerification = @{ confirmedBy = $e.manualVerification.confirmedBy; confirmedOn = $e.manualVerification.confirmedOn; checklist = @($check) }
        graphApplicationPermission = 'not read (entra.manualVerification)' }
    $null = Write-StgEvidence 'stage4.verify.json' $result
    return $result
}

function Invoke-Stage4 {
    param($Cfg, [switch]$Apply)
    $e = $Cfg.entra; $s1 = Get-StgStage $Cfg 1
    if ($e -is [Collections.IDictionary] -and $e.Contains('manualVerification')) { return Invoke-StgStage4Manual -Cfg $Cfg -Stage1 $s1 -Apply:$Apply }
    $me = Get-StgGraph 'me?$select=id'
    $resolve = { param($x) if ($x -ceq '@me') { $me.id } else { $x } }
    # Gateway API + developer sign-in (one application, ADR-0009 single-app contract).
    $gw = Resolve-StgApp $Cfg 'gateway' -Apply:$Apply
    $res = Resolve-StgApp $Cfg 'resolver' -Apply:$Apply
    $adm = if ($Cfg.stage1.includeAdmin) { Resolve-StgApp $Cfg 'admin' -Apply:$Apply }
    if (-not $Apply) {
        Write-Host ('preview: gateway app: api://<appId>, access_as_user, v2 tokens, public client (' + $(if ($e.browserSignIn -ne $false) { 'localhost, WAM' } else { 'WAM only; entra.browserSignIn false' }) + '), self preauthorized' + $(if ($e.allowAzureCliClient) { ' and Azure CLI' } else { '' }))
        Write-Host 'preview: resolver app: api://<appId>, v2 tokens, no redirects or secrets'
        if ($Cfg.stage1.includeAdmin) { Write-Host ('preview: admin app: Projects.Manage scope, CCOF.Projects.Read/Write roles, SPA redirects /api/console and /api/console-v3, assignment required, self preauthorized' + $(if (@($Cfg.admin.extraAllowedClientIds).Count) { " and $(@($Cfg.admin.extraAllowedClientIds) -join ', ')" } else { '' })) }
        foreach ($g in $Cfg.groups) { Write-Host "preview: group $($g.projectId)/$($g.classification): $(if ($g.groupId) { "use $($g.groupId)" } else { "create or reuse '$($g.groupDisplayName)'" }), members $(@($g.members) -join ',')" }
        Write-Host 'not done here: Microsoft Graph application permission for the sync identity (sync.mode delegated-snapshot needs none); a Privileged Role Administrator runs infra/quickstart/Grant-SyncGraphPermissions.ps1 if approved.'
        return $null
    }
    $gwScope = Set-StgScope $gw 'access_as_user' 'User' 'Access the Claude gateway as the signed-in user'
    $clients = @($gw.appId) + $(if ($e.allowAzureCliClient) { @($script:AzureCliClientId) } else { @() })
    # Each change is sent only when a required setting is missing, so registrations an Entra administrator
    # has configured (for example by hand in the Portal) are verified by an operator who cannot write them.
    $gwRedirects = @("ms-appx-web://microsoft.aad.brokerplugin/$($gw.appId)") + $(if ($e.browserSignIn -ne $false) { @('http://localhost') } else { @() })
    $gwExisting = @($gw.api.oauth2PermissionScopes | Where-Object { $_.value -ceq 'access_as_user' -and $_.isEnabled })
    if ((Test-StgHasAll $gw.identifierUris @("api://$($gw.appId)")) -and $gw.isFallbackPublicClient -eq $true -and $gw.api.requestedAccessTokenVersion -eq 2 -and
        $gwExisting.Count -eq 1 -and (Test-StgHasAll $gw.publicClient.redirectUris $gwRedirects)) { Write-Host 'gateway app: identifier URI, scope, v2 tokens, public client redirects already set' }
    else {
        $null = Send-StgGraph 'patch' "applications/$($gw.id)" @{
            identifierUris = (Join-StgUnique $gw.identifierUris @("api://$($gw.appId)")); isFallbackPublicClient = $true
            api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = $gwScope.scopes }
            publicClient = @{ redirectUris = (Join-StgUnique $gw.publicClient.redirectUris $gwRedirects) } }
        $gw = Get-StgAppById $gw.appId
    }
    if (Test-StgPreauthorized $gw $clients $gwScope.id) { Write-Host 'gateway app: clients already preauthorized' }
    else { $null = Send-StgGraph 'patch' "applications/$($gw.id)" @{ api = @{ preAuthorizedApplications = (Merge-StgPreauthorized $gw $clients $gwScope.id) } } }
    if ((Test-StgHasAll $res.identifierUris @("api://$($res.appId)")) -and $res.api.requestedAccessTokenVersion -eq 2) { Write-Host 'resolver app: identifier URI and v2 tokens already set' }
    else { $null = Send-StgGraph 'patch' "applications/$($res.id)" @{ identifierUris = (Join-StgUnique $res.identifierUris @("api://$($res.appId)")); api = @{ requestedAccessTokenVersion = 2 } } }
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
        $admRedirects = @("https://$hostName/api/console", "https://$hostName/api/console-v3")
        $roleNames = @($adm.appRoles | Where-Object { $_.isEnabled } | ForEach-Object { $_.value })
        if ((Test-StgHasAll $adm.identifierUris @("api://$($adm.appId)")) -and $adm.api.requestedAccessTokenVersion -eq 2 -and
            @($adm.api.oauth2PermissionScopes | Where-Object { $_.value -ceq 'Projects.Manage' -and $_.isEnabled }).Count -eq 1 -and
            (Test-StgHasAll $roleNames @('CCOF.Projects.Read', 'CCOF.Projects.Write')) -and (Test-StgHasAll $adm.spa.redirectUris $admRedirects)) {
            Write-Host 'admin app: identifier URI, scope, app roles, v2 tokens, SPA redirects already set'
        } else {
            $null = Send-StgGraph 'patch' "applications/$($adm.id)" @{ identifierUris = (Join-StgUnique $adm.identifierUris @("api://$($adm.appId)")); appRoles = $roles
                api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = $scope.scopes }
                spa = @{ redirectUris = (Join-StgUnique $adm.spa.redirectUris $admRedirects) } }
            $adm = Get-StgAppById $adm.appId
            $scope = Set-StgScope $adm 'Projects.Manage' 'Admin' 'Manage CCOF projects'
        }
        # ADMIN_ALLOWED_CLIENT_IDS also lists admin.extraAllowedClientIds (Staged.Application.ps1); without
        # preauthorization those clients cannot get a token without a consent prompt (AADSTS65001).
        $adminClients = @($adm.appId) + @($Cfg.admin.extraAllowedClientIds | Where-Object { $_ -match $script:Guid })
        if (Test-StgPreauthorized $adm $adminClients $scope.id) { Write-Host 'admin app: clients already preauthorized' }
        else { $null = Send-StgGraph 'patch' "applications/$($adm.id)" @{ api = @{ preAuthorizedApplications = (Merge-StgPreauthorized $adm $adminClients $scope.id) } } }
        $admSp = Get-StgServicePrincipal $adm.appId -Apply
        if ($admSp.appRoleAssignmentRequired -eq $true) { Write-Host 'admin enterprise application: assignment already required' }
        else { $null = Send-StgGraph 'patch' "servicePrincipals/$($admSp.id)" @{ appRoleAssignmentRequired = $true } }
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
    if ($adm) {
        $admNow = Get-StgAppById $adm.appId
        $admScopeId = @($admNow.api.oauth2PermissionScopes | Where-Object { $_.value -ceq 'Projects.Manage' })[0].id
        foreach ($cid in $adminClients) {
            Assert-Stg (@($admNow.api.preAuthorizedApplications | Where-Object { $_.appId -ieq $cid -and @($_.delegatedPermissionIds) -contains $admScopeId }).Count -eq 1) "admin app does not preauthorize client $cid for Projects.Manage"
        }
    }
    $result = @{ registrations = $registrations; gatewayIdentifierUri = "api://$($gw.appId)"; gatewayServicePrincipalId = $gwSp.id
        resolverServicePrincipalId = $resSp.id; admin = $admin; groups = $groups; azureCliClientAllowed = [bool]$e.allowAzureCliClient
        graphApplicationPermission = 'not granted (sync.mode delegated-snapshot)' }
    $null = Write-StgEvidence 'stage4.verify.json' $result
    return $result
}
