# ADR 0034: Prerequisite-first DR and project-authorized backend failover

Status: accepted for the implementation contract, 2026-10-23.
Branch: `main` (merged 2026-10-25).
Supersedes the unconditional backend-pool part of [ADR 0033](0033-dr-active-passive.md).
At acceptance, deployment remained unimplemented. Current implementation and lab status are tracked
in [STATUS](../STATUS.md), [ROADMAP](../ROADMAP.md), and the [drill record](../runbooks/DR-STANDBY-CLOUD-SHELL.md#11-live-drill-record-2026-10-2526).

## Context

The DR proposal used compatible local/remote pools for every project. The implementation request
requires an admin to keep routing specific projects to specific backends and opt individual
projects into failover. Identity and network prerequisites must be prepared before runtime
deployment. Existing partner/lab resources are not automatically deployment-owned.

## Decision

- `backendId` remains the primary target. An absent or disabled project routing override preserves
  today's direct backend behaviour. New projects default to failover off.
- Physical backend registration and project fallback authorization are separate. Registering an
  endpoint does not authorize any project to use it. The admin selects ordered fallback members
  for each project; an empty, duplicate, incompatible, disabled or unapproved list cannot activate.
- The circuit breaker is an optional failure-detection mechanism, not a Foundry account. The UI
  presents "Enable backend failover", "Primary backend" and "Allowed fallback backends".
  It does not automatically add every endpoint from the other region.
- Selected members must match the requested model/deployment, hosting version, API, geography,
  authentication and approved billing attribution. First implementation is same-tenant only;
  budgets/quota approval remain scoped per subscription/account.
- Each enabled project routing revision uses isolated APIM pool/member entities. A breaker on a
  shared physical-backend entity must not change another project's direct routing.
- Desired configuration is audited before modification. A routing publisher with narrowly scoped
  APIM backend permissions applies and reads back both regional configurations. Only a verified
  revision can become active. Pending/failed publication retains the last verified route; initial
  failure retains direct routing. Concurrent edits require ETags.
- Disablement stops new fallback selection after the bounded configured cache window. In-flight
  requests drain; partial streams and ambiguous model executions are not automatically replayed.
- Identity and network bootstrap have explicit create/reuse inputs, immutable resource IDs and
  separate owners. Existing APIM/Foundry accounts start as discovery-only external references.
- Prerequisite-first DR is an additional workflow, not a renumbering of existing stages 0-8.
  DR stages do not call the legacy all-app seed/publish path against an adopted environment.
- Read traffic can run in both prepared regions, but Cosmos stays single-writer. Sync, reconciler
  and admin writes require fenced promotion. Front Door origin failover does not promote writers.
- Accounting must include both APIM resource IDs, the actual serving backend and full monthly
  ledger history. Incomplete history must not produce a lower persisted spend.

## Amendment: existing standby network

An explicitly selected existing-network mode uses the supplied VNet resource ID independently of
the workload resource group. Bootstrap deploys only the named standby managed identities and reads
the VNet, subnets, DNS links and peerings; it does not deploy those network resources. The network
team owns any missing network prerequisites. Creating standby private endpoints and DNS zone
groups, and attaching standby services to subnets, is a separate, explicitly approved action.
An existing VNet is not considered approval for these changes. Private Function App publishing
requires a verified private path and does not turn on public access. Existing create-network
configurations retain create semantics but now require explicit Network and public Shells approval.
The current standby Shells template creates APIM
with public network access enabled; either network mode requires explicit approval for that
bootstrap. This approval does not authorize public access for the Function Apps.
When create-mode Bootstrap finds that its target VNet already exists, it refuses unless an operator
explicitly approves updating that authoritative subnet list. This safety stop also applies to legacy
configuration files without `networkMode`; create mode for a new VNet is unchanged.
Shells must also stop if its existing APIM has public access disabled or its access state cannot be
read: the creation template would otherwise reopen it. The initial creation remains public only
with explicit approval. The standby-only release does **not** implement the separately reviewed
Front Door driver changes: all Front Door operations remain STOP. Full deployment and approval
must eventually require recorded standby phase completion, independent ownership review of exact
connection IDs and explicit operator confirmation of manual Entra and end-to-end checks. Primary
recovery must not require a healthy B or re-enable B. Saved identity and approval records are not a
substitute for reviewing the live target and confirming end-to-end readiness.

## Rejected alternatives

| Alternative | Reason |
| --- | --- |
| Automatically use all regional backends | Violates project authorization, residency and billing boundaries |
| Put a breaker on each shared registered backend | A project opting in would change behaviour for projects that opted out |
| Let the SPA call ARM directly | Exposes infrastructure permissions at the browser boundary and bypasses server-side publication/audit |
| Give the admin app general Contributor on both subscriptions | Wider than backend publication requires; identity/network provisioning stays with operators |
| Treat a recent log timestamp as proof of ledger continuity | Missing month history can silently reset budget consumption |
| Enable both writer sets and rely only on replicated lease documents | Asynchronous regional replication is not a split-brain fencing mechanism |

## Consequences

New admin routes, backend validation, project routing metadata, publication status, gateway
descriptors, deployment inputs and tests are required. Existing schema readers and seed comparisons
must preserve the new optional fields without forcing existing projects into pools.
The exact API/storage schema is written and tested in DR-02/DR-03 before implementation.

Implementation notes (2026-10-23): the breaker stays optional per registered backend, but switching
a project's failover on requires an enabled breaker on its primary, because an APIM pool moves
traffic only away from a member whose breaker can open. Only managed-identity backends route to a
pool (pool members carry no credential). Schema: `src/contracts/project-routing.ts`; results:
[DR implementation](../design/DR-IMPLEMENTATION.md#implemented-and-proven-2026-10-23).

Sources: existing routing in `src/resolver/backend.ts` and
`infra/gateway/policy/claude-messages.template.xml`; admin writes in `admin/src/api.ts` and
`admin/src/change-log.ts`; [APIM backend pools and circuit breakers](https://learn.microsoft.com/azure/api-management/backends);
[Cosmos consistency](https://learn.microsoft.com/azure/cosmos-db/consistency-levels);
[workspace replication](https://learn.microsoft.com/azure/azure-monitor/logs/workspace-replication).
