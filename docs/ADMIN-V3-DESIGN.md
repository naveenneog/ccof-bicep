# Admin console V3: design and required changes

Status: **design proposal**. Nothing in V3 is deployed. V2 (`/api/console`, package 2.0.x) stays
unchanged and remains the supported console until V3 is accepted. One V3 building block exists
in code today: the budget-to-token planner (`admin/src/token-planner.ts`, tested).

## 1. Goals

| Goal | What it means |
| --- | --- |
| Dashboard, not a side list | All sections in a collapsible sidebar; every section uses the full content width. Projects becomes a real page, not a permanent left column. |
| Chargeback inside the console | The chargeback workbook's figures, filters and charts, computed from the same ledger and rate card. |
| Light and dark themes | Light, Dark and System, from one token set, AA contrast in both. |
| Budget assistant | Turn a USD budget into suggested token quotas and rate limits per model family, with sliders. |
| Helper view | Contextual help on every page: what a figure means, which permission enables it, how to fix common problems. |
| Coexistence | V2 and V3 ship together; either can be used; rollback is a URL change, not a redeploy. |
| 10,000 projects | All lists, filters and aggregations stay server-side and paged. |

## 2. Layout

```text
┌───────────────────────────────────────────────────────────────────────┐
│ CCOF Admin     Projects / CCOFE2E4               ?Help  ◐Theme  User   │
├────────────────────┬──────────────────────────────────────────────────┤
│ « Collapse         │ Page title                  Observed 10:42  ⟳    │
│ ▣ Overview         │ Filter bar (sticky)                              │
│ ▤ Projects         │                                                  │
│ ¤ Chargeback       │ Charts / tables / detail                         │
│ ◔ Budgets          │                                                  │
│ ◇ Foundry          │                                     ┌──────────┐ │
│ ♥ Health           │                                     │ Help     │ │
│ ≡ Audit            │                                     │ drawer   │ │
│ $ Cost definitions │                                     └──────────┘ │
│ ? Help             │                                                  │
└────────────────────┴──────────────────────────────────────────────────┘
```

- **Sidebar:** 240 px expanded; 56 px icon rail when collapsed, with tooltips; the choice is
  remembered. Below 820 px it becomes an overlay drawer opened from the top bar.
- **Top bar:** breadcrumb, help toggle, theme switch (Light / Dark / System), signed-in user and role.
- **Content:** page header with observation time and Refresh; a sticky filter bar where the page
  has filters; content sized by its own container (the fix already in V2), so nothing clips at
  125–150 % display scaling.

## 3. Pages

| Page | Content | Data (existing unless marked new) |
| --- | --- | --- |
| Overview | Month-to-date cost trend, budgets near or over limit, telemetry coverage, health concerns, recent changes | Chargeback API (new), `/v2/budgets`, `/v2/health`, `/v2/audit` |
| Projects | Full-width paged table: name, ID, tags, backend, classifications, % of budget used; filters for search, tags (multi), backend, classification | `/v2/projects` (add multi-tag and classification filters) |
| Project detail | Tabs: Overview, Models & limits, Access groups, Budgets (with assistant), Settings, Activity | Existing project, settings and limits APIs |
| New project | Stepper: Basics → Access groups → Models & budget (assistant) → Review | `POST /api/projects` (unchanged) |
| Chargeback | Workbook parity: totals, by group, developer, model, family, daily trend, coverage, unpriced/unattributed, diagnostics; charts plus tables; export | Chargeback API (new) |
| Budgets | Today's Group budgets, plus person budgets and a burn-down chart per group | `/v2/budgets` (+ person scope, new) |
| Foundry | Accounts, APIM backends, deployments, linked projects; `not_found` flagged with affected projects | `/v2/inventory`, `/v2/deployments` |
| Health | Resource state, endpoint probes, sync and reconciler freshness, shown as separate signals | `/v2/health`, `/v2/runs` |
| Audit | Filter by project, actor, action, date; before → after | `/v2/audit` (add server-side filters, paging) |
| Cost definitions | Model catalog, versioned rate card, retail meters, billed cost | `/v2/catalog`, `/v2/prices`, `/v2/billed-cost` |
| Help | Index of all help topics, permissions matrix, runbook links | Static, packaged |

## 4. Chargeback in the console

The workbook stores **queries**, not data. V3 runs the same queries server-side through the admin
app's managed identity and renders results natively. It never embeds or scrapes the workbook.

**Required change: one shared query builder.** Move the query construction in
`analytics/workbooks/chargeback.ts` (ledger, pricing, rollups, coverage) into a module both the
workbook build and the admin app import. Today's workbook keeps generating from it, so the
console and the workbook cannot drift. Workbook parameters (`{Period:base64}` and so on) become
bound parameters of a server-built query; the browser never sends KQL.

