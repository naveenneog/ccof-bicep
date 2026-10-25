# Change log

## 2026-10-25 - Two-region backend failover drill

- [Drill record](DR-NOVICE-WALKTHROUGH-2026-10-25.md#two-region-backend-failover-drill-central-us-account-in-a-second-subscription): SASLAB1's fallback moved to a Foundry account in Central US in a second subscription of the same tenant. When the primary answered 404, the breaker opened and Central US served 22 of 26 calls; traffic returned to the primary after the fault.
- Fix (N-20): a primary that does not answer never opened the published breaker, which counted only response codes; an unreachable primary timed out on every call (0 of 4 failed over). `infra/dr/ProjectRouting.psm1` now publishes `failureCondition.errorReasons` `BackendConnectionFailure` and `Timeout` with every enabled breaker and treats a member without them as unverified. Two new checks in `tests/Test-ProjectRouting.ps1` (26 pass); each was shown to fail with its line removed. Live: Central US served 9 of 12 calls with `errorReasons`; revision 4 published by the fixed publisher failed over after 2 timeouts. Pools verified earlier keep the old breaker until a new revision is published ([DR runbook 6.6](runbooks/DR-CLOUD-SHELL.md#66-drill-prove-that-a-fallback-serves-workstation)).
- [DR runbook](runbooks/DR-CLOUD-SHELL.md): 6.1 covers a fallback account in another subscription and the region-shared Claude quota (N-23). The new 6.6 is a reversible drill that changes the pool member URL. A rejected private endpoint connection cannot be approved again (N-21), and deleting a deployment or lowering its capacity did not cause a failover (N-22).

## 2026-10-25 - DR walkthrough from the documentation

- [DR walkthrough](DR-NOVICE-WALKTHROUGH-2026-10-25.md): a first-time operator followed the README and linked guides in Azure Cloud Shell. In the Fabrikam lab, P0-P2, per-project failover and workspace replication were applied; D1-D6 remain unavailable. In a fresh Contoso sandbox, Stages 0-8 were applied (Stage 8 from the workstation); P2 and workspace replication were applied; the sandbox had no Claude deployment, so there was no positive model call. 19 issues are logged with screenshots and fixes; the main blockers are standby identity grants, provisioned Cosmos and missing D1-D6 tooling.
- The walkthrough caught a false Stage 1 verification failure: Flex returned a null subnet when no VNet integration was configured. `Get-StgSite` now normalizes the value; a regression test failed before the fix and 357 staged checks pass after it (commit `088e400`).
- The second Contoso run also exposed missing admin-app preauthorization for Microsoft Azure CLI. `admin.extraAllowedClientIds` was set and Stages 4, 5 and 7 reapplied before the workstation Stage 8 run. Eight pseudonymised Cloud Shell screenshots cover the Contoso deployment and DR results; OCR of all 195 repository images finds no real identifier.

## 2026-10-24 - Step-by-step deployment guide

- BSL-06 measured on a temporary lab probe API (deleted afterwards): APIM `limit-concurrency` releases
  its slot when a streamed response's headers arrive, so a per-person concurrency cap does not bound
  BSL-05 bursts. ADR 0035 and UNKNOWNS updated.
- Portal routes gain live captures of the Register an application, New Group and Create a private
  endpoint forms and of the Logs page in KQL mode.

- Novice review (council): 16 findings addressed. The guide now covers the APIM choice (`apim.existing`
  or a new public bootstrap), the 3-8 character prefix, creating the resource group before the Step 1
  preview, the Portal deployment-name limit for Step 1, the complete Entra script for all three
  registrations (run in the Contoso test tenant and deleted), a full Step 6 build and check, the
  Application Insights read needed by Step 7, and a configuration-driven Step 8 with telemetry by
  request ID. Placeholders in commands use `REPLACE-...`, which `cmd.exe` does not treat as redirection.
- Lab brought to the branch head: Stage 3 added one missing Cosmos data-role grant; Stage 5 replaced
  the gateway policy that still carried the rejected BSL-05 reservation; Stages 6, 7 and 8 verified.
  SASLAB1 STD limits and person budget restored to their values before the budget tests
  (person 500,000 and group 2,000,000 tokens a day; 25,000 CCU a month); Stage 8 showed
  `person-quota-remaining 499980`.

- [Deploy CCOF step by step](runbooks/DEPLOY-STEP-BY-STEP.md): steps 0-8, each with what it does, the
  permission needed, the driver command, Azure CLI commands, the Portal route and a check with
  screenshots. README and the runbooks index point to it first.
- Run screenshots are read-only driver previews of every step against the Fabrikam lab (2026-10-24),
  in the current step numbering. Read-only Azure CLI commands from the guide were run against the lab;
  the Entra `az ad` and Graph commands were run in the Contoso test tenant and the objects deleted.
- Nine more Portal pages captured live (subscription access, resource providers, resource group,
  APIM, Foundry, Cosmos, APIs, group members, custom template deployment). The pseudonym map now also
  covers the operator's surname, email domain and avatar initials, and an abbreviated sandbox
  subscription name in one earlier image; an OCR sweep of all 161 repository images finds no real
  identifier.

## 2026-10-24 - Documentation for new readers, pseudonymous screenshots

- README: what CCOF is, how it works in five steps, a "which guide to read" table, one current-release
  table and four screenshots. New [glossary](GLOSSARY.md) and [budgets and spend pacing](BUDGETS.md).
- Superseded pages carry a **Historical**, **Design record** or **Test record** line at the top;
  the runbooks index gives the reading order. The Portal deployment workbook has a linked module list.
- Main guides state Admin 3.3.0 and who uses them; references to an unpublished commit were removed.
- 35 links to unpublished ADRs, status pages and images became plain text; `tests/docs-links.test.ts`
  fails on any relative Markdown link or image that does not resolve.
- Screenshots: stage-run and budget-test terminal captures re-rendered from the original transcripts,
  admin console recaptured read-only from the Fabrikam lab (writes blocked), and 13 Portal pages
    captured live from the signed-in Fabrikam lab Portal on 2026-10-24, each checked for its expected
    value, with page text replaced by pseudonyms before capture. Names, IDs, subscriptions and hosts are pseudonyms of the same shape; OCR of all 55
  changed images finds none of the real values. Lab environments are named Fabrikam lab and Contoso.

## 2026-10-24 - Budget soft limit and spend pacing

- [ADR 0035](adr/0035-budget-soft-limit-and-spend-pacing.md): the gateway did not apply the
  reconciler's per-minute ceiling (BSL-01), so budget overshoot was bounded only by the ledger delay.
- Reconciler: optional `RECONCILER_SOFT_LIMIT_PERCENT` and `RECONCILER_PACING_WINDOW_MINUTES`.
  The ceiling spreads the remaining budget over one window, and over two from the soft limit on.
  `budgetState` gains `softLimitPercent`/`softLimitReached`; the budget log line gains `softLimitReached`.
- Gateway: keeps the resolver's ceiling in its cached decision and applies
  `ccof-limit-person-budget-pace` (key `pb:<project>:<oid>:<ceiling>`).
- `/usage` and `ccof-usage` show a soft-limit warning; admin Reconciler/Budgets show `warning`.
- Paced ceiling rounded down to a power of two, so the gateway's pace counter key changes only when
  the remaining budget halves. Live runs: $25 budget ended at 108.1%, $35 at 106.0% (ADR 0035).
- Live run 3 on the lab: $15 load against a $52.11 budget ended at 100.3%; warning at 81.9%,
  205 pace 429s, block 5 s after the budget was marked exhausted (ADR 0035).
- Deployment: quickstart/staged app settings, core answers schema and examples (80 / 30); answers reject a window shorter than the schedule interval.

## 2026-10-23 - DR routing, admin 3.3.0 and prerequisites, proven live

- Per-project optional backend failover (ADR 0034): routing contract, sync/resolver
  `routeBackendId`, gateway validation and forwarding, admin Backends page with optional circuit
  breaker, project failover section, `routing/pending` and `routing/{id}/publication`.
- `infra/dr/Publish-ProjectRouting.ps1` publishes project pools; `infra/dr/Invoke-DrPrerequisites.ps1`
  runs P0 discover, P1/P2 bootstrap (secondary VNet, DNS links, peering, identity shells) and verify.
- Gateway policy deployed as per-section policy fragments: Standard v2 began refusing API policy
  documents over 16 KiB (documented limit 512 KiB).
- Live: Contoso and Fabrikam lab P0-P2 in Central US; Fabrikam lab Stages 5 and 7; SASLAB1 failover drill with
  restore and switch-off; test quotas restored. Third subscription still HTTP 403.
  Evidence: [DR implementation](design/DR-IMPLEMENTATION.md#implemented-and-proven-2026-10-23).

## 2026-10-23 - DR implementation branch and prerequisite contract

- Started the DR work from the single-region Admin 3.2.0 state (now `feat/admin-console-v2`). DR-01 defines prerequisite-first
  identity/network preparation and a staged rollout in [DR implementation](design/DR-IMPLEMENTATION.md).
- [ADR 0034](adr/0034-dr-project-routing-and-prerequisites.md) replaces unconditional pools with
  project-specific optional failover, off by default. Backend registration does not authorize project
  routing; compatible fallback selection, isolated breaker scope, verified publication and audit are
  required. No admin/gateway behaviour changes are implemented in this packet.
- Read-only ARM discovery: Fabrikam lab and Contoso visible; the supplied third subscription and its exact
  APIM/Foundry targets return HTTP 403. Identifiers/evidence stay in session-private inventory files.
  No deployment, inference-spend test, consent or resource mutation was performed.
- Existing stages 0-8 are not renumbered. Runtime backend administration, pool publication, accounting
  continuity, data replication, edge deployment and failover drills remain separate roadmap packets.

## 2026-10-23 — DR diagram: original Azure icons and network boundaries

- Preserves the left-to-right layout with active/passive application regions in the middle and
  managed Foundry, Log Analytics and Cosmos services on the right.
- Uses original Microsoft Azure SVG icons, embedded for offline viewing. Front Door, WAF and subnet
  icons were added from the same Microsoft V24 collection; provenance and hashes are recorded.
- Regional VNets show separate APIM/Functions outbound-integration subnets and private-endpoint
  subnets. Cosmos and Log Analytics stay outside VNet boundaries. Monitor private endpoints connect
  to a shared AMPLS for private queries; APIM diagnostic ingestion uses the managed Microsoft channel.
- Reproducible vector/PNG generator: `docs/diagrams/dr-network-architecture.py`.
  Design only; no Azure deployment changes.

## 2026-10-23 — DR diagram: Standard v2 and Foundry backend resilience

- Updated the proposed DR diagram and ADR 0033 to use two Standard v2 APIM instances, private
  inbound through Front Door Premium (WAF and built-in DDoS protection), with outbound VNet
  integration rather than Standard v2 VNet injection.
- Added multiple illustrative Foundry members, model-specific local/remote priority pools and
  per-member circuit breakers. Documented cooldown, exhausted-pool failures, independent gateway
  breaker state, shared quota and no replay of partially delivered streams.
- The design requires private remote routing, identity grants and actual-backend accounting.
  Updated the PNG and browser HTML. No infrastructure or application behaviour changed.

## 2026-10-23 — Disaster recovery design (active/passive)

- [DR-ACTIVE-PASSIVE.md](DR-ACTIVE-PASSIVE.md) and [ADR 0033](adr/0033-dr-active-passive.md):
  - East US 2 active, Central US passive.
  - Front Door Premium with WAF.
  - Two APIM Premium v2 instances.
  - Cosmos with one write region and one read region, Session consistency.
  - One Log Analytics workspace replicated to Central US.
  - Fail-closed budgets with a ledger continuity gate before the reconciler restarts.
- East US + West Central US was rejected: neither region offers APIM Premium v2, and West Central US
  is not a Log Analytics replica location.
- Diagram: `docs/diagrams/dr-active-passive.mmd`, rendered to `docs/images/dr/dr-active-passive.png`.
  Design only; nothing deployed.

## 2026-10-23 — Developer self-service usage (`/usage`)

- Resolver route `POST /api/me/usage` (`src/resolver/my-usage.ts`), gateway API `ccof-usage`
  (`GET /me/usage`, policy `infra/gateway/policy/my-usage.template.xml`), client `ccof-usage` and the
  Claude Code `usage` skill. No new Azure resource, Entra app or permission. Staged Stage 5 deploys the
  API; Stage 7 the resolver. See [USAGE-SELF-SERVICE.md](USAGE-SELF-SERVICE.md).
- Tests: resolver 4, gateway render 4, client 3; 7/7 mutants caught.
- Live on Fabrikam lab: $10.09 of real calls; `/usage`, the admin reconciler snapshot, admin chargeback and the
  load script's own total all equal 1,008.7586 CCU. Fabrikam lab reconciler timer is now enabled
  (`reconciler.timerEnabled: true`).

## 2026-10-23 — Developers CSV includes user names

- Chargeback > Developers > Export CSV adds `displayName`, `userPrincipalName` and `nameLookup` after
  the `person` object ID (`admin/ui-v3/lib/user-names.ts` `withUserNames`). The object ID stays the
  accounting key. Names come from the same in-memory Graph lookup as the tables, so they need
  `ADMIN_USER_NAMES_ENABLED=true` and `User.Read.All`; otherwise the columns are empty and `nameLookup`
  states why (`disabled`, `permission_required`, `not_found`, `unavailable`).
- The UPN is the sign-in name; it can differ from the Entra `mail` attribute, which is not read.
- Tests: `admin/tests/csv-user-names.test.ts` (2; a mutant dropping the UPN fails); admin 116 pass; demo
  export checked in Edge (224 rows, all resolved).

## 2026-10-22 — Deployment, admin operations and user onboarding guides

- Added [deployment runbook](runbooks/DEPLOYMENT-RUNBOOK.md): Entra app/group/managed-identity
  configuration tables, required Graph grants, resource/access-team JSON handoff, network/endpoint/DNS
  prerequisites, stages 0-8, Portal screenshots, recovery and acceptance.
- The one-hour execution target explicitly assumes resources, approvals and network readiness;
  the current templates do not import arbitrary precreated managed identities or provide a
  read-only Stage 4. No unmeasured greenfield one-hour guarantee is claimed.
- Added [admin operations](runbooks/ADMIN-OPERATIONS.md): project/group onboarding, token and money
  budgets, retirement, removal limits, audit, and Portal/APIM/registry steps for another Foundry backend.
- Added [user onboarding](runbooks/USER-ONBOARDING.md): `onboarding.json` versus `config.json`,
  self-service sign-in/setup, user-context Intune packaging and detection examples, rollback,
  and the distinction between file detection, user sign-in and actual gateway acceptance.
- Reused labeled historical Portal references and added three synthetic 3.2 console screenshots.
  Intune tenant rollout and universal Desktop packaging remain explicitly unverified.
- Final Contoso Stage 8 rerun passed its configured negative/authentication matrix; no model call
  was admitted because the sandbox remains Marketplace-blocked. This is not positive inference proof.

## 2026-10-22 — Admin 3.2.0 bug bash (live in Contoso)

- Sync: memberships of retired projects no longer count in the removal-fraction base, which had made the
  limit easier to pass for other projects' removals (`src/sync/plan.ts`, regression test in `tests/sync-plan.test.ts`).
- Change record: a write that raised an error is recorded as `unconfirmed` (it may have been applied),
  not `failed`.
- Removal limits: an expired override can be switched off; the console no longer offers to keep an
  expired expiry.
- Stage 4 preauthorizes `admin.extraAllowedClientIds` (for example Azure CLI) on the admin app and reads it
  back; before, those clients hit AADSTS65001 although `ADMIN_ALLOWED_CLIENT_IDS` accepted them.
- Live (Contoso, Stages 3/4/5/7 reapplied): 26 API and security checks pass (401 for missing, forged,
  tampered and ARM tokens; no foreign CORS origin; 413/422/412/428 on bad limit writes; 400 on query
  injection attempts). The sync read the admin override (`removal_limits_from_admin`, 7 / 0.25). Retiring
  test project CONLAB3 removed its membership at the next run without reading its group. The change
  record lists each step. Independent security review: no findings.

## 2026-10-22 — Admin 3.2.0: project retirement, removal limits, change record

- **Retire project** (V3 project Settings, `POST /api/projects/{id}/retire`, If-Match and the project ID
  repeated in the body). Sets `status: "retired"` and `retiredAt`; edits then return 409
  `project_retired`. The sync removes all memberships of a retired project at its next run without
  reading its groups, outside the removal limits (`src/sync/plan.ts`, `src/sync/run.ts`). Other
  non-active statuses still freeze the project.
- **Removal limits** page and `GET/PUT /api/v3/sync/removal-limits`: an override of
  `SYNC_MAX_REMOVALS_PER_RUN` / `SYNC_MAX_REMOVAL_FRACTION` with reason and expiry (≤ 90 days), stored
  in `adminConfig`. The sync reads it when `SYNC_LIMITS_CONTAINER` is set; a missing, invalid, expired
  or unreadable override falls back to the app settings (`src/sync/removal-limits.ts`).
- **Change record**: every admin change (projects, catalog, removal limits) is written to `adminConfig`
  before it is applied and completed with its result; if it cannot be written, the change is refused
  with 503 `change_log_unavailable` (`admin/src/change-log.ts`). Audit has a Change record / Telemetry
  source switch; project Activity reads the change record. `GET /api/v3/audit/changes`.
- Staged deployment: Stage 3 assignment `sync-limits-reader` (Cosmos Built-in Data Reader on
  `adminConfig`, only with the admin app); Stage 5 sets `SYNC_LIMITS_CONTAINER=adminConfig` with the
  admin app. `tests/Test-StagedStages.ps1` checks both.
- [VDI upgrade](ADMIN-V3-VDI-UPGRADE.md) section 9: admin and sync packages, the sync grant and setting.
- Tests: admin 114, sync 237 (1 skipped), staged 355 checks; 11/11 mutants caught (control load
  failure reported separately); Edge check of retire, removal limits, audit in both themes and as reader.

## 2026-10-22 — Admin 3.1.0: Entra names and admin-only VDI upgrade

- V3 displays current Entra display names/UPNs beside full object IDs in Overview, Chargeback
  Developers, Budgets/Reconciler and Audit/Project Activity. Accounting, CSVs and filters keep IDs.
- Authenticated, bounded Graph lookup using the admin managed identity, enabled with
  `ADMIN_USER_NAMES_ENABLED=true` and Graph application `User.Read.All` with tenant admin consent.
  Missing users, denied permissions and provider failures keep IDs and other data available.
- Names are memory-only. Browser cache uses remaining server freshness, translated for clock
  skew, instead of restarting a five-minute TTL. Server lookup (including token acquisition) and
  browser queue have deadlines; failing batches cancel sibling requests.
- Added [manual VDI upgrade](ADMIN-V3-VDI-UPGRADE.md): existing managed identity consent, SPA
  redirect, private publishing, settings, verification and rollback. No changes to the gateway,
  sync, reconciler, APIM policies or deployed permissions.
- 108 admin tests, build/package, Edge UI/failure checks and the repository packet gate pass.

## 2026-10-21 — Network is the last setup stage

- New stage order: 0 checks, 1 resources, 2 schema, 3 grants, 4 Entra, 5 configuration,
  **6 network**, 7 code and data, 8 acceptance. As in the manual deployment, the customer usually
  builds the network; stages 2-5 do not need it, and Stage 7 requires it.
- `network.mode: verify` is the default: Stage 6 changes nothing and runs
  `scripts/manual/Test-NetworkConfiguration.ps1` (read-only) against the Stage 1 resources; a FAIL
  row stops it. `existing` and `create` (lab) remain opt-in.
- Templates and ARM deployment names follow the numbers: `stage2-schema`, `stage3-grants`,
  `stage5-config` (+ `stage5-api-telemetry`), `stage6-network`. An existing `state.json` moves to
  the new keys on first read (backup `state.layout1.json`).
- Fixes found on the way: the network check never reached Azure (`& az` recursed into its own
  `Az` function), failed on unrelated same-named DNS zones, and changed the CLI default
  subscription (`az account set`); the schema stage could not be rerun after grants; Stage 7 could
  not be rerun after a successful snapshot ([B-16 to B-20](../BUGS-FOUND.md)).
- Portal walkthrough steps and screenshots renumbered to match.

## 2026-10-21 — Portal walkthrough on both Standard v2 deployments

- Playwright walked the guide's 20 Portal steps on the signed-in Fabrikam lab and Contoso Portals:
  20/20 and 19/20 pass; the remaining Contoso step is the APIs blade staying on "Service is getting
  ready..." while ARM lists the API ([report](STAGED-STDV2-RUNS-2026-10-20.md#portal-walkthrough-with-playwright)).
- Walker fixes in `tests/playwright`: blade-menu navigation for sub-blades without a stable deep
  link, IAM **Role assignments** tab and list filters, reuse of the signed-in tab and its Portal
  host, one re-read for slow blades, literal-string masking. Two weak expectations were tightened;
  a negative control shows the resolver Authentication check fails on the wrong blade.
- The staged guide embeds 13 masked Contoso captures (`docs/runbooks/images/staged-portal`).
  Pages that list people are not published.

## 2026-10-20 — Staged deployment bug bash and live recheck

- Stage 1 shared-RG ownership now uses exact prior deployment resource IDs; the inventory verifier
  ignores unrelated and later-stage resources.
- Stage 2 create-mode retries skip the authoritative network deployment when a VNet already exists
  with saved state, and refuse to rewrite an existing VNet when that state is missing. DNS-link
  checks support earlier deployment outputs.
- Stage 8 acceptance uses the configured project header. Dependency hashes now migrate only when
  saved outputs match exactly or the relevant ARM outputs confirm the stable projection.
- Logged findings B-10 through B-15 in [`BUGS-FOUND.md`](../BUGS-FOUND.md). Offline staged,
  customer-deployment, quickstart and public-manual checks pass. Stage 1, Stage 2 and Stage 8
  acceptance rechecks and the Stage 4 grant recheck pass in both Fabrikam lab and Contoso
  ([report](STAGED-STDV2-RUNS-2026-10-20.md)).

## 2026-10-20 — Standard v2 and private Foundry, Fabrikam lab and Contoso

- Stage 1 can create a keyless private Foundry account with Claude deployments
  (`foundry-account.bicep`; `modelProviderData` required, API `2025-10-01-preview`).
- Stage 2 integrates a Standard v2 APIM with the VNet (outbound) and creates the Foundry private
  endpoint with its three DNS zones.
- `sharedResourceGroup` and the guarded Stage 1 rerun: what-if must not change resources outside
  the deployment's prefix. State is bound to tenant/subscription/RG. Stage 8 correlates telemetry by
  this run's request IDs.
- Live: Fabrikam lab (shared RG) stages 0-8 with 200 responses; Contoso stages 0-8 with new
  Entra objects, Claude blocked by the sandbox subscription, Graph consent refused without an active
  admin role ([report](STAGED-STDV2-RUNS-2026-10-20.md)).

## 2026-10-20 — Manual Portal walkthrough and verification gaps

- Added click paths for the staged guide, Foundry setup prerequisites, Standard v2 outbound
  networking, IAM and Entra checks, and the operations that still need Bicep or CLI.
- Embedded five existing masked Portal screenshots beside the relevant steps. They are
  labelled historical navigation references, not new Fabrikam/Contoso deployment evidence.
- Real Playwright Portal probes for Fabrikam and Contoso reached the Microsoft sign-in page.
  Fresh blade captures and the requested Standard v2 runs remain blocked on sign-in and
  confirmation of the separate Fabrikam lab/personal subscription targets.
- Documented unresolved APIM integration, Foundry provisioning, cross-target state reuse
  (reproduced offline) and uncorrelated telemetry acceptance. Bicep compilation and existing
  stage tests pass but do not prove those missing behaviours.
- Playwright verified the rendered guide's five images and internal anchor. A broken-image
  negative control failed as intended, and restoring the image passed.

## 2026-10-20 — Stages 2-8 implemented and run live

- New entry points in `infra/staged`: `stage2-network.bicep`, `stage3-schema.bicep`,
  `stage4-grants.bicep`, `stage6-config.bicep` (+ `stage6-api-telemetry.bicep`), and the driver
  `Invoke-StagedDeployment.ps1` (stages 0-8: preview by default, apply, read-back, state).
  Configuration: `staged.config.example.json`.
- Stage 1: optional APIM moved into `apim-service.bicep` (what-if failed on the conditional scope);
  `BasicV2` allowed; outputs `names` and `apimName` for later stages.
- Live run in a new lab RG after deleting the Stage 1 RG: all nine stages verified, gateway
  401/200/403 matrix, Admin V3 with live chargeback data
  ([report](STAGED-LIVE-RUN-2026-10-20.md), 20 screenshots in `docs/images/staged`).
- Tests: `tests/Test-StagedStages.ps1` (stage boundaries with a negative control, Cosmos
  contract against the quickstart, driver and configuration checks).
- Runbook rewritten: [configurable staged deployment](runbooks/STAGED-DEPLOYMENT-V2.md).

## 2026-10-20 — Stage 1 resources-only proof

- Completed live provider verification of the existing staged templates in an
  isolated new lab RG: 20 template resources at read-back (Application Insights
  later auto-added four Failure Anomalies alert rules, recorded in the report);
  all four private/keyless service checks pass, and no schema, application settings or runtime grants were created.
  Existing inference/admin deployments were not write targets. APIM is deferred.
- Added a scoped work ledger and local Ironclad charter/gate without installing
  hooks or changing CI. The stage contract remains the existing resources-only
  template and recursive offline test.
- Added the Stage 1 [live report](STAGE1-LIVE-VERIFICATION.md) and
  [permission/configuration/runbook](runbooks/STAGED-DEPLOYMENT-V2.md).
- Full packet gate, root regression/type-check/build and 95 admin tests pass.
  Later-stage entry points, Admin V3 Azure acceptance and scale/accessibility
  verification remain pending.
