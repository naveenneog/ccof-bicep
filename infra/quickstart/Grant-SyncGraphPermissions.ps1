#Requires -Version 7.0
<#
.SYNOPSIS
    Quick-start phase 3, post-deployment (ADR-0024, Proposed; docs/QUICKSTART.md): grants the sync's
    managed identity the Microsoft Graph application permissions it needs: GroupMember.Read.All
    (read the direct members of the registered groups) and User.Read.All plus Application.Read.All
    (see disabled and deleted members; docs/SYNC.md, "Deleted and disabled members").

.DESCRIPTION
    Run by a Privileged Role Administrator (activated through PIM for the task) or a Global
    Administrator, possibly another person, any time after Deploy-Quickstart.ps1 step 3. It:
    1. reads the sync principal id (-SyncPrincipalId, or the quick-start state file's step 3 outputs);
    2. refuses unless the signed-in account holds an active Privileged Role Administrator or Global
       Administrator role, and prints the PIM activation steps (docs/DEPLOYMENT-GUIDE.md, Step 7b);
    3. resolves each permission's app role id from the Microsoft Graph service principal by value;
    4. skips an assignment that exists, posts the others with a body file (no quotes in az arguments);
    5. reads the assignments back (Step 7c) and prints the rollback (DELETE) for each.
    Until it runs, the sync reports that it cannot read the groups; or the administrator uses
    sync.mode delegated-snapshot (docs/SYNC.md), which needs no application permission.
    Then set syncTimerEnabled = true in the parameters file and run Deploy-Quickstart.ps1 -Only 3
    (the template alone; the code and the seed stay as they are).
#>
[CmdletBinding()]
param(
    [string]$SyncPrincipalId,
    [string]$StatePath = (Join-Path $PSScriptRoot '.env.quickstart.state.json'),
    [string[]]$Permissions = @('GroupMember.Read.All', 'User.Read.All', 'Application.Read.All'),
    [switch]$PlanOnly,
    [switch]$DotSourceOnly
)

$script:GraphAppId = '00000003-0000-0000-c000-000000000000'
# Directory role template ids: Privileged Role Administrator and Global Administrator (Learn,
# "Microsoft Entra built-in roles", retrieved 2026-10-13).
$script:AllowedRoles = @{ 'e8611ab8-c189-46e8-94e1-60213ab1f814' = 'Privileged Role Administrator'; '62e90394-69f5-4237-9190-012177145e10' = 'Global Administrator' }

function Invoke-QsGraph {
    param([string]$Method, [string]$Path, $Body)
    $arguments = @('rest', '--method', $Method, '--url', "https://graph.microsoft.com/v1.0/$Path", '--only-show-errors')
    $file = $null
    if ($null -ne $Body) {
        $file = Join-Path ([System.IO.Path]::GetTempPath()) "ccof-qs-graph-$([guid]::NewGuid()).json"
        $Body | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath $file -Encoding utf8NoBOM
        $arguments += @('--headers', 'Content-Type=application/json', '--body', "@$file")
    }
    try {
        $out = az @arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Graph $Method $($Path.Split('?')[0]) failed: $(@($out) -join ' ')" }
        $text = @($out | Where-Object { $_ -is [string] }) -join "`n"
        if ($text.Trim()) { return $text | ConvertFrom-Json -AsHashtable -Depth 50 }
    }
    finally { if ($file) { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue } }
}

function Get-QsActiveAdminRole {
    $roles = @((Invoke-QsGraph 'get' 'me/transitiveMemberOf/microsoft.graph.directoryRole?$select=roleTemplateId,displayName').value)
    return @($roles | Where-Object { $script:AllowedRoles.Contains([string]$_.roleTemplateId) } | ForEach-Object { $script:AllowedRoles[[string]$_.roleTemplateId] })
}

function Get-QsPlan {
    param([string]$PrincipalId, [string[]]$Names)
    $graph = @((Invoke-QsGraph 'get' "servicePrincipals?`$filter=appId eq '$script:GraphAppId'&`$select=id,appRoles").value)[0]
    if (-not $graph) { throw 'graph_service_principal_missing: Microsoft Graph has no service principal in this tenant.' }
    $existing = @((Invoke-QsGraph 'get' "servicePrincipals/$PrincipalId/appRoleAssignments").value)
    foreach ($name in $Names) {
        $role = @($graph.appRoles | Where-Object { $_.value -ceq $name -and @($_.allowedMemberTypes) -contains 'Application' })[0]
        if (-not $role) { throw "app_role_missing: Microsoft Graph has no application permission $name." }
        $held = @($existing | Where-Object { $_.appRoleId -eq $role.id -and $_.resourceId -eq $graph.id })[0]
        [pscustomobject]@{ Permission = $name; AppRoleId = $role.id; ResourceId = $graph.id; AssignmentId = $(if ($held) { $held.id }) }
    }
}

if ($DotSourceOnly) { return }
$ErrorActionPreference = 'Stop'
if (-not $SyncPrincipalId) {
    if (-not (Test-Path -LiteralPath $StatePath)) { throw "no_principal: pass -SyncPrincipalId, or run Deploy-Quickstart.ps1 to step 3 first (state file $StatePath)." }
    $SyncPrincipalId = (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable).completed['3'].outputs.syncPrincipalId
}
if ($SyncPrincipalId -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { throw 'no_principal: the sync principal id is not a GUID.' }

$plan = @(Get-QsPlan -PrincipalId $SyncPrincipalId -Names $Permissions)
$plan | ForEach-Object { Write-Host "$($_.Permission): $(if ($_.AssignmentId) { 'already granted, skipped' } else { 'to grant' })" }
if ($PlanOnly) { return }
$active = @(Get-QsActiveAdminRole)
if (-not $active.Count -and @($plan | Where-Object { -not $_.AssignmentId }).Count) {
    Write-Host 'REFUSED: the signed-in account holds no active Privileged Role Administrator or Global Administrator role. Nothing was changed.' -ForegroundColor Red
    Write-Host '  1. Entra admin center > ID Governance > Privileged Identity Management > My roles > Microsoft Entra roles > Eligible assignments > Activate Privileged Role Administrator, with a reason.'
    Write-Host '  2. Sign in again (az logout; az login --tenant <tenant id>): a session keeps the role state it started with.'
    Write-Host '  3. Run this script again.'
    exit 2
}
foreach ($item in $plan | Where-Object { -not $_.AssignmentId }) {
    $null = Invoke-QsGraph 'post' "servicePrincipals/$SyncPrincipalId/appRoleAssignments" @{ principalId = $SyncPrincipalId; resourceId = $item.ResourceId; appRoleId = $item.AppRoleId }
}
$verified = @(Get-QsPlan -PrincipalId $SyncPrincipalId -Names $Permissions)
$missing = @($verified | Where-Object { -not $_.AssignmentId })
foreach ($v in $verified | Where-Object { $_.AssignmentId }) {
    Write-Host "verified $($v.Permission). Rollback: az rest --method delete --url https://graph.microsoft.com/v1.0/servicePrincipals/$SyncPrincipalId/appRoleAssignments/$($v.AssignmentId)"
}
if ($missing.Count) { throw "not_verified: $($missing.Permission -join ', ') not found after the grant." }
Write-Host 'Next: set syncTimerEnabled = true in the parameters file and run Deploy-Quickstart.ps1 -Only 3 (the template alone; the code and the seed stay as they are). Managed identity tokens are cached for up to 24 hours (docs/DEPLOYMENT-GUIDE.md, Step 7).'
