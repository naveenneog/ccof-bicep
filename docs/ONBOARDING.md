# Onboarding

WP-ONB implements the P-2 stage contract. ADR-0012 (internal record, not published) records the private-runner boundary and the owner's explicit-decision requirement.

## Decisions and confirmation

A stage accepts either `-AnswersFile <JSON path>` or `-Interactive`. No operational choice has a default. Interactive prompts take JSON values and require an explicit `true` for confirmation. The prompt reader is injectable in tests.

The answers envelope is:

```json
{
  "schemaVersion": 1,
  "decisions": {},
  "confirmedDiscovery": {},
  "confirm": true
}
```

`decisions` uses that stage's schema. Unknown properties, missing decisions, invalid types and invalid ranges refuse. An unattended refusal lists all missing decisions together. `confirmedDiscovery` is the exact non-secret snapshot returned by `-DiscoverOnly`; a changed resource or identifier requires confirmation again. Discovery-only needs the decisions but does not need `confirm` or `confirmedDiscovery` and performs no remote write.

Pilot examples also carry `provenance: {allDecisionValues: "coordinator_default",
ownerConfirmed: false}`. This marks every nested decision value as a coordinator
default. Discovery accepts unconfirmed examples; apply requires both
`provenance.ownerConfirmed: true` and `confirm: true`. Neither flag is inferred.

The current Azure CLI identity supplies attribution; answers cannot name `CompletedBy`. The selected subscription and tenant are explicit decisions. The selected tenant must equal the signed-in tenant. No stage changes the machine's current subscription or login.

## Checkpoint record

The existing `stages` array remains compatible with earlier records. A completed entry contains `stageId`, `completedBy`, `completedAt` and `evidence`. A separate append-only `decisions` array records:

| Field | Meaning |
|---|---|
| `stageId` | Stage that asked the question |
| `questionId` | Stable question path, such as `resilience.budgetStateGraceSeconds` |
| `value` | Validated JSON answer or confirmed non-secret discovery |
| `who` | Signed-in Entra object id |
| `when` | UTC ISO 8601 timestamp |
| `source` | `prompt`, `answers_file` or `confirmed_discovery` |

Decision history can exist for a refused or failed stage; it does not mean the stage completed. Schema-invalid inputs are not recorded. Retrying checks current permissions and current provider state rather than trusting a prior completion alone. Earlier completions remain historical evidence, not a live-health assertion.

## Structured audit

Every run appends UTF-8 JSON lines to `<CheckpointPath>.audit.jsonl`. This local audit is written even when remote operations are refused. It is distinct from an Azure/Graph/Cosmos write.

```json
{
  "schemaVersion": 1,
  "timestamp": "2026-10-11T00:00:00.0000000+00:00",
  "runId": "random-per-run-uuid",
  "stageId": "stage-3-project:PROJECT1",
  "event": "write_performed",
  "actorId": "signed-in-object-id",
  "tenantId": "selected-tenant-id",
  "data": { "operation": "create", "target": "projects:PROJECT1" }
}
```

| Event | `data` |
|---|---|
| `stage_start` | Empty object; actor can be null before identity discovery |
| `decision_recorded` | Question id and provenance source; values remain in the checkpoint only |
| `precondition_refused` | Reason code; the caller receives the separate human-readable remedy |
| `write_performed` | Operation name and non-secret target identifier |
| `resource_created` | Operation, logical target id and validated created resource id; a resumable creation receipt |
| `completed` | Empty object, or reason code `discovery_only` |
| `failed` | Reason code, never a provider payload or remedy text |

This is an event envelope for later Log Analytics ingestion, not an installed forwarding pipeline. Audit data is restricted to identifiers and reason/provenance codes. Keys, bearer tokens, decision values, raw provider errors and request/response bodies are not audit fields. Checkpoints contain identifiers and budget configuration; their storage, access control and retention belong to the operating team. The checkpoint and audit travel together because audit creation receipts support safe retries. Neither is a tamper-proof security log.

## Availability decisions

The admin supplies whole-second `resilience.budgetStateGraceSeconds` and `resilience.budgetStateHardLimitSeconds`, with `0 <= grace <= hardLimit`. No implicit zero or suggested value is accepted on the admin's behalf. These map to WP-RES settings `RESOLVER_BUDGET_STATE_GRACE_SECONDS` and `RESOLVER_BUDGET_STATE_HARD_LIMIT_SECONDS`.

Both intervals are measured after `validUntil`. Runtime use of last-known ceilings through the hard limit is the resolver's responsibility (WP-RES / ADR-0008); grace changes the degraded-state severity. Stage 5 initial enforcement still requires fresh records. Ordered backend failover members stay within the designated subscription; no decision permits another project's subscription to pay for a request.

Recording availability decisions is not proof of regional or fleet availability. Runtime deployment, capacity, redundant failure domains and the 500,000-developer single-failure requirement remain separate milestone work.

## Stage 1 — groups and owners

`scripts/Stage1-CreateClassificationGroups.ps1` accepts the common switches above. `Get-OnboardingSchema -Stage 1` from `scripts/Onboarding.Schemas.psm1` returns the decisions JSON Schema.

