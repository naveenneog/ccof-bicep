# Staged customer deployment and private VDI updates

**Historical four-stage plan.** The implemented driver now has stages 0-8; the four stage
numbers below are retained for reference, not as driver arguments.
The current [deployment runbook](DEPLOYMENT-RUNBOOK.md) includes the identity/network handoffs
and permission-separated commands. The [driver reference](STAGED-DEPLOYMENT-V2.md) describes
its implemented preview, apply, verification and recovery behavior.

**Current sequencing correction, 16 October 2026.** Use this runbook for the
public repository's customer deployment plan. The original
[completion workbook, Modules 00–16](PUBLIC-ACCESS-WORKBOOK.md) is retained as
historical, granular Portal/CLI instructions, not authorization to enable public
access or run all its permission steps as the application deployer.

**Release source:** v1 is on `feat/project-admin-api`; v2 is on
`feat/admin-console-v2`. A branch name is not a release approval. Record the
reviewed commit and package hashes. The [v2 feature/API contract, optional access
matrix and private-VDI upgrade](../ADMIN-V2.md) are in `docs\ADMIN-V2.md`; the v1 workbook's capability descriptions
are not a v2 specification. Updating the admin application does not redeploy the
inference gateway or reset the registry.

## 1. Four stages and acceptance gates

| Order | Owner and work | Required exit evidence |
|---|---|---|
| **1 — services only** | Platform team: `infra\staged\main.bicep` for approved **new** service resources. **Exclude all network components**, subnet attachments, VNet integration, private endpoints, DNS zones/groups/links, routes, NSGs, peerings and resolvers. No access grants. | Approved compiled resource inventory/what-if, successful deployment and exact resource/principal/hostname inventory. APIM requires the explicit new-public-bootstrap decision below. |
| **2 — identity/access handoff** | Separate identity/access team: Entra registrations/service principals, scopes, app roles, assignments/consent, managed-identity access, Azure RBAC and native Cosmos data roles. | Signed handoff with exact principal IDs, scopes/actions, role/consent read-back and authorized operator/deployment identities. No implicit grants by stage 1 or 3. |
| **3 — application initialization and release** | Application team: build code, verify/create only missing database/containers, inspect indexing, generate validated artifacts, create-only initial seed and publish app-specific code. Configure settings/auth/policy only after the access handoff. | Exact schema/data verification, immutable package hashes, retained rollback ZIPs, handler registration and applicable authenticated/read-only checks. No reset or upsert of existing project data. |
| **4 — customer network and acceptance** | Customer network/DNS team hand-configures the approved VNets/subnets, integrations, private endpoints, central DNS and client/VDI path. Application team then runs configuration diagnostics and live health/functional acceptance. | Actual endpoint NIC IPs, scoped DNS/route evidence from relevant hosts, authenticated health, authorized/negative functional tests and recorded access state. Static checker success is not production acceptance. |

**Private-bootstrap exception, not a public-access workaround:** if storage,
Cosmos or the publish/SCM endpoint is already private, or policy requires that
from creation, stage 3 may build offline but must pause before the blocked write
or probe. Prepare the required stage-4 network path first, then resume stage 3
from the approved VDI/private runner, and finish stage-4 acceptance. Do not
enable public network access (PNA), remove firewalls, enable storage keys or
relax SCM restrictions to preserve the nominal order.

Keep timers disabled until their own prerequisites pass. Reconciler stays off
in `token-limits-only`; seed and entitlement sync are separate operations.
Back up settings/auth/policy and retain approved ZIPs before any update.
Never publish private inputs, tokens, keys or customer backups.

### Implementation status: what can actually run today?

This document was checked against repository source and offline doc tests.
**No Azure deployment or customer acceptance was performed by this update.**
The commands below are existing script interfaces or explicit Azure CLI/REST
commands, not a new orchestration script.

| Existing path | Actual behavior and suitability |
|---|---|
| `infra\staged\main.bicep` | **New resource-only stage 1.** Cosmos account, workspace, sync/reconciler identities, separate resolver/sync/reconciler/optional admin Flex services with per-app storage/container/Insights/diagnostics; conditional new APIM shell and diagnostics. No database schema, settings, code, network resources/attachments or grants. |
| `infra\prereqs\all.bicep` | **Not stage 1.** Even with `network.mode = 'existing'`, its modules create Cosmos/blob private endpoints and DNS zone groups and attach Functions/APIM to subnets. |
| `infra\prereqs\function-app.bicep`, `cosmos-account.bicep`, `apim.bicep` | Also include network resources or integration. They cannot be advertised as resource-only leaf templates. |
| `infra\quickstart\Deploy-Quickstart.ps1` / `main.bicep` | Integrated deployment/configuration/access path. Existing-network mode is not a no-network/no-grants mode. Not this staged deployment entry point. |
| `infra\manual\Invoke-ManualConfiguration.ps1`, step 3 | Deploys `configuration.bicep` including Cosmos role definitions/assignments, Azure RBAC and optional Foundry assignments. **Not a permission-free stage 3.** Its checkpointed later steps depend on this step; do not skip it or manufacture state. |
| `infra\admin\admin-resources.bicep` | No private endpoints by default, but creates two IAM assignments and app settings; accepts an integration subnet and defaults storage PNA to Enabled. **Not the strict stage-1 resource-only template.** Do not use it to loosen existing production exposure. |
| `scripts\Stage-D2-DeploySchemaAndApps.ps1` | Existing checkpointed D2 schema/settings/auth/APIM/code flow, not Bicep service provisioning. Requires the matching D1 record; code also requires D3 evidence. Names/order D1/D2/D3 belong to that older flow, not the four stages here. |
| `scripts\manual\Run-Bundles.ps1` | Existing-resource helper; `Discovery`, `Settings`, `Publish`, `Artifacts` can be used explicitly below. **Roles belongs only to stage 2.** Not a service/network deployment script. |
| `scripts\portal\Build-PortalPackage.ps1` | Local resolver/sync/reconciler ZIP builder; accepts no admin app. |
| `infra\admin\admin-v2-catalog.bicep` | Optional **stage-3 schema only**: `adminConfig` container with `/scopeId` in an existing database. No account/service/network/grant creation. ARM upsert is not a create-only item seed; use only after missing-container verification and schema approval. |