**New API:** `GET /api/v3/chargeback/{view}`, where view is `totals`, `groups`, `developers`,
`models`, `families`, `trend`, `coverage`, `unpriced` or `diagnostics`.

| Filter | Source | Notes |
| --- | --- | --- |
| Period | Workbook | Current month, previous month, custom. UTC, half-open `[start, end)` |
| Date and time range | Workbook (custom) | Date-time pickers; capped at `maxQueryDays` (62) |
| Project | Workbook | Searchable picker from `/v2/projects` |
| Entra group | Workbook | Picker by Object ID, with name snapshot |
| Developer | Workbook | Entra Object ID; no directory lookup unless Graph is enabled |
| Model | Workbook | Exact model ID |
| Foundry backend | **New** | Uses the ledger's request-time `backendId`, not today's project assignment |
| Model family | **New** | Same family derivation as the workbook |
| Chart interval | **New** | Hour or day bins; independent of the range |

Charts (each paired with a table):
- cost over time, stacked by model family;
- token-category cost split (input, output, cache read, cache writes);
- top groups or projects by cost;
- budget burn-down against the monthly budget.

The rules the workbook already follows stay visible:
- blank is not zero;
- coverage state: `incomplete`, `retention_truncated` or `no_data_not_zero`;
- rate-card version and observation time on every view;
- list price is labeled as not an invoice.

Export downloads the same bounded rows the workbook exports, with its `truncated` flag.

**Scale:** server-side aggregation; series capped at about 2,000 points; queries bounded by range and
time out after 30 s; results cached for 60 s per filter set; cancelled when filters change.

## 5. Budget assistant

Shown in New project and Project → Budgets. It suggests values; the admin reviews them in the usual
change review before anything is saved.

```text
Monthly budget  [ $100 ]   Members [ 10 ]   Geography [ Global ▾ ]
Sizing  ( ) Expected mix   (•) Guaranteed (never exceeds budget)

Traffic mix
  Output share of tokens       ──●──────────  20 %
  Cache reads (of input)       ─────●───────  50 %
  Cache writes 5 m (of input)  ●────────────  10 %
  Cache writes 1 h (of input)  ●────────────   0 %

Budget split by family
  Sonnet  claude-sonnet-5   ─────────●───  70 %
  Haiku   claude-haiku-4-5  ───●─────────  30 %

Rate limits   Working days [22]  Hours/day [8]  Burst ×  ───●──── 3

┌────────┬──────────┬─────────────┬─────────────┬──────────┬──────────┐
│ Family │ $/MTok   │ Group/month │ Person/mon. │ Person   │ Group    │
│        │ (blend)  │ tokens      │ tokens      │ TPM      │ TPM      │
├────────┼──────────┼─────────────┼─────────────┼──────────┼──────────┤
│ Sonnet │ 2.92     │ 7,000,000   │   700,000   │ 199      │ 1,989    │
│ Haiku  │ 1.46     │ 6,000,000   │   600,000   │ 171      │ 1,705    │
└────────┴──────────┴─────────────┴─────────────┴──────────┴──────────┘
Guaranteed sizing: expected $29.20 · worst case $100.00   [ Apply to limits ]
```

Rules, all implemented and tested in `token-planner.ts`:
- **Rates** come from the approved rate card (per million tokens, with cache categories and the
  geography multiplier), not from retail meters.
- **Blended rate:**
  - **Output:** the output share is priced at the output rate.
  - **Input:** split into cache reads, 5-minute writes, 1-hour writes and uncached input, each at
    its own rate.
  - *Example:* Sonnet 5 at 20 % output, 50 % cache reads and 10 % 5-minute writes blends to
    $2.92/MTok, against $10 for output alone.
- **A token quota can't cap dollars exactly.** Output costs more per token than cached input. So
  every plan shows both:
  - the expected spend at the assumed mix;
  - the worst-case spend if every token were billed at the family's most expensive rate.
- **Expected sizing** gives more tokens, and warns when the worst case would exceed the budget.
  **Guaranteed sizing** uses the worst-case rate, so the quota alone can never overspend.
  - *Example:* $100 split 70 % Sonnet / 30 % Haiku. Expected sizing gives 23.97 M Sonnet tokens a
    month; guaranteed sizing gives 7.0 M.
- **Rate limits:** TPM = monthly quota ÷ working minutes × burst factor. *Example:* 20 days × 8 h
  with burst 4 gives 4,167 group TPM and 417 person TPM for a 10 M-token group.
- **Per person** = group quota ÷ members, floored. Under 10,000 tokens per person per month is flagged.
- **Fill in the form:** "Apply to limits" fills the family and aggregate limit fields. It saves
  nothing until the admin reviews and saves.

