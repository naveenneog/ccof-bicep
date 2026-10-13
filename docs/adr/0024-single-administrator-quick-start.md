# ADR-0024: Single-administrator quick-start

- **Status:** Proposed
- **Date:** 2026-10-13
- **Deciders:** owner (request of 2026-10-13 11:27 IST), coordinator

## Context

ADR-0019 (Accepted) deploys the core in checkpointed stages (D0 to D3, then onboarding stages 1 to 5)
that different teams run, because a single installer does not work at the customer (owner,
2026-10-11). Some readers hold every Azure role themselves: a proof of concept, a demo, a single
team. For them the stages are many commands and checkpoint files for one person. The owner asked
(2026-10-13) for one Bicep file whose values all sit in one parameters file, for an existing API
Management instance and three existing Entra groups, with every configuration applied, and a
wrapper that can be rerun from the step that failed. A later instruction (2026-10-13) split the
work by Entra role: Entra objects are prerequisites, and the privileged Graph grant is
post-deployment.

## Decision

Add a separate path, `infra/quickstart/`, for one administrator. It does not replace the stages.

1. **Three phases, by role.**
   - *Prerequisites* (an Entra application or groups administrator, or a member user while the
     tenant settings allow it): the Gateway API, Developer Sign-in and Resolver API app
     registrations and the groups. Their ids go into `main.bicepparam`. The wrapper only reads them
     through Microsoft Graph and refuses with a named reason; it never creates or changes an Entra
     object.
   - *Deployment* (Azure roles only: Owner, or Contributor plus Role Based Access Control
     Administrator or User Access Administrator, on the resource group and on each backend Foundry
     account): `main.bicep` and `Deploy-Quickstart.ps1`. No Entra directory role is needed.
   - *Post-deployment* (Privileged Role Administrator through PIM, or Global Administrator):
     `Grant-SyncGraphPermissions.ps1` grants `GroupMember.Read.All`, `User.Read.All` and
     `Application.Read.All` to the sync identity. It is not part of the deployment run. The
     delegated-snapshot mode (docs/SYNC.md) needs no application permission.
2. **One template, existing modules.** `main.bicep` composes `infra/prereqs` (network, Log
   Analytics, identities, Cosmos account, Flex Consumption apps), `infra/poc/phase4-telemetry.bicep`
   and `infra/workbook`, and adds modules for the Cosmos database, containers and data-plane roles,
   the application settings and the resolver's authentication, the API in the existing APIM, the
   Azure role assignments, the cross-subscription Cognitive Services User grant and, when
   `runner.enabled` is true, the private runner.
3. **The existing APIM is referenced, never changed.** The template reads its system-assigned
   identity with `existing` and writes only child resources (API, operation, backends, policy,
   logger, diagnostics).
4. **Rerunnable wrapper.** Numbered steps, a git-ignored state file, resume at the first step not
   completed, `-From` to restart, `-Only` to run one step.

## Parity rule

The quick-start must create what the stages create, from the same sources:

- the Cosmos containers and partition keys equal D2's schema step (`scripts/Core.D2Steps.psm1`);
- the application settings per app equal D2's settings step (`Get-CoreAppSettings`): names, and
  the values that are constants, plus the quick-start setting named below
  (`AzureWebJobs.registrySeed.Disabled`);
- the Cosmos data-plane role definitions and assignments equal D3's data files, plus the additions
  named below.

`tests/Test-Quickstart.ps1` checks the three. A change to D2 or D3 that the quick-start does not
follow fails that test.

## The backend registry writer (D-7): the quick-start's Proposed answer

D-7 (PENDING, `docs/STATUS.md`) asks who writes the backend registry documents in `backends`, with
which grant; D3's data has no writer. The quick-start seeds `projects` and `backends` itself (step 5),
so it needs one. Cosmos public access is off, so the writer runs inside the VNet.

- **The sync identity** (user-assigned, `identities.sync`) holds D3's custom role "onboarding project
  writer" (`onbProjectWriter`: `readMetadata`, `items/read`, `items/create`) on `projects` and on
  `backends`: assignments `qs-sync-projects-writer` and `qs-sync-backends-writer` in
  `infra/quickstart/modules/cosmos-data.bicep`, in every sync mode. It keeps Cosmos DB Built-in Data
  Reader on `projects` (`sync-projects-reader`). Step 5 has the sync app's `registrySeed` timer
  function (`src/sync/registry-seed.ts`) create the documents.
  - *Reason.* A customer whose Azure Policy denies marketplace VM images cannot create the runner VM
    that held this role before (PR #58), and without a VM the only compute inside the VNet is the
    Flex Consumption apps. The sync app already runs as this identity, with VNet integration and the
    Cosmos private endpoint.
  - *Risk.* The sync identity already writes `entitlement` (`syncEntitlementWriter`: create and
    replace), and an entitlement document grants access directly: whoever controls the sync code or
    identity can already admit anyone to any project. Creating `projects` or `backends` documents adds
    no access path beyond that one. Create-only cannot change an existing document: the role has no
    `items/upsert` and no `items/replace` (Learn, "Azure Cosmos DB for NoSQL data plane security
    reference", https://learn.microsoft.com/azure/cosmos-db/reference-data-plane-security, retrieved
    2026-10-13: upsert and replace are separate data actions), so a registered project or backend
    cannot be altered or retargeted with it. The residual risk is that the role stays after step 5
    (a rerun needs it): a compromised sync could add documents for new projects, which its
    `entitlement` write already allows in effect. Revoking the two assignments after the seed is an
    operator's option.
  - *When the function runs.* The function is registered only while the app setting
    `CCOF_SEED_DOCUMENTS` is set, which only step 5 does (the staged path never does), and the host
    runs it only while `AzureWebJobs.registrySeed.Disabled` is `false`. The quick-start's settings
    keep that switch `true` (the one quick-start setting that D2 does not write); step 5 sets it to
    `false` with the documents and, whatever the outcome, back to `true` and deletes the documents.
- **The runner**, when it exists (`runner.enabled` true, which only the delegated-snapshot sync mode
  needs), holds the same role on `backends` (`qs-runner-backends-writer`) besides D3's on `projects`,
  and step 5 then uses it through Run Command, as reviewed in PR #58. Its assignments exist only when
  the runner is enabled.
- Either way, step 5 creates each document, takes an existing one (HTTP 409) as present, reads it
  back and compares its seeded fields with the parameters; it reports a document that differs by
  container and id and never overwrites it. Changing a seeded document is an onboarding change,
  outside the quick-start.
- This answers D-7 for the quick-start only. The staged path keeps D-7 PENDING until the owner
  decides it for onboarding Stage 2.

## What stays with the staged path

Team hand-offs and checkpoint records (ADR-0019, ADR-0021); creating the APIM; second-tenant
backends (named-value secrets); onboarding stages 1 to 5 with approvals (ADR-0012, ADR-0015);
policy revisions that stay non-current until smoke-tested (the quick-start writes the policy to the
current revision); alert configuration; network shapes other than one VNet with private endpoints.

## Consequences

- One person can stand the core up with three commands, one per phase.
- Two ways to deploy the same thing: the parity test is what keeps them equal.
- A rerun of the Bicep step rewrites the apps' settings, so values that later stages own in the
  staged path (the sync timer, the budget mode) are parameters here (`syncTimerEnabled`,
  `resolver.budgetEnforcement`).