The new template extracts service shapes into `infra\staged` without changing
the existing deployment templates. It compiles locally and has recursive static
no-network/no-grants tests. This is **not** live ARM/provider validation.
Service identities are enabled to obtain principal IDs, not to grant access.
Storage deployment containers are real, empty blob containers, not code packages.
No placeholder credentials, package URL, app settings or Entra app IDs are
invented; stage 3 supplies runtime configuration after stage-2 handoff.
Database/container schema remains stage 3. Services are intentionally non-running
until grants/configuration/network prerequisites pass.

**APIM provider constraint:** Azure permits disabling APIM public network access
only **after** an approved inbound private endpoint exists
([Microsoft Learn](https://learn.microsoft.com/en-us/azure/api-management/private-endpoint)).
A no-network template cannot honestly create a private-only APIM in one pass.
`approveNewPublicApimBootstrap` therefore defaults **false**: APIM is deferred,
with empty ID/URL/principal outputs and an explicit `apimStatus`. Set it true
only with customer approval to create a **new public service shell**, with
approved publisher contact/name. No API/backend/policy/code is published here.
The customer then prepares inbound Private Link and disables APIM PNA in stage 4
before private acceptance. If that public bootstrap is prohibited, stop the APIM
portion and agree an independently approved creation/private-endpoint procedure;
do not claim full stage-1/APIM completion from the default deferred outputs.
Never use this option against an existing private production APIM.

## 2. Pin the source and inventory existing services

Use PowerShell **7.2+**, Node/npm and Azure CLI on the approved operator host.
Use the approved checkout directory; all paths below are repository-relative.
Do not discard local changes or switch an in-use checkout during a deployment.

```powershell
git status --short
git branch --show-current
git rev-parse HEAD
```

**Check:** reviewed v2 source is on `feat/admin-console-v2`, with an approved
commit/diff. For a clean, separate existing checkout, select the branch only
after preserving local work:

```powershell
git switch feat/admin-console-v2
if ($LASTEXITCODE -ne 0) { throw 'Select the reviewed v2 checkout before continuing.' }
git rev-parse HEAD
```

Use workbook **00.8 / 01.2** to prepare the private `customer-inputs.json`.
Do not replace verified customer resource names/database IDs with lab defaults.
Set `$out` to the approved restricted artifact directory; example below uses a
private, ignored directory in this checkout. Confirm it is ignored before
creating private inputs. It is not a temporary directory.

```powershell
$repo = (Get-Location).Path
$out = Join-Path $repo '.env.customer-release'
git check-ignore --quiet -- $out
if ($LASTEXITCODE -ne 0) { throw 'Private artifact directory must be excluded from version control.' }
New-Item -ItemType Directory -Path $out -Force | Out-Null
$bundle = Join-Path $repo 'scripts\manual'
$runner = Join-Path $bundle 'Run-Bundles.ps1'
. (Join-Path $bundle 'Session-Helpers.ps1')
```

### 2.1 Greenfield stage 1: compile, inspect, then deploy services only

Skip service creation for an existing deployment: continue at **2.2**. ARM
deployments are **upserts**, not enforceable create-only calls. This entry point
must target a new, approved resource group with **no resources**. Resource names
derive from the approved lowercase alphanumeric `prefix` (3–8 characters) and
`uniqueString(resourceGroup().id, prefix)`, then app/service suffixes. Review
those exact names in what-if; changing RG/prefix changes names. Global name
collisions are a stop, not permission to target the other existing resource.

Copy the ARM JSON parameter example privately:

```powershell
$stage1Parameters = Join-Path $out 'stage1.parameters.json'
Copy-Item .\infra\staged\main.parameters.example.json $stage1Parameters
```

Edit the private copy: fill the approved prefix/region/tags/capacity and the
APIM bootstrap choice. Example values are not customer approval.
Preserve the secure PNA defaults (`Disabled` for Cosmos/storage/Functions).
Storage also defaults firewall Deny/no bypass and shared keys off; changing
PNA to Enabled alone does not add firewall exceptions. No table/file/queue
resources are provisioned for these current HTTP/timer workloads.

The following commands only compile locally; they do not change Azure:

```powershell
az bicep build --file .\infra\staged\main.bicep --stdout | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Stage-1 template compilation failed.' }
az bicep build-params --file .\infra\staged\main.bicepparam --stdout | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Stage-1 Bicep parameter example compilation failed.' }
Get-Content -LiteralPath $stage1Parameters -Raw | ConvertFrom-Json -Depth 100 | Out-Null
$stage1Values = (Get-Content $stage1Parameters -Raw | ConvertFrom-Json -Depth 100).parameters
if ($stage1Values.prefix.value -cnotmatch '^[a-z0-9]{3,8}$') { throw 'Approved lowercase alphanumeric prefix required.' }
if ($stage1Values.approveNewPublicApimBootstrap.value -and
    (-not $stage1Values.apimPublisherEmail.value -or -not $stage1Values.apimPublisherName.value)) {
    throw 'Approved new APIM bootstrap requires publisher email and name.'
}
```

The separate access team provisions/authorizes the target RG/operator. Record
the approved tenant/subscription/RG and confirm the RG is empty before preview:

```powershell
$stage1Sub = 'REPLACE-approved-new-subscription-id'
$stage1Rg = 'REPLACE-approved-empty-resource-group'
az account show --subscription $stage1Sub --query '{id:id,tenant:tenantId,name:name}' -o json
if ($LASTEXITCODE -ne 0) { throw 'Stage-1 subscription verification failed.' }
$resources = az resource list --subscription $stage1Sub -g $stage1Rg -o json
if ($LASTEXITCODE -ne 0) { throw 'Target inventory failed; unreadable is not empty.' }
if (@(($resources -join "`n" | ConvertFrom-Json)).Count -ne 0) { throw 'Create-new-only workflow: target RG is not empty.' }
az deployment group what-if --subscription $stage1Sub -g $stage1Rg `
    --template-file .\infra\staged\main.bicep --parameters "@$stage1Parameters"
if ($LASTEXITCODE -ne 0) { throw 'Stage-1 preview failed.' }
```

**Gate:** reviewed what-if must create only the listed service resources and
nested ARM deployment wrappers. No network component/integration, role
assignment, Graph operation, Cosmos schema/data mutation or existing-resource
modification is permitted. Verify APIM publisher values if opted in. Capacity,
SKU availability, policy, quotas/provider registration and cost approval remain
customer prerequisites; local Bicep compile does not establish them.

After explicit approval, **recheck the empty RG** immediately before create:

```powershell
$resources = az resource list --subscription $stage1Sub -g $stage1Rg -o json
if ($LASTEXITCODE -ne 0) { throw 'Target recheck failed.' }
if (@(($resources -join "`n" | ConvertFrom-Json)).Count -ne 0) { throw 'Target changed; stop before upsert.' }
$deployment = az deployment group create --subscription $stage1Sub -g $stage1Rg `
    --name ccof-stage1-services --template-file .\infra\staged\main.bicep `
    --parameters "@$stage1Parameters" --output json
if ($LASTEXITCODE -ne 0) { throw 'Service deployment failed; inspect partial state before retry.' }
$record = $deployment -join "`n" | ConvertFrom-Json -Depth 100
if ($record.properties.provisioningState -cne 'Succeeded') { throw 'Services not verified.' }
$record.properties.outputs | ConvertTo-Json -Depth 100 |
    Set-Content (Join-Path $out 'stage1-outputs.private.json') -Encoding utf8NoBOM
```

The empty-RG check is a procedural guard, not an atomic ARM create-only
guarantee: reserve the RG against concurrent deployment. After any partial
failure it will no longer be empty. Inspect operations/resources and approve a
targeted recovery; do not delete the RG, remove the guard or blindly rerun
the whole template over manually configured services. Outputs record the exact
service/principal/storage/hostname IDs; **empty APIM outputs mean deferred**,
not successful APIM deployment. Do not reuse the service template for updates
after stage 4: its service properties could undo later customer configuration.

### 2.2 Read-only completion inventory

Populate workbook **00.8 / 01.2** inputs from verified service outputs and
independently read-back IDs, not guessed names. The following path assumes the
needed services exist; it does not create a deferred APIM.

The following inventory command reads Azure and writes private local inventory;
it does not create services or grant permissions:

```powershell
& $runner -Bundle Discovery -Repo $repo -Out $out
$C = Get-Content (Join-Path $out 'customer-values.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
Assert-CcofSession $C
```

**Limitation:** the underlying discovery helper requires an existing database
and completed gateway/resolver registrations before it can save verified
`customer-values.json`; the bundle also checks all eight containers and fails
if any are missing/wrong. For a new registry, use stage-1 outputs for the access
handoff, initialize only the approved missing schema in **4.1** using the
independent inputs there, and then rerun Discovery. Do not fabricate
`customer-values.json` or treat a partial warning as success. Unknown,
unreadable or unauthorized resources are not absent resources.

## 3. Stage 2: separate identity/access-team prerequisite

Give the identity/access team the verified resource IDs, managed-identity
principal **and client** IDs, tenant/subscription IDs, database/container names,
normal hostnames and approved user/group IDs. They own these workbook steps:

| Handoff item | Existing granular instructions |
|---|---|
| Core runtime storage/monitoring access | Modules **02–03**: per-app Storage Blob Data Owner and telemetry roles; exact native Cosmos reader/writer/create-only roles and assignments. A management-plane Contributor grant is not Cosmos data-plane access. |
| Sync Microsoft Graph application permissions | Module **04**, separately privileged approval: `GroupMember.Read.All`, `User.Read.All`, `Application.Read.All` for the application-permission sync path. Do not substitute delegated login or grant tenant write permissions. |
| Gateway/resolver registration, token audience, permitted clients and resolver trust | Module **06**, **09.1**, **13.2A–13.3A**, and [registration prerequisites](../QUICKSTART-PREREQUISITES.md). APIM's exact managed identity must be retained and permitted. |
| APIM → Foundry model access | Module **09.1**: verify the approved APIM principal's `Cognitive Services User` on the actual Foundry account in each subscription. This does not prove private network access. |
| Admin application registration and reader/editor authorization | Appended workbook **20**, **22**: new admin registration, `Projects.Manage`, explicit permitted clients and `CCOF.Projects.Read` / `CCOF.Projects.Write`, approved users/groups. Projects data scope includes container metadata and `readChangeFeed` for listing, not just item point reads. Review v2's documented operation-specific additions separately. |
| Optional v2 integrations | [Admin v2 access matrix](../ADMIN-V2.md): separately scoped Graph/ARM/Logs/Cost Management access for the **admin managed identity**, not the sync/APIM identity or browser user; optional `adminConfig` native role scoped to that container. No implicit grants from stage 1 or code publishing. |
| Workbook and operational readers | Module **14.6–14.7**: Workbook Reader on the saved resource plus approved workspace query access. This is stage-2 team work even if performed after the workbook resource exists. |
| Deployment and DNS diagnostics operators | Approved resource/code publishing rights and function-key read only where needed; Reader on the actual network, NIC, central DNS subscription/RG/zone/link resources, even across subscriptions. No Owner/directory-wide write shortcut. |

If an assignment requires a not-yet-created schema/workbook scope, record it as
**pending**; arrange the narrow resource initialization and return to the access
team for that assignment before dependent operations. Do not silently run Roles
under the application deployer's identity.

**Stage-2 gate:** receive the approved access matrix, exact assignment/consent
read-backs, scopes/actions and identity IDs, including any conditional pending
items. Resolve each pending item before its dependent application operation.
Permission propagation may take time; retry bounded read-back, never widen roles
because a DNS/TLS/network request failed. `Run-Bundles.ps1 -Bundle Roles -Apply`,
`Stage-D3-GrantPermissions.ps1` and Graph grant helpers are **not** invoked by
this runbook's application deployment commands.

V2 optional settings are `ADMIN_GRAPH_ENABLED`, `ADMIN_RESOURCE_IDS` /
`ADMIN_DISCOVERY_SCOPES`, `ADMIN_WORKSPACE_ID` + `ADMIN_LOG_RESOURCE_IDS`,
`ADMIN_CONFIG_CONTAINER`, `ADMIN_RETAIL_PRICES_ENABLED`, `ADMIN_COST_SCOPE`
and `ADMIN_HEALTH_TARGETS`. They stay **unset/disabled unless separately
approved**; none is written by stage 1. Use the v2 matrix's exact identity/scopes
and configure one capability at a time. Retail price discovery needs outbound
HTTPS, not a new Azure role. Health-target keys use protected setting references,
not host-key-listing permissions granted to the app. Manual group IDs and core
project operations remain available when optional integrations are disabled.

## 4. Stage 3: schema, build, create-only seed and code

### 4.1 Initialize only missing schema; do not reset existing data

Read the exact database/container state first. The required core containers are:

| Container | Partition key |
|---|---|
| `entitlement` | `/personId` |
| `projects` | `/projectId` |
| `subscriptionIndex` | `/subscriptionId` |
| `budgetState` | `/personId` |
| `aggregateBudgetState` | `/scopeId` |
| `syncLease` | `/id` |
| `reconcilerLease` | `/id` |
| `backends` | `/backendId` |

For an existing registry with verified `$C`, workbook **01.5** gives the
single-container path. For a greenfield registry, `$C` may not exist yet:
use these **independent** approved inputs, matching the stage-1 account ID.
This initialization block supports only an approved **serverless** account:

```powershell
$schemaInput = Get-Content (Join-Path $out 'customer-inputs.json') -Raw | ConvertFrom-Json -Depth 100
$expectedCosmosId = 'REPLACE-verified-full-stage1-cosmos-account-resource-id'
$accountJson = az cosmosdb show --subscription $schemaInput.subscriptionId -g $schemaInput.resourceGroup -n $schemaInput.cosmosAccount -o json
if ($LASTEXITCODE -ne 0) { throw 'Schema account read failed.' }
$account = $accountJson -join "`n" | ConvertFrom-Json -Depth 100
if ($account.id -ine $expectedCosmosId -or $account.capabilities.name -notcontains 'EnableServerless') {
    throw 'Wrong account or unapproved capacity mode; do not initialize.'
}
$databasesJson = az cosmosdb sql database list --subscription $schemaInput.subscriptionId `
    -g $schemaInput.resourceGroup -a $schemaInput.cosmosAccount -o json
if ($LASTEXITCODE -ne 0) { throw 'Database inventory failed; unreadable is not absent.' }
$databases = $databasesJson -join "`n" | ConvertFrom-Json -Depth 100
if (-not @($databases | Where-Object { $_.resource.id -ceq $schemaInput.database }).Count) {
    az cosmosdb sql database create --subscription $schemaInput.subscriptionId -g $schemaInput.resourceGroup `
        -a $schemaInput.cosmosAccount -n $schemaInput.database --output none
    if ($LASTEXITCODE -ne 0) { throw 'Database initialization failed; inspect before retry.' }
}
```

Read back the database and select **one** approved missing container at a time:

```powershell
$container = 'REPLACE-one-approved-container-from-the-table'
$partitionKey = 'REPLACE-its-exact-partition-key'
$requiredKeys = @{
    entitlement='/personId'; projects='/projectId'; subscriptionIndex='/subscriptionId'; budgetState='/personId'
    aggregateBudgetState='/scopeId'; syncLease='/id'; reconcilerLease='/id'; backends='/backendId'
}
if (-not $requiredKeys.ContainsKey($container) -or $requiredKeys[$container] -cne $partitionKey) {
    throw 'Choose one approved container and its exact required partition key.'
}
$containersJson = az cosmosdb sql container list --subscription $schemaInput.subscriptionId `
    -g $schemaInput.resourceGroup -a $schemaInput.cosmosAccount -d $schemaInput.database -o json
if ($LASTEXITCODE -ne 0) { throw 'Container inventory failed; unreadable is not absent.' }
$containers = $containersJson -join "`n" | ConvertFrom-Json -Depth 100
$existing = @($containers | Where-Object { $_.resource.id -ceq $container })
if ($existing.Count -and $existing[0].resource.partitionKey.paths[0] -cne $partitionKey) {
    throw 'Existing partition key mismatch; stop for a reviewed migration.'
}
if (-not $existing.Count) {
    az cosmosdb sql container create --subscription $schemaInput.subscriptionId -g $schemaInput.resourceGroup `
        -a $schemaInput.cosmosAccount -d $schemaInput.database -n $container --partition-key-path $partitionKey --output none
    if ($LASTEXITCODE -ne 0) { throw 'One container initialization failed; inspect before retry.' }
}
az cosmosdb sql container show --subscription $schemaInput.subscriptionId -g $schemaInput.resourceGroup `
    -a $schemaInput.cosmosAccount -d $schemaInput.database -n $container `
    --query '{id:resource.id,partitionKey:resource.partitionKey,indexingPolicy:resource.indexingPolicy}' -o json
if ($LASTEXITCODE -ne 0) { throw 'Container read-back failed.' }
```

Do not add throughput flags to serverless; provisioned/autoscale throughput is
a separately reviewed capacity change. Inspect each existing container's
partition key, indexing policy, TTL and unique-key policy against the approved
schema. Preserve existing indexing: the existing D2 schema helper only creates
missing containers and verifies partition keys; it is **not** an index-migration
engine. A wrong partition key or needed index change is a reviewed migration,
not permission to delete/recreate or overwrite container properties.

For optional v2 cost-definition persistence, see the
[admin v2 catalog requirements](../ADMIN-V2.md#optional-settings-and-least-scoped-permission-handoff)
and the actual `infra\admin\admin-v2-catalog.bicep` schema template. The optional
container is **`adminConfig`**, partition key **`/scopeId`**, not a ninth required
core container. Leave `ADMIN_CONFIG_CONTAINER` unset if it is not approved.
Read an existing container's key/indexing first and preserve its contents;
do not blindly rerun the catalog ARM template over it. For a confirmed missing
container, this is an optional separately approved schema operation, not a
service-resource/network deployment or seed. The separate access team then
grants only its documented read/query/create/replace actions (no delete) on that
container before enabling catalog writes.

For operators already using the **matching** D1/checkpoint answers flow,
`scripts\Stage-D2-DeploySchemaAndApps.ps1 -Action Plan|Apply -Steps schema
-AnswersPath ... -CheckpointPath ...` is the existing schema-only interface.
It creates only on 404, refuses unreadable containers and wrong partition keys,
and preserves existing items. Do not fabricate D1 evidence to use it in the
manual flow. Full D2 also performs settings/auth/API/code/policy/workbook work;
it is not an alternate name for stage-1 Bicep.

### 4.2 Back up and build; no Azure grants

After verified Discovery and access handoff, plan the existing settings bundle.
It writes local backup/generated files even without `-Apply`; it does not write
Azure unless applied. Review its actual diff and disabled timers:

```powershell
& $runner -Bundle Settings -Repo $repo -Out $out
```

After approval, merge settings using the same interface:

```powershell
& $runner -Bundle Settings -Repo $repo -Out $out -Apply
```

Complete resolver authentication using workbook **06** under the approved
handoff. Keep authentication enabled; a 401/403 is not host-health acceptance.
Do not redeploy an appsettings Bicep resource with blank defaults over existing
customer settings.

The existing local package builder builds one core app at a time. It compiles
TypeScript, stages that app's files, installs production dependencies into its
package and makes a ZIP; this is **not** an ARM/Bicep deployment:

```powershell
pwsh -NoProfile -File .\scripts\portal\Build-PortalPackage.ps1 -App resolver -OutputDirectory $out
if ($LASTEXITCODE -ne 0) { throw 'Resolver package build failed.' }
Get-FileHash (Join-Path $out 'resolver.zip') -Algorithm SHA256
```

Repeat with `-App sync` and `-App reconciler`, preserving previous approved ZIPs
**before** the builders overwrite their fixed output names. Do not pass `admin`:
admin uses `admin\Build-AdminPackage.ps1 -OutFile ...` and the v2 release contract.
The bundled `Publish` plan also builds ZIPs; `Publish -Apply` builds and deploys
all three apps, so use individual workbook **07** steps for a scoped update.

### 4.3 Publish from a reachable approved host

Check deployment-storage reachability and publish/SCM restrictions before any
upload. If private bootstrap blocks them, complete the required section-5 path,
resume here from the VDI/private runner, and do not alter PNA.

For one core app, use workbook **07.2**'s checked Flex-aware command:

```powershell
$resolverZip = Join-Path $out 'resolver.zip'
Invoke-CcofAzWrite @('functionapp','deployment','source','config-zip','--subscription',$C.subscriptionId,'-g',$C.resourceGroup,'-n',$C.apps.resolver.name,'--src',$resolverZip)
```

`az functionapp deployment source config-zip` detects Flex and its package
endpoint. Do **not** substitute `az functionapp deploy --type zip`, set
`WEBSITE_RUN_FROM_PACKAGE`, or assume a Flex Kudu/SCM shell is available.
The CLI still needs its actual selected publish endpoint and deployment storage
to be reachable. Read back handler registration using workbook **07.3/07.6/07.9**;
handler names alone do not prove working auth, storage, Cosmos or inference.

### 4.4 Local artifacts, approved policy and create-only seed

Fill the private registry/routing inputs using workbook **08.1–08.3**, then run
the existing offline builder:

```powershell
& $runner -Bundle Artifacts -Repo $repo -Out $out
```

This validates through the runtime registry validator and generates policy,
seed payload/ID, documents and workbook locally. No Azure write or Bicep is run.
The builder reuses an existing matching seed ID and refuses changed documents
over an unresolved previous seed. It does not prove existing Cosmos items match.

Use workbook **09–10** for the individually approved APIM API/operation/backend,
rendered policy and diagnostics. **09.1 access grants remain with stage 2.**
Keep request/response bodies and credentials out of diagnostics. Dynamic
`set-backend-service` in the policy selects the backend at runtime: a blank
operation-level fixed backend URL is not by itself a defect. Verify the rendered
policy, registered backend entity URL and actual selected route together.

Only for initial approved records, follow workbook **11**'s create-only seed or
individual manual create path. Require the intended seed ID and verification of
**every** expected backend/project. Existing conflicting items are a stop/review
condition, not an instruction to upsert, replace, purge, recreate the database
or reset usage/budget counters. Disable the seed trigger and remove its payload
after success **or failure**. For an existing v1→v2 application update, skip
initial seeding; use v2's explicit schema/migration requirements, if any.

Enable entitlement sync only after its own approved seed/Graph/group checks
(workbook **12**). An admin save does not prove refreshed entitlements or expired
gateway caches. Budget-state activation remains separately approved Module **15**.

### 4.5 Workbook corrections: arrays, real Bearer header, full content GET

The historical Module 14 is intentionally unchanged. Apply these corrections
instead of its masked Authorization examples. The local groups file must remain
a JSON **array even for one group**. When writing an approved `$groups` collection:

```powershell
ConvertTo-Json -InputObject @($groups) -Depth 100 |
    Set-Content -LiteralPath (Join-Path $out 'workbook.groups.json') -Encoding utf8NoBOM
```

Do not pipe `$groups` into `ConvertTo-Json`: a singleton can become an object.
Rebuild only reporting using workbook **14.2**, not the whole policy/seed bundle,
when repairing reporting inputs.

For the CLI save route **14.4**, prepare/verify the full notebook, content-digest
verification file, `workbook-save.json` and recorded workbook ID as instructed
there. **Stop before its masked-header PUT**. Use this replacement only after
approval of that recorded target; after a timeout/error inspect state before retry.
For intentional updates, retain the previous full notebook privately.

```powershell
$workbookId = (Get-Content (Join-Path $out 'saved-workbook-id.txt') -Raw).Trim()
$save = Get-Content (Join-Path $out 'workbook-save.json') -Raw | ConvertFrom-Json -Depth 100
$publishCheck = Join-Path $out 'workbook-publish-verification.json'
node (Join-Path $repo 'analytics\workbooks\chargeback.ts') --verify $publishCheck
if ($LASTEXITCODE -ne 0) { throw 'Approved workbook content digest did not verify.' }
$checked = (Get-Content $publishCheck -Raw | ConvertFrom-Json -Depth 100).parameters
$notebook = $save.properties.serializedData | ConvertFrom-Json -Depth 100
if ($save.properties.sourceId -ine $C.workspaceResourceId -or
    ($notebook | ConvertTo-Json -Depth 100 -Compress) -cne
    ($checked.workbookContent.value | ConvertTo-Json -Depth 100 -Compress)) {
    throw 'Save payload does not match the verified full notebook/workspace.'
}
$expectedPrefix = "/subscriptions/$($C.subscriptionId)/resourceGroups/$($C.resourceGroup)/providers/Microsoft.Insights/workbooks/"
if (-not $workbookId.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unapproved workbook resource scope.' }
$armToken = az account get-access-token --subscription $C.subscriptionId --resource 'https://management.azure.com/' --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $armToken) { throw 'ARM token acquisition failed.' }
try {
    $body = Get-Content (Join-Path $out 'workbook-save.json') -Raw
    Invoke-RestMethod -Method Put -Uri "https://management.azure.com$workbookId`?api-version=2022-04-01" `
        -Headers @{Authorization="Bearer $armToken"} -ContentType 'application/json' `
        -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
} finally { $armToken = $null }
```

Replace **14.5**'s masked header with the actual Bearer token too, and request
`canFetchContent=true` so the GET includes serialized content:

```powershell
$workbookId = (Get-Content (Join-Path $out 'saved-workbook-id.txt') -Raw).Trim()
$token = az account get-access-token --subscription $C.subscriptionId --resource 'https://management.azure.com/' --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'No authorized ARM token.' }
try {
    $saved = Invoke-RestMethod -Method Get `
        -Uri "https://management.azure.com$workbookId`?api-version=2022-04-01&canFetchContent=true" `
        -Headers @{Authorization="Bearer $token"}
} finally { $token = $null }
$notebook = $saved.properties.serializedData | ConvertFrom-Json -Depth 100
if ($saved.properties.sourceId -ine $C.workspaceResourceId -or
    $notebook.version -cne 'Notebook/1.0' -or @($notebook.items).Count -lt 10) {
    throw 'Wrong workspace or incomplete saved notebook.'
}
'Workbook resource/content read-back passed; query and reader acceptance remain separate.'
```

Never print/store tokens or paste them into public examples. Verify actual report
queries/reader experience separately. Unknown prices and unattributed usage must
remain **unknown/unpriced/unattributed**, not `$0`. A report is not a settled
Azure/Marketplace invoice or a monetary admission guarantee.

## 5. Stage 4: customer hand-configures network, then validate

Use the approved customer topology, not the old workbook's assumption of new
admin-owned zones/VNets. Central DNS subscription/RG and corporate forwarding may
already exist. Hand off exact service IDs, normal hostnames, resource subresources,
actual endpoint IPs, deployment endpoints and caller/resolver paths.

| Path | Customer configuration and gate |
|---|---|
| APIM StandardV2 → private Foundry | **Outbound** VNet integration on a dedicated subnet delegated to `Microsoft.Web/serverFarms`, with required NSG and effective egress. APIM inbound Private Link alone does not provide outbound backend reachability. Foundry endpoint subresource `account`, approved connection and hostname-specific DNS record. |
| Flex Functions → Cosmos/storage | Integration subnet delegated to `Microsoft.App/environments`, separate from APIM and undelegated PE subnet. Cosmos `Sql` endpoint with `privatelink.documents.azure.com`. Each current HTTP/timer app needs storage `blob` and `privatelink.blob.core.windows.net`; do not add tables/files/queues as presumed requirements of this workload. Reassess if future triggers require them. |
| VDI → admin console/API and publisher | Admin `sites` private endpoint, `privatelink.azurewebsites.net` records for the app and applicable SCM/publish hostname, corporate private routing/DNS. Outbound integration alone does not privatize inbound access. Verify the actual Flex CLI publishing path as well as the browser path. |
| Central DNS | Exact subscription/RG/zone IDs and Reader access across those scopes for diagnostics. Azure-provided DNS needs relevant resolution-VNet links; **links do not propagate through peering**. For custom DNS, prove forwarding/Private Resolver rulesets and reachability to the authoritative path instead of blindly adding a VNet link. |

APIM and the backend PE can be in the **same VNet**; peering is not mandatory.
For example, a customer-managed `100.104.x.x` PE address may be the intended
answer; compare DNS to the endpoint's **actual NIC IP**, not only a `10.x.x.x`
test or an RFC1918 heuristic. A missing CNAME alone is not a DNS-failure verdict
if an approved resolver supplies the correct A answer. No attached route table
does **not** prove “no firewall”: system/BGP/effective routes, NVAs, NSGs, return
paths and the actual DNS path still need verification.

### 5.1 Read-only focused Foundry/VDI configuration checker

This command uses the actual current script parameters. DNS subscription may be
a visible display **name** or GUID; duplicate names require the GUID.
`DnsResourceGroup` is optional. BackendHost is the actual runtime backend's
normal hostname, not the private-link hostname, project URL or operation URL.

```powershell
$pathCheck = @{
    ApimResourceId = 'REPLACE-full-apim-resource-id'
    FoundryResourceId = 'REPLACE-full-foundry-account-resource-id'
    BackendHost = 'REPLACE-account.services.ai.azure.com'
    DnsSubscription = 'REPLACE-central-dns-subscription-name-or-guid'
    DnsResourceGroup = 'REPLACE-central-dns-resource-group'
}
& .\scripts\manual\Test-FoundryPrivatePath.ps1 @pathCheck
```

For optional client/VDI static DNS checking, add the paired client VNet/normal
hostname. `ClientDnsZoneId` selects the full central sites-zone ID explicitly;
`ClientPrivateEndpointId` is optional but enables comparison with actual NIC IPs:

```powershell
$pathCheck.ClientVnetResourceId = 'REPLACE-full-vdi-vnet-resource-id'
$pathCheck.ClientHost = 'REPLACE-admin.azurewebsites.net'
$pathCheck.ClientDnsZoneId = '/subscriptions/REPLACE-dns-sub/resourceGroups/REPLACE-dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.azurewebsites.net'
$pathCheck.ClientPrivateEndpointId = 'REPLACE-full-admin-sites-private-endpoint-id'
& .\scripts\manual\Test-FoundryPrivatePath.ps1 @pathCheck
```

For multiple endpoints/ambiguous backend discovery supply `PrivateEndpointId`
and `BackendHost`; for centrally managed records use `PrivateDnsZoneIds`.
`DnsVnetResourceId` is an optional DNS-resolution hub override, not evidence of
working forwarding. Select only the zone matching the actual backend suffix
(`services.ai.azure.com`, `cognitiveservices.azure.com` or `openai.azure.com`).

Exit 0 means no detected **static** failure, **not** a working private path.
Exit 1 is a failed/incomplete static check; exit 2 is a DNS permission gap unless
a known failure takes precedence. Treat WARN/**UNVERIFIED** as unresolved.
The checker reads configuration, not APIM traffic/DNS caches or live VDI DNS;
routed hub/NVA topologies may require manual evidence outside its direct-peering
model.

The older `Test-NetworkConfiguration.ps1` is not a central-DNS acceptance gate:
it switches active subscription, searches zones there and PEs in the VNet RG,
can treat a hub link as sufficient and checks all Foundry zone suffixes. Its
optional admin probe reads a function key. It cannot establish live DNS,
effective firewall access or cross-subscription topology correctness. Do not
“repair” production to satisfy those assumptions.

### 5.2 Relevant-host DNS/TLS checks and read-only health

Run DNS checks **on the VDI/private host that actually calls the app**; ordinary
public Cloud Shell cannot prove that host's DNS or route. A separately connected
host does not prove APIM's own network path.

```powershell
$adminHost = 'REPLACE-admin.azurewebsites.net'
$cosmosHost = 'REPLACE-account.documents.azure.com'
Resolve-DnsName $adminHost
Resolve-DnsName $cosmosHost
nslookup $adminHost
```

Compare answers with the selected PE NICs. From a suitable approved host,
`curl --resolve` isolates DNS while retaining the original TLS SNI/Host:

```powershell
$adminPeIp = 'REPLACE-actual-sites-pe-ip'
curl.exe --silent --show-error --resolve "${adminHost}:443:${adminPeIp}" `
    --output NUL --write-out '%{http_code}' "https://$adminHost/api/health"
if ($LASTEXITCODE -ne 0) { throw 'Forced-IP TLS/connectivity probe failed.' }
```

No key is supplied by that isolation probe: 401/403 may be expected; it is not
authenticated health. Do not use `-k` or test `https://<IP>` as a TLS equivalent.
If forced-IP TLS works but normal-host access fails from the same host, investigate
that DNS path; it does not by itself prove the full application or APIM backend.

For the deployed admin application's **read-only** `GET /api/health`, set its
actual subscription/RG/name and retrieve the default function key only if that
read is authorized. Do not reuse the resolver's differently protected endpoint:

```powershell
$adminSub = 'REPLACE-admin-subscription-id'
$adminRg = 'REPLACE-admin-resource-group'
$adminName = 'REPLACE-admin-function-app-name'
$keyJson = az functionapp keys list --subscription $adminSub -g $adminRg -n $adminName -o json
if ($LASTEXITCODE -ne 0) { throw 'Authorized function-key read failed.' }
$healthKey = [string](($keyJson -join "`n" | ConvertFrom-Json).functionKeys.default)
$keyJson = $null
if (-not $healthKey) { throw 'No default health function key.' }
try {
    $health = Invoke-WebRequest "https://$adminHost/api/health" `
        -Headers @{'x-functions-key'=$healthKey} -SkipHttpErrorCheck -TimeoutSec 90
    $body = $health.Content | ConvertFrom-Json
    if ($health.StatusCode -ne 200 -or $body.checks.cosmos -cne 'ok' -or $body.checks.auth -cne 'configured') {
        throw 'Admin health not ready; inspect the scoped private diagnostics.'
    }
    'Read-only admin health passed; project listing, roles and inference still require acceptance.'
} finally { $healthKey = $null }
```

Health does not create/update a project and is not a permission-management API.
It does not prove `readChangeFeed`/list permissions, the v2 operations matrix,
browser sign-in, entitlement propagation or model inference.

### 5.3 Final acceptance and diagnosis

1. Keep production PNA/firewalls/SCM restrictions unchanged unless an explicitly
   approved cutover is being made. Complete network preconditions first.
2. Verify allowed VDI browser sign-in, authorized app operations and reader/stale
   write rejection on an approved **test** record. Follow the v2 contract, not
   assumptions from the v1 UI. Never create a production project as a health probe.
3. Verify approved developer inference and negative cases (workbook **13**) and
   actual sync/entitlement/cache propagation. An operation URL, 200 console page,
   function list or ARM deployment success alone is insufficient.
4. If Foundry public previously worked but private fails, investigate a possible
   **network 403 wrapped as 502** by APIM policy. Do not assume the credential
   message means IAM failure or add permissions to fix a route. Inspect scoped
   APIM diagnostics/selected backend and DNS/network evidence; do not re-enable
   production public access to reproduce the comparison.
5. Record exact host/source, endpoint IP, time, request/correlation IDs and the
   boundary each check proves. Keep credentials/bodies private. Missing evidence
   remains **UNVERIFIED**, never “production-ready”.

## 6. Existing private admin app: repeatable v1 → v2 VDI update

This is a **code update**, not a resource-only Bicep deployment. Stage-1 service
creation and initial create-only seed are not rerun for an existing app.
Use the [admin v2 private-VDI upgrade and compatibility notes](../ADMIN-V2.md)
alongside this deployment sequence.

1. On an approved VDI/private deployment host, verify the recorded v1 app,
   principal, storage, settings/auth, access restrictions and private paths.
   Confirm the v2 release's identity/data-scope prerequisites with the separate
   access team; do not infer new grants from installing new code.
2. Retain the previous approved **admin ZIP** and its SHA-256, pinned source and
   configuration backup in the approved private release store. A git branch is
   not a rollback package. Stop if the previous package cannot be recovered.
3. Build from the approved `feat/admin-console-v2` commit with the actual admin
   builder; use a new output directory so its fixed ZIP name cannot overwrite
   the prior release:

```powershell
$v2Out = Join-Path $out 'admin-v2'
New-Item -ItemType Directory -Path $v2Out -Force | Out-Null
$adminZip = Join-Path $v2Out 'admin.zip'
pwsh -NoProfile -File .\admin\Build-AdminPackage.ps1 -OutFile $adminZip
if ($LASTEXITCODE -ne 0) { throw 'Admin v2 package build failed.' }
Get-FileHash $adminZip -Algorithm SHA256
```

4. Review v2's schema/migration requirements. Do not seed, reset, upsert existing
   project data, rebuild other apps or rerun infra just to change the UI.
   Apply separately reviewed settings changes only if required, preserving the
   existing app identity, authentication and private exposure.
5. From the same approved VDI/private publishing path, upload **only admin**:

```powershell
az functionapp deployment source config-zip --subscription $adminSub -g $adminRg -n $adminName --src $adminZip --build-remote false --output none
if ($LASTEXITCODE -ne 0) { throw 'Admin publish failed; inspect deployment state before retry.' }
```

6. Repeat section-5 DNS/TLS and protected read-only health, then v2 sign-in,
   operation/authorization/concurrency and data-preservation acceptance.
   A private SCM failure is a network prerequisite failure, not permission to
   open SCM. Do not claim a successful update from upload status alone.
7. **Rollback compatibility gate:** v1's strict project validator does not accept
   v2's optional `adminTags`. Do not blindly republish v1 after using tags. Export
   the affected state privately; while v2 remains available, use its reviewed
   project settings/ETag-guarded API to clear **only** `adminTags` on those
   projects as described in [v2 rollback](../ADMIN-V2.md#rollback). No bulk data
   replacement, usage reset or removal of other project fields is authorized.
   Keep the optional `adminConfig` container/data; v1 ignores it. If tags cannot
   be safely cleared, stop rollback and use the approved incident recovery path.
8. Once compatibility is verified, retain failed-package diagnostics privately
   and republish the recorded previous ZIP through the **same** reachable,
   Flex-aware path:

```powershell
$previousAdminZip = 'REPLACE-absolute-path-to-retained-approved-admin-v1.zip'
$previousAdminSha256 = 'REPLACE-recorded-approved-v1-sha256'
if (-not (Test-Path -LiteralPath $previousAdminZip)) { throw 'Recorded rollback ZIP missing.' }
if ((Get-FileHash $previousAdminZip -Algorithm SHA256).Hash -ine $previousAdminSha256) { throw 'Rollback ZIP does not match the approved hash.' }
az functionapp deployment source config-zip --subscription $adminSub -g $adminRg -n $adminName --src $previousAdminZip --build-remote false --output none
if ($LASTEXITCODE -ne 0) { throw 'Rollback upload failed; inspect live state.' }
```

Compare its hash with the recorded previous release **before** upload. Restore
only approved changed settings if necessary, never PNA/grants as a rollback
shortcut. Verify health and v1 behavior again. Code rollback does not roll back
customer data edits or make an unreviewed schema migration reversible.

## 7. Offline verification boundary

Run the focused test from the repository root; it compiles Bicep/parameter
examples, recursively inspects nested ARM resources, checks secure defaults and
parses this runbook's PowerShell blocks. It does not execute those blocks or
call Azure:

```powershell
pwsh -NoProfile -File .\tests\Test-StagedCustomerDeployment.ps1
if ($LASTEXITCODE -ne 0) { throw 'Offline staged deployment contract failed.' }
```

The preserved-workbook guards are `tests\Test-PublicManualGuide.ps1` and
`tests\Test-AdminHandWorkbook.ps1`. Passing these checks is not live deployment,
private-path or production acceptance.
