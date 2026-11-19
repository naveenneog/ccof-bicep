# Optional admin self-service and private upgrades

Implements the optional infrastructure boundary of [ADR 0041](../adr/0041-admin-self-service-operations.md).
**No live deployment or acceptance is implied by offline tests.** Apply now uses durable Cosmos
requests and correlated worker receipts, not an ARM/host invocation API. Enabling its gate alone
does not prove worker readiness or successful Graph/budget execution.
Routing publication and configuration history have independent gates. Existing authentication,
project validation, mandatory audit, removal/budget/continuity guards and region B's writer fence
remain prerequisites, not optional checks.

## 1. Settings: opt in independently

Old staged JSON remains valid without an `admin` feature section. Every new gate defaults to false;
unset/false gates add no optional ARM grant. Supply JSON booleans, not strings.

| Staged configuration | Admin app setting | Encoding/default |
|---|---|---|
| `admin.routingPublish` | `ADMIN_ROUTING_PUBLISH_ENABLED` | `true` only when opted in; otherwise absent/disabled |
| `admin.applyNow` | `ADMIN_APPLY_ENABLED` | `true` only when opted in; fresh worker readiness and real receipts still required |
| `admin.configurationHistory` | `ADMIN_HISTORY_ENABLED` | `true` only when opted in; otherwise absent/disabled |
| `admin.gatewayResourceIds` | Existing `ADMIN_GATEWAY_RESOURCE_IDS` | Comma-separated full APIM IDs; both approved gateways for DR |
| `admin.workerResourceIds` | `ADMIN_WORKER_RESOURCE_IDS` | JSON array of approved worker pairs; emitted only with `applyNow` |

Example fragment to merge into the **existing** staged config, replacing all example IDs/names:

```json
{
  "admin": {
    "v3Enabled": true,
    "routingPublish": true,
    "applyNow": false,
    "configurationHistory": true,
    "gatewayResourceIds": [
      "/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/ccof/providers/Microsoft.ApiManagement/service/gateway-a",
      "/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/ccof/providers/Microsoft.ApiManagement/service/gateway-b"
    ],
    "workerResourceIds": [
      {
        "region": "A",
        "syncResourceId": "/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/ccof/providers/Microsoft.Web/sites/a-sync",
        "reconcilerResourceId": "/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/ccof/providers/Microsoft.Web/sites/a-reconciler"
      },
      {
        "region": "B",
        "syncResourceId": "/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/ccof/providers/Microsoft.Web/sites/b-sync",
        "reconcilerResourceId": "/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/ccof/providers/Microsoft.Web/sites/b-reconciler"
      }
    ],
    "extraAllowedClientIds": []
  }
}
```

Worker entries accept **only** `region` (`A`/`B`), `syncResourceId` and `reconcilerResourceId`.
Regions/sites must be unique. They never accept URLs, scripts, commands or function names from a
browser. Keep `applyNow:false` until the worker packages, permissions and readiness below are verified. Retain all other
existing admin options when merging; the fragment is not a replacement deployment file.

When `admin.applyNow` is true and the admin app is enabled, Stage 5 additionally configures **both
local workers**, including the standby region when its config is applied:

| Worker app setting | Value/source |
|---|---|
| `CCOF_APPLY_WORKER_ENABLED` | `true`; otherwise absent/disabled |
| `CCOF_APPLY_WORKER_RESOURCE_ID` | That worker's own exact Function App ARM resource ID |
| `CCOF_APPLY_WORKER_IDENTITY_RESOURCE_ID` | That worker's existing user-assigned managed identity ARM ID, from Stage 1/DR names |
| `CCOF_APPLY_WORKER_PAIRS` | Same JSON array as `ADMIN_WORKER_RESOURCE_IDS` |
| `ADMIN_CONFIG_CONTAINER` | `adminConfig` |
| Existing `COSMOS_ENDPOINT`, `COSMOS_DATABASE` | Existing shared account/database; no management endpoint |

Existing `CCOF_APP_ROLE` remains exactly `sync` or `reconciler`. Existing role-specific managed
identity client IDs and projects-container settings are retained. The optional `applyControl`
timer is registered only for an enabled, correctly configured worker and polls every ten seconds.
It is a control/heartbeat timer, not permission to bypass the business timers' Disabled fences.
No new `AzureWebJobs.*.Disabled` setting is required or written.

