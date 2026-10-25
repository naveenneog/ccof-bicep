# Current work

## Documentation for new readers

Done 2026-10-24 and merged to `main`: README entry points, glossary, budgets page, historical
banners, link test, pseudonymous screenshots and the
[step-by-step deployment guide](runbooks/DEPLOY-STEP-BY-STEP.md) (see [CHANGELOG](CHANGELOG.md)).
Not done: the 85 older middle-masked Portal images under `runbooks/images/portal/` and splitting the
two long workbooks.

## Budget soft limit and spend pacing

**Packet:** BSL-1, merged to `main` on 2026-10-25.
Decision: [ADR 0035](adr/0035-budget-soft-limit-and-spend-pacing.md). Unknowns: BSL-01 to BSL-04.

Acceptance:
- Given pacing settings 80/W, when spend is below 80%, the ceiling is remaining / W minutes at the
  worst-case rate; from 80% on it is remaining / 2W, at least 1 while budget remains.
- Given either setting alone, the reconciler refuses to run and names the missing one; given neither,
  documents are as before.
- The gateway applies the resolver's ceiling as `ccof-limit-person-budget-pace` on its own key.
- `/usage` warns past the soft limit; the admin Reconciler/Budgets views show `warning`.

Proof (offline): root suite (one golden workbook digest updated for the KQL change), admin 121,
client 56, `tests/Test-StagedStages.ps1` 356 checks, quickstart 88 and steps 30, Bicep build;
13 mutants caught with an unchanged test count.
Live (lab, 2026-10-24): warning, pace and block observed; $25 budget ended at 108.1%, $35 at 106.0%
(ADR 0035 "Live test"). The ceiling is rounded down to a power of two after run 1. Run 3 ($15 load on
$37.11, $52.11 budget): warning at 81.9%, 205 pace 429s, block 5 s after exhaustion, final 100.3% ($0.18 over).
Open: BSL-05 (overshoot of about one burst of parallel streams). The per-request reservation was rejected in code review, and a per-person concurrency cap was measured not to hold streams (BSL-06); the remaining options need a product decision (UNKNOWNS BSL-05).

## Disaster recovery implementation

