# Admin V3.1 and V3.2 upgrade from a Windows VDI

This upgrades the existing **admin Function App only** to version **3.1.0**. Resolver, sync,
reconciler, APIM policies, project records and enforcement are unchanged. Nothing here runs the
staged-deployment driver. V2 remains at `/api/console`; V3 is `/api/console-v3`.

Sections 1-8 cover 3.1.0. [Section 9](#9-upgrade-to-320-retirement-removal-limits-change-record)
covers 3.2.0, which also updates the **sync** app, one sync Cosmos grant and one sync setting.

## What changes

V3 shows the current Entra display name and user principal name beside the full object ID in
Chargeback developers, Budgets people, Reconciler snapshots, Audit and Project Activity. Overview
shows the display name and full ID. Filters and links still use object IDs. The Chargeback Developers CSV keeps the object ID and adds `displayName`, `userPrincipalName` and `nameLookup` columns.

Names come from Microsoft Graph, not from the request ledger. A renamed user's current name can
therefore appear on older usage. Deleted users and non-user objects keep their IDs with
"No directory user". A lookup failure shows its state without removing cost or budget figures.
Names are cached in bounded memory for up to five minutes, not written to Cosmos or telemetry.

## 1. Prerequisites and permissions

The VDI/build host needs PowerShell 7, Git, Node 22.18+ and npm for a source build, and a recent
Azure CLI. A supplied, approved ZIP does not require a local Node build. The VDI needs access to
the admin site and its publishing endpoint, including private DNS/routing where applicable.
The admin app needs outbound HTTPS to `graph.microsoft.com`. No public network access is enabled
by this upgrade.

| Identity | Permission / configuration | New for this upgrade? | Where it is set |
| --- | --- | --- | --- |
| Admin Function App managed identity | Microsoft Graph **application** `User.Read.All`, tenant admin consent | **Yes, required for names** | Entra service principal of the existing admin identity; section 2 |
| Entra administrator | Active Privileged Role Administrator or Global Administrator and permission to run the Graph commands | Needed to grant the above application permission | PIM / Entra; no directory role is assigned to the app itself |
| Deployment operator | Existing publish and configuration rights on the **admin app only** | Usually already held | Azure IAM; Website Contributor on that app or an approved equivalent |
| Admin users | Existing `CCOF.Projects.Read` / `CCOF.Projects.Write` app-role assignments | No new user roles or scopes | Existing CCOF Admin Enterprise Application |
| Admin managed identity | Existing Cosmos project/config data roles | No change for names | Existing Cosmos data-plane assignments |
| Admin managed identity | Log Analytics Reader on gateway/reconciler workspaces and the admin audit workspace | Existing V2/V3 integration requirement; add only if missing | Workspace > Access control (IAM) > Add role assignment > Log Analytics Reader > Managed identity > select the admin Function App |
| Admin app registration | SPA redirect `https://<admin-host>/api/console-v3` | Add if upgrading from V2 | App registrations > CCOF Admin > Authentication > Single-page application |

`User.Read.All` is granted to the **admin managed identity**, not the CCOF Admin SPA registration,
APIM, sync or reconciler identity. `GroupMember.Read.All` alone does not satisfy the user-lookup
API. No `Directory.Read.All`, Graph write permission, client secret or new app registration is
needed. An existing `User.Read.All` grant on a different managed identity does not transfer.

## 2. Grant the Graph permission manually

### Identify the exact managed identity

In Azure Portal, open the existing **admin Function App > Settings > Identity > System assigned**.
Record its **Object (principal) ID** and confirm the identity is already On. Do not turn it off
and on: that replaces its identity and invalidates existing role assignments.

If the admin app uses a user-assigned identity through `ADMIN_MANAGED_IDENTITY_CLIENT_ID`, select
that assigned identity instead. Its **principal ID**, not its application/client ID, is used below.

Managed identities do not have the normal app registration's "Add a permission" workflow. The
Entra administrator grants the application permission to its service principal using Graph.
This operation grants one permission and does not deploy or change any Function App.

### Entra administrator: PowerShell 7

The administrator can run this on their own approved workstation; it need not be the publishing
VDI. If Microsoft Graph PowerShell is not installed:

```powershell
Install-Module Microsoft.Graph.Applications -Scope CurrentUser
```

After activating the approved Entra role:

```powershell
$ErrorActionPreference = 'Stop'
$tenantId = 'REPLACE-tenant-guid'
$adminPrincipalId = 'REPLACE-admin-managed-identity-principal-guid'
if ($tenantId -notmatch '^[0-9a-fA-F-]{36}$' -or
    $adminPrincipalId -notmatch '^[0-9a-fA-F-]{36}$') {
    throw 'Replace tenantId and adminPrincipalId with the approved GUIDs.'
}
Connect-MgGraph -TenantId $tenantId `
    -Scopes 'Application.Read.All','AppRoleAssignment.ReadWrite.All' -NoWelcome
if ((Get-MgContext).TenantId -ine $tenantId) { throw 'Wrong Graph tenant.' }
$identity = Get-MgServicePrincipal -ServicePrincipalId $adminPrincipalId `
    -Property Id,DisplayName,ServicePrincipalType
if ($identity.ServicePrincipalType -ne 'ManagedIdentity') {
    throw 'The selected principal is not a managed identity.'
}
$identity | Select-Object Id,DisplayName,ServicePrincipalType
# Verify that the displayed identity is the existing ADMIN app identity before continuing.
$graph = @(Get-MgServicePrincipal `
    -Filter "appId eq '00000003-0000-0000-c000-000000000000'" -Property Id,AppRoles)
