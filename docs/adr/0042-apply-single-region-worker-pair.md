# ADR 0042: Apply now on a single-region deployment

Status: accepted (2026-11-20).

## Context

ADR 0041 requires exactly one enabled sync/reconciler pair, with any standby pairs disabled,
before Apply enqueues work. Stage validation (`infra/staged/Staged.Common.ps1`) accepts one or two
`admin.workerResourceIds` pairs. The runtime did not: the worker heartbeat
(`src/operations/apply-worker.ts`), the active-pair proof (`activeHeartbeatPair` in
`src/operations/apply-contracts.ts`) and the admin capability
(`admin/src/self-service-apply-cosmos.ts`) each refused fewer than two pairs. No test or document
gave a reason for that. A single-region deployment with `applyNow:true` was accepted by Stage 5,
but at runtime its workers wrote no heartbeat, and the admin reported `worker_targets_invalid`
for good. The Contoso lab (one region, DR identity shells only) hit this during the positive
Apply acceptance test (SS-03).

## Decision

Accept one or more approved pairs at runtime, to match stage validation. The safety rule from
ADR 0041 does not change: every configured pair needs fresh heartbeats, both fences in each pair
must match, exactly one pair may be enabled, that pair's sync must be in `apply` write mode, and
every other pair (none, in a single-region deployment) must be fenced off. A single pair whose
business timers are disabled is still unavailable (`worker_fence_unverified`).

## Consequences

- Single-region deployments can use Apply now without a standby region.
- When DR adds region B, list both pairs in `admin.workerResourceIds` and redeploy Stage 5 in
  both regions. The configuration fingerprint changes, so workers that still hold the old
  one-pair list stop matching and Apply stays unavailable until both regions run the new settings.
- Test: `tests/apply-worker.test.ts` ("a single-region deployment with one approved pair...").
