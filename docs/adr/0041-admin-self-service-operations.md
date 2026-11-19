# ADR 0041: independently gated admin self-service operations

Status: proposed; implementation and private-lab acceptance pending.

## Context

Existing console edits are validated and audited, but routing publication, immediate sync and
configuration recovery require an operator. The customer uses application-permission Graph sync
and private endpoints. An upgrade must not enable standby writers, expose a public deployment
endpoint, require Graph writes, or break existing projects when optional permissions are missing.

## Decision

Keep the existing project store, registry, validation, write-ahead change log and runtime safety
guards. Add three default-off settings: `ADMIN_ROUTING_PUBLISH_ENABLED`, `ADMIN_APPLY_ENABLED`,
and `ADMIN_HISTORY_ENABLED`. Configure only approved resource IDs on the server. Never accept
an arbitrary URL, resource ID, function name, script or command from a browser.

Routing and Apply now are durable asynchronous jobs in the existing `adminConfig` container,
with create-only idempotency, ETag leases, bounded retries, expiry and a queryable result.
Admin instances in either region may process a leased job. This does not make either instance
a sync/reconciler writer. Only the currently enabled worker pair may execute Apply now.

Each feature exposes its own capability and exact missing action/data action and scope.
Failures are isolated: one denied APIM action cannot disable history, project viewing or editing.
Foundational authentication, project-data and mandatory audit permissions remain prerequisites;
optional-feature handling never bypasses an existing mandatory audit refusal.

Publication uses the existing project/revision-specific pool and compatibility contract. Read
back every member and pool in every configured gateway before activating with the project's
original ETag. Preserve the last verified route on partial failure or concurrent edits.
Project documents and registry records occupy different logical partitions: their reads and
the project CAS are not a cross-partition transaction. A published revision represents its
immutable, verified registry-input snapshot. Re-read registry ETags immediately before the CAS
and refuse observed drift; do not describe that check as an atomic registry fence.
All updated registry writers also take the same short-lived Cosmos registry leases as
publication. This excludes cooperating application writes while a publication step runs;
it does not turn independent partitions into a transaction or cover privileged direct edits.
Upgrade both admin instances before enabling publication. Direct registry maintenance must
first disable publication and drain its jobs; older writers cannot honor the new protocol.

Apply now invokes only the existing sync/reconciler logic and retains removal limits, locks,
continuity and budget guards. It must distinguish accepted execution from completed work, show
freshness, reject split-brain/standby execution, and never flip timer settings. The narrow
transport uses immutable requests and sanitized receipts in the existing `adminConfig`
container. Optional ten-second worker-control timers publish enabled/standby heartbeats and
consume only requests addressed to their configured resource ID. Require fresh evidence of
exactly one enabled sync/reconciler pair and disabled standby pairs before enqueueing work.
`CCOF_APPLY_WORKER_ENABLED` defaults off; `CCOF_APPLY_WORKER_RESOURCE_ID` binds worker identity.
Existing timer-disable settings remain authoritative. Workers recheck project ETag/status
and preserve the existing business entrypoints and their locks. A failed sync cannot trigger
reconciliation; accepted requests and missing/expired receipts are never reported as success.
Workers need narrowly scoped Cosmos read/create/replace/query permissions on `adminConfig`;
there is no ARM function invocation, function-key lookup, Graph write, new queue, or public
endpoint. Missing existing Graph application permissions must block real sync honestly.

History stores immutable project-configuration versions. Restores preview differences, require
a current ETag and reason, validate through existing contracts and produce a new audit record.
Never restore project identity, access-group identities, retired status, provider publication
verification, usage, spend, counters or audit history. Restored routing needs fresh publication.
Capturing optional history must not make unrelated existing writes depend on that feature.

Upgrade through the existing private updater, using an immutable approved commit/package,
backup, hash/read-back evidence and a retained previous artifact. Preserve authentication,
all existing app settings, private networking and the standby writer fence.

## Interfaces

- Authenticated capability and job-status reads; `CCOF.Projects.Write` for every mutation.
- `POST /api/v3/projects/{id}/operations`: fixed `publish-routing` or `apply` kind, reason,
  `If-Match`, and `Idempotency-Key`; returns 202 and a durable job ID.
- Project history list, version preview and ETag-guarded restore routes under
  `/api/v3/projects/{id}/history`.
- Feature modules remain framework-free and injectable; API/worker wiring is separate.

## Alternatives and consequences

A generic runner, function keys in the console, settings changes to wake a timer, or synchronous
browser-held deployment requests were rejected. Durable jobs add a small amount of Cosmos
metadata, but survive disconnected browsers and avoid claiming that HTTP acceptance is success.
No new Entra write permission or new hosting service is part of this decision.
