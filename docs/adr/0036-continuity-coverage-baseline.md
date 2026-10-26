# ADR 0036: Verify ledger coverage before continuity writes

Status: accepted, 2026-10-26.
Branch: `feat/dr-standby`.
Related: [ADR 0034](0034-dr-project-routing-and-prerequisites.md), [DR-05R](../ROADMAP.md).

## Context

The DR-05 gate currently refuses when the earliest LLM-log record is later than the month start plus
15 minutes, or when no LLM-log record is newer than that interval. Those checks confuse a quiet
period or a late first request with missing usage telemetry. They also do not prove that each
backend-forwarded model request has a corresponding usage row.

The Fabrikam lab has a different, real gap. The service-level diagnostic setting for
`GatewayLogs` and `GatewayLlmLogs` was written at **2026-10-20T15:41:34Z**. Neither table has rows
from October 1 through October 19, but non-zero October spend is already persisted. The available
logs cannot prove whether there was traffic before diagnostic coverage began.

A first-reconcile timestamp alone is not evidence that no earlier usage occurred. The current
October state must remain fenced unless its missing history is recovered or the billing period
changes.

## Options

1. **Keep the month-start and recency heuristics.** This remains fail-closed for the current lab but
   also blocks a quiet system or a new deployment whose first request arrives later in the month.
2. **Use the first reconciliation time as the history start.** This avoids the false refusal but can
   bless usage that occurred before the first reconcile and was not logged.
3. **Use an explicit diagnostic-coverage start, correlate gateway requests with LLM usage rows, and
   persist the coverage start in budget states (chosen).** Existing state without a matching marker
   stays refused; a fresh deployment can establish its baseline only after logging is configured
   and traffic is fenced until coverage is verified.

## Decision

- Add `RECONCILER_LEDGER_COVERAGE_START_AT`, a UTC timestamp for when both APIM gateway diagnostic
  categories were enabled and verified. It must be set before model traffic is allowed. With the
  continuity gate on, a missing or future timestamp is a settings error.
- For the active budget period, query `ApiManagementGatewayLogs` and `ApiManagementGatewayLlmLog`
  by APIM resource ID and correlation ID. A backend-forwarded `claude-messages` request without an
  LLM row, an LLM row without its gateway request, or a model request earlier than the configured
  coverage start refuses before any budget write.
- Remove the `no_recent_record` and `early_history_missing` timestamp heuristics. A quiet period is
  not by itself a telemetry gap.
- Store `ledgerCoverageStartAt` in the person and aggregate budget states written by a passing gated
  run. A later gated run requires the marker to match the configured coverage start. Existing
  current-period state without a marker is not silently adopted; it refuses until a verified
  baseline is established.
- Keep the `spend_would_decrease` refusal unchanged. The coverage check is additional protection,
  not a replacement for monotonic spend.

## Consequences

- A new deployment enables APIM gateway diagnostics before opening traffic, sets the coverage start,
  and runs the continuity gate before promotion. A late first request and a period with no requests
  do not fail solely because no event occurred in the first 15 minutes.
- The current October lab remains unqualified: its diagnostic coverage began after the month started
  and existing spend has no persisted coverage marker. This ADR does not backfill or attest to
  missing October usage.
- The gate may refuse temporarily when a gateway request and its LLM usage row arrive at different
  times. The next run can pass after both records are queryable; it must not write through a
  demonstrated mismatch.
- DR-08 still requires a separate live failover, writer promotion, workspace switchover and failback.

## Verification

Tests cover idle periods, a late first request after the configured coverage start, backend requests
without usage rows, usage rows without gateway requests, requests before coverage start, legacy
states without a marker, mismatched markers, failed telemetry reads and spend decreases.

## Amendment 2026-10-26: one-time baseline adoption

**Context.** The decision above gives an existing deployment no way to establish its first marker.
A reconciler that ran with the gate off writes current-period states without
`ledgerCoverageStartAt`. With the gate on, those states refuse
(`ledger_coverage_baseline_missing`) until the month ends. The resolver fails closed once budget
state passes its hard limit (ADR 0008), so a DR failover in such a month leaves the service
refusing every budget-enforced request. The 2026-10-26 lab drill showed this: 50 of 50 calls through
Front Door returned HTTP 503 `budget_state_stale`.

