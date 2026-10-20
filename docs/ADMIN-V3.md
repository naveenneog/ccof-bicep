# Admin console V3: settings, permissions, upgrade and rollback

Release source: `feat/admin-console-v2`; package version **3.0.0**. Design: [ADMIN-V3-DESIGN.md](ADMIN-V3-DESIGN.md).
One ZIP serves both consoles. V2 stays at `/api/console` and is unchanged; V3 is at
`/api/console-v3` and is served only when `ADMIN_V3_ENABLED=true`. This is an
**admin-app-only** upgrade: no gateway, sync or reconciler change, no new Entra app, roles or scopes.

## What V3 adds

| Page | What it shows | Data |
| --- | --- | --- |
| Overview | **Cost breakdown** (full width): overall known cost, tag toggles and a project picker; a project donut (top 7 + "N more") → select a project for its classification donut (STD, PRM, CYB, ...) → select a classification; the **users** split (top 8 by cost, Entra Object IDs) and **models** donut beside it follow the selection, and unknown cost is never drawn as zero. Then month-to-date known list cost stacked by model family (with its data table), needs-attention list (groups at ≥ 80 % of budget, incomplete coverage, late reconciler, failing probes), telemetry and reconciler facts, recent changes | `/api/v3/chargeback/{projects,classifications,developers,models,trend,totals,coverage}`, `/api/v2/budgets`, `/api/v3/reconciler/runs`, `/api/v2/health`, `/api/v3/audit` |
| Projects | Full-width table, 25 a page with continuation tokens; search, tags (all must match), backend and classification filters; budget used per project | `/api/v2/projects` (new `tags`, `classification` filters), `/api/v2/budgets` |
| Project detail | Tabs: Overview (cost trend, group budget use, facts), Models & limits (editor, review, save), Access groups, Budgets (person/group budgets in USD or CCU, burn-down, budget assistant with *Apply to limits*), **Onboarding** (per classification: download `config.json` for the developer's CCOF helper and `onboarding.json` for whoever onboards the team, with a preview, install paths and steps), Settings (name, tags, backend, subscription), Activity | `/api/projects/{id}` and its existing PUT/PATCH routes with If-Match, `/api/v3/plan`, `/api/v3/audit`, `/api/v3/projects/{id}/client-config` |
| New project | Stepper: Basics → Access groups → Models & budget (with the assistant) → Review (the exact document) → `POST /api/projects` | existing |
| Chargeback | Totals, coverage state, rate-card version, observation time, "list price, not an invoice"; charts each paired with a data table: cost over time by family (hour/day bins), cost by token category, top groups/projects, budget burn-down; breakdown tabs (groups, developers, models, families, projects, unpriced, diagnostics) paged ≤ 500 rows; CSV export with `truncated` flag | `/api/v3/chargeback/{view}` |
| Budgets | Group and person budget counts, spend, capped use; burn-down per access group; snapshots table (groups or people) | `/api/v3/reconciler/{summary,snapshots}`, `/api/v2/budgets` |
| Reconciler | Last written run age vs timer interval, states written (person/group), ingestion delay, unattributed/unpriced; latest run per outcome; snapshot search by period, scope, project, classification, person, snapshot state, budget state (server-side paging) | `/api/v3/reconciler/{runs,snapshots}` |
| Foundry | Accounts (lifecycle, region, public access, matched backends, deployments on demand), gateway backends with linked projects, `not_found` accounts with affected projects | `/api/v2/inventory`, `/api/v2/deployments`, `/api/v2/projects?backendId=` |
| Health | Reconciler freshness, telemetry freshness, admin version, endpoint probes, configured integrations — as separate signals | `/api/v2/health`, `/api/v3/{reconciler/runs,chargeback/coverage,version,capabilities}` |
| Audit | Filter by project, actor, operation, outcome and UTC dates; before → after; paged | `/api/v3/audit` |
| Cost definitions | Rate card in USD or CCU per MTok (exact, 100 CCU = USD 1), families, effective dates, geography multipliers, prompt tiers, cache categories; **Load from file**, **Edit prices** (reprice from a future date), server review, save with ETag; export JSON; model mappings, retail meters, billed cost | `/api/v2/catalog`, `/api/v3/rate-card/review`, `/api/v2/{prices,billed-cost}` |
| Help | All help topics, permissions matrix, runbooks; every page also has a contextual Help drawer | static |

Shell: collapsible sidebar (240 px / 56 px icon rail with tooltips, remembered), overlay drawer under
820 px, breadcrumb, Help toggle, Light / Dark / System theme (remembered; System follows
`prefers-color-scheme`), signed-in user and role. Both themes keep text at 4.5:1 or better
(checked by `admin/tests/ui-v3.test.ts`).

## One query builder for the workbook and the console

`analytics/workbooks/chargeback-queries.ts` builds the chargeback KQL for both the workbook build and
the admin app. The workbook build is unchanged byte for byte (`tests/chargeback-shared-queries.test.ts`
pins the content digests; `admin/tests/chargeback-queries.test.ts` proves the console's options only
add backend/family filter lines, hourly bins and row paging). Workbook parameters (`{Period:base64}`,
`{TimeRange:start}`, …) are bound on the server by the workbook's own renderer (`render.ts`): every
filter value is validated, then reaches KQL base64-encoded. The browser never sends KQL.

The packaged `kql/` folder holds copies of `analytics/ledger.kql`, `analytics/workbooks/pricing.kql`
and `analytics/workbooks/budgets.kql`, made by `npm run build`.

Limits: custom ranges ≤ `ADMIN_CHARGEBACK_MAX_QUERY_DAYS` (default 62), UTC half-open `[from, to)`;
series capped at 2,000 points; row pages ≤ 500; Log Analytics calls time out after 30 s; identical
requests are cached for 60 s per filter set and rate card; the browser cancels a request when filters
change.

## Settings

| Setting | Needed for | Value |
| --- | --- | --- |
| `ADMIN_V3_ENABLED` | V3 console and `/api/v3/*` | `true` to serve; anything else returns 404 (V2 unaffected) |
| `ADMIN_GATEWAY_RESOURCE_ID` | Chargeback, Overview cost | Full ARM ID of the APIM instance (`_ResourceId` of `ApiManagementGatewayLogs`) |
| `ADMIN_CHARGEBACK_WORKSPACE_ID` | Chargeback (optional) | Workspace GUID holding the gateway logs; defaults to `ADMIN_WORKSPACE_ID` |
| `ADMIN_CHARGEBACK_MAX_QUERY_DAYS` | Chargeback (optional) | 31–366, default 62 |
| `ADMIN_LOG_RETENTION_DAYS` | Chargeback (optional) | Workspace retention, default 90; earlier periods are flagged `retention_truncated` |
| `ADMIN_WORKSPACE_ID`, `ADMIN_LOG_RESOURCE_IDS` | Reconciler, Budgets, Audit (as V2) | Workspace GUID; comma-separated originating resource IDs (include the reconciler app) |
| `ADMIN_RECONCILER_RESOURCE_ID` | Reconciler (optional) | Reconciler Function App ID; when set, only it is read for runs and snapshots |
| `ADMIN_RECONCILER_INTERVAL_MINUTES` | Reconciler freshness (optional) | Timer interval matching `RECONCILER_SCHEDULE`, default 5 |
| `ADMIN_BUDGET_LOOKBACK_DAYS` | Reconciler (optional) | 1–93, default 31 |
| `ADMIN_AUDIT_WORKSPACE_ID` | Audit (as V2) | Admin app's own workspace when it differs |
| `ADMIN_CLIENT_ID` | Onboarding downloads | Application (client) ID of the CCOF client app registration developers sign in with |
| `ADMIN_CLIENT_TENANT_ID` | Onboarding downloads (optional) | Entra tenant GUID for the client; defaults to `ADMIN_TENANT_ID` |
| `ADMIN_CLIENT_SCOPE` | Onboarding downloads (optional) | Token scope; defaults to `api://<ADMIN_CLIENT_ID>/access_as_user` |
| `ADMIN_GATEWAY_URL` | Onboarding downloads | Gateway base URL the client calls, `https://…` without `/v1` (same value as the client's `gatewayUrl`) |
| `ADMIN_PROJECT_HEADER` | Onboarding downloads (optional) | Project selector header, default `x-ccof-project` |
| `ADMIN_CONFIG_CONTAINER` | Saving cost definitions (as V2) | Cosmos container; when a catalog is saved, chargeback and the budget assistant use its rate card |

A missing or invalid setting disables only its feature, which then shows its capability state
(`disabled`, `permission_required`, `unavailable`) with the reason and the permission that enables it.
Without the client settings the Onboarding tab still generates both files but lists the missing settings
and writes `REPLACE-…` placeholders in their place, which the client's validator refuses.

## Permissions

All belong to the **admin Function App managed identity**; none are granted by the deployment.

| Feature | Needs | Without it |
| --- | --- | --- |
| Projects, limits, budgets | Existing Cosmos projects data role | Console unavailable (as today) |
| Chargeback, Overview cost | Log Analytics Reader on the gateway telemetry workspace | Chargeback shows `disabled` or `permission_required` |
| Budgets, Reconciler | Log Analytics Reader on `ADMIN_WORKSPACE_ID` with the reconciler's logs | Those panels show their state |
| Audit, Activity | Log Analytics Reader on the admin app's workspace | Audit disabled |
| Foundry inventory | Reader on APIM and Foundry accounts | Inventory disabled; type backend IDs |
| Billed cost, retail meters, group search | As V2 | As V2 |
| Budget assistant | None | Always available |

People: reading needs `CCOF.Projects.Read` (or `ADMIN_READER_IDS`); changes need `CCOF.Projects.Write`
(or `ADMIN_EDITOR_IDS`). Every write keeps the field-level review and If-Match ETag and emits one
`ccof.admin.audit.v1` line.

## New API

| Route | Behavior |
| --- | --- |
| `GET /api/v3/chargeback/{view}` | `view`: totals, groups, developers, models, families, projects, classifications (project × classification), trend, coverage, unpriced, diagnostics. Query: `period` (month, previous, custom), `from`/`to` (UTC, custom only), `project`, `group` and `developer` (Object IDs), `model`, `backend` (request-time `backendId`), `family`, `classification`, `tags` (comma-separated, ≤ 10, all must match; resolved to project IDs from the registry, refused with 400 `tag_matches_too_many_projects` above 2,000 projects; no match selects nothing), `interval` (hour, day), `limit` (1–500, default 100), `offset`. Unknown or repeated parameters return 400. |
| `GET /api/v3/projects/{id}/client-config?classification=STD` | Reader. Returns `config` (validates with `client/src/config.mjs`: tenant, client, scope, gateway URL, the classification's models by family, a stable Desktop profile ID, `project {id, selectorHeader}`), `onboarding` (Entra group, models, install paths, steps), `missing` and `complete`. No secrets. 400 invalid classification, 404 unknown project or classification, 409 classification without models. |
| `GET /api/v3/reconciler/runs` | Latest run per outcome and reason, with `ageMinutes` and `freshness` against the interval |
| `GET /api/v3/reconciler/snapshots`, `/summary` | `period`, `scope` (person, group), `project`, `classification`, `person`, `state` (current, expired, historical, invalid_event), `budgetState`, `limit`, `offset`; exact USD equivalents |
| `GET /api/v3/audit` | `project`, `actor`, `operation`, `outcome`, `from`, `to` (≤ 93 days, default last 31), `limit`, `offset` |
| `GET /api/v3/plan` | In-force models by family, geography multipliers, rate card version and source |
| `POST /api/v3/plan` | Budget assistant: `monthlyBudget {amount, currency USD/CCU}`, `members`, `geography`, `sizing`, `mix`, `families[{family, model?, budgetPercent}]`, working days/hours, burst. Pure; no writes. 422 with `detail` on invalid input. |
| `POST /api/v3/rate-card/review` | Validates a candidate rate card with the reconciler's parser and the history rules (version must change, recorded entries unchanged, new or closed entries not in the past) and returns added/closed/unchanged. Saving stays `PUT /api/v2/catalog` with If-Match. |
| `GET /api/v3/version`, `/capabilities` | `3.0.0`; which features are configured and the caller's role |

`/api/v2/version` and `/api/health` report 3.0.0. `/api/v2/projects` accepts `tags` (comma-separated, all
must match, up to 10) and `classification`.

## Upgrade from the VDI

Follow [ADMIN-V2.md](ADMIN-V2.md) "VDI build and upgrade" with these differences:

1. Build `ccof-admin-v3.0.0.zip` with `admin\Build-AdminPackage.ps1 -OutFile <path>`. Keep the 2.0.x ZIP
   as the rollback package. The ZIP adds `ui-dist-v3/` and `kql/`.
2. Add the SPA redirect URI `https://<admin-host>/api/console-v3` to the existing **CCOF Admin** app
   registration (Authentication → Single-page application). No new app, roles or scopes.
3. Publish with the same private `az functionapp deployment source config-zip` route.
4. Leave `ADMIN_V3_ENABLED` unset first: confirm `/api/console` (V2) works and `/api/health` reports
   `3.0.0`; `/api/console-v3` returns 404.
5. Set `ADMIN_V3_ENABLED=true` (and the chargeback settings above when approved). Open
   `/api/console-v3` from the VDI, sign in, and check each page's state against the settings you set.
6. Acceptance: reader cannot edit; editor reviews and saves a test limit (audit line appears); the
   chargeback totals for this month match the workbook's for the same filters and rate-card version.

## Rollback

- **To V2 only:** set `ADMIN_V3_ENABLED` to `false` (or remove it). V3 routes return 404; V2 is untouched.
  No redeploy, no data change.
- **To the 2.0.x package:** publish the retained ZIP with `config-zip`. V3 writes nothing V2 doesn't
  understand: projects and catalog documents keep the V2 schema.
- A project or catalog change made in V3 is a real change; reverse it through a reviewed, ETag-guarded
  edit in either console, never by restoring the database.

## Local demo

`cd admin; npm run build; $env:PORT=7272; node dev/serve.ts` serves both consoles with synthetic
data (`dev/demo-data.ts`: chargeback ledger aggregates, reconciler runs, person and group budgets,
inventory, audit). Demo only: it is not packaged and never used in Azure.
