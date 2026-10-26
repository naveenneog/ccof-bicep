# ADR 0038: Budget ledger after a mid-month workspace switchover

Status: proposed, 2026-10-26. Needs an owner decision before implementation.
Related: [ADR 0036](0036-continuity-coverage-baseline.md), UNKNOWNS DR-17,
[drill record](../runbooks/DR-STANDBY-CLOUD-SHELL.md#11-live-drill-record-2026-10-2526).

## Context

The reconciler computes each person's and group's spend for the month from the gateway logs in
Log Analytics. Workspace replication copies only data ingested after replication is enabled
([workspace replication](https://learn.microsoft.com/azure/azure-monitor/logs/workspace-replication)).

In the 2026-10-26 lab drill, replication had been enabled on 2026-10-25T07:09Z. After the switchover
to Central US (08:07Z) the earliest ledger row was 2026-10-25T07:23Z instead of 2026-10-20. Region B's
reconciler computed a lower October spend than the stored states and refused every run with
`spend_would_decrease` until the workspace failback (08:16Z). The gate worked as designed: it did not
lower recorded spend. The effect is that budget state stops refreshing while switched over:

- with `resolver.budgetEnforcement: budget-state`, requests are refused once state passes its hard
  limit (`budgetState.hardLimitSeconds`, 3600 in the example configuration);
- with `token-limits-only`, requests continue and budget reports stop updating.

## Options

1. **Accept and plan around it.** Enable workspace replication when region A is deployed, so only
   the first month is exposed; document that a switchover in a month where replication started late
   stops budget refresh until failback or the month end.
2. **Read both workspaces.** Query the primary and the replica together. Rejected for the outage case:
   the primary workspace is the component assumed unavailable.
3. **Persist a spend checkpoint outside Log Analytics.** Store per-scope spend with a ledger
   watermark in Cosmos DB (replicated with the account). After a switchover, spend is the checkpoint
   plus replica rows after the watermark, provided the replica covers the watermark. The continuity
   gate checks that coverage. Durable, but a change to the reconciler's model and to ADR 0036's gate.

## Proposed decision

Option 1 now: replication is enabled during the initial region A deployment and the runbooks state
the limit. Option 3 as the durable change, designed in its own packet with tests for watermark
gaps, duplicate rows across gateways (DR-11) and monotonic spend.

## Consequences

- No code change under option 1; runbooks and the DR readiness checklist gain the replication-start
  rule.
- Option 3 adds a Cosmos write per reconcile run per scope and a new failure mode (watermark ahead of
  replica coverage), which the gate refuses.