Stage 5 still writes the complete app-settings collection, using the existing staged defaults.
Do not rerun it on a customized production app without reviewing the full settings diff. A **code-only**
private update below never writes settings. A private endpoint is not a substitute for authorization.

## 2. One-time permissions and setup

Inventory both APIM IDs and the system-assigned principal IDs of **both admin apps**. Approve the IDs
server-side. Review each proposed assignment with the APIM owner, especially for existing/shared APIMs.

### Routing publication

For each opted-in admin identity, assign exactly these control-plane actions at **each configured
APIM resource**, not its subscription or resource group:

```text
Microsoft.ApiManagement/service/read
Microsoft.ApiManagement/service/backends/read
Microsoft.ApiManagement/service/backends/write
Microsoft.Authorization/permissions/read
```

`infra\staged\admin-routing-role.bicep` creates a deterministic custom definition with no data
actions, wildcard, delete, policy, subscription-key or role-assignment write permissions. Its
definition is available within the APIM's resource group; the actual assignment is on that APIM
only. This necessarily allows writing **all backend names within that APIM**, not only CCOF's
prefix. Use dedicated APIMs when that residual scope is unacceptable.

The one-time security setup operator needs `Microsoft.Authorization/roleDefinitions/read` and `/write` at the
definition scope, `Microsoft.Authorization/roleAssignments/read` and `/write` at each APIM scope,
plus the existing deployment/resource read permissions. An existing grant operator must explicitly
check custom-role-definition creation rights; do not assume resource Contributor supplies them.
The admin app itself receives none of those setup write permissions. Stage 3 preserves its existing
assignment-only ARM boundary; it references the already-created definition and never creates it.

The permission owner first reviews/deploys this standalone definition **once per approved APIM**:

```powershell
# Preview each APIM's definition in its own subscription/resource group.
az deployment group what-if --subscription REPLACE-subscription-guid --resource-group REPLACE-apim-rg `
  --template-file .\infra\staged\admin-routing-role.bicep --parameters apimName=REPLACE-approved-apim-name
