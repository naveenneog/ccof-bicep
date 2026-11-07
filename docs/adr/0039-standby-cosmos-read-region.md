# ADR 0039: Cosmos read region for the standby (region B) Function Apps

Status: proposed, 2026-11-07 (owner decision required; no code change in release/dr-infosys-resume).
Related: UNKNOWNS DR-BYO-24, [ADR 0038](0038-ledger-after-mid-month-switchover.md).

## Context

The lab resume run on 94aeafa showed that resolver B in Central US reads Cosmos from East US 2 while
region A is healthy. Read-only checks:

- No Cosmos client sets a read region. `src/resolver/registry-reads.ts` (`cosmosClientOptions`),
  `src/sync/azure.ts`, `src/reconciler/azure.ts` and `admin/src/cosmos-store.ts` pass only endpoint,
  credential, timeout and retry options. No setting such as `COSMOS_PREFERRED_REGIONS` exists;
  `src/resolver/config.ts` reads only `COSMOS_ENDPOINT`, `COSMOS_DATABASE` and the resolver timeout and
  retry settings.
- Lab resolver A and B app settings carry the same Cosmos settings and no region setting.
- `@azure/cosmos` 4.10.1 (`dist/commonjs/globalEndpointManager.js`, `resolveServiceEndpointInternal`)
  uses `connectionPolicy.preferredLocations` when set; otherwise it takes the first available
  entry of the account's `readableLocations`, which follows failover priority (East US 2 first).
  Endpoint discovery is on by default, so after a service-managed failover reads and writes follow
  the new region without configuration.

So an app setting alone cannot change behaviour; the client must read one.

## Options

1. **Accept for this release.** Region B is a warm standby; while A is healthy, B serves only
   Front Door probes and drill traffic. Cost: cross-region latency (tens of ms per registry read,
   mitigated by the resolver cache) and inter-region egress on B's reads. Availability is not
   reduced: if East US 2 becomes unavailable for reads the SDK marks it unavailable and moves on.
2. **Add an optional preferred-regions setting (recommended follow-up).** Scope:
   - `src/resolver/config.ts`: parse optional `COSMOS_PREFERRED_REGIONS` (comma-separated Azure
     region display names, validated non-empty entries); `registry-reads.ts` passes it as
     `connectionPolicy.preferredLocations`. Same small change in `src/sync/azure.ts`,
     `src/reconciler/azure.ts` and `admin/src/cosmos-store.ts` (writers are off in B, so the resolver
     matters most).
   - Unit tests for parsing and for the options passed to `CosmosClient`.
   - Deployment: staged Stage 5 sets `East US 2,Central US` for A; DR Config sets
     `Central US,East US 2` for B (one app-setting entry each, with a DR test).
   - Requires rebuilding and republishing the four Function Apps in both regions.
3. **Set it only in DR Config now.** Rejected: no code reads the setting, so it would be a no-op
   that looks like a fix.

## Decision

Option 1 for the customer resume release; option 2 is the proposed follow-up packet, pending the
owner's decision on whether B should read locally while A is healthy. No setting is added now.

## Consequences

- Region B behaviour is unchanged from the lab run that passed end to end.
- Latency/egress measurements of B's reads are not recorded; DR-BYO-24 stays OPEN until the owner
  decides and, if option 2 is chosen, the follow-up ships with tests and a lab check of the region
  in the Cosmos diagnostics.