| Decision | Value |
|---|---|
| `subscriptionId`, `tenantId` | Explicit Azure CLI context; no account selection is changed |
| `projectId` | Admin-chosen project identifier |
| `creationAuthority` | `directoryRole` or `selfServiceOwner`, explicitly selected |
| `classifications` | Nonempty array of `{classification, groupName, mailNickname}`; all three values are explicit and distinct |
| `projectLeadIds` | Nonempty, distinct array of enabled Entra user object ids |

The directory-role path requires Groups Administrator (or Global Administrator)
and delegated Graph `Group.ReadWrite.All`. The self-service path requires an
enabled member user who is explicitly among the chosen owners. Existing groups
must already be owned by that user. Creating new groups additionally requires a
live `allowedToCreateSecurityGroups: true` policy result; inability to read it
refuses with the `Policy.Read.All` remedy. Global Reader is not treated as write
authority. Existing owned groups need no new-group-creation permission.

Stage 1 confirms existing ids, creates missing flat non-role-assignable security
groups, and adds only missing owner references. In self-service mode, creation
omits owners and then verifies actual automatic ownership; the Graph known
issue forbidding a non-admin self-owner binding is not bypassed. A creation
receipt is recorded before the ownership read, so a retry uses the created id
even if the name listing is stale. Missing ownership refuses completion.
Dynamic, mail-enabled, role-assignable, ambiguous or differently named groups
refuse. No directory role or group membership is granted by Stage 1.

A normal sequence is a discovery-only run, review of its `Discovery` object, then an apply with that object in `confirmedDiscovery`. Existing names/ids are rediscovered on retries; ownership additions are idempotent. Group creation or ownership failure does not mark the stage complete. The supplied JSON and checkpoint contain no keys.

