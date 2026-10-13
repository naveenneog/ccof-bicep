# Chargeback workbook

## Fixed-price quickstart report — WP-CHARGEBACK-OCT13

Quickstart step 2 now uses `analytics/workbooks/chargeback.ts`. This is a
**separate reporting mode**, not the legacy budget-follow-up layout described
below: no reconciler tables, budget enforcement or contract discounts required.
It embeds the fixed USD list rates from `config/rate-card.json`, with source
dates/version/digests. Fable/Mythos usage remains visible but their rates are
excluded until exact Foundry IDs/prices are verified.

Views: selected-period totals, developer totals, developer/project/group
detail, stable group totals, models, prefix-derived model families, daily
trends, unpriced rows and failure/conflict/missing-usage diagnostics.
Period/project/group object ID/developer object ID/model filters are display
filters, never authorization. Person keys are existing authorized Entra
object IDs; no invented user names or new user lookup.

Exact Graph group names are deployment metadata, preserving case/punctuation/
spacing, never replacing names with STD/PRM/CYB. Names stamped in a trusted
request win and remain historical snapshots after renames/deletions. Baseline
traces lack group IDs: `current_mapping_historical_unverified` explicitly
means today's deployment mapping, **not settled historical chargeback**.
Stable group totals retain all exact `groupNameSnapshots` (up to 32).
Missing names/IDs are labelled unknown. No per-request Graph calls.

`inputTokens` means uncached input; cache reads and creation/write TTL counts
are disjoint and never counted a second time as input. `<category>CostUsd`
prices input/output/cacheRead/cacheWrite5m/cacheWrite1h separately.
`knownTokenCostUsd` is only the observed priced subtotal; `totalCostUsd` stays
blank with any unpriced/partial/unattributed/retention-truncated usage.
`knownTokensSpent` is the known count subtotal; `tokensSpent` stays blank if
any category is missing. Streamed cache counts stay null under actual APIM
telemetry; a proposed stream reader is not deployed.

`observedCacheHitRequestPercent` = positive known read requests / known read
requests. Unknown reads are excluded (not a fleet-wide hit rate).
`knownCacheReadSavingsUsd` = reads × (uncached input rate − cache read rate);
a counterfactual read-only saving, not net saving after write premiums.
Unknown cache TTLs are never guessed to be five minutes.

Offline validation:

```powershell
node --test tests/chargeback-report.test.ts tests/chargeback-accounting.test.ts
pwsh -NoProfile -File tests/Test-ChargebackQuickstart.ps1
node tests/helpers/chargeback-render.ts .env.chargeback-kql.json
dotnet restore tests/kql-checker/KqlCheck.csproj
dotnet run --project tests/kql-checker/KqlCheck.csproj --no-restore -- .env.chargeback-kql.json
```

The pinned Microsoft Kusto language service checks syntax and semantics
against the APIM table contract **offline**, not execution against real logs.
If nuget.org TLS is blocked, the official public Microsoft mirror works:
`--source https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-public/nuget/v3/index.json`.
All fixtures are synthetic. Native portal rendering and live query execution
are explicitly unverified in this worktree; no Azure resources were changed.

The chargeback workbook is an Azure Monitor workbook. It shows each project's, each classification
group's and each person's Claude token usage, priced at list price in CCU, and each person's and
group's budget against spend. It reads two sources in the Log Analytics workspace:

- the usage ledger: `CcofUsageLedger` in `analytics/ledger.kql` (WP-TEL; ADR-0010), built from the
  gateway's LLM log and its content-free usage trace;
- the reconciler's log lines `ccof.reconciler.budget.v1` and `ccof.reconciler.run.v1` (WP-REC;
  ADR-0018), in the table `FunctionAppLogs`.

The workbook only reads. It does not change budgets, and it has no part in deciding whether a
request is served. If the workbook or the workspace is unavailable, only reporting stops.

**What it is not.** It is not an invoice. Amounts are list prices, not the CCUs that Azure
Marketplace bills (ADR-0005). It is not the immutable month-end archive described in
`docs/CHARGEBACK-RETENTION.md` (ADR-0004). Use it for operational chargeback and budget follow-up.

