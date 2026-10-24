# Admin console v2: private-VDI upgrade and optional capabilities

> **Historical.** This page describes admin console 2.0.1. The current version is described in [ADMIN-V3](ADMIN-V3.md) and [admin operations](runbooks/ADMIN-OPERATIONS.md).

Release source: `feat/admin-console-v2`; package version `2.0.1`.
This is an **admin-app-only** upgrade. It does not deploy to the customer's
environment, change the gateway/sync/reconciler binaries, grant permissions,
create networks, or enable public access. Keep the deployed v1 ZIP.

## What changes

- Projects have server-side search, tag/backend filtering and continuation-token
  paging (50 per page, API maximum 100). The UI does not fetch 10,000 groups
  into the browser. This is not a claim of a customer-scale load test.
- Administrator-defined tags organize the project list; they do not grant
  access or create an authorization hierarchy. STD/PRM/CYB project access
  groups remain independent. No group is added to or removed from Entra.
- Optional Entra name lookup during creation returns at most 25 groups per
  prefix query. Manual Object ID/name entry always remains available.
- Exactly one APIM backend per project; many projects can share a backend.
  Backend, budget and tag changes use ETags and a review step. No project or
  group deletion/rename is introduced.
- A Foundry inventory shows scoped Azure tags, APIM linkage, deployment names
  and resource observations. A failed GET is `not_found`, `access_denied` or
  `unavailable`, not an automatic deletion, failover or retirement.
- Cost definitions contain a model/family/deployment catalog and a versioned
  rate card. A new model may be added without a UI release. A genuinely new
  runtime family still requires a compatible gateway/sync release; custom
  pricing-family labels do not silently authorize a new runtime family.
  Catalog requests are capped at 1 MiB/2,000 mappings; the sheet shows 50
  mappings per page. Existing project write requests retain the 64 KiB cap.
- Operations separates control-plane observations, HTTP endpoint responses
  and reconciler-run telemetry. There are no paid synthetic inference calls.
- Audit shows the latest 200 change/refusal events in the last 31 days from
  configured log resources. Log ingestion/sampling can delay or omit events;
  this is not an immutable or transactional audit store.
- **Group budgets** (new in 2.0.1) lists every project access group's
  month-to-date consumption against its group budget, across all projects:
  consumed CCU and USD, % used (with a meter), remaining (negative = over
  budget), mode/exhausted, coverage and freshness, plus totals across groups.
  The project view shows the same per-group figures for the selected project.
- Each optional capability fails independently (2.0.1): a missing or invalid
  packaged rate card now disables only Cost definitions instead of every v2
  panel, and is retried on the next request.

React renders the new operator panels using native controls and the existing
static CSS. The existing limits editor remains in place. Same-origin assets,
strict CSP (no unsafe-inline/eval), server-side authorization and ETag guards
remain the security controls; using React is not a security certification.

### Operator workflow and responsive layout

The section navigation has visible selection and keyboard focus states. Project
search stays visible; exact tag/backend filters expand separately and show an
active-filter count. On narrow screens, the project list is a separate screen;
use **All projects** to return from a project. Wide data tables scroll within
their own frame, while numeric figures remain aligned and timestamps use UTC.

Project settings and catalog saves retain their review and ETag safeguards.
Settings reviews show field-level before/after changes; stale saves offer a
reload without silently overwriting another administrator. Refresh asks before
discarding drafts and retains the previous observation while fetching. Loading,
permission-denied, partial and retry states are distinct. These presentation
changes do not add permissions, alter cost meanings, or change API contracts.

## How administrators use the console

| Role | Typical tasks |
| --- | --- |
| Project editor (`CCOF.Projects.Write`) | Create projects; change models, token limits, budgets, tags and the single backend; every save is reviewed as a field-level diff and guarded by ETag |
| Reader, finance or auditor (`CCOF.Projects.Read`) | Review projects, group consumption against budgets, cost definitions and audit events |
| Platform operations | Foundry inventory and deployments, APIM backend linkage, endpoint probes and reconciler runs |