Group owners can subsequently manage membership without a directory role.
Sources, retrieved 2026-10-11: [Graph add owners](https://learn.microsoft.com/graph/api/group-post-owners?view=graph-rest-1.0),
[Graph add members](https://learn.microsoft.com/graph/api/group-post-members?view=graph-rest-1.0),
[group creation and the self-owner issue](https://learn.microsoft.com/graph/api/group-post-groups?view=graph-rest-1.0),
[creation policy](https://learn.microsoft.com/graph/api/resources/defaultuserrolepermissions?view=graph-rest-1.0),
[policy read permission](https://learn.microsoft.com/graph/api/authorizationpolicy-get?view=graph-rest-1.0).

The provider adapter uses native HTTP JSON bodies and disables redirects. Only token acquisition and simple role lookups cross `az.cmd`; their arguments are validated and always include `--subscription`. JSON quotes and encoded Graph query strings never cross the Windows command shell.

## Stage 2 — backend registration

`scripts/Stage2-RegisterBackend.ps1` uses schema `2`. The admin supplies `subscriptionId`, `tenantId`, `apimResourceId`, `designatedSubscriptionId`, `foundryAccountResourceId`, `backendId`, `backendAuthMode`, `reconcilerResourceId`, `backendFailoverOrder` and `costQueryPeriod: {from,to}` in UTC.

`managed-identity` (`managedIdentity` remains accepted for existing answers)
implements same-tenant registration. The reconciler resource is a Function App
or user-assigned managed identity. The script discovers both principals, the
designated tenant, the Foundry subdomain, backends and existing grants.
`DiscoverOnly` emits `{principal,role,scope}` permission data. D3 applies it;
Stage 2 refuses to create a backend until the grants are verified. Stage 2
performs no role-assignment write.

`second-tenant` confirms an **existing D2-configured** Validation backend, without a
foreign login, directory write, credential creation or model deployment. It
requires `backendTenantId` and `secondTenantAuth`, exactly one of:

```json
{"mode":"existing-named-values","clientId":"<Validation app client GUID>","secretNamedValueId":"<secure APIM named-value id>"}
```

```json
{"mode":"credential-manager","providerId":"<APIM provider id>","connectionId":"<connection id>"}
```

The backend and credential reference must exist; a named-value reference must
be marked secret. Only references are read/recorded, never secret values. The
credential-manager variant returns a C-8 descriptor for the registry consumer.
Legacy named values remain the already-configured gateway fallback, not a new
registry auth mode. Actual token exchange and the connection's access policy
remain D2/D3/coordinator verification; evidence explicitly says
`runtimeAuthVerified: false`. A coordinator gateway smoke call proves runtime
authentication. The obsolete `crossTenantOAuth2` spelling is not accepted.

| Actor / identity | Role | Scope |
|---|---|---|
| Registration operator | API Management Service Contributor, Contributor or Owner | Gateway resource |
| Registration operator, managed identity mode | Reader, Contributor or Owner | Foundry account and designated subscription |
| Registration operator | Reader, Contributor or Owner | Reconciler identity resource |
| APIM managed identity | Cognitive Services User, applied by D3 | Foundry account |
| Reconciler managed identity | Cost Management Reader, applied by D3 | Designated subscription |
| Billing administrator | Billing-account cost-visibility authority | EA “AO view charges” or MCA “Azure charges”; not a service identity's billing-scope role |

Contributor alone is not role-assignment authority; that authority is confined
to D3. Unevaluated conditional Azure assignments do not authorize a stage. Named
role checks select each checked scope's subscription, not the machine's current
subscription. Private approved-plan apply additionally disables Graph group
expansion.

The backend URL is `https://<confirmed-custom-subdomain>.services.ai.azure.com/anthropic`. An existing backend with a different account, URL, protocol, credentials or disabled TLS verification refuses instead of being overwritten. No APIM service-level update is performed, so this operation does not replace the gateway's managed-identity configuration.

`backendFailoverOrder` includes the chosen primary first. Every later member must already be a registered Foundry backend in the same designated subscription. The order is recorded, not deployed as runtime failover policy.

Cost visibility is `visible` only when the explicit-period Cost Management query returns rows; `no_rows` is inconclusive and `unavailable` covers denial or failure. Evidence names the query identity, not the reconciler. A grant plus the operator's successful query does not prove the reconciler's grant has propagated. Billing visibility remains a separate prerequisite for reconciliation.

Sources, retrieved 2026-10-11: [Azure privileged roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/privileged), [role assignment API](https://learn.microsoft.com/rest/api/authorization/role-assignments/create?view=rest-authorization-2022-04-01), [backend API](https://learn.microsoft.com/rest/api/apimanagement/backend/create-or-update?view=rest-apimanagement-2024-05-01), [Cost Management query](https://learn.microsoft.com/rest/api/cost-management/query/usage?view=rest-cost-management-2025-03-01), [cost access](https://learn.microsoft.com/azure/cost-management-billing/costs/assign-access-acm-data).

## Stage 3 — project registration

`scripts/Stage3-RegisterProject.ps1` uses schema `3`. Its decisions are `subscriptionId`, `tenantId`, `apimResourceId`, `registry: {accountResourceId,endpoint,database}`, the full `project` document, `resilience`, `backendRegistrationMode` and `dependencyValidation`.

`ConvertTo-OnboardingProjectDocument` in `scripts/Onboarding.Projects.psm1` is the pure build/validation step. The document follows LLD §1: `id`, `projectId`, `displayName`, `status`, `backendId`, `designatedSubscriptionId`, `classifications`, `supersedes`, `retiredAt`. Initial registration supports `status: active`, `supersedes: null` and `retiredAt: null`; retirement, rename and budget changes are not implicit upserts.

Each classification explicitly supplies `groupId`, `modelAllowList`, `personBudget`, `aggregateBudget`, `aggregateMode` and `onboardingMode`. The latter is the checkpoint-flow decision now materialized in the classification. Budget objects are `{amount,currency,period}`: nonnegative amounts, an explicit `CCU` or `USD`, and `monthly`. An uncapped aggregate is the explicit value `null`. No missing unit, period or mode gets a default. 25,000 CCU and USD 250 describe the same commitment but retain their chosen unit in the document.

M1.7 contract C-5 additionally requires `tokenLimits` on every classification.
Its `person` and `group` objects each contain `tokensPerMinute`, `tokenQuota`
and `tokenQuotaPeriod`. Numeric limits are positive integers or null. Quota
and period are both null or both set; periods are exactly `Hourly`, `Daily`,
`Weekly`, `Monthly` and `Yearly`. Unknown fields, zero, negative, fractional,
string and boolean limits refuse. These limits are independent of CCU budgets;
the pilot enforces token limits and reports CCU budgets (`docs/PILOT.md`).

| Operator permission | Scope |
|---|---|
| Azure Reader, Contributor or Owner | Registry account and gateway metadata |
| Cosmos data-plane `readMetadata`, `containers/items/read`, `containers/items/create` | `projects` container; normalized by the preflight as `Cosmos Onboarding Writer` |
| Delegated Graph group/member read access | Each chosen classification group |

Cosmos preflight evaluates direct principal assignments, matching container scopes and data actions. Azure Owner alone and another container's grant do not authorize the write. The tool does not infer group-inherited Cosmos data permissions.

Apply requires public network access `Disabled`, the confirmed account endpoint and private DNS addresses only. An authenticated project point read then verifies the data path. A developer machine outside the VNet receives the named private-runner remedy; there is no public endpoint exception, key-auth fallback or automatic jump-box creation.

Missing groups, nested groups, overlapping members across classifications, duplicate group ids and an unregistered or wrong-subscription backend refuse before a write. The confirmed snapshot gives group ids/names/counts and the backend account. A matching existing document is a no-op; a different one refuses. A create uses `/projectId` as the partition key, not an upsert. The checkpoint records the response's actual `x-ms-request-charge` in RU when available.

Sources, retrieved 2026-10-11: [Cosmos Entra/data-plane RBAC](https://learn.microsoft.com/azure/cosmos-db/how-to-connect-role-based-access-control), [Cosmos REST authorization](https://learn.microsoft.com/rest/api/cosmos-db/access-control-on-cosmosdb-resources), [create document and request charge](https://learn.microsoft.com/rest/api/cosmos-db/create-a-document). The private-runner requirement was measured in this repository (U-13; `infra/poc/jumpbox-full-test.sh`).

### Existing backend and private-runner handoff

`backendRegistrationMode: designated_foundry` retains the account/subscription
checks above. `existing_apim` verifies the exact existing APIM entity name
without requiring Stage 2 or access to the backend's tenant. No backend, policy,
credential or named value is changed. Credential-bearing URLs are not copied
into the dependency evidence.

`dependencyValidation` is explicit:
- `{"mode":"live","validUntil":null}` checks Graph/APIM and Cosmos from one
  authorized, private-endpoint-reachable caller.
- `{"mode":"approved_plan","validUntil":"<owner-chosen UTC instant>"}` separates
  the owner's workstation preflight from private apply. There is no default
  lifetime. A deadline is rechecked after confirmation, immediately before apply.

The workstation runs `-PublicPreflight` and saves a reviewed `-PlanPath`.
It checks the project schema, current groups/membership conflicts, backend
existence and the owner's APIM read permission. It does not contact Cosmos.
The plan binds every decision and the dependency evidence by digest and records
the preparing identity and expiry. A digest protects integrity, not provenance:
this is an operator-controlled artifact, not a signature or an Azure role grant.

The private runner uses `-DependencyPlan`. It needs **Azure Reader on the Cosmos
account**, plus Cosmos data-plane **readMetadata, items/read and items/create**
on `/dbs/<database>/colls/projects`: readMetadata for the role check, items/read
for its point reads, items/create for the one write. D3 grants exactly these
through a custom role named by `names.cosmosRoles.projectWriter`
(`docs/examples/onboarding.permissions.json`), and refuses Cosmos DB Built-in Data
Contributor (`00000000-0000-0000-0000-000000000002`), which also allows delete
and every container action. Azure Owner alone is not data access. Private ARM
role lookup uses the known principal id without Graph lookup or group expansion;
direct or inherited principal grants are required. The runner needs neither
Graph nor APIM access.

Private apply revalidates the plan/digests/deadline, its current identity and
permissions, the account/endpoint binding, private-only DNS and the existing
project. It confirms the newly discovered runner/network ids before a create.
It never upserts a different project. After creation it echoes the Cosmos
session token **in memory only** for read-your-write verification and compares
the read-back against the approved document. A mismatch, absent read-back or
expired plan prevents completion. Both preparing owner and applying runner are
attributed in the checkpoint. No bearer token or CLI token cache is transferred.

### Tonight's pilot: owner correction, 2026-10-11 18:21 IST

Claude remains only in Validation subscription
`00000000-0000-4000-8000-000000001000`. No Claude account, model or Marketplace
offer is created in Contoso. Tonight uses Contoso APIM/Cosmos and the existing
second-tenant `foundry-sample-hub` backend:

| Example | Groups | Backend |
|---|---|---|
| `docs/examples/pilot01-stage{1,3}.answers.json` | CCOFPILOT01STD, CCOFPILOT01PRM, CCOFPILOT01CYB | foundry-sample-hub |
| `docs/examples/pilot02-stage{1,3}.answers.json` | CCOFPILOT02STD | foundry-sample-hub |

The files' provenance applies to **every nested value**: supplied values are
coordinator defaults awaiting owner confirmation. Null group ids await actual
Stage 1 results. Null grace/hard limits and plan expiry are **undecided**, not
zero/default values. They must be explicitly supplied. The models, token limits
and CCU budgets are the `PILOT.md` table. The same code can target the full core
in Validation by supplying Validation deployment values and a same-tenant backend; the owner's
separate Validation sign-in and environment validation are outside tonight's run.

## Exact coordinator commands

These commands describe operator actions; WP-ONB did not execute them live.
PowerShell 7 and Azure CLI are prerequisites. `$Repo` is the checkout containing
the approved commit; all local artifacts below stay in its ignored `.env.pilot`
directory. The owner workstation uses its existing signed-in Azure CLI profile.
No login, logout, subscription switch, VM creation or model deployment is part
of these commands.

### 1. Workstation: Stage 1 discovery, explicit approval, apply

```powershell
$Repo = Read-Host 'Reviewed repository checkout, absolute path'
Set-Location -LiteralPath $Repo
$Commit = Read-Host 'Full reviewed commit SHA containing these scripts'
if ($Commit -notmatch '^[0-9a-f]{40}$') { throw 'A full reviewed SHA is required.' }
git diff --quiet $Commit -- scripts
if ($LASTEXITCODE -ne 0) { throw 'Local scripts differ from the reviewed commit.' }
$env:AZURE_CONFIG_DIR = Read-Host 'Existing signed-in owner Azure CLI profile directory'
$Pilot = Read-Host 'Pilot suffix: 01 or 02 (no default)'
if ($Pilot -notin @('01','02')) { throw 'Pilot must be 01 or 02.' }
$Work = Join-Path $PWD ".env.pilot\$Pilot"
New-Item -ItemType Directory -Path $Work -Force | Out-Null
$S1 = Join-Path $Work 'stage1.answers.json'
$S3 = Join-Path $Work 'stage3.answers.json'
$Checkpoint = Read-Host 'Existing shared C-9 checkpoint file (contains stage-D1)'
if (-not (Test-Path -LiteralPath $Checkpoint)) { throw 'The D1 checkpoint is required; no new deployment record is invented.' }
$Plan = Join-Path $Work 'dependency.plan.json'
Copy-Item "docs\examples\pilot$Pilot-stage1.answers.json" $S1
Copy-Item "docs\examples\pilot$Pilot-stage3.answers.json" $S3
Import-Module .\scripts\Onboarding.Decisions.psm1
. .\scripts\Stage1-CreateClassificationGroups.ps1 -DotSourceOnly
function Save-Answers($Value,$Path) {
    $Value | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $Path -Encoding utf8
}
$d = Invoke-Stage1CreateGroups -AnswersFile $S1 -CheckpointPath $Checkpoint -DiscoverOnly
if (-not $d.Satisfied) { throw $d.Remedy }
$a = ConvertFrom-OnboardingJson (Get-Content $S1 -Raw)
$a.decisions | ConvertTo-Json -Depth 64
$d.Discovery | ConvertTo-Json -Depth 64
if ((Read-Host 'Owner approves these decisions and discoveries? Type APPROVE') -cne 'APPROVE') { throw 'Not approved.' }
$a.provenance.ownerConfirmed = $true
$a.confirm = $true
$a.confirmedDiscovery = $d.Discovery
Save-Answers $a $S1
$r = Invoke-Stage1CreateGroups -AnswersFile $S1 -CheckpointPath $Checkpoint
if (-not $r.Satisfied) { throw $r.Remedy }
$r.Evidence.groups
```

A policy-read refusal names `Policy.Read.All`; it is not permission to bypass
the precondition. An owner can instead use already-owned groups created through
an approved directory process. A partial creation retains ids in the audit;
subsequent discovery and confirmation resume those ids without duplicating them.
Stage 1 does not add the owner as a group member.

### 2. Workstation: complete Stage 3 answers and prepare the handoff

```powershell
Import-Module .\scripts\Checkpoint.psm1
. .\scripts\Stage3-RegisterProject.ps1 -DotSourceOnly
$a = ConvertFrom-OnboardingJson (Get-Content $S3 -Raw)
$id = $a.decisions.project.projectId
$stage = @((Get-CheckpointRecord $Checkpoint).stages | Where-Object {
    [string]::Equals($_.stageId,"stage-1-groups:$id",'Ordinal')
})
if ($stage.Count -ne 1) { throw 'Exactly one completed Stage 1 record is required.' }
foreach ($classification in $a.decisions.project.classifications.Keys) {
    $g = @($stage[0].evidence.groups | Where-Object {
        [string]::Equals($_.classification,$classification,'Ordinal')
    })
    if ($g.Count -ne 1) { throw "Missing/ambiguous Stage 1 group: $classification" }
    $a.decisions.project.classifications[$classification].groupId = $g[0].groupId
}
$grace = Read-Host 'Owner-selected budget grace seconds; no default'
$hard = Read-Host 'Owner-selected budget hard-limit seconds; no default'
if ($grace -notmatch '^[0-9]+$' -or $hard -notmatch '^[0-9]+$') { throw 'Both settings require explicit whole seconds.' }
$a.decisions.resilience.budgetStateGraceSeconds = [int]$grace
$a.decisions.resilience.budgetStateHardLimitSeconds = [int]$hard
$a.decisions.dependencyValidation.validUntil = Read-Host 'Owner-selected plan expiry, UTC yyyy-MM-ddTHH:mm:ssZ; no default'
Save-Answers $a $S3
$d = Invoke-Stage3RegisterProject -AnswersFile $S3 -CheckpointPath $Checkpoint -PublicPreflight -DiscoverOnly
if (-not $d.Satisfied) { throw $d.Remedy }
$a.decisions | ConvertTo-Json -Depth 64
$d.Discovery | ConvertTo-Json -Depth 64
if ((Read-Host 'Owner approves the project, limits, expiry and dependencies? Type APPROVE') -cne 'APPROVE') { throw 'Not approved.' }
$a.provenance.ownerConfirmed = $true
$a.confirm = $true
$a.confirmedDiscovery = $d.Discovery
Save-Answers $a $S3
$r = Invoke-Stage3RegisterProject -AnswersFile $S3 -CheckpointPath $Checkpoint -PublicPreflight -PlanPath $Plan
if (-not $r.Satisfied) { throw $r.Remedy }
```

### 3. D3 runner permission data

The runner is an **existing**, coordinator-selected VM inside the VNet, with
PowerShell 7, Python 3 and Azure CLI already installed. Its owner has already
established a managed-identity CLI session in a runner-specific profile. The
profile path and expected principal are explicit below. No workstation login
cache or token is copied. C-9 assigns all permission changes to WP-CORE's D3,
not to this onboarding script. This step emits the required assignment data;
D3 applies and verifies it before private apply. The package data is
`docs/examples/onboarding.permissions.json`, in the agreed `ccof.assignments`
format. It uses `${answers.permissions.privateRunnerPrincipalIds}` and the
recorded D1 Cosmos id, not hardcoded resource ids.

```powershell
$Sub = $a.decisions.subscriptionId
$RegistryId = $a.decisions.registry.accountResourceId
$parts = $RegistryId -split '/'
$CosmosRg = $parts[4]; $CosmosAccount = $parts[8]
$RunnerRg = Read-Host 'Existing runner resource group'
$Runner = Read-Host 'Existing private runner VM name'
foreach ($name in @($RunnerRg,$Runner)) {
    if ($name -notmatch '^[A-Za-z0-9._-]+$') { throw 'Unsafe Azure CLI name.' }
}
$RunnerId = az vm show --subscription $Sub -g $RunnerRg -n $Runner --query identity.principalId -o tsv
if ($LASTEXITCODE -ne 0 -or $RunnerId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Runner identity was not discovered.' }
if ((Read-Host "Confirm runner principal $RunnerId and D3 permission plan? Type APPROVE") -cne 'APPROVE') { throw 'Not approved.' }
Copy-Item .\docs\examples\onboarding.permissions.json "$Work\onboarding.permissions.json"
```

D3 includes that file in its permission sources. The D3 operator explicitly
includes `$RunnerId` in Core answers `permissions.privateRunnerPrincipalIds`.
Private Stage 3 reads `stage-D1`, `stage-D2:schema` and `stage-D3` from the same
record and independently verifies current assignments. Missing records or
permissions refuse. Existing PoC grants are verified, not assumed.

For both pilot projects, the workstation completes steps 1–2 for **01 and 02
using the same checkpoint** before the first private transfer. Private runs
also share one runner work directory and checkpoint. The transfer does not
overwrite an existing runner checkpoint/audit with an older workstation copy.

### 4. Stage 3 private apply: code, probe, apply

`scripts/Invoke-Stage3PrivateRunner.ps1` sends the reviewed code and one project's
handoff to the runner through Azure Run Command and runs
`scripts/runner/run-private.ps1` there. No workstation login cache or token
reaches the runner; it signs in with its own managed identity.

**Runner configuration.** Copy `docs/examples/stage3-runner.json` (the Contoso
PoC runner `ccof-jumpbox-sync`, as used on 2026-10-12) and set every value:
`runner.subscriptionId`, `runner.resourceGroup` and `runner.vmName` (the VM of
step 3), `remote.workDirectory` (a dedicated runner directory) and
`remote.azureConfigDir` (the runner's Azure CLI profile).
`scripts/runner/stage3-runner.schema.json` checks it; a missing or unsafe value
refuses and is named. The subscription that Stage 3 uses comes from the answers
(`decisions.subscriptionId`). Local paths are parameters.

**Runner profile.** Sign the runner's profile in with `az login --identity`
after D3's role grants, and again after any later grant to the runner. A
profile signed in earlier keeps its old subscription list: on 2026-10-12,
`/opt/ccof/runner-az` failed with "Subscription ... not found" until it was
signed in again into the same profile, after a backup; no role was added
(`docs/status/WP-ONB.md:193`). The Azure CLI caches subscriptions locally
(`az account list --refresh`: "Retrieve up-to-date subscriptions from server";
Microsoft Learn, `az account` reference, retrieved 2026-10-12). On the runner,
for example through Run Command, with the configured `remote.azureConfigDir`:

```bash
AZURE_CONFIG_DIR=/opt/ccof/runner-az az login --identity
```

`run-private.ps1` refuses with `runner_identity_unavailable` and this remedy
when the profile cannot get a token for the answers' subscription.

**Commands**, from the reviewed checkout. `$Work` and `$Checkpoint` are those of
steps 1 and 2; `$Commit` is the full SHA of the reviewed commit, checked out.

```powershell
$Config = Read-Host 'Runner configuration file (a copy of docs/examples/stage3-runner.json)'
$Commit = Read-Host 'Full reviewed commit SHA, checked out in this checkout'
pwsh -NoProfile -File .\scripts\Invoke-Stage3PrivateRunner.ps1 -Part code -ConfigPath $Config -ReviewedCommit $Commit
pwsh -NoProfile -File .\scripts\Invoke-Stage3PrivateRunner.ps1 -Part probe -ConfigPath $Config -ReviewedCommit $Commit -WorkDirectory $Work -CheckpointPath $Checkpoint
# The owner reviews the printed discovery (runner and network ids, project state); it is saved in $Work\private.discovery.json.
pwsh -NoProfile -File .\scripts\Invoke-Stage3PrivateRunner.ps1 -Part apply -ConfigPath $Config -ReviewedCommit $Commit -WorkDirectory $Work -Confirmed
```

| Part | Sends | Runs on the runner | Success |
|---|---|---|---|
| `code` | Stage 3, every module it loads and `scripts/runner/run-private.ps1`, archived at `-ReviewedCommit` (13 files, 36,724 base64 characters at `f853563`) | Extracts them into `<workDirectory>/code/<commit>` | `CCOF_CODE_READY:<commit>` |
| `probe` | `stage3.answers.json`, `dependency.plan.json`, the checkpoint and its audit, and `runner.json` (the answers' subscription, the VM's managed identity principal, the profile) | Stage 3 with `-DependencyPlan -DiscoverOnly` | The discovery, printed and saved as `$Work\private.discovery.json` |
| `apply` | The answers, with that discovery as `confirmedDiscovery` | Stage 3 with `-DependencyPlan`: create, then read-back | `CCOF_STAGE3:{stageId, runnerId, reasonCode: project_readback_verified, alreadyComplete}` |

Guards:
- **Reviewed code.** The checkout must be at `-ReviewedCommit`, with no staged,
  unstaged or untracked change under `scripts/`. Probe and apply run only
  `code/<commit>` and refuse with `runner_code_missing` until `-Part code` has
  sent that commit.
- **Size.** Each call carries at most 48,000 base64 characters. A larger
  payload is refused before it is sent, never truncated.
- **Checkpoint.** The runner's checkpoint and audit are authoritative: the probe
  extracts them only when the runner has none. Because the first copy is kept,
  the probe refuses a checkpoint without this project's
  `stage-3-preflight:<projectId>` record from step 2.
- **Identity.** `run-private.ps1` refuses with `runner_identity_mismatch` unless
  the profile's signed-in identity is the VM principal that the probe
  discovered.
- **Apply.** It needs `-Confirmed` and a private discovery from the latest probe.
  Each probe first deletes the previous discovery and refuses with
  `private_discovery_stale` if it cannot.
- **One project at a time.** The runner keeps one set of answers, plan and
  `runner.json`, so run probe and apply for one project before the next. An
  apply against another project's plan refuses with `dependency_plan_mismatch`
  (`scripts/Onboarding.DependencyPlan.psm1:71`); nothing is written.
- **Azure CLI.** Every argument passes `Assert-OnboardingAzArguments`
  (`scripts/Onboarding.Azure.psm1:12`) and names `--subscription`.

Exit codes: 0 done; 1 the runner refused, its output was not recognized or an
Azure CLI call failed; 2 refused before any Azure call. A refusal prints
`CCOF_REFUSED <reasonCode>: <remedy>`. Stage 3's own refusals keep their reason
code and remedy, for example `precondition_refused: The runner refused: The
selected registry must match the discovered Cosmos endpoint with public network
access Disabled.` Run Command returns only the last 4,096 bytes of output
(Microsoft Learn, "Run scripts in a Linux VM in Azure using action Run
Commands", retrieved 2026-10-12), so the runner prints its result line last; a
missing or incomplete result line is refused and nothing is read from it.

The transfer contains no `.env`, CLI profile, key or token. Base64 is transport
encoding, not encryption; Run Command and the runner directory remain
operator-controlled. On the PoC runner, `run-private.ps1` and `scripts/` directly
under `/opt/ccof/stage3`, from the transfer of 2026-10-12, are no longer used.

### 5. Verified result

The authoritative completed checkpoint and identifier-only audit persist in
`remote.workDirectory` on the runner; the workstation copy retains the preparation
history. Operators retain and transfer the authoritative record through their
approved artifact channel for future stages; its full decision values are not
printed into Run Command logs.
No VM is deleted by this procedure. A repeat uses the same approved document and
fresh discovery; conflicting data refuses. `PILOT=02` repeats the same sequence
with the STD-only project and the same backend. Source for Run Command:
[Linux VM Run Command](https://learn.microsoft.com/azure/virtual-machines/linux/run-command),
retrieved 2026-10-11. Cosmos role and session-token semantics are in the sources
cited above.

### D4 portal evidence supplied by WP-SHOTS

| Step id | Portal view | Evidence state |
|---|---|---|
| D4-01 | Entra ID → Groups → General/settings: security-group creation policy | Capture requested |
| D4-02 | Entra ID → Groups: pilot group names, Security/Assigned | Capture requested |
| D4-03 | Each pilot group → Overview: object id | Awaiting coordinator-created ids |
| D4-04 | Each pilot group → Owners: owner object id; names/UPNs redacted | Capture requested |
| D4-05 | Each pilot group → Members: empty after Stage 1, then owner-authorized E2E add/remove | Capture requested |

The step list has been sent to WP-SHOTS. Live, redacted, annotated image links
are supplied by that package; placeholders are not presented as screenshots.

## Onboarding cost and capacity commitment

Prices below were retrieved from the **Azure Retail Prices API on 2026-10-11**,
in USD. East US 2 was the live Contoso gateway region read before the no-live
instruction. These are list prices, not negotiated invoice rates or a
recommendation to deploy an option. Validation region availability/policy validation
remains the owner's separate-profile check. D0 records all sizing, region,
replication, cache and always-ready choices; this sheet supplies no defaults.

### Incremental onboarding

| Item | Per-person/project effect |
|---|---|
| Group membership | Directory membership change; the sync writes the person's `entitlement` projection. Cosmos RU is measured per actual write, not inferred from group size |
| Project registration | One `projects` create for the project, not per member. Stage 3 records the create's actual `x-ms-request-charge` and verifies read-back |
| Legacy per-project key path | One APIM subscription entity and one `subscriptionIndex` document per person/project. No separate per-subscription-entity price appears in the retrieved APIM meters; requests still count toward the APIM call meter |
| Current pilot selector path | C-1 uses the selected project plus membership; per-person APIM keys are not needed for the pilot |
| Budget-state maintenance | Reconciler writes are recurring operational cost, separate from the one-time admission event |
| Capacity commitment | `activeMembers × personBudget`, in the explicitly selected unit. This is potential authorized spend, not a prepaid charge or actual bill |

At the retrieved Cosmos serverless rate, `writeCostUsd = measuredRU ×
0.25 / 1,000,000`. For example, **if** a write measures 5 RU, its request cost
is USD 0.00000125, excluding reads and storage. No live data-plane write was
performed to fabricate a fixed RU-per-person figure. For the pilot STD limit,
20 members imply 500,000 CCU (USD 5,000) of potential monthly capacity; actual
consumption can be lower.

APIM Standard v2 has a 25,000-subscription per-instance limit (U-25); the legacy
key path is not a 500,000-person scale design. Sources:
[APIM limits](https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits#api-management-limits),
[Cosmos request charge](https://learn.microsoft.com/rest/api/cosmos-db/create-a-document),
[CCU billing](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/claude-models-billing),
retrieved 2026-10-11.

### Platform fixed and usage costs

`H` is the administrator's selected monthly operating hours; 730 hours below
is an illustration only. Unit count, endpoints, zones and always-ready capacity
are separate explicit D0 decisions.

| Component / meter | Retrieved price | Cost interpretation |
|---|---:|---|
| APIM Standard v2 Unit, East US 2 | USD 0.9589 / hour | First unit: `0.9589 × H`; approximately USD 700 at 730 hours |
| APIM Standard v2 Secondary Unit, East US 2 | USD 0.68493 / hour | Additional unit: approximately USD 500 at 730 hours |
| Private Link Standard Private Endpoint, Global | USD 0.01 / hour | `endpointCount × 0.01 × H`; USD 7.30 per endpoint at 730 hours |
| Private Link data processed, Global | USD 0.01 / GB ingress and USD 0.01 / GB egress, first tier | Traffic-dependent, in addition to endpoint hours; subsequent API tiers are 0.006 and 0.004 |
| Private DNS Zone, global/empty region | USD 0.50 / zone, first 25; USD 0.10 thereafter | Zone/month; private queries are USD 0.40 / million |
| Log Analytics Analytics Logs Data Ingestion, East US 2 | USD 2.76 / GB above the API's 5-GB zero-price tier | Usage-dependent; free allowances are not assumed to remain available for this project |
| Functions Flex On Demand Execution Time, East US 2 | USD 0.000026 / GB-second above the API's 100,000-unit zero-price tier | No fixed on-demand instance floor |
| Functions Flex On Demand Total Executions, East US 2 | USD 0.000004 / 10 executions above the API's 25,000-unit zero-price tier | USD 0.40 / million executions; the API unit is **10**, not one execution |
| Functions Flex Always Ready Baseline, East US 2 | USD 0.000004 / GB-second | A selected always-ready instance adds baseline cost; it is not enabled by this runbook |
| Functions Flex Always Ready Execution Time / executions | USD 0.000016 / GB-second; USD 0.000004 / 10 executions | Usage on always-ready instances, in addition to baseline |
| Cosmos DB serverless 1M RUs, East US 2 | USD 0.25 / million RU | Operational request consumption; storage is separate |

Actual API queries (the `$filter` value is URL-encoded when requested):

```text
https://prices.azure.com/api/retail/prices?$filter=serviceName eq 'API Management' and armRegionName eq 'eastus2'
https://prices.azure.com/api/retail/prices?$filter=contains(productName,'Private Link')
https://prices.azure.com/api/retail/prices?$filter=serviceName eq 'Azure DNS'
https://prices.azure.com/api/retail/prices?$filter=serviceName eq 'Log Analytics' and armRegionName eq 'eastus2'
https://prices.azure.com/api/retail/prices?$filter=serviceName eq 'Functions' and armRegionName eq 'eastus2'
https://prices.azure.com/api/retail/prices?$filter=serviceName eq 'Azure Cosmos DB' and armRegionName eq 'eastus2'
```

Selected meter ids: APIM unit `00000000-0000-4000-8000-000000001001`;
private endpoint `00000000-0000-4000-8000-000000001010`;
private DNS zone `00000000-0000-4000-8000-000000001011`;
Log Analytics ingestion `00000000-0000-4000-8000-000000001100`;
Flex on-demand time `00000000-0000-4000-8000-000000001101`;
Flex executions `00000000-0000-4000-8000-000000001110`;
Cosmos RU `00000000-0000-4000-8000-000000001111`.

Sources: [Retail Prices API](https://prices.azure.com/api/retail/prices),
[DNS pricing period](https://azure.microsoft.com/pricing/details/dns/),
[Functions pricing](https://azure.microsoft.com/pricing/details/functions/),
retrieved 2026-10-11. Totals exclude storage, egress, optional Front Door/cache,
additional regional stamps and negotiated discounts unless the administrator
includes those components explicitly.