if ($graph.Count -ne 1) { throw 'Exactly one Microsoft Graph service principal is required.' }
$role = @($graph[0].AppRoles | Where-Object {
    $_.Value -ceq 'User.Read.All' -and $_.IsEnabled -and
    $_.AllowedMemberTypes -contains 'Application'
})
if ($role.Count -ne 1) { throw 'Graph User.Read.All application role not found.' }
$held = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $identity.Id -All |
    Where-Object { $_.ResourceId -eq $graph[0].Id -and $_.AppRoleId -eq $role[0].Id })
if ($held.Count -eq 0) {
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $identity.Id `
        -PrincipalId $identity.Id -ResourceId $graph[0].Id -AppRoleId $role[0].Id
}
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $identity.Id -All |
    Where-Object { $_.ResourceId -eq $graph[0].Id -and $_.AppRoleId -eq $role[0].Id } |
    Select-Object PrincipalId,ResourceId,AppRoleId
Disconnect-MgGraph
```

This creates the Microsoft Graph app-role assignment on the managed identity. Azure subscription
Owner is not a substitute for the Entra administrator's grant. In Entra Portal, **Enterprise
applications > Application type: Managed Identities > the admin identity > Permissions** shows
the resulting permission. Managed-identity tokens can remain cached after permission changes;
allow propagation, then sign in to V3 again and retry. A restart is not a guaranteed token-cache
flush.

## 3. Retain rollback material and build the admin ZIP

Keep the currently deployed admin ZIP and its SHA-256, the source commit, and a private record of
the existing admin app settings. App settings can contain sensitive values; do not put backups in
the repository or attach them to email. Retain the two existing SPA redirects.

Use an approved release archive or commit that includes **admin version 3.1.0**. Older `main`
or a previously downloaded 3.0.0 archive does not include name lookup. A source commit must be
published/shared before a customer can fetch it.

The implementation is on branch `feat/admin-console-v2` and in `main`. The tested local `ccof-admin-v3.1.0.zip` has SHA-256
`f25438c857b7058ec9bdc8b55c48491dc9d33b2e7f27fa1e0ce472a90e857554`; rebuilding produces a
different archive hash, so a shared ZIP is checked against its own recorded release hash.

From the VDI, in a clean approved source checkout:

```powershell
$ErrorActionPreference = 'Stop'
Set-Location 'C:\REPLACE\ccof-bicep'
git status --short
# Continue only after preserving/resolving customer-local changes.
git rev-parse HEAD
$repo = (Get-Location).Path
$version = (Get-Content admin\package.json -Raw | ConvertFrom-Json).version
if ($version -ne '3.1.0') { throw 'This is not the approved Admin 3.1.0 source.' }
$release = Join-Path $HOME 'ccof-admin-releases'
New-Item -ItemType Directory -Force -Path $release | Out-Null
$zip = Join-Path $release 'ccof-admin-v3.1.0.zip'
& (Join-Path $repo 'admin\Build-AdminPackage.ps1') -OutFile $zip
if (-not (Test-Path -LiteralPath $zip)) { throw 'The admin package was not built.' }
Get-FileHash -LiteralPath $zip -Algorithm SHA256
```

The builder restores locked admin dependencies, runs admin tests, compiles/bundles both consoles,
and packages production dependencies plus `host.json`, `ui-dist-v3` and `kql`. It deploys nothing.
If building fails, stop rather than publishing a previously existing ZIP.

## 4. Confirm the exact target and VDI publishing path

Use a dedicated Azure CLI profile so another session cannot switch this deployment's account:

```powershell
$tenantId = 'REPLACE-tenant-guid'
$sub = 'REPLACE-workload-subscription-guid'
$rg = 'REPLACE-admin-resource-group'
$app = 'REPLACE-admin-function-app'
foreach ($value in @($tenantId, $sub, $rg, $app, $zip)) {
    if (-not $value -or $value -match '[()&|<>^"]') {
        throw 'Azure CLI arguments must be non-empty and contain no cmd.exe metacharacters.'
    }
}
$env:AZURE_CONFIG_DIR = Join-Path $HOME '.azure-ccof-admin-upgrade'
az login --tenant $tenantId
if ($LASTEXITCODE -ne 0) { throw 'Azure sign-in failed.' }
$account = az account show --subscription $sub -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $account.tenantId -ine $tenantId) { throw 'Wrong deployment tenant.' }
$site = az functionapp show --subscription $sub -g $rg -n $app -o json |
    ConvertFrom-Json
$hostName = if ($site.defaultHostName) { $site.defaultHostName } else { $site.properties.defaultHostName }
if ($LASTEXITCODE -ne 0 -or -not $hostName) {
    throw 'Admin Function App not found in the specified subscription.'
}
$site | Select-Object id,defaultHostName
$scmHost = $hostName -replace '\.azurewebsites\.net$', '.scm.azurewebsites.net'
Resolve-DnsName $hostName
Resolve-DnsName $scmHost
Test-NetConnection $scmHost -Port 443
```

The selected resource ID must be the **admin app**, not resolver, sync or reconciler. For private
hosting, site and SCM records must resolve through the VDI's private DNS path to the sites private
endpoint. Do not substitute the blob-storage private endpoint IP. Keep public access and account
key settings unchanged. Runtime admin-to-Graph egress and VDI-to-admin access are separate paths.

## 5. Publish only the admin package

```powershell
az functionapp deployment source config-zip --subscription $sub `
    --resource-group $rg --name $app --src $zip
if ($LASTEXITCODE -ne 0) { throw 'Admin publishing failed. Inspect deployment logs before retrying.' }
```

This is the Flex-compatible publishing command, not a manual ZIP upload into `wwwroot`. Do not
run `Invoke-StagedDeployment.ps1 -Stage 7` for this upgrade: that stage republishes the other apps.
Do not rerun Stage 3 or Stage 5, which apply wider grants/settings.

## 6. Configure V3 and names in the Portal

1. **App registrations > existing CCOF Admin app > Authentication > Single-page application**:
   add `https://<admin-host>/api/console-v3` if absent. Keep `/api/console` for rollback. No new
   scopes or roles are needed; keep `Projects.Manage` and the existing Read/Write assignments.
2. **Admin Function App > Settings > Environment variables > App settings**: add/update
   `ADMIN_V3_ENABLED` = `true` and `ADMIN_USER_NAMES_ENABLED` = `true`, then Apply.
3. Preserve the existing `ADMIN_TENANT_ID`, `ADMIN_AUDIENCE`, `ADMIN_UI_CLIENT_ID`,
   `ADMIN_UI_SCOPE`, `ADMIN_ALLOWED_CLIENT_IDS`, Cosmos and storage settings. They must still
   refer to the existing Admin registration and identity.
4. For V3 cost/reconciler views, review these existing integration settings:

| Setting | Value |
| --- | --- |
| `ADMIN_GATEWAY_RESOURCE_ID` | Full APIM ARM resource ID; used as the telemetry scope |
| `ADMIN_WORKSPACE_ID` | Log Analytics workspace GUID for gateway/reconciler logs |
| `ADMIN_CHARGEBACK_WORKSPACE_ID` | Only if the gateway logs use a different workspace |
| `ADMIN_LOG_RESOURCE_IDS` | Existing reconciler/admin log-source ARM IDs |
| `ADMIN_AUDIT_WORKSPACE_ID` | Only if admin audit traces are in a different workspace |
| `ADMIN_RECONCILER_RESOURCE_ID` | Existing reconciler Function App resource ID, read-only |
| `ADMIN_RECONCILER_INTERVAL_MINUTES` | Match the existing timer; do not change that timer |

No new Cosmos container or data role is required for user names. `ADMIN_GRAPH_ENABLED` controls
the separate group-search feature and does not enable user-name lookup. Group search retains its
own `GroupMember.Read.All` requirement; it is not a substitute for `User.Read.All`.

## 7. Verify from the VDI

Open `https://<admin-host>/api/console-v3` and sign in normally. The root URL should redirect to
`/api/console-v3#/overview`. Browser developer tools can show the following authenticated requests
without putting access tokens in scripts, screenshots or tickets:

| Check | Expected |
| --- | --- |
| `/api/v3/version` | `version: 3.1.0` |
| Overview user cost split / Chargeback > Developers | Current Entra name plus the original full object ID |
| Budgets > People / Reconciler snapshots | Names beside person object IDs; group rows remain groups |
| Audit / Project > Activity | Current user names beside actor IDs |
| POST `/api/v3/directory/users`, body `{"objectIds":["<known-user-guid>"]}` | `available` with matching `objectId`, display name and UPN; at most 100 GUIDs per request |
| Unknown/deleted/non-user object | ID retained with "No directory user" |
| Consent or Graph connectivity missing | ID retained with "Name lookup needs User.Read.All" or "Name unavailable"; costs and budgets still load |
| Reader account | Can view labels; cannot save project changes |
| `/api/console` | V2 still loads |

The API response is `Cache-Control: no-store`. Labels are current directory information, not a
change to past costs, membership or budget ownership. CSV exports keep the object ID as the accounting key; the Developers export adds the current name and UPN beside it.

## 8. Rollback

- Disable only names: set `ADMIN_USER_NAMES_ENABLED=false` and reload the console. IDs remain.
- Return to V2: set `ADMIN_V3_ENABLED=false`; use `/api/console`. No project-data migration is
  involved.
- Roll back code: publish the retained **admin** ZIP with the same `config-zip` command.
- If the Graph grant was newly added solely for this feature, the Entra admin can remove that
  exact `User.Read.All` app-role assignment from the admin managed identity. Do not remove other
  grants or disable the managed identity. Removing consent does not instantly revoke cached
  tokens or displayed labels.

## 9. Upgrade to 3.2.0: retirement, removal limits, change record

3.2.0 adds project retirement, removal limits edited in the console, and a permanent change record
([ADMIN-V3.md](ADMIN-V3.md), [SYNC.md](SYNC.md)). Steps 1-8 still apply, with `3.2.0` in place of
`3.1.0` in the build check and file name. The admin side needs no new permission: the change record
and the removal limits use the existing admin role on `adminConfig` (read, query, create, replace).

| Item | Who | Change |
| --- | --- | --- |
| Admin Function App | Deployment operator | Publish `ccof-admin-v3.2.0.zip` (steps 3-5) |
| Sync Function App | Deployment operator | Publish the 3.2.0 sync package; without it a retired project is only frozen and the override is ignored |
| Sync managed identity | Cosmos account owner | Cosmos DB Built-in Data Reader (`00000000-0000-0000-0000-000000000001`) on `/dbs/<database>/colls/adminConfig` only |
| Sync app setting | Deployment operator | `SYNC_LIMITS_CONTAINER` = `adminConfig` |

`ADMIN_CONFIG_CONTAINER` must be set on the admin app (it already is when cost definitions are
saved). With it set, an admin change that cannot be written to the change record is refused with
503 `change_log_unavailable`, and nothing is modified.

### Build both packages

```powershell
$ErrorActionPreference = 'Stop'
Set-Location 'C:\REPLACE\ccof-bicep'
$repo = (Get-Location).Path
$version = (Get-Content admin\package.json -Raw | ConvertFrom-Json).version
if ($version -ne '3.2.0') { throw 'This is not the approved Admin 3.2.0 source.' }
$release = Join-Path $HOME 'ccof-admin-releases'
New-Item -ItemType Directory -Force -Path $release | Out-Null
$zip = Join-Path $release 'ccof-admin-v3.2.0.zip'
& (Join-Path $repo 'admin\Build-AdminPackage.ps1') -OutFile $zip
& (Join-Path $repo 'scripts\portal\Build-PortalPackage.ps1') -App sync -OutputDirectory $release
$syncZip = Join-Path $release 'sync.zip'
Get-FileHash -LiteralPath $zip, $syncZip -Algorithm SHA256
```

Keep the currently deployed sync ZIP as its rollback package, as for the admin ZIP.

### Grant the sync read access to adminConfig

Run with the dedicated profile from step 4. The principal is the sync app's managed identity
(the user-assigned identity named in `SYNC_MANAGED_IDENTITY_CLIENT_ID`), not the admin identity.

```powershell
$cosmosAccount = 'REPLACE-cosmos-account'
$cosmosRg = 'REPLACE-cosmos-resource-group'
$database = 'REPLACE-cosmos-database'
$syncApp = 'REPLACE-sync-function-app'
$syncPrincipalId = 'REPLACE-sync-identity-object-id'
foreach ($value in @($cosmosAccount, $cosmosRg, $database, $syncApp, $syncPrincipalId)) {
    if (-not $value -or $value -match '[()&|<>^"]') {
        throw 'Azure CLI arguments must be non-empty and contain no cmd.exe metacharacters.'
    }
}
az cosmosdb sql role assignment create --subscription $sub --account-name $cosmosAccount `
    --resource-group $cosmosRg --role-definition-id 00000000-0000-0000-0000-000000000001 `
    --principal-id $syncPrincipalId --scope "/dbs/$database/colls/adminConfig"
if ($LASTEXITCODE -ne 0) { throw 'Cosmos role assignment failed.' }
az cosmosdb sql role assignment list --subscription $sub --account-name $cosmosAccount `
    --resource-group $cosmosRg -o table
```

The list must show the new assignment with scope ending `/colls/adminConfig`. The empty-value check
matters: a missing scope part widens the assignment.

### Publish the sync package and set the setting

```powershell
az functionapp deployment source config-zip --subscription $sub `
    --resource-group $rg --name $syncApp --src $syncZip
if ($LASTEXITCODE -ne 0) { throw 'Sync publishing failed.' }
az functionapp config appsettings set --subscription $sub --resource-group $rg `
    --name $syncApp --settings SYNC_LIMITS_CONTAINER=adminConfig -o none
if ($LASTEXITCODE -ne 0) { throw 'Sync setting failed.' }
```

`$rg` is the resource group of the sync app; change it if it differs from the admin app's. Do not run
Stage 3, Stage 5 or Stage 7 of the staged driver for this: they apply all grants, settings and apps.
The staged driver includes the same grant (`sync-limits-reader`) and setting for new deployments.

### Verify

| Check | Expected |
| --- | --- |
| `/api/v3/version` | `version: 3.2.0` |
| `/api/v3/capabilities` | `changeLog` and `removalLimits` are `configured` |
| Edit a test project setting | Audit > Change record shows the change with outcome `updated` |
| Removal limits page, save an override with a short expiry | State `in effect`; the next sync run emits the notice `removal_limits_from_admin` |
| Sync run after the override is switched off | No `override_unreadable` notice (that one means the grant or setting is missing) |
| Retire a test project | Read-only banner; the next sync run emits `project_retired` with the removal count |

### Rollback

- Admin: publish the retained admin ZIP. Retired projects stay retired; admin 3.1.0 and earlier
  refuse edits to them (`retiredAt:invalid`). Change-record documents remain in `adminConfig`.
- Sync: publish the retained sync ZIP and remove `SYNC_LIMITS_CONTAINER`. A retired project is then
  frozen: its remaining memberships are kept, nothing is added.
- The sync Cosmos assignment can be removed with `az cosmosdb sql role assignment delete` using the id
  from the list above.

## References

- Implementation: `admin/src/user-directory.ts`, `admin/src/v3.ts`,
  `admin/ui-v3/components/user-identity.tsx`; packaging: `admin/Build-AdminPackage.ps1`.
- [Graph Get user and application permissions](https://learn.microsoft.com/en-us/graph/api/user-get?view=graph-rest-1.0).
- [Graph JSON batching: 20 requests per batch](https://learn.microsoft.com/en-us/graph/json-batching).
- [Assign an app role to a managed identity](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/assign-app-role-managed-identity-powershell).
- [Graph New-MgServicePrincipalAppRoleAssignment](https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.applications/new-mgserviceprincipalapproleassignment).
- Retirement and removal limits: `src/sync/plan.ts`, `src/sync/removal-limits.ts`, `admin/src/sync-limits.ts`,
  `admin/src/change-log.ts`, `infra/staged/stage3-grants.bicep` (`sync-limits-reader`).
- [az cosmosdb sql role assignment create](https://learn.microsoft.com/en-us/cli/azure/cosmosdb/sql/role/assignment#az-cosmosdb-sql-role-assignment-create).
- [Cosmos DB built-in data roles](https://learn.microsoft.com/en-us/azure/cosmos-db/nosql/reference-data-plane-security#built-in-roles).
- [Functions ZIP deployment and Flex Consumption](https://learn.microsoft.com/en-us/azure/azure-functions/deployment-zip-push#deploy-by-using-azure-cli).