## Opening it

| Item | Value |
| --- | --- |
| Portal path | Resource groups > the deployment's resource group > the workbook's display name (type Azure Workbook) > Open workbook |
| Contoso proof of concept | `sample-pilot-rg`, display name "CCOF Pilot chargeback - list price", resource name `00000000-0000-4000-8000-000000000010` |
| Access | Workbook Reader on the workbook, and Log Analytics Reader on the workspace (`infra/workbook/assignments.json`, granted by stage D3) |

Log Analytics Reader can read every table in the workspace, not only the workbook's results: the
gateway logs (URLs, correlation ids, and usage traces with Entra object ids and project ids), the
gateway's LLM log (models and token counts), the Function App logs of the resolver, the sync and the
reconciler, and anything else sent to the same workspace. No prompts or responses are logged
(ADR-0010). The project selector in the workbook is a display filter. It is not an access control.

## Selectors

| Selector | Meaning |
| --- | --- |
| Period (UTC) | Current calendar month, previous calendar month, or a custom range. All periods are UTC and half-open: the start is included, the end is excluded |
| Custom range | Used only when Period is "Custom range" |
| Project id | `*` for every project, or one exact, case-sensitive project id, such as `CCOFPILOT01` |

Every period, including a calendar month, may not exceed `maxQueryDays` (62 in the proof of concept;
the setting must be at least 31). A longer or empty range shows `invalid_range` and reads no usage. A
period that starts before the workspace's retention (`retentionDays`, 31 in the proof of concept)
shows `retention_truncated`: its oldest rows are gone, so its amounts are lower bounds.

## Sections and figures

Amounts are in CCU. **100 CCU = USD 1** (`docs/PILOT.md`, C-7). Each USD column is the CCU column
divided by 100.

### Coverage and observed delivery lag

One row for the selected period and project.

| Figure | Meaning |
| --- | --- |
| `observedRequests` | Ledger rows that are model usage |
| `pricedRequests`, `partialRequests`, `unpricedRequests` | How those rows were priced (see "How a request is priced") |
| `unattributedRequests` | Rows without a valid gateway trace, so with no person, project or classification |
| `noUsageRequests` | Rows where no model ran, counted here and never priced: `noBackendCallRequests` (refused before any backend call, `usageSource` `no-backend-call`) plus `zeroTokenRequests` (input and output measured zero, with no cache tokens) |
| `latestRequest`, `latestIngested`, `requestToIngestSeconds` | The newest request, its arrival in the workspace, and the longest delay between the two |
| `reportState` | `invalid_range`; `retention_truncated` (the period starts before the workspace retention); `no_data_not_zero` (no rows: this does not prove zero use); `incomplete` (some rows are partial, unpriced or unattributed); or `observed_token_usage_complete` |

### Usage, model mix and top people

"Usage" groups rows by project, then classification group, then person. "Model mix" groups them by
model. "Top people" ranks people by known list CCU. That ranking is not complete spend.

| Figure | Meaning |
| --- | --- |
| `requests` | Ledger rows in the group, excluding no-usage rows |
| `inputTokens`, `outputTokens`, `cacheWrite5mTokens`, `cacheWrite1hTokens`, `cacheReadTokens` | Sum of the known counts of each token category. Blank when no row knew that category |
| `<category>KnownRequests`, `<category>UnknownRequests`, `<category>Status` | How many rows knew the category; status `known`, `partial` or `unknown`. A measured zero is known |
| `knownListCcu`, `knownListUsd` | The sum of every amount that could be priced: priced rows in full, partial rows as lower bounds. Blank when nothing could be priced |
| `listCcu`, `listUsd` | The complete total. Shown only when every row in the group is priced and attributed and the period is within retention; blank otherwise. Blank is not zero |
| `completeness` | The first that applies: `retention_truncated`, `unattributed` (some rows have no owner), `unpriced_usage` (some rows have no amount), `partial` (some rows are lower bounds), else `complete` |
| `reportRows`, `displayedLimit`, `truncated` | The grid shows at most `maxRows` rows (1,000 in the proof of concept). When `truncated` is true, narrow the project or period |
| `periodStart`, `periodEnd`, `basis`, `rateCardVersion`, `rateSourceDates`, `rateCardSha256`, `ledgerSha256`, `retentionTruncated` | Provenance: the period, "list price", the rate card, the exact rate-card and ledger files deployed, and whether retention cut the period |

