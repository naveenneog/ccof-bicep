# Group sync: Entra classification groups into Cosmos `entitlement`

The sync is the only writer of `entitlement` (`docs/PILOT.md` C-4). For every active `projects`
document, it reads each classification group's direct members from Microsoft Graph and writes each
person's `projectMemberships`. Adding a person to a registered group grants a membership on the next
run; removing them takes it away. Rules and reasons: [ADR-0016](adr/0016-group-sync-projection-rules-and-safety.md).
Packet evidence: [WP-SYNC](status/WP-SYNC.md).

## How a run works

1. Take the lease `ccof-entitlement-sync` in the lease container. If another run holds it, stop
   (`skipped`, `lease_held`).
2. Read every `projects` document and validate each one (C-5, including C-2 `tokenLimits`); only
   active, valid ones are projected.
3. Read every registered group: `GET /v1.0/groups/{id}/members?$select=id,accountEnabled&$top=999`, all pages,
   with bounded `Retry-After` waits on 429 and 503. v1.0 does not list service principals among a
   group's members (Learn "Known issues with Microsoft Graph APIs", retrieved 2026-10-12), so when
   `SYNC_MEMBER_TYPES` lists `servicePrincipal`, each group is also read through the OData cast
   `GET /v1.0/groups/{id}/members/microsoft.graph.servicePrincipal?$select=id,accountEnabled&$top=999&$count=true`
   with `ConsistencyLevel: eventual` on every page, under the same rules. Either read failing fails
   the group read. `accountEnabled`: see "Deleted and disabled members" below.
4. Read every `entitlement` document.
5. Plan: one membership per person and project, the conflict rule, frozen projects, removal limits.
6. Write the changed documents (`SYNC_WRITE_MODE=apply`), or only report them (`dry-run`).
7. Release the lease and write one `ccof.sync.run.v1` line.