**Active packet:** DR-07 - standby regional shells and data. DR-02 to DR-04 and DR-06 (P0-P2)
are implemented and proven live, and merged to `main` on 2026-10-25; results in
[DR implementation](design/DR-IMPLEMENTATION.md#implemented-and-proven-2026-10-23).

- Admin 3.3.0: backend registry with optional circuit breaker, per-project failover, routing
  publication. Gateway forwards a verified project pool; sync/resolver carry `routeBackendId`.
- Fabrikam lab: Stages 5 and 7 deployed; SASLAB1 failover proven (primary broken, fallback served,
  restore, switch off). Contoso: P0-P2 in Central US verified. Third subscription: HTTP 403.
- Fabrikam full-DR lab (2026-10-26 03:22 IST): Front Door routed traffic to B; Cosmos wrote in Central
  US; the continuity gate refused B reconciliation before writes (`early_history_missing`). Both
  `syncEntitlement` and `reconcileBudgets` timers are disabled in A and B; B's gate remains `on`.
  The primary-origin drill fault is still active. No writer promotion, workspace switchover or
  failback occurred. B had 16 APIM request-forwarder timeouts, 15 fallback HTTP 200s, and one primary
  backend HTTP 200 in the same 30-minute window; the timeout root cause is unknown. The lab is
  not qualified; see the [partial drill record](runbooks/DR-STANDBY-CLOUD-SHELL.md#11-live-drill-record-2026-10-2526-partial-and-unqualified).
- Standard v2 refused API policies over 16 KiB from 2026-10-23; the gateway policy now deploys as
  per-section policy fragments.

DR-01 completed scope:
- Contract: [DR implementation](design/DR-IMPLEMENTATION.md), merged to `main`.
- Project-specific failover is optional, off by default, and uses explicitly approved compatible
  backends. A circuit breaker detects failure; it is not itself a fallback endpoint.
- Identity, network, ownership and permission handoffs precede runtime deployment. Existing
  resources are read-only inventory until a separately scoped deployment adopts them.
- The implementation roadmap separates backend administration, routing, accounting, replicated
  data, regional deployment and a failover drill.
- Environment identifiers and discovery evidence remain outside public git.

Contract: [DR implementation](design/DR-IMPLEMENTATION.md). Decision:
[ADR 0034](adr/0034-dr-project-routing-and-prerequisites.md).
DR-01 is design and read-only discovery, not a DR deployment or a completed failover test.

Discovery, 2026-10-23:
- Fabrikam lab and Contoso subscription/tenant and exact resource reads passed using isolated profiles.
  Both APIMs are Standard v2 in East US 2. Foundry deployment lists contain two and zero models,
  respectively; listing a deployment is not a successful inference test.
- Supplied third subscription: subscription metadata and exact APIM/Foundry/deployment reads
  returned HTTP 403. CLI-cache refresh was stopped when it did not finish; direct ARM queries
  used a tenant-pinned token. No access grant or resource mutation was attempted.
- Private evidence: session `files\dr-implementation\*-inventory.json`.
- Later DR packets and their unresolved prerequisites remain pending. The independent `CCOF`
  generalization checkout is untouched.
- Documentation review: Coder PASS (self-review); local links and whitespace checks passed;
  `.ironclad/gate.mjs --stage pre-commit` passed with the existing file-size warning.
  This doc-only packet did not run the feature packet/release gate or claim live DR acceptance.

DR-02 acceptance (not implemented yet):
- Editor can register approved existing backend metadata; a reader cannot modify it.
- Endpoint/deployment/authentication/geography and ownership are validated; arbitrary resource
  provisioning and raw secret input are excluded.
- Concurrent edits require ETags, and every modification uses the permanent change record.
- Registration does not activate project failover or modify APIM until an authorized publication.

## Admin V3 user names (historical completed packet)

**Completed packet:** V3-names - Admin 3.1.0 displays current Entra names beside full object
IDs. Only admin code/package changed; no gateway, sync or reconciler code, config or deployment.
Manual upgrade: [VDI procedure](ADMIN-V3-VDI-UPGRADE.md); new permission: admin managed identity
Graph application `User.Read.All`, consent, `ADMIN_USER_NAMES_ENABLED=true`.

Evidence:
- 108 admin tests and the admin build pass. Package inspected for admin entry points/UI/KQL.
- Edge demo: names/full IDs on Overview, Developers, Budgets, Reconciler, Audit and Project Activity;
  Light/Dark/mobile; denied/disabled/unavailable/missing users retain IDs and cost figures.
- Integrated server/browser cache tests cover original expiry, clock skew, cache bounds, stalled
  requests and queue recovery. Provider errors are sanitized, with no names/UPNs in logs.
- Five PowerShell guide blocks parse; local links resolve; no guide commands were executed.
- Council: ARCHITECT PASS, CODER PASS, QA PASS, SECURITY PASS (independent reviewers);
  UX PASS (browser checks). Review found layered TTL and stalled-request edge cases; regression
  tests reproduced them before the fixes.
- Repository packet gate passes; existing file-size warnings remain.

The local ZIP is `ccof-admin-v3.1.0.zip` in this session's files
(SHA-256 `f25438c857b7058ec9bdc8b55c48491dc9d33b2e7f27fa1e0ce472a90e857554`).
No live directory lookup, customer deployment or Graph permission change was performed.

## Standard v2 and Foundry, two tenants (S3, complete with open items)

Verified 2026-10-20 in Fabrikam lab and Contoso ([report](STAGED-STDV2-RUNS-2026-10-20.md)).
Open: Graph application consent needs PIM activation in Contoso; Claude in Contoso needs a
non-sandbox subscription. Portal screenshots were recaptured live from the Fabrikam lab on 2026-10-24.


## Staged deployment, stages 0-8

**Completed packet:** S2 — staged entry points for stages 2-8 and a live end-to-end run.

Status: verified, 2026-10-20, in the new lab RG `ccof-staged-20261020-rg`
([report](STAGED-LIVE-RUN-2026-10-20.md)). The Stage 1 RG below was deleted first.

Open items:

- Private-only variant (StandardV2 APIM with VNet integration, private Function endpoints,
  in-network build agent) not run.
- New Entra registrations/groups not exercised (operator directory quota); merge path verified.
- Least-privilege identity per stage, timers, load and 10,000-project scale not tested.
- Admin console shows sub-cent costs as $0.00.


## Stage 1 resources-only live proof

**Completed packet:** S1 — Stage 1 resources-only live proof.

Status: verified, 2026-10-20. No later-stage deployment is active.

Acceptance:

- `infra/staged/main.bicep` and both parameter examples compile.
- Recursive template checks reject network attachments, role assignments, schema,
  application settings and code deployment.
- A new, empty lab resource group receives only the approved resource inventory.
- Live read-back verifies private/keyless settings and identity outputs; an ARM
  success is not runtime acceptance.
- The runbook states operator permissions, inputs, outputs, recovery and deferred work.

Source baseline: `b116f63`. Scope is Stage 1 only. Existing lab/customer resources,
Entra, application packages and permission assignments are outside the write boundary.

See [unknowns](UNKNOWNS.md) and [roadmap](ROADMAP.md).

## Evidence

- Azure deployment `stage1-proof` in the new lab RG succeeded.
- Read-back passed for all four services, private/keyless controls and the
  absence of application settings, schema and grants.
- The existing Bicep templates needed no provider-driven changes.
- A valid forbidden-role fixture was rejected by the existing contract test.
- `node .ironclad/gate.mjs --stage packet --json`: exit 0; full root tests,
  type-check and build pass. The pre-existing file-size warning remains.
- Admin build and all 95 tests pass.
- New runbook's three PowerShell blocks parse and local documentation links resolve.

Detailed [live report](STAGE1-LIVE-VERIFICATION.md) and
[commands/permissions](runbooks/STAGED-DEPLOYMENT-V2.md).
This packet's commit is the Git change containing this status file.