Server route (new): `POST /api/v3/plan` validates the input and returns the plan using the
catalog's current rate card. Pure computation; no writes, no extra permission.

## 6. Themes and framework

- **Framework:** React 19 (already a dependency) with TypeScript, React Router (hash routing, to
  keep the Functions route model), and a small headless primitive library for accessible menus,
  dialogs, tabs, sliders and tooltips (Radix UI). Bundled by esbuild into same-origin static assets.
  No CDN, no runtime fetch of code.
- **Charts:** a React chart library that renders SVG and supports keyboard focus and data tables
  (Recharts or visx). Colors come from theme tokens and stay distinguishable without color
  (patterns, labels).
- **Themes:** CSS custom properties in OKLCH, the existing moss accent and tinted neutrals for
  Light, a matching Dark set. System follows `prefers-color-scheme`; the choice is stored locally.
  Both themes checked for 4.5:1 text contrast.
- **Motion:** 150–250 ms state transitions (sidebar, drawer, theme); `prefers-reduced-motion` respected.
- **Security:** strict CSP unchanged (`default-src 'none'`, no inline scripts or eval). The asset
  allow-list in `ui.ts` and its test gain the V3 bundle files. Authorization stays server-side;
  ETag reviews unchanged.

## 7. Coexistence, packaging and deployment

| Item | V2 | V3 |
| --- | --- | --- |
| URL | `/api/console` | `/api/console-v3` |
| Source | `admin/ui/` | `admin/ui-v3/` (new) |
| Build output | `ui-dist/` | `ui-dist-v3/` |
| APIs | `/api/projects`, `/api/v2/*` | same, plus `/api/v3/chargeback/*`, `/api/v3/plan` |

- **Package:** one ZIP serves both consoles. Package version 3.0.0. The V2 2.0.x ZIP stays the rollback.
- **Entra:** add the SPA redirect URI `https://<admin-host>/api/console-v3` to the existing
  CCOF Admin registration. No new app, roles or scopes.
- **Private network:** unchanged. Upgrade from the VDI with the existing Flex publish
  (`az functionapp deployment source config-zip`).
- **Feature flag:** `ADMIN_V3_ENABLED=true` serves the V3 route. When it's off, V3 returns 404
  and V2 is untouched.

## 8. Permissions (all optional; each missing one disables only its feature)

| Feature | Admin app identity needs | Without it |
| --- | --- | --- |
| Projects, limits, budgets | Existing Cosmos projects role | Console unavailable (as today) |
| Chargeback, Overview cost | Log Analytics Reader on the gateway telemetry workspace | Chargeback shows "permission required" |
| Budgets, runs | Log Analytics Reader on the workspace with reconciler logs | Budgets panel disabled |
| Audit | Log Analytics Reader on the admin app's workspace (`ADMIN_AUDIT_WORKSPACE_ID`) | Audit disabled |
| Foundry inventory | Reader on APIM and Foundry accounts | Inventory disabled; manual backend IDs still work |
| Group search | Graph `GroupMember.Read.All`, tenant-admin consent | Paste Object IDs |
| Billed cost | Cost Management Reader | Billed cost disabled |
| Budget assistant | None | Always available |

## 9. Scale to 10,000 projects

- **Projects:** server-side search and filters, continuation-token paging, virtualized table rows.
- **Chargeback:** aggregation in KQL. The browser gets aggregated series and pages of at most 500 rows.
- **Budgets and audit:** server-side filters and paging; totals computed on the server.
- **Load test before release:** 10,000 projects, 30,000 groups and 30 days of synthetic ledger
  rows in the lab, measuring page latency, Cosmos RU per query and KQL duration.

## 10. Delivery plan

| Phase | Scope | Acceptance |
| --- | --- | --- |
| 1 | V3 shell: sidebar, routing, themes, help drawer, `/api/console-v3`, flag | Both consoles live in the lab; V2 unchanged |
| 2 | Projects page and detail, New project stepper with budget assistant | Create the E2E project through V3; gateway 200 after sync |
| 3 | Shared chargeback query module, `/api/v3/chargeback`, Chargeback page and charts | Figures match the workbook for the same filters, row for row |
| 4 | Overview, Budgets burn-down, Foundry, Health, Audit, Cost definitions | Feature parity with V2 |
| 5 | Scale load test, accessibility audit, VDI upgrade runbook | Targets met; customer acceptance |

## 11. Risks

- **Workbook drift:** avoided only if the workbook and the console share one query module.
- **Query cost:** large custom ranges can be expensive. They are bounded, cached and cancellable.
- **Budget assistant expectations:** a token quota doesn't cap dollars exactly. The UI shows
  expected and worst-case spend, and offers guaranteed sizing.
- **New dependencies** (router, primitives, charts): pinned, bundled and reviewed. No runtime CDN.