| Situation | Effect |
|---|---|
| A group read fails (403, 404, throttling past the bound, 5xx, network, malformed page) | Its project is frozen: no addition, change or removal; one `refusal` event with the group and reason |
| A `projects` document is invalid, or its status is neither `active` nor `retired` | That project is frozen; the event lists field paths and problem codes |
| A `projects` document has `status: "retired"` with a `retiredAt` UTC timestamp (set by the admin console's Retire action) | Every membership of the project is removed; its groups are not read. One `project_retired` notice with the removal count. These removals are not counted against the removal limits and are never withheld (`src/sync/plan.ts`) |
| A membership's project has no `projects` document at all | The membership is kept (`project_document_missing`): deleting or recreating a document is not evidence that anyone left |
| A Graph member arrives without `@odata.type` | The group read fails (`graph_response_invalid`); the page is not read as a group of nobody. On the service-principal read, an item without a type counts only on a page whose `@odata.context` is the `servicePrincipals` collection, as Graph returns it |
| One id arrives as a service principal and as another type | The group read fails (`graph_response_invalid`) |
| A record the resolver would refuse (legacy `expiresAt` passed, invalid `generation` or `lastVerifiedAt`, two active memberships of one project) | It grants nothing, so none of its memberships is carried over; only verified memberships are written |
| A `projects` document has no readable `projectId` | Every removal in the run is withheld |
| Removals exceed both limits | Removals are withheld; additions and changes apply; `removal_limit_exceeded` event. The limits are the app settings, or the admin console override (below) |
| A person is in two classification groups of one project | The incumbent classification stays if it is one of them, otherwise none; `classification_conflict` event |
| A nested group, a service principal (when not configured) or an unknown member type | Not admitted, not expanded; one `notice` event per member |
| A document already matches | Not written |
| A person is in no registered group | Their document keeps an empty `projectMemberships`; the resolver answers `no_entitlement` |
| No project could be evaluated | The run is `failed` and writes nothing, not even repairs |

## Settings

All required, no defaults, except `SYNC_LIMITS_CONTAINER` (`src/sync/config.ts`). The deploy script writes them from the answers
file (`infra/sync/sync.answers.pilot.json`) and validates them with the app's own code first.

| Setting | Meaning |
|---|---|
| `SYNC_TENANT_ID` | Tenant of the groups; the CLI's Azure CLI credential is pinned to it |
| `COSMOS_ENDPOINT`, `COSMOS_DATABASE` | The registry account (`https://<account>.documents.azure.com:443/`) and database |
| `SYNC_PROJECTS_CONTAINER`, `SYNC_ENTITLEMENT_CONTAINER`, `SYNC_LEASE_CONTAINER` | Three distinct containers |
| `SYNC_LEASE_SECONDS` | Lease duration; at least 2 × (`SYNC_GRAPH_MAX_RETRY_AFTER_SECONDS` + `SYNC_GRAPH_TIMEOUT_SECONDS`) |
| `SYNC_MEMBER_TYPES` | `user`, or `user,servicePrincipal` to admit test identities. With `servicePrincipal`, every group read adds the service-principal read (step 3). Pilot: `user,servicePrincipal`, owner approval (c) of 2026-10-11 ([WP-SYNC-SP](status/WP-SYNC-SP.md)) |
| `SYNC_MAX_REMOVALS_PER_RUN`, `SYNC_MAX_REMOVAL_FRACTION` | Removal limits; a run is refused only when it exceeds both |
| `SYNC_LIMITS_CONTAINER` (optional) | Container holding the admin console's removal-limit override (`adminConfig`). Unset: the override is not read. Must differ from the entitlement and lease containers |
| `SYNC_GRAPH_MAX_RETRIES`, `SYNC_GRAPH_MAX_RETRY_AFTER_SECONDS`, `SYNC_GRAPH_TIMEOUT_SECONDS` | Graph retry budget, longest wait honoured, request timeout |
| `SYNC_WRITE_MODE` | `apply` or `dry-run` |
| `SYNC_SNAPSHOT_MAX_AGE_SECONDS`, `SYNC_SNAPSHOT_MAX_BYTES`, `SYNC_SNAPSHOT_MAX_GROUPS`, `SYNC_SNAPSHOT_MAX_MEMBERS` (`apply-snapshot` only) | Oldest snapshot accepted, and its size limits |
| `SYNC_SCHEDULE` (app only) | NCRONTAB, six fields; `0 */1 * * * *` is every minute |
| `SYNC_MANAGED_IDENTITY_CLIENT_ID` (app only) | Client id of the user-assigned identity |
| `AzureWebJobs.syncEntitlement.Disabled` (app only) | `true` until the Graph permission is granted |

## Removal limits from the admin console

With `SYNC_LIMITS_CONTAINER=adminConfig`, each run point-reads the document `syncRemovalLimits`
(`src/sync/removal-limits.ts`), saved from the admin console's **Removal limits** page
([ADMIN-V3.md](ADMIN-V3.md)). The override replaces the two app settings only while it is enabled,
valid and not expired. A missing, disabled, expired, invalid or unreadable document falls back to the
app settings; it can never raise the limits. The run emits a `notice` event `removal_limits_from_admin`, or
the fallback reason `override_unreadable`, `override_invalid` or `override_expired` (`src/sync/run.ts`).

Permission: Cosmos DB Built-in Data Reader on the `adminConfig` container for the sync identity (staged
Stage 3 assignment `sync-limits-reader`; Stage 5 sets the setting when the admin app is deployed).

## Deleted and disabled members (P-9)

Rule: [ADR-0016](adr/0016-group-sync-projection-rules-and-safety.md), amendment from P-9. Evidence:
[WP-SYNC](status/WP-SYNC.md), "P-9: deleted and disabled members".

| Member | What Graph returns | Effect |
|---|---|---|
| Deleted | Not listed: deletion takes the member out of its groups ([Track changes to group memberships](https://learn.microsoft.com/graph/delta-query-groups)) | Its memberships are removed on the next run, within the removal limits. A soft-deleted user restored within 30 days is listed again and readmitted |
| Disabled user or service principal, state readable | Listed with `accountEnabled: false` | Admitted nowhere in that run, so its memberships are removed within the removal limits; a frozen project keeps it. The run that removes (or withholds) one of its memberships logs `member_account_disabled` for the group; later runs only count it (`membersDisabled`). Re-enabled, it is admitted on the next run |
| Any member, state not readable | `accountEnabled: null`, which an identity without `User.Read.All` (users) or `Application.Read.All` (service principals) receives ([List group members](https://learn.microsoft.com/graph/api/group-list-members)) | Admitted as before, never read as disabled; counted in `membersAccountStateUnread` |
| `accountEnabled` other than true, false or null | — | The group read fails (`graph_response_invalid`); its project is frozen |

The disabled rule acts only where Graph returns the state. The timer's identity holds only
`GroupMember.Read.All` (read 2026-10-13), so on timer runs every member is unread and a disabled member
keeps its entitlement, as before. A run with a person's sign-in (`--once --credential azure-cli`, and
`snapshot`) gets the state wherever that person can read users, as the owner's read of 2026-10-13 did,
so on those paths the rule applies as soon as this code runs: in shape A the first `apply-snapshot`
applies it, and in shape B a manual `azure-cli` run can remove a disabled member that the next timer
run readmits, until the grants below. Entra issues no new token to a disabled account; a token issued
earlier lasts 60 to 90 minutes ([Access tokens](https://learn.microsoft.com/entra/identity-platform/access-tokens)).
Putting the rule in force is the owner's decision:

1. Count the disabled backlog first, before the grants and before the first snapshot apply or
   `azure-cli` run on this code: with your own sign-in, read each registered group both ways
   (`GET /v1.0/groups/{id}/members?$select=id,accountEnabled`, and the service-principal cast with
   `ConsistencyLevel: eventual` and `$count=true`), and count the memberships (person and project) of
   accounts with `accountEnabled: false`. A `null` means your sign-in cannot read the state, so the
   count is not possible with it. If the count, with the run's ordinary removals, exceeds both removal
   limits, the first run withholds every removal, and so does every run after it, until an
   administrator removes those accounts from their groups or raises the limits for one supervised run.
2. A Privileged Role Administrator grants the sync identity `User.Read.All`, and `Application.Read.All`
   when `SYNC_MEMBER_TYPES` lists `servicePrincipal`. Both are tenant-wide: the identity can then read
   every user's profile and every application and service principal, and so can anyone who can get
   its token: whoever deploys code to the app, holds Managed Identity Operator with compute of their
   own, or holds Contributor or Owner on the identity (who can add a federated credential and get its
   tokens from outside Azure). No narrower permission returns `accountEnabled`. The alternative needs
   no grant: the leaver process removes a disabled account from its groups (Lifecycle Workflows "Remove
   users from all groups").
3. The new roles reach the app when its cached Graph token expires (about 24 hours, "Graph permission
   before the first run" below). `EnableTimer` checks only `GroupMember.Read.All`; the proof is a run
   line with `membersAccountStateUnread` 0 and `membersAdmitted` above 0, with a service principal among
   the members when they are admitted. Afterwards alert on `membersAccountStateUnread` above 0 (no alert
   rule for the sync's lines exists yet): an unread state readmits a disabled account still in a group.
4. `Rollback` does not remove Graph app roles; retiring the sync removes these too.

## Deploy (checkpointed stages, `docs/PILOT.md` C-9)

| Stage | Sync piece | Who |
|---|---|---|
| D1 Prerequisite resources | `infra/sync/sync-resources.bicep` (optional): storage with a blob private endpoint and DNS record, Application Insights, the Flex plan and app on the user-assigned identity. No role assignment, Cosmos object or app setting. Outputs the ids D1 records | Infrastructure team |
| D2 Schema and apps | The lease container (`/id`); every app setting below; the code package (`dist/sync`, `infra/sync/host.json`, `package.json` with `main` = `dist/sync/function-app.js`) | Platform deployer |
| D3 Permissions | `infra/sync/sync.assignments.json` (`ccof.assignments`): the custom writer role, Storage Blob Data Owner and Monitoring Metrics Publisher (runtime), Data Reader on `projects`, the Graph permission in `application-permission` mode, and the runners' Cosmos access in `delegated-snapshot` mode. The timer is enabled last | RBAC administrator; Privileged Role Administrator for Graph |

For the proof of concept, `infra/sync/Deploy-SyncFunction.ps1` runs the same pieces. PowerShell 7,
the owner's own Azure CLI login in the gateway tenant; the script never signs in or switches
subscription, and writes `ccof.sync.setup.v1` audit lines to `-AuditPath`.

```powershell
$answers = 'infra/sync/sync.answers.pilot.json'
$audit = '.env.sync-audit.jsonl'
$deploy = 'infra/sync/Deploy-SyncFunction.ps1'
pwsh -NoProfile -File $deploy -AnswersFile $answers -Action Validate -AuditPath $audit   # offline
pwsh -NoProfile -File $deploy -AnswersFile $answers -Action WhatIf   -AuditPath $audit   # D1 what-if
pwsh -NoProfile -File $deploy -AnswersFile $answers -Action Deploy   -AuditPath $audit   # D1
# D3: apply infra/sync/sync.assignments.json (WP-CORE's permissions script)
pwsh -NoProfile -File $deploy -AnswersFile $answers -Action Schema   -AuditPath $audit   # D2: lease container
pwsh -NoProfile -File $deploy -AnswersFile $answers -Action Settings -AuditPath $audit   # D2: app settings
pwsh -NoProfile -File $deploy -AnswersFile $answers -Action Package  -AuditPath $audit   # D2: code (OneDeploy)
```

After any D1 re-run on an existing app, run D2 `Settings` again: the D1 template carries no app
settings.

### Graph permission before the first run

The identity needs the Microsoft Graph application permission `GroupMember.Read.All` (owner action 1
in `docs/PILOT.md`). Grant it **before** the timer is enabled. Managed identity tokens are cached by
the platform "per resource URI for around 24 hours", and "it isn't possible to force a managed
identity's token to be refreshed before its expiry" (Learn, "Best practice recommendations for
managed system identities", updated 2026-02-19, retrieved 2026-10-11). A run before the grant would
keep a token without the role in use for hours. A setup in any other tenant follows the same order.

```powershell
# After the grant: set "timerEnabled": true in the answers file, then
pwsh -NoProfile -File $deploy -AnswersFile $answers -Action EnableTimer -AuditPath $audit
```

`EnableTimer`, and `Settings` whenever `timerEnabled` is true, refuse unless
`GET /servicePrincipals/{identity}/appRoleAssignments` shows the app role. If a run reports
`graph_permission_missing` after the grant, disable the timer and wait for the cached token to
expire; retrying does not help.

Never attach the sync's user-assigned identity to a machine that several people use: anyone with a
shell there could take its tokens and rewrite `entitlement`. Runners use their own identity.

### First runs

Start with `"SYNC_WRITE_MODE": "dry-run"`: the run line reports what it would write. Switch to
`apply` in the answers file and run `-Action Settings`.

## Rollback

```powershell
pwsh -NoProfile -File $deploy -AnswersFile $answers -Action Rollback -ConfirmRollback -AuditPath $audit
```

Deletes the Function App, its plan, Application Insights component, storage private endpoint and
storage account, the identity's Cosmos role assignments, the custom Cosmos role and the lease
container. It does not touch `entitlement`: the resolver keeps serving the last projection, because
records persist until a sync changes them (ADR-0008). It does not remove the Graph app role
assignment either; when the sync is retired, a Privileged Role Administrator removes it (owner
action). To stop writes without deleting anything, set `AzureWebJobs.syncEntitlement.Disabled=true`.

## Manual run (CLI)

From a machine inside the VNet (Cosmos has no public endpoint), with the repository built:

```bash
node dist/sync/cli.js --once --credential azure-cli --settings sync-settings.json
node dist/sync/cli.js --once --credential managed-identity [--client-id <guid>] --settings sync-settings.json
```

`sync-settings.json` holds the same names and string values as the app settings. With
`azure-cli`, the signed-in person's delegated Graph read and Cosmos data-plane role are used. Exit
codes: 0 succeeded, 1 failed, 2 refused input, 3 partial, 4 skipped. The CLI and the timer share the
lease, so they never write at once.

## Without the Graph application permission

Where no one can grant the application permission (shape A in Validation, `docs/PILOT.md`), a person reads
the groups on a workstation with their own delegated sign-in, and a runner inside the VNet applies
the snapshot with the same plan, lease and removal limits as the timer. No interactive sign-in
happens inside the VNet, and no credential travels.

**1. Snapshot, on the workstation** (the Azure CLI signed in to the groups' tenant). No privileged
directory role is needed: with the default user permissions, a member user can read groups and their
members. Only where an administrator restricted the default user permissions, or for groups with
hidden membership, does the person need to own the groups or hold a directory reader role:

```powershell
# groups.json: {"groupIds": ["<group object id>", ...]}, the registered classification groups
#   (from onboarding Stage 1 / Stage 3; the workstation cannot read the private projects container).
# snapshot-settings.json: SYNC_TENANT_ID, SYNC_GRAPH_MAX_RETRIES, SYNC_GRAPH_MAX_RETRY_AFTER_SECONDS,
#   SYNC_GRAPH_TIMEOUT_SECONDS (string values).
npx tsc -p tsconfig.json
node dist/sync/cli.js snapshot --credential azure-cli --groups groups.json --settings snapshot-settings.json --out .env.sync-snapshot.json
```

It reads every group completely (paging, bounded throttling), service principals included through
the OData cast whatever the apply admits, and writes `ccof.sync.snapshot.v1`:
`schema`, `tenantId`, `readAt`, and per group the member ids with their types and, where Graph
returned it to the operator's sign-in, `accountEnabled`. No names or UPNs. Any failed
group writes nothing; the file is written whole and renamed, never over an existing one. The last
line reports the SHA-256. `apply-snapshot` admits the service principals only when its own
`SYNC_MEMBER_TYPES` lists them, applies the disabled-member rule above, and refuses a snapshot whose
`accountEnabled` is anything but true or false (`groups:invalid_member`). A snapshot taken with a
sign-in that cannot read account states records none, so its apply readmits disabled members; check
`membersAccountStateUnread` on the apply's run line.

**2. A runner inside the VNet.** A jump box in the runner subnet with a system-assigned identity, no
public IP, Node.js 22 or later installed from an approved image or package source (the apply never
downloads and runs an installer), and the runner grants from D3 (`sync-runner-*` in
`infra/sync/sync.assignments.json`).
For the proof of concept:

```powershell
$s = '<subscription id>'; $rg = '<resource group>'
az network nic create --subscription $s -g $rg -n ccof-jumpbox-sync-nic --vnet-name <vnet> --subnet <runner subnet>
az vm create --subscription $s -g $rg -n ccof-jumpbox-sync --image Canonical:ubuntu-24_04-lts:server:latest `
  --size Standard_D2as_v7 --nics ccof-jumpbox-sync-nic --assign-identity --admin-username azureuser `
  --ssh-key-values $HOME\.ssh\id_rsa.pub
# Runner grants: the custom writer role on entitlement and syncLease, Data Reader on projects.
az cosmosdb sql role assignment create -a <account> -g $rg --subscription $s --role-definition-id <writer role id> `
  --principal-id <vm principal id> --scope /dbs/<db>/colls/entitlement
```

(`Standard_D2as_v7` because the 2026-10-11 attempt with `Standard_B2s` failed validation in this
subscription; an empty `--public-ip-address ""` is mangled by `az.cmd`, so the NIC is created first.)

**3. Apply, from the workstation through Run Command:**

```powershell
# apply-settings.json: the app's sync settings (above, without SYNC_SCHEDULE) plus
#   SYNC_SNAPSHOT_MAX_AGE_SECONDS, SYNC_SNAPSHOT_MAX_BYTES, SYNC_SNAPSHOT_MAX_GROUPS, SYNC_SNAPSHOT_MAX_MEMBERS.
pwsh -NoProfile -File infra/sync/Invoke-SnapshotApply.ps1 -AnswersFile $answers -VmName ccof-jumpbox-sync `
  -SnapshotPath .env.sync-snapshot.json -ExpectedSnapshotSha256 <sha256 printed by the snapshot command> `
  -SettingsPath .env.sync-apply-settings.json -MaxScriptBytes 262144 -AuditPath $audit
```

The runner checks size first, then schema, tenant, maximum age, and group and member counts; refuses
a snapshot that names a group no valid project registers (`snapshot_group_unregistered`); freezes a
project whose registered group is missing from the snapshot (`snapshot_group_missing`); then plans
and writes exactly as the timer does. A snapshot no newer than the evidence already applied (the
lease's `evidenceAt`: the last Graph run or applied snapshot) is refused
(`snapshot_older_than_applied`), so an old file cannot undo later removals. The run line carries
`source: "snapshot"`, the snapshot's SHA-256 and `readAt`. The wrapper refuses a file whose SHA-256
differs from `-ExpectedSnapshotSha256` and uncommitted `src/sync`; its audit line records the commit
and the bundle's SHA-256; its exit code follows the run (0, 1, 3, 4).

**Transport and size.** The script carries three base64 blocks: the built `dist/sync` with the lock
file (the runner installs the same dependency versions), the snapshot and the settings. Microsoft
Learn documents no maximum size for an action Run Command script or its parameters (checked
2026-10-11: "Run scripts in a Linux VM in Azure using action Run Commands", the `az vm run-command`
reference and the `RunCommandInput` REST schema); it states that "Output is limited to the last
4,096 bytes". So `-MaxScriptBytes` is required and enforced before any call, and the run line is
printed last. Measured 2026-10-11: a 39,521-byte script ran.

**Trust.** A snapshot is as trustworthy as the person who made it and the files they hand over; the
runner cannot tell a forged member list from a real one, though it limits a forgery to registered
groups and the limits, models and backends of `projects`. The SHA-256 ties each apply to the exact
file. The runner identity can write `entitlement` directly: anyone with Run Command on the VM, or a
shell on it, holds that power. D3 grants it only in `delegated-snapshot` mode, to the
`privateRunnerPrincipalIds` list, which onboarding's runner shares (a separate sync-runner list is
architecture proposal 11). Grant before an apply and remove after when you can. The timer path with
the application permission has none of these steps.

**4. Delete the runner** when done: the VM, its OS disk and NIC, and its three Cosmos role
assignments.
### Apply through the sync Function App without a runner VM

When the sync app already has private-network access and its approved Cosmos roles,
an operator can apply a delegated snapshot through its conditional snapshotApply timer:

```powershell
pwsh -File infra/sync/Invoke-SnapshotApplyThroughFunction.ps1 -Subscription <sub> -ResourceGroup <rg> `
  -FunctionApp <prefix>-sync-func -AppInsights <prefix>-sync-ai -SnapshotPath .env.sync-snapshot.json `
  -ExpectedSnapshotSha256 <sha256 printed by the snapshot command>
```

The helper checks the file's SHA-256 before any Azure call, sets the temporary base64
snapshot/hash, a fresh operation ID and explicit limits, enables snapshotApply, resynchronizes triggers,
polls for that operation's snapshot run line, and always disables the function and removes
temporary settings. The function revalidates tenant, age, schema, size and hash,
then uses the same registered-group, lease, generation and removal safeguards.
Keep the ordinary sync timer disabled when its Graph application permission is absent.

Anyone allowed to edit the sync app's settings has the delegated snapshot trust
described above; SHA-256 is integrity binding, not proof of directory membership.
Windows command-line transport is limited to 7,000 base64 characters; Cloud Shell's
helper limit is 96 KiB. This is not a large-fleet transport guarantee. Offline tests
do not establish this path's live acceptance.

The operator helper wakes the app using an anonymous HTTPS GET after setting the
snapshot and synchronizing triggers, and repeats the wake while `snapshotApply`
is unlisted. A live attempt showed that settings changes and trigger synchronization
alone did not start a scaled-to-zero Flex host. The response can be 404; polling
still requires the matching snapshot run outcome. Restricted inbound access must
permit the operator's wake request; this does not bypass network policy.

Hostname lookup is retried at most three times before any settings mutation; a missing host
refuses with `snapshot_hostname_unavailable` and a permission/connectivity check.
The default is 30 polls with 20-second sleeps between attempts, not a ten-minute elapsed
deadline: serial query/wake requests and Azure CLI time add to the sleep budget.
Queries and wakes each have a 60-second request timeout; allow additional request time.
Current-attempt telemetry uses the temporary operation ID, including hashless refusals.
A successful apply is retained over later timer replay refusals. Deploy matching current
sync code and operator helper together: older Function code lacks the required operation ID.

## Telemetry

`ccof.sync.run.v1` (one per run, the last line): `runId`, `trigger`, `writeMode`, `outcome`
(`succeeded`, `partial`, `skipped`, `failed`), `reasons`, `refusals`, `startedAt`, `finishedAt`,
`durationMs`, `timings` (lease, projects, groups, entitlements, plan, apply) and `counts`
(projects read, valid and frozen; groups read and failed; members read, admitted, disabled
(`membersDisabled`) and with an unread account state (`membersAccountStateUnread`); documents read
and ignored; created, replaced, upserted, unchanged; removed and withheld memberships; emptied
documents; write conflicts and failures; classification conflicts).

`ccof.sync.event.v1` (one per refusal, conflict or notice): `runId`, `event`, `reason` and, where
they apply, `projectId`, `groupId`, `personId`, `memberId`, `classifications`, `kept`, `problems`,
`httpStatus`, `graphErrorCode`, `errorCode`, `counts`. Ids and codes only, never names or UPNs.

In the app, both go to Application Insights traces (Entra-authenticated ingestion).