**Lab evidence that replaced the October assumption.** The Context section above assumed October
usage before 2026-10-20 might exist. Read-back on 2026-10-26 shows it cannot. Resource-group
activity log from 2026-10-01 (2,617 events): the Cosmos account was created 2026-10-20T15:40:51Z,
the APIM service was first written 15:41:16Z, the gateway diagnostic setting at 15:41:34.8Z, and the
`claude-messages` API, backends and policies were first written at 16:21Z. No model API existed on
the gateway before diagnostics began. The gate's correlation query for October, run live with both
APIM IDs, returned no `backend_call_without_llm`, `llm_without_gateway` or `request_before_coverage`
rows. APIM writes an LLM log row for a timed-out backend call (16 of 16 drill timeouts had one, with
0 tokens), so backend failures do not appear as gaps.

**Decision.** Add `RECONCILER_LEDGER_BASELINE_ADOPT`:

- Its value must equal `RECONCILER_LEDGER_COVERAGE_START_AT` exactly, and the gate must be `on`.
  Otherwise the run fails settings validation (`mismatch`, `gate_not_on`, `invalid`). Binding the
  value to the coverage start means changing the start later voids the attestation.
- With it, a current-period state with **no** marker is accepted and the run stamps the marker on
  every state it writes. A state with a **different** marker still refuses. The coverage-gap,
  attribution and `spend_would_decrease` checks run unchanged before any write.
- The run line records `continuityBaselineAdopted` (number of unmarked states accepted).
- The operator sets it once, with evidence that no model traffic preceded the coverage start
  (activity log for the APIM API and the Cosmos account), and removes it after one passing run.

**What it does not protect against.** Usage that occurred before the coverage start and was never
persisted is invisible to every check; the operator's evidence is the only control. Unlogged usage
that was persisted is caught by `spend_would_decrease`, because the recomputed spend is lower.

**Consequences.** Region A should run with the gate `on` permanently: the DR-05R checks no longer
refuse quiet periods, and a gate-off run writes unmarked states that block the next failover.

**Stored timestamp form.** App Service drops zero milliseconds from date-like app setting values: a
PUT of `2026-10-20T15:41:34.000Z` (through `az functionapp config appsettings set`, `az rest` and a
raw HTTP request) reads back as `2026-10-20T15:41:34Z` (lab, 2026-10-26). Before this amendment the
reconciler required exactly three fractional digits, so every deployment that set a coverage start
would have failed settings validation at run time. Both settings now accept a UTC `Z` instant with
or without fractional seconds, refuse offsets and impossible dates, and compare the normalized
millisecond form; markers are written in that form.
Tests: `tests/reconciler-settings.test.ts` (setting rules) and `tests/reconciler-continuity.test.ts`
(adoption, stamping, mismatch, gap and decrease refusals). Four mutants (adopt any marker, skip the
mismatch check, skip the gate check, force adoption on) each fail a named test with the test count
unchanged.

**Failed calls without attribution.** With adoption in place, the lab's first gated run refused with
`ledger_attribution_missing`. The October ledger had 36 unattributed rows: 20 on gateway A
(2026-10-24/25) and the 16 drill timeouts on gateway B. All 36 were failed requests with every
token count null and no `ccof.usage.v1` trace. The gateway emits the attribution trace only when a
response arrives, so a backend timeout or connection failure is never attributed. A real
primary-region outage produces exactly these rows, so the gate as written could never promote the
standby after the outage it exists for.

Decision: an unattributed row whose `requestFailed` is `true` and whose five token counts are all null
is counted as `unattributedFailedRequests` on the run line and does not refuse. Any other unattributed
row still refuses: a successful request, or a failed one with any token count. A ledger answer without
the `requestFailed` column (recorded before it existed) reads the value as unknown, so those rows still
refuse. Such a row has no figure to charge to anyone, and the gate-off reconciler has always skipped
it. Refusing it protected no budget figure and blocked promotion.

Residual risk: a call that timed out at the gateway but completed at the backend is billed by Azure
and not counted. That is true with the gate on or off; the gate cannot recover the count. Tests:
`tests/reconciler-continuity.test.ts` (exempt case; refusals for a successful call without tokens and
a failed call with a token count). Five mutants each fail a named test with the test count unchanged.