Typical flows:
- **Onboard:** New project, then for each classification (STD/PRM/CYB) paste or look up the Entra group, choose models and limits, review and save. Access reaches developers after the next sync.
- **Organize:** add tags such as `bu:payments` or `region:india`; filter the project list by exact tag or backend. Tags never grant access.
- **Watch spend:** Group budgets, sorted by % used; filter to groups at or above a threshold or needing attention, then open the project to adjust its budget.
- **Foundry change or loss:** Foundry inventory marks unreadable accounts `not_found`, `access_denied` or `unavailable` and shows linked projects; reassign their backend in project settings.
- **Investigate:** Audit shows who changed what, before and after, with request IDs for correlation.

## Scale toward 10,000 projects

Built in:
- Project list: Cosmos query with server-side search, exact tag/backend filters, `ORDER BY projectId`, 50 per page (max 100) and continuation tokens. The browser never loads the registry.
- One document per project with ETag writes: concurrent administrators never block or overwrite each other.
- Group budgets (2.0.1): exact roll-up on the server, then paged (100 per page, max 500) and filtered on the server. Totals still cover every group. Offline test: 30,000 groups rolled up and paged in well under a second, one page under 100 KB.
- Stateless Flex Consumption app; bounded integrations (Graph 25 results, catalog 2,000 mappings, ARM 30 pages, audit 200 events, probes 30 targets six at a time).

Known limits, not yet load-tested against a live 10,000-project registry:
- Name/ID search uses `CONTAINS`, which scans the container; request-unit cost grows with registry size. Next: a normalized search field with prefix matching, or a search index.
- The Group budgets query still reads the month's latest line per group from Log Analytics on each request (about 30,000 rows at 10,000 projects); only the response to the browser is paged.
- Tag filter is one exact tag; no tag roll-up of budgets yet.
- Inventory links Foundry accounts only to projects already loaded in the browser.
- No bulk import/export; audit is the latest 200 events.
- Outside the admin app, the larger 10,000-project risks are the sync's Entra group expansion (Graph throttling) and the reconciler's log volume.

## Cost meanings (do not combine these totals)

| Figure | Source and meaning |
| --- | --- |
| Configured budget | Existing project classification `personBudget` / `aggregateBudget`, USD or CCU, monthly. Changing a displayed unit does not convert an amount automatically; review it. |
| Group consumption | Latest current-UTC-month `ccof.reconciler.budget.v1` **group** observation; project/classification and freshness remain visible. This is the reconciler's calculated estimate, not an invoice. |
| Group budget roll-up | Computed server-side with exact decimals from those group lines: `spentCcu`, `budgetCcu` (null = no cap), USD at 100 CCU = USD 1, % used = spent ÷ budget, remaining = budget − spent. "Used of capped budgets" sums only capped groups; uncapped groups are counted separately. Malformed lines are counted as rejected, never guessed. Totals are flagged as a **lower bound** whenever any group is partial, stale (past `validUntil`) or rejected. |
| USD equivalent | Existing repository definition: **100 CCU = USD 1**. Token prices remain USD per million tokens and include distinct cache categories, effective dates and geography. |
| Coverage | `complete`, `partial`, unpriced request counts and validity. Missing telemetry is unavailable, never zero. |
| Azure billed cost | Optional Cost Management **ActualCost**, month to date, before tax, in the returned currency. Resource totals can lag and are not allocated to Entra groups sharing that resource. No invented per-group invoice reconciliation. |
| Published live pricing | Optional Azure Retail Prices API discovery. A returned meter is not guaranteed to be a per-model token price, Marketplace/private-offer price or contract discount. Empty results mean no published match, not free usage. |

