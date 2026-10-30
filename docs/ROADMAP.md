# Deployment packets

| Packet | Status | Observable acceptance |
| --- | --- | --- |
| S5-NULL | Implemented; PR CI pending | Missing/null/blank optional admin gateway IDs never become `[null]`; valid IDs retain order; malformed retained IDs and required admin identity fail before settings writes |

| Packet | Status | Observable acceptance |
| --- | --- | --- |
| S5-ARM | Implemented; full gate/PR CI pending | Stage 5 sends workbook JSON as a string across the nested ARM boundary; dropdown/bracket literals and content digests remain unchanged; legacy object callers still serialize normally |

## Disaster recovery feature branch

Implementation branch: `feat/dr-standby` (not merged). Each packet has a separate RED/GREEN cycle,
review, gate and commit. No packet implicitly authorizes a later Azure deployment.

| Packet | Status | Observable acceptance |
| --- | --- | --- |
| DR-01: contract and prerequisites | Complete; third-environment access blocked for DR-06 | Identity/network handoffs, resource ownership and project-specific optional fallback are specified; reachable environments inventoried without writes; HTTP 403 recorded for the supplied third subscription |
| DR-02: backend administration | Complete 2026-10-23 (admin 3.3.0, Fabrikam lab live) | Editor registers an existing Foundry endpoint; reader cannot write; invalid/unapproved targets are refused; ETag and write-ahead audit apply |
| DR-03: project routing | Complete 2026-10-23 (sync/resolver/gateway, Fabrikam lab live) | Existing projects keep direct routing; editor can choose only compatible fallback members; disabled failover produces no pool or breaker; changed routing shows pending/applied/failed |
| DR-04: pool publication and gateway | Complete 2026-10-23 for one gateway (Fabrikam lab); publisher read-back hardening committed as `a7d1672` on `feat/dr-standby`; second-region gateway pending DR-07 | Approved routing is published to both gateways, verified and activated by revision; breaker scope is isolated per project; partial streams are not replayed |
| DR-05: accounting and continuity | Code complete on `feat/dr-standby`; live gate refused before writes on 2026-10-25 because October history starts after month start | Both APIM IDs and actual serving backends are counted once; incomplete month history cannot lower previously recorded spend; UI/export/usage remain consistent |
| DR-05R: coverage-aware continuity gate | Complete on `feat/dr-standby`, commit `25b77e7`; not merged | Late first traffic and idle periods do not fail solely for lacking a month-start event; backend calls without LLM usage, LLM usage without a gateway request, invalid coverage starts, unmarked legacy spend, and spend decreases refuse before writes |
| DR-06: prerequisite deployment | P0-P2 complete 2026-10-23 (Contoso, Fabrikam lab); third subscription blocked (HTTP 403) | Explicit create/reuse identity and network inventory; public ingress not weakened; read-back records permissions and DNS/connectivity evidence |
| DR-07: regional/data/edge deployment | Deployed and drilled in the Fabrikam lab on `feat/dr-standby` (2026-10-26): standby shells, single-write Cosmos replication, workspace replication with a switchover and failback, and private Front Door origins, with standby writers fenced | Standby shells, single-write Cosmos replication, workspace replication and private Front Door origins are verified with standby writers fenced |
| DR-08: promotion and failback | Full cycle drilled 2026-10-26 (failover, Region B promotion, workspace switchover, failback to A) by hand; scripted, guarded promotion and failback added 2026-10-26 (`infra/dr/Invoke-DrFailover.ps1`, offline tests only, not yet run live); not qualified for production: DR-15 (Region B to East US 2 Foundry resets), DR-16 (fallback capacity) and DR-17 (mid-month switchover leaves the ledger incomplete) are open | Losing primary compute, backend, Cosmos and logging are tested separately; no split-brain writer; failback does not reset spend or silently double quotas |

Details and stage owners: [DR implementation](design/DR-IMPLEMENTATION.md).

## Historical deployment packets

| Packet | Status | Acceptance |
| --- | --- | --- |
| V3-names | Complete | Names plus full IDs across V3; authenticated Graph lookup with explicit failures; admin-only VDI upgrade guide |
| Stage 1 resources-only proof | Complete | Compile and inspect templates, deploy new lab services, verify live properties, document permissions and evidence |
| Later-stage separation | Complete | Stages 0-8 exercised in the existing Fabrikam lab/Contoso labs; prerequisite-first DR workflow remains separate |
| Admin V3 Azure acceptance | Pending | Verify deployed root redirect, Entra sign-in, real telemetry and onboarding settings |
| Health and outage e-mail alerts (HA-1) | Complete | Add-on over Steps 0-8: action group, availability tests, metric and log alerts for the admin Health page's signals; what-if refuses changes to resources it does not own; offline tests; lab apply verified |
| Admin V3 scale/accessibility | Pending | Measure 10,000-project behavior and perform assistive-technology checks |

Later stages are not implicitly executed by the Stage 1 proof.

- [x] S1 — Verify and document the resource-only Stage 1 in Azure.
- [x] S2 — Implement later-stage entry points with their permission boundaries.
- [x] HA-1 — Health and outage e-mail alerts as an add-on (docs/runbooks/HEALTH-ALERTS.md).
- [ ] V3-live — Complete Admin V3 Azure acceptance.
- [ ] V3-scale — Measure scale and accessibility.
