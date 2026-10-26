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