Live pricing discovery never overwrites a rate card. Approve sources and
effective intervals explicitly. Existing rate entries cannot be removed or
repriced in place; close an open interval and append a new version. Export the
approved rate card to the reconciler's existing configuration/build path before
changing enforcement pricing. Saving console cost definitions **does not**
change deployed reconciler prices or its contract schedule.

## Optional settings and least-scoped permission handoff

All permissions below belong to the **admin Function App managed identity**,
not to the browser user or APIM identity. Existing Reader/Editor app roles
continue to authorize users. The deployment procedure grants none of these.

| Feature / setting | Extra access, approved separately by the responsible team | Disabled behavior |
| --- | --- | --- |
| Project tags/backend/budgets | Existing Cosmos projects native data role (read/query/create/replace), same as v1 | Core API refuses writes if the registry cannot be reached; no success fallback. |
| `ADMIN_GRAPH_ENABLED=true` | Microsoft Graph **application** `GroupMember.Read.All` (or an approved sufficient group-read permission) on the managed identity, tenant-admin consent; outbound Graph HTTPS | Directory search alone shows disabled/permission required; manual group IDs remain usable. No membership writes or automatic consent. |
| `ADMIN_RESOURCE_IDS` | Comma-separated full APIM, Foundry **account**, Function App IDs; Reader on those resources and child backend/deployment resources | Inventory disabled/unavailable; existing project IDs/models remain editable manually. |
| `ADMIN_DISCOVERY_SCOPES` | Optional comma-separated subscription or RG IDs; Reader on those discovery scopes | Only approved scopes are scanned. Prefer RG scope; no tenant-wide discovery. |
| `ADMIN_WORKSPACE_ID` and `ADMIN_LOG_RESOURCE_IDS` | Workspace GUID plus comma-separated originating Function App/Application Insights ARM IDs as present in `_ResourceId`; Log Analytics Reader on the workspace. **Include the reconciler Function App ID** for Group budgets and runs. | Group budgets/operations/audit views alone show disabled/permission required. Existing telemetry must already route to this workspace. |
| `ADMIN_AUDIT_WORKSPACE_ID` (optional) | Workspace GUID of the admin app's own Application Insights workspace, when it differs from `ADMIN_WORKSPACE_ID` (the quick install creates a separate admin workspace). Log Analytics Reader on it; add the admin Application Insights component ID to `ADMIN_LOG_RESOURCE_IDS`, because audit lines are `AppTraces` there. Flex Consumption apps don't send `FunctionAppLogs` through diagnostic settings, so routing the admin app into the shared workspace isn't an alternative. | Without it, Audit reads `ADMIN_WORKSPACE_ID`; if the audit lines aren't there, Audit shows no events while budgets and runs keep working. |
| `ADMIN_CONFIG_CONTAINER=adminConfig` | Optional Cosmos SQL container, partition key **`/scopeId`**, in existing `COSMOS_DATABASE`; native data role scoped to this container: readMetadata, executeQuery, readChangeFeed, item read/create/replace. No delete. | Packaged catalog readable; saving cost definitions disabled. If configured but denied, the panel reports failure; other features continue. |
| `ADMIN_RETAIL_PRICES_ENABLED=true` | No Azure role; outbound HTTPS to `prices.azure.com` | Live retail discovery only disabled. Configured rates remain available. |
| `ADMIN_COST_SCOPE` | Subscription or RG ARM ID; Cost Management Reader at that scope, subject to billing-agreement access; Foundry accounts must also be in inventory | Billed-cost comparison alone disabled/unavailable. |
| `ADMIN_HEALTH_TARGETS` | See below; private DNS/routing/HTTPS from **admin app** to each target | Only live probes disabled. Configuration and telemetry observations remain available. |

Workspace roles expose the workspace's data to the managed identity. Approve
that scope explicitly. Server-generated queries restrict displayed data to
`ADMIN_LOG_RESOURCE_IDS`. No arbitrary KQL or provider URLs come from the
browser.