### Budget versus spend

One row per budget scope: each person in a project, and each project's classification group. Each
row is the reconciler's latest snapshot, chosen by `computedAt`, for each monthly budget period that
overlaps the selected period. Only lines logged in the last `budgetLookbackDays` days (31 in the proof
of concept) are read.

| Figure | Meaning |
| --- | --- |
| `scope`, `scopeId` | `person` (`<personId>:<projectId>`) or `group` (`<projectId>:<classification>`) |
| `period`, `periodStart`, `periodEnd` | The snapshot's own budget month, which can differ from the selected period |
| `spentCcu`, `budgetCcu`, `spentUsdEquivalent`, `budgetUsdEquivalent` | Spend and budget as the reconciler computed them, exact decimals |
| `budgetState` | `available`, `exhausted` (a budget of 0 is valid and exhausted), `no_cap` (a group without a cap), or `unknown` (the line failed validation, for example a missing field; its values are blanked, not zeroed) |
| `exhausted`, `mode` | When the resolver's budget enforcement is on (onboarding Stage 5), `exhausted` with `strict` refuses requests; `notify` only flags them (C-7) |
| `completeness`, `pricedRequests`, `partialRequests`, `unpricedRequests` | Whether the reconciler's spend is complete or a lower bound |
| `activeMemberCount` | Members of the group (groups only) |
| `computedAt`, `validUntil`, `snapshotAgeSeconds`, `eventDeliverySeconds` | When the snapshot was computed, until when the resolver may use it, its age, and its log delivery time |
| `snapshotState` | `current`, `expired` (past `validUntil`: not current evidence), `historical` (its month has ended), or `invalid_event` |
| `rateCardVersion`, `rateCardMismatch` | The rate card the reconciler used, and whether it differs from the workbook's |

"No matching observations" means no budget line was received. It does not mean a zero budget or zero
spend.

### Reconciler runs

The latest run for each outcome (`written`, `skipped_lease_held`, `failed`, `settings_invalid`), with
`runs` (how many in the lookback), `latestRunAt`, `latestAgeSeconds`, `statesWritten`,
`personStates`, `groupStates`, `maxIngestionDelaySeconds` (the ledger delay that run saw),
`unattributedRequests`, `unattributedCcu`, `unpricedRequests` and `logDeliverySeconds`. A
`latestAgeSeconds` well above the reconciler's timer interval means budget state is stale. No rows
means no run line was received, not that the reconciler is healthy.

### Unpriced, partial or unattributed usage

One row per request that is not fully priced or has no owner, with `pricingStatus`, `pricingReason`,
the token counts and the known amount. Reasons for unpriced rows: `input_or_output_unknown`,
`geography_mismatch`, `model_not_in_rate_card`, `no_rate_in_force`, `geography_not_in_rate_card`.
Reasons for partial rows: `cache_categories_unknown`, `geography_unknown`. The reason looks at every
rate-card entry for the model, so a model with several effective periods gets the right reason.

### Chargeback export

One row per project for the selected period, with the totals, `completeness` and the provenance
columns. Use the grid's **Export to Excel** control. Before sending an export as a chargeback, check
that `truncated` is false and `completeness` is `complete`, or state that the amounts are lower
bounds. The chargeback grid has no person column. Exports of the usage, top-people, budget and
unpriced grids contain Entra object ids; handle them like the workspace data.

## How a request is priced

1. **Rate card.** WP-COST's static file `config/rate-card.json` (version `2026-10-11`; ADR-0011) is
   read once, at deployment, and embedded in the workbook. Rates are Anthropic's published list
   prices in USD per million tokens for five categories: input, output, 5-minute cache write, 1-hour
   cache write and cache read. CCU per token = USD per million tokens × geography multiplier × 100 ÷
   1,000,000. Example: Claude Sonnet 5 input at USD 2 per million tokens is 0.0002 CCU per token.