# After permission-owner review, same arguments with "create" instead of "what-if".
```

This creates no role assignment. Keep the returned definition ID in setup evidence. The Stage 3
grant operator subsequently needs only its existing role-assignment/deployment rights, not custom
role-definition writes; a missing one-time definition must be reconciled before enabling routing.

Use the existing staged driver for region A and DR driver for region B:

```powershell
# Preview first; these commands contact Azure. Only the authorized deployment owner runs them.
pwsh -NoProfile -File .\infra\staged\Invoke-StagedDeployment.ps1 -Stage 3 -ConfigPath .\.env.staged\staged.config.json
pwsh -NoProfile -File .\infra\dr\Invoke-DrStandby.ps1 -Phase Grants -ConfigPath .\.env.dr\dr.config.json
```

Review the two narrow assignments per admin, then repeat with `-Apply`. Stage 3 verifies local and
cross-region assignment readback. Its input hash changes when the optional routing targets change;
false/absent flags preserve the legacy Stage 3 hash. Allow RBAC propagation, then review Stage 5 /
DR `Config` previews and apply those separately. Those configuration phases have their existing
site/APIM/workbook write requirements and are **not** a narrow settings-only update.

DR derives B's config from the primary: it preserves optional feature flags and the exact approved
worker-pair list, supplies both gateway IDs when B exists, and forcibly leaves both B timers off.
It does not update region A's config or state: configure the plural gateway IDs on A too and review
both settings readbacks. Do not edit generated standby JSON as the source of truth.

Turning a flag off disables the feature; incremental ARM deployment does **not** revoke an earlier
assignment. Have the permission owner remove the named optional assignments explicitly when
decommissioning the feature, before expecting a baseline Stage 3 grant inventory.

### History and durable jobs

Reuse the existing admin custom Cosmos role on the existing database's `adminConfig` container:

```text
Microsoft.DocumentDB/databaseAccounts/readMetadata
Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/executeQuery
Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/readChangeFeed
Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/read
Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create
Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/replace
```

These are already assigned for admin editing; no new Cosmos role or scope is introduced for
history/jobs, and no delete/upsert is added. Existing project permissions and mandatory audit must
still work. History restore creates a new validated configuration change, not a rollback of project
identity, retirement, access groups, usage, spend, counters or audit history. Restored routing needs
fresh publication. Missing optional history access must not disable unrelated existing edits.

No new Entra app roles or Microsoft Graph write permissions are required. Existing
`CCOF.Projects.Write` remains the mutation authority.

### Feature Azure RBAC is not the worker's existing Graph permission

The APIM actions above authorize the **admin identity** against Azure Resource Manager. They do
not authorize a **sync identity** to read Microsoft Graph. Configuration history and successful
admin project reads likewise do not prove that the application-permission sync can run.

The existing application-permission runtime separately requires the sync identity's
`GroupMember.Read.All` Microsoft Graph application read permission for direct group membership.
The existing grant helper also defaults to `User.Read.All` and `Application.Read.All` for
disabled/deleted user and application visibility; these account-state checks are distinct from the
baseline membership read. Review the existing `docs\SYNC.md` contract and
`infra\quickstart\Grant-SyncGraphPermissions.ps1` before approving those additional read scopes.
Verify the existing assignments for **both** regional sync identities, including the identity that
would become active after failover. This upgrade neither grants these permissions nor runs that
grant script. Any missing read permission is a separately approved Entra/runtime prerequisite;
Azure subscription roles do not supply it. Do not grant Graph writes, switch to a delegated
snapshot, change sync mode or relax runtime guards to manufacture successful acceptance.

**Read-only lab baseline, 2026-11-19, before upgrade:** Graph assignment queries returned HTTP 200
but **zero app-role assignments** for both regional sync managed identities
(`infsim-5dnel4x4647ag-sync-id`, `infsim-sync-b-id`). Therefore no real Graph sync or Apply success
can be claimed. Authenticated reads of `INFSIMPROJ` and `INFSIMFD2` through the existing Front Door
returned HTTP 200; the pre-upgrade self-service capabilities route returned 404. These establish
only the old authenticated project-read baseline and the absence of the new route, not new-feature
acceptance or permission readiness. The Cosmos control transport does not repair missing runtime
Graph reads; do not silently grant them during the admin code upgrade.

### Apply now: narrow Cosmos control access and real worker receipts

The admin identities reuse their existing `adminConfig` read/query/create/replace access.
**Only when `admin.applyNow:true`**, Stage 3 adds a separate custom Cosmos role and assigns each
local sync/reconciler identity that role on the existing database's **`adminConfig` container only**.
Apply Grants for A and B to cover all four worker identities. The exact data actions are:

```text
Microsoft.DocumentDB/databaseAccounts/readMetadata
Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/executeQuery
Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/read
Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create
Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/replace
```

No delete, upsert, change-feed or wildcard action is added. The setup operator needs the existing
`Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions/read` and `/write`, plus
`Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments/read` and `/write` on the existing
Cosmos account; worker identities receive none of those setup rights. Stage 3 reads assignments
back. The grant's scope is the whole container, not a document/partition ACL; runtime validation
restricts controls to the fixed `scopeId='admin-apply'` request/heartbeat/receipt protocol. Review that
residual container-wide capability explicitly. False/absent flags add no worker assignment or role.
Disabling a flag does not revoke a previously assigned role; remove old assignments separately
when decommissioning.

The optional ten-second control timers run in both regions but must freshly prove **exactly one
active sync/reconciler pair** and the standby pair's original business timers disabled before
dispatch. Each worker checks its original Disabled fence before processing every request; active
sync still requires its existing apply write mode. Requests are limited to the approved resource
pairs, durable and correlated with the project/job. Completion requires receipts from actual
`runSync` and `runReconciler` execution. HTTP 202, fresh budget documents, heartbeat/token readiness,
or a successful admin read are **not** substitute completion evidence.

Sync heartbeats expose only sanitized Graph readiness
(`granted`, `permission_required` or `unknown`) and the explicit identity resource ID. No Graph JWT
or token is logged or stored. A managed-identity token's role claims can identify a missing read
prerequisite without giving admin identities Graph-directory access; they do not prove a real
Graph read succeeded. Preserve unknown/missing permission states until actual runtime evidence
resolves them.

No runtime `Microsoft.Web/sites/config/list/action`, hostruntime invoke, list-keys, new Entra role,
or Graph permission is needed by this transport. In particular, do not introduce a master-key or
guessed ARM invoke fallback. Never flip timer settings or enable B's writers to simulate a run.

## 3. First private code upgrade

Use the existing lab VM/private SCM setup in [ADMIN-UPDATE-FROM-VM](ADMIN-UPDATE-FROM-VM.md).
Do not create a replacement VM, public SCM exception, new outbound path or temporary public access
as part of an upgrade. The VM must already be running; the updater refuses a stopped VM, it does
not start one. Setup installs tools only when explicitly requested with `-Phase Setup -Apply`.

**Private connectivity is per app, not per VM or per region.** Before updating either admin app,
run `-Phase Check` for that exact app and verify both `<app>.azurewebsites.net` and
`<app>.scm.azurewebsites.net` resolve through its approved private endpoint from the updater VNet.
A working A endpoint/DNS record does not provide a private publishing path to B. If B's SCM name
still resolves publicly, stop: the updater fails closed before building or publishing. The platform/
network owner must separately approve/provision B admin's `sites` private endpoint, connection
approval and app/SCM records in the existing `privatelink.azurewebsites.net` zone reachable from that
VNet (or its existing resolver). Do not fall back to B's pre-existing public endpoint or change its
public-access flag incidentally. Rerun Check after private DNS readback.

Apply requires the root **sync and reconciler packages in both regions**, as well as both admin
packages. Each of the six targets needs its own verified private SCM path. A working admin private
endpoint does not cover either worker. The updater defaults to the existing admin source build;
its explicit `-PackageKind Sync` / `Reconciler` modes publish only approved retained role-specific
artifacts, with mandatory hashes and safe rollback, as described below.

The invoking operator needs VM read/instance-view and
`Microsoft.Compute/virtualMachines/runCommand/action` on the **existing VM**. Run Command executes
as root: treat this operator as privileged. The VM identity uses its existing Website Contributor
assignment on the **exact target app**, not an RG-wide assignment. Each worker target needs its
own separately approved deployment assignment; neither admin runtime nor worker identities receive
the VM deployment role. It must read app metadata/list
functions and publish via OneDeploy. Safe upgrade additionally reads:

```text
Microsoft.Web/sites/config/list/action   # sensitive full app-settings collection
Microsoft.Web/sites/config/read         # authentication configuration readback
```

Existing Website Contributor is a broad deployment role, not the narrow runtime routing role.
Do not assign it to admin runtime identities. Safe upgrade hashes settings/auth/network-access
readbacks in memory; it never writes their values to its log or evidence, and never modifies them.
Restrict the VM's work directory, logs and evidence to trusted deployment operators.

### Bootstrap the retained previous artifact

Before the first safe upgrade, identify the **exact last deployed, known-good ZIP** and its
approved full 40-character commit and SHA-256 from the earlier successful deployment evidence.
The existing updater retains `/var/lib/ccof-admin-update/admin-<commit>.zip` on the VM. If it is
missing, recover the original approved artifact from your secure artifact retention into that exact
VM path using your established private administrative file-transfer procedure. Verify its SHA-256
out of band. Do not rebuild it and call it the original artifact, or run an unprotected update to
manufacture a baseline. The safe updater refuses a missing or mismatched baseline before deployment.
Flex Consumption has no built-in deployment revision history to recover it for you.

Run from the approved checkout. These are operator examples, **not commands executed by this task**:

```powershell
$common = @{
  Subscription = 'REPLACE-subscription-guid'
  VmResourceGroup = 'REPLACE-existing-vm-rg'
  VmName = 'REPLACE-existing-private-vm'
  AdminResourceGroup = 'REPLACE-admin-rg'
  AdminApp = 'REPLACE-region-a-admin'
  RepoUrl = 'https://github.com/REPLACE-owner/REPLACE-repository'
  EvidenceDirectory = '.\.env.admin-updates'
}
$release = @{
  Commit = 'REPLACE-approved-full-40-character-lowercase-commit'
  PreviousCommit = 'REPLACE-last-deployed-full-40-character-lowercase-commit'
  PreviousPackageSha256 = 'REPLACE-last-deployed-64-character-lowercase-sha256'
}
& .\infra\admin\Update-AdminFromVm.ps1 -Phase Check @common
& .\infra\admin\Update-AdminFromVm.ps1 -Phase Update @common @release -SafeUpgrade
# After review:
& .\infra\admin\Update-AdminFromVm.ps1 -Phase Update @common @release -SafeUpgrade -Apply
```

Only a pushed immutable commit is accepted; the local checkout's remote refs must contain it.
The VM verifies `HEAD` after checkout, uses the lockfiles/build tests, hashes the new ZIP, verifies
and backs up the old ZIP to
`/var/lib/ccof-admin-update/backups/<app>/<previous-sha256>.zip`, and deploys through the private
SCM name. It reads back required functions plus unchanged app settings, auth and access guards.
On deployment/readback failure it attempts to republish the **verified old bytes**, then verifies
the rollback; a failed upgrade still exits nonzero even if rollback succeeds.

### Private worker artifact upgrades

Use the existing root role-specific packaging contract in `scripts\Core.D2Code.psm1`
(`New-CoreAppPackage`, production dependency installation and `New-CoreZip`) at the approved pushed
commit after the root build/tests pass. Preserve the reconciler's approved customer rate card,
contract schedule and ledger query from its current deployment inputs; do not substitute repository
examples or publish one generic all-functions archive to both roles. Retain each ZIP/hash and its
source/input provenance. This updater intentionally does **not** rebuild workers or choose those
customer files.

Using the established private administrative file-transfer procedure, place the reviewed new and
exact known-good previous role-specific artifacts on the existing VM:

```text
/var/lib/ccof-admin-update/sync-<approved-commit>.zip
/var/lib/ccof-admin-update/reconciler-<approved-commit>.zip
```

For **each region and each role**, set `$common.AdminApp` and `$common.AdminResourceGroup` to that
exact worker site (the legacy parameter names are retained). Supply an explicit allowlist of one
to four full approved worker site IDs; the exact target ID must occur in it. The updater rejects
empty, malformed, duplicate/case-aliased lists and checks the target's existing `CCOF_APP_ROLE`
against the fixed package kind before deployment. This is not a generic VM command facility.
Use that app's own previous commit/hash:

```powershell
# Sync example; use -PackageKind Reconciler and that role's hashes for the reconciler.
$common.AdminApp = 'REPLACE-region-a-sync'
$common.AdminResourceGroup = 'REPLACE-that-worker-rg'
$approvedPairs = (Get-Content -Raw .\.env.staged\staged.config.json | ConvertFrom-Json).admin.workerResourceIds
$common.ApprovedWorkerResourceIds = @($approvedPairs | ForEach-Object {
  $_.syncResourceId
  $_.reconcilerResourceId
})
$workerRelease = @{
  Commit = 'REPLACE-approved-full-40-character-lowercase-commit'
  PackageSha256 = 'REPLACE-approved-new-worker-64-character-lowercase-sha256'
  PreviousCommit = 'REPLACE-that-app-previous-full-40-character-lowercase-commit'
  PreviousPackageSha256 = 'REPLACE-that-app-previous-64-character-lowercase-sha256'
}
& .\infra\admin\Update-AdminFromVm.ps1 -Phase Check @common -PackageKind Sync
& .\infra\admin\Update-AdminFromVm.ps1 -Phase Update @common @workerRelease -PackageKind Sync -SafeUpgrade
# After review:
& .\infra\admin\Update-AdminFromVm.ps1 -Phase Update @common @workerRelease -PackageKind Sync -SafeUpgrade -Apply
```

Worker Update refuses a missing or mismatched new artifact, missing/mismatched previous artifact,
implicit commit, or missing `-SafeUpgrade`. It does not need repository/npm connectivity on the VM.
Both worker modes verify the original business function registration and unchanged full
settings/auth/access hashes. They probe only the private root URL without credentials or redirects;
HTTP 200 or an authentication-preserving 401 establishes **host reachability only**. Neither proves
that a business function ran, that Graph access works, or that a job completed. Other/unreachable
responses fail readiness and trigger safe rollback; the updater never disables authentication to
obtain a 200. Its receipt includes the exact target `resourceId`, `packageKind`, submitted ZIP
`sha256`, `hostHttpStatus`, guard readback and `businessVerified:false`.
Authenticated acceptance must separately verify `applyControl`
registration when enabled, fresh heartbeats, and actual correlated execution receipts. Updating
code does not configure flags, grant Cosmos/Graph access, or enable B's business timers.

## 4. Future updates, rollback and evidence

For every later release use the **last successfully deployed** commit/hash as the previous pair;
retain both ZIPs and evidence outside the VM according to your recovery policy. Update both admin
apps and the four workers one at a time, checking each before moving on; the script targets one
app and has no multi-app transaction. Use `-PackageKind Sync` or `Reconciler` for workers; the default
is Admin. It does not update resolver code, permissions or app settings.

Manual code rollback, with the same `$common`, uses the approved retained artifact without
rebuilding or accepting arbitrary remote scripts:

```powershell
& .\infra\admin\Update-AdminFromVm.ps1 -Phase Rollback @common `
  -PreviousCommit 'REPLACE-approved-previous-commit' `
  -PreviousPackageSha256 'REPLACE-approved-previous-sha256' -Apply