### Health target configuration

The operations panel accepts a server-configured JSON array (maximum 30):

```json
[
  {
    "name": "Resolver",
    "url": "https://EXACT-RESOLVER-HOST.azurewebsites.net/api/health",
    "keySetting": "ADMIN_PROBE_KEY_RESOLVER"
  },
  {
    "name": "Gateway smoke operation",
    "url": "https://EXACT-APIM-HOST.azure-api.net/APPROVED-READ-ONLY-SMOKE-PATH"
  }
]
```

Use only an existing, approved GET endpoint. Do not guess an endpoint for
Foundry or assume every Function App implements `/api/health`. Timer progress
is observed through reconciler telemetry, not inferred from an HTTP 200.
Values of `ADMIN_PROBE_KEY_*` must be stored as protected app settings/Key Vault
references. Keys are sent in `x-functions-key`, never in URLs, browser JSON or
logs. No role capable of listing host keys is requested.

Probes have timeouts, reject redirects, and allow HTTPS Azure service hosts
only. HTTP 401/403 means an endpoint refused the probe, not that it is healthy
or deleted. HTTP success is reachability evidence only, not proof of model
inference, correct business output, or a fresh timer run. Private connectivity
from the VDI and from the admin app are **different** paths.

## VDI build and upgrade (Windows PowerShell 7)

Perform this from an approved VDI/build host that can reach npm (or its approved
mirror), Azure management endpoints and the private Function App **SCM** host.
Requirements: Git, Node **22.18+**, npm, PowerShell 7 and a recent Azure CLI.
Use the operator's approved deployment identity. Do not enable public access
or weaken network rules to make publishing work.

### 1. Get v2 without changing the v1 branch

```powershell
Set-Location 'C:\REPLACE\ccof-bicep'
git fetch origin
git switch feat/admin-console-v2
git pull --ff-only origin feat/admin-console-v2
git status --short
```

Stop if local changes conflict; do not reset or discard customer changes.

### 2. Build a separate v2 ZIP

```powershell
$ErrorActionPreference = 'Stop'
$repo = (Get-Location).Path
$release = Join-Path $HOME 'ccof-admin-releases'
New-Item -ItemType Directory -Force -Path $release | Out-Null
$zip = Join-Path $release 'ccof-admin-v2.0.1.zip'
& (Join-Path $repo 'admin\Build-AdminPackage.ps1') -OutFile $zip
if (-not (Test-Path $zip)) { throw 'Admin v2 package was not built.' }
Get-FileHash $zip -Algorithm SHA256
```

The builder restores locked dependencies, compiles the API, bundles the UI,
runs admin unit tests and includes production Node dependencies. Nothing is
deployed. Keep the source commit, SHA256 and previously deployed v1 ZIP.
Build errors stop packaging; do not deploy a stale ZIP.

### 3. Check the exact private publishing hosts

```powershell
$sub = 'REPLACE-workload-subscription'
$rg = 'REPLACE-admin-resource-group'
$app = 'REPLACE-admin-function-app'
$site = az functionapp show --subscription $sub -g $rg -n $app -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $site.defaultHostName) { throw 'Admin app lookup failed.' }
$hostName = $site.defaultHostName
$scmHost = $hostName -replace '\.azurewebsites\.net$', '.scm.azurewebsites.net'
Resolve-DnsName $hostName
Resolve-DnsName $scmHost
Test-NetConnection $scmHost -Port 443
```

Compare the IPs with the admin **sites** private endpoint DNS configuration.
Both site and SCM records must resolve along the VDI's DNS path. Do not
substitute the Function App's blob-storage endpoint IP. If a custom SCM
hostname is configured, use its exact publishing hostname instead.

### 4. Publish only the admin app after change approval

First ensure an approved role permits publishing on this app and the previous
ZIP is retained. Optional integration settings/permissions can be added later
by their owning team. Existing auth, Cosmos, VNet and identity settings remain.

