# ADR 0040: Onboard a Foundry backend from the admin console

Status: accepted, 2026-11-08.
Related: [ADR 0034](0034-backend-registry-and-per-project-failover.md), UNKNOWNS ONB-01 to ONB-05,
runbook `docs/runbooks/ADMIN-OPERATIONS.md` (Onboard a Foundry backend).

## Context

Adding a second Foundry account (same or another subscription in the tenant) today needs three
writes done by scripts or by hand:

1. An APIM backend entity in every regional APIM (`https://<account>.services.ai.azure.com/anthropic`).
2. A Cosmos `backends` descriptor (`{id, backendId, status, apiFormat, auth}`). Without it the
   resolver returns the verdict `legacy`, and the gateway policy
   (`claude-messages.template.xml`, `ccofBackendAllowed`) admits a legacy backend only if its ID was
   baked into `%%BACKEND_IDS%%` at render time. A new backend would be refused until the policy is
   re-rendered.
3. The ADR 0034 registry entry, used by the console for failover compatibility.

The platform team already creates the account, the model deployments, the private endpoint and the
APIM managed-identity role on the account. The admin should not run scripts or need Entra changes.

## Options

1. Keep scripts (Stage 2/3/5 reruns). Works, but needs a deployer with Contributor and a policy
   re-render for each backend.
2. Console writes the APIM backend, the descriptor and the registry entry, after a read-only
   preflight. Needs narrow Azure RBAC roles for the admin app identity.
3. Console also creates the account, private endpoint and role assignments. Needs Contributor and
   `roleAssignments/write`; rejected (privilege escalation path from the console).

## Decision

Option 2, off by default (`ADMIN_BACKEND_ONBOARDING=true` enables it).

- `POST /api/v3/backend-onboarding/preflight` is read-only. It checks: the ID is free in the
  registry, the descriptor store and every target APIM (or already holds the same URL); the account
  is inside `ADMIN_RESOURCE_IDS` or `ADMIN_DISCOVERY_SCOPES`; its endpoint is derived from
  `customSubDomainName`; every requested deployment exists; network (an Approved private endpoint
  passes; none with public access enabled is a warning; anything else fails); and every target
  APIM's managed identity holds Cognitive Services User or Foundry User at or above the account.
- `POST /api/v3/backend-onboarding` reruns the preflight and refuses on any failure. It then writes,
  in order, each APIM backend, the descriptor, the registry entry. Every step is idempotent, so a
  retry after a partial failure resumes. The response lists each step's outcome. One change-log
  entry and one audit line record the request.
- Target APIMs: `ADMIN_GATEWAY_RESOURCE_IDS` (both regions under DR), else
  `ADMIN_GATEWAY_RESOURCE_ID`.
- The backend ID is owned by the admin: `ccof-` stays reserved for generated pool IDs.
- Moving a project to the new backend uses the existing project edit; sync propagates it.
  Publishing failover pools from the console stays a separate packet.

## Consequences

- No Entra or Graph permission. Azure RBAC for the admin identity, granted once by the platform
  team: a custom role with `Microsoft.ApiManagement/service/read`,
  `Microsoft.ApiManagement/service/backends/read` and `/write` on each APIM; the admin Cosmos data
  role on the `backends` container (Stage 3, `admin.backendOnboarding`); Reader on the account or
  its resource group (already needed for inventory).
- Stage 5 writes backend entities incrementally, so console-added backends survive a rerun.
- The console cannot fix a missing private endpoint approval or role assignment; the preflight
  names the missing item and who fixes it.
- A disabled feature changes nothing: no route, no setting value, no grant.