# For a worker, also pass its exact -PackageKind Sync or Reconciler;
# $common must still include ApprovedWorkerResourceIds and that exact target app.
```

Review local `admin-<phase>-<UTC>.json`: target app, `packageKind`, `approvedPackageSha256`,
`run.outcome`, `run.sha256`, `run.previousSha256` and `run.guardReadback`; retain the VM log and
backup path. For workers also review `run.resourceId`, `run.hostHttpStatus` and the explicitly false
`run.businessVerified`. Use a separate evidence directory per app to avoid same-second filename collisions.
Legacy Admin Update without `-SafeUpgrade`
remains available for backward compatibility, **but lacks the approved-baseline/readback/rollback
protection** and is not this upgrade procedure.

Readback limitations: function enumeration proves registration, **not** execution or a remote
byte-for-byte package hash. `sha256` identifies the retained local bytes submitted to OneDeploy;
the updater does not download the mounted Flex package. It does not execute Entra-authenticated
business acceptance tests, restore settings, undo schema/data changes, manage private-repository
credentials, prevent another operator's concurrent deployment, or update multiple apps atomically.
Serialize updates operationally; stop on unexpected settings drift. A code rollback cannot repair
external settings/auth/network edits, so a failed guard readback requires operator reconciliation,
not opening the public endpoint or overwriting settings.

After each app update, the customer deployment owner verifies through the normal authenticated
private/Front Door path:

1. Sign-in, project reads and ordinary validated/audited edits still work.
2. Each disabled or unavailable capability reports that state without breaking other features.
3. Opted-in routing verifies all members/pools on both APIMs before activation; partial failures
   preserve the last verified route. History preview/restore is ETag-guarded and configuration-only.
4. Both B timers and the existing B writer fence remain unchanged; no Graph write grant appeared.
   When Apply is enabled, all four control heartbeats must be fresh, exactly one pair active, and
   a permitted real job must finish with matching sync and reconciler execution receipts. A missing
   existing Graph read remains an explicit prerequisite, not success.
5. Locked-down targets still refuse direct public access; preserve any pre-existing B access state
   for separately approved remediation rather than incidentally changing it in an upgrade.
   The known-good artifact/evidence remain recoverable.

## Sources and offline validation

Checked 2026-11-19:

- [APIM permissions](https://learn.microsoft.com/en-us/azure/role-based-access-control/permissions/integration#microsoftapimanagement)
- [Custom role scope/permissions](https://learn.microsoft.com/en-us/azure/role-based-access-control/custom-roles)
- [Web resource-provider permissions](https://learn.microsoft.com/en-us/azure/role-based-access-control/permissions/web-and-mobile#microsoftweb)
- [Manual non-HTTP invocation](https://learn.microsoft.com/en-us/azure/azure-functions/functions-manually-run-non-http)
- [Flex deployment recovery and lack of retained revisions](https://learn.microsoft.com/en-us/azure/azure-functions/functions-rollback-deployments)
- [Private SCM DNS](https://learn.microsoft.com/en-us/azure/app-service/overview-private-endpoint#kuduscm-endpoint)

Focused, logged-out tests (no live Azure calls; the Bicep tests use only the local compiler):

```powershell
pwsh -NoProfile -File .\tests\Test-AdminSelfServiceInfra.ps1
pwsh -NoProfile -File .\tests\Test-AdminVmUpdate.ps1
```