```powershell
az functionapp deployment source config-zip --subscription $sub `
  --resource-group $rg --name $app --src $zip --build-remote false
if ($LASTEXITCODE -ne 0) { throw 'Admin v2 publishing failed; inspect deployment status before retrying.' }
```

For Flex use **config-zip**; `az functionapp deploy --type zip` returned 415 in
the PoC. Do **not** set `WEBSITE_RUN_FROM_PACKAGE`.

### 5. Read back and accept

- Open `https://<exact-host>/api/console` from the VDI; confirm v2.0.1.
- Call the existing function-key-protected `/api/health` with
  `x-functions-key`; expect `version: "2.0.1"`, `auth: "configured"`,
  `cosmos: "ok"`. Never print or screenshot the key.
- Reader: inspect projects; confirm editing cannot be performed.
- Editor: review and save an approved test tag/limit change; verify the audit
  record and use two sessions to confirm a stale ETag is refused.
- Leave optional permissions off initially; confirm each unavailable panel is
  explicit and existing project creation/limits still work.
- Enable one integration at a time with its owner, then validate actual data,
  freshness, classification attribution and provider errors.
- Rerun `scripts\manual\Test-FoundryPrivatePath.ps1` for infrastructure evidence,
  including client VNet parameters if needed. Static passes are not live VDI or
  APIM DNS/TCP evidence; validate both separately.

## Rollback

Do not restore v1 blindly after using v2 tags: v1's strict project validator
does not accept the optional `adminTags` field. Export/tag snapshots first.
While v2 is still available, use its reviewed project settings to clear tags
on affected projects (or authenticated `PUT /api/projects/<id>/settings` with
`{"adminTags":null}` and the current ETag). This removes **only** the optional
field, not groups, budgets, limits or backend assignments. Record the action.

After confirming tagged documents have been handled, publish the retained v1
ZIP using the same private `config-zip` route. Keep v2's optional catalog
container/data; v1 ignores it. Backend/budget changes are real project changes
and are not undone by rolling back code: reverse them only through a reviewed,
ETag-guarded change. Never restore an entire database over concurrent edits.

## API additions

Existing v1 project operations remain. New authenticated routes:

| Route | Behavior |
| --- | --- |
| `GET /api/v2/projects` | `search`, exact `tag`, `backendId`, `limit` (1–100), opaque `cursor`. |
| `PUT /api/projects/{id}/settings` | Editor, current If-Match. Tags/display name/single backend + subscription/classification budgets only; no group-ID changes. |
| `GET /api/v2/groups?q=...` | Optional bounded prefix lookup; manual group IDs remain supported. |
| `GET /api/v2/inventory`, `/deployments?resourceId=...` | Only server-configured resources/scopes; resource URL cannot be supplied. |
| `GET /api/v2/budgets` | Server-generated query against allowlisted log resource IDs. Paged: `limit` (1-500, default 100), `offset`; filters `search` (project/group, max 100 chars), `projectId` (exact), `minUsedPercent`, `attention=true` (exhausted, stale or partial). Totals always cover every group; `page` reports `matched`, `total` and `nextOffset`. Invalid values return 400 `invalid_budget_query`. |
| `GET /api/v2/runs`, `/audit` | Server-generated queries against allowlisted log resource IDs. |
| `GET /api/v2/health`, `/prices`, `/billed-cost` | Separate optional capability results, including observation time/permission requirement. |
| `GET/PUT /api/v2/catalog` | Editor writes; If-None-Match `*` for first create, exact If-Match for replace; parsed rate card and deployment mappings. |
| `GET /api/v2/version` | Authenticated version information. |

Optional integrations return an explicit capability envelope: `available`,
`partial`, `disabled`, `permission_required` or `unavailable`; the UI does not
turn an access denial into a zero cost or green health indicator.