2. **Model.** The ledger's model name is lowercased and stripped to letters and digits. A trailing
   date (`YYYYMMDD`) is removed when the dated name is not itself in the card, so
   `claude-haiku-4-5-20251001` is priced as `claude-haiku-4-5`. Unknown models are unpriced.
3. **Effective date.** Each entry applies from `effectiveFrom` (included) to `effectiveTo`
   (excluded). The pilot card starts at 2026-10-11T00:00Z, so earlier usage is unpriced.
4. **Geography.** A known geography uses its multiplier (US-only inference is 1.1× for models that
   support it). A known geography that the entry does not list is unpriced. An unknown geography
   takes the entry's smallest multiplier, and the row is partial.
5. **Prompt tiers.** Where the card has tiers (Claude Haiku 5.5 above 100,000 prompt tokens), the
   tier follows the counted categories. If a counted category is unknown, the cheapest tier still
   possible is used, and the row is partial.
6. **Status.** `priced`: all five counts, the geography and the tier are known. `partial`: input and
   output are known but a cache category, the geography or the tier is not; the amount is a lower
   bound. `unpriced`: no amount, because the model, the date, the geography or the input or output
   count cannot be priced, or the trace's geography conflicts with the deployment's.
7. **No usage.** Refusals before any backend call, and rows with zero input, zero output and no cache
   tokens, are counted in `noUsageRequests` and not priced. The reconciler applies the same rule
   (ADR-0018), so the two agree on what is usage.

All arithmetic uses decimals, not floating point. Unknown values are never replaced by zero.

## Limits

- **List prices only.** No private-offer discount is recorded (`config/contract-schedule.json` is
  empty), and Marketplace CCU billing is not read. Charges outside the five token categories, such as
  web search, are not included.
- **Cache categories are often unknown.** The gateway captures cache counts only from a
  non-streamed response whose usage the trace records. Streamed responses, which Claude Code uses,
  and rows without a trace have unknown cache categories, so they are partial lower bounds. Cache
  reads cost 0.1× the input rate for most models (0.05× or 0.025× for some), and cache writes 1.25× or
  2×, so the missing part can be large in cache-heavy sessions. Source: the Anthropic pricing page,
  as quoted in `config/rate-card.json`.
- **Geography is unknown in the pilot.** The gateway learns a deployment's geography from its
  configuration, and that map is empty in the proof of concept until the deployment types are
  decided (owner decision 3b). Until then every row is partial on geography and is priced at the
  smallest multiplier, which is the global price.
- **Attribution needs the gateway trace.** Rows without a valid `ccof.usage.v1` trace are shown as
  `(unattributed)`, and no complete total includes them.
- **Reconciler lag.** Budget state lags spend by the ledger's ingestion delay, plus up to one timer
  interval, plus the run time, plus the gateway's cache time (C-7; ADR-0018). Resource logs usually
  arrive in 3 to 10 minutes and can take 30 seconds to 20 minutes (Microsoft Learn, "Log data
  ingestion time in Azure Monitor"). In the proof of concept on 2026-10-11, the longest observed
  delay from request to ledger was 131 seconds. Use `computedAt`, `validUntil`, `snapshotAgeSeconds`
  and the reconciler runs grid to see the actual lag.
- **Budget periods are calendar months.** A custom range shows the monthly snapshots that overlap it,
  not spend within the custom range.
- **The workbook and the reconciler can differ.**
  - When the trace's geography conflicts with the deployment's, the workbook marks the row unpriced;
    the reconciler prices it with the deployment's geography.
  - The reconciler applies the contract schedule's discounts once entries exist; the workbook shows
    list price only. The schedule is empty for the pilot, so both are list price today.
  - A month's last snapshot is the reconciler's last run in that month. Rows that reach the
    workspace after that run are in the workbook's usage but not in that snapshot.
- **Retention.** The workbook shows only what the workspace still holds (31 days in the proof of
  concept), and marks a period that starts earlier as `retention_truncated`. It archives nothing.
- **Names.** People are shown by Entra object id. There is no directory lookup.
- **Scale.** Grids show at most `maxRows` rows and the top `topUsers` people. Filter by project for
  large fleets. Behaviour with 500,000 developers has not been measured.

## Operating it

| Task | Command or file |
| --- | --- |
| Create the empty workbook resource (stage D1, optional Bicep) | `infra/workbook/resource.bicep` |
| Deploy the content (stage D2) | `pwsh infra/workbook/deploy.ps1 -AnswersPath <file>` (`-ValidateOnly` makes no Azure call; `-WhatIf` records a what-if). It refuses before any write if the D1 workbook, the workspace, the gateway or the reconciler does not exist |
| Check the deployed workbook, read-only | `pwsh infra/workbook/verify.ps1 -AnswersPath <file> -Period month -Project '*'`. It prints counts, sums and states, writes no query results to disk, and fails if the deployed content or its `ccof-*` tags differ from the reviewed build |
| Reader permissions (stage D3) | `infra/workbook/assignments.json` |
| Portal screenshot steps | `infra/workbook/screenshot-steps.json` |
| Run the queries on fixtures in the workspace (explicit opt-in) | `CCOF_LIVE_TESTS=1 pwsh infra/workbook/Test-WorkbookKql.ps1 -SubscriptionId <id> -WorkspaceId <workspace customer id> -OutputDirectory .env.<name>` |

The answers file holds every environment value: tenant, subscription, resource group, workspace,
gateway, reconciler, rate card and ledger paths, the five report settings (`defaultProjectId`,
`maxRows`, `topUsers`, `maxQueryDays`, `budgetLookbackDays`) and `retentionDays`, the workspace's
retention (WP-CORE takes it from the availability decision; `deploy.ps1` refuses unless it equals
the workspace's live retention). A missing or invalid value stops the script before any Azure call.
The scripts print JSON lines with ids and reason codes only. The deployed workbook carries the tags
`ccof-rate-card`, `ccof-ledger`, `ccof-answers` and `ccof-content` (SHA-256 digests, computed with
LF line endings so every machine gets the same values). Re-running D1's `resource.bicep` after D2
resets the content to its placeholder, and `verify.ps1` reports `deployed_content_differs`. Run D2
again: its workbook step checks an unchanged workbook with `verify.ps1` and deploys it again when it
does not verify.

Both scripts run on Windows and Linux: node gets each script's full path, joined with the platform's
separator. Before their first Azure CLI call, they pass each value they give `az` (answers, ids built
from them and the checkout's paths) through `Assert-OnboardingAzArguments`
(`scripts/Onboarding.Azure.psm1`). On Windows `az.cmd` passes arguments through cmd.exe, so a value
holding `&`, `|`, `<`, `>`, `^`, `(`, `)`, `%`, a quote, a backtick or a line break refuses with
`az_arguments_refused`, `-ValidateOnly` included. The answers checks already refuse those characters
in names and ids, so in practice the cause is the checkout folder: move it to a path without them.

## Sources

- `docs/PILOT.md`, C-7 (CCU budgets; 100 CCU = USD 1) and C-9 (deployment stages).
- ADR-0004 and `docs/CHARGEBACK-RETENTION.md` (archival, not built here); ADR-0005 (Marketplace CCU
  billing).
- ADR-0010 and `docs/TELEMETRY.md` (WP-TEL): the ledger and its columns.
- ADR-0011 and `config/rate-card.json` (WP-COST): rates and pricing outcomes. Rates from
  https://platform.claude.com/docs/en/about-claude/pricing, retrieved 2026-10-11.
- ADR-0018 (WP-REC): the reconciler, its log lines and its lag.
- Microsoft Learn: [Azure Workbooks](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-overview),
  [workbook time parameters](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-time),
  [log data ingestion time](https://learn.microsoft.com/azure/azure-monitor/logs/data-ingestion-time),
  [Azure built-in roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles)
  (Workbook Reader, Log Analytics Reader).
