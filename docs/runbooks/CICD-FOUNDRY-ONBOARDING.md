# Add a Foundry backend with the onboarding pipeline

This runbook adds a new Microsoft Foundry account (a backend) to an existing CCOF deployment in region A
and, when it exists, the region B standby. It uses `.github/workflows/onboard-foundry.yml` on the
private self-hosted runners. The manual path stays in [ADMIN-OPERATIONS.md section 7](ADMIN-OPERATIONS.md#7-add-another-same-tenant-foundry-backend);
both paths make the same changes. Decision record: [ADR 0040](../adr/0040-pipeline-foundry-onboarding.md).

## What the pipeline changes

| Region | Change | Made by |
| --- | --- | --- |
| A | Cognitive Services User for the APIM A identity on the new account | Stage 3 (`foundry-role.bicep`) |
| A | APIM backend entity named after the backend id; policy `%%BACKEND_IDS%%` list; workbook metadata | Stage 5 |
| A | Private endpoint, only when `privateEndpoint` is true (workload subscription and resource group only) | Stage 6 |
| B | Same role for the APIM B identity; APIM B backend entity and policy | `Invoke-DrStandby.ps1 -Phase Backends` |
| Shared | Registry descriptor `backends/<id>` in Cosmos (one multi-region account) | `Set-CicdBackendDescriptor.ps1` |

It never runs Stage 7 (code, seed, client files) or Stage 8, never deletes anything, and never changes
region B writers, fencing or Front Door routing. Projects use the new backend only after an
administrator selects it in the console (ADMIN-OPERATIONS section 7, step 6).

## Before you start

1. **Foundry account.** Same tenant as the workload (see [Network: backend authentication](../NETWORK.md#backend-authentication-managed-identity-only-works-same-tenant)).
   Kind `AIServices`, at least one Claude deployment in state Succeeded. The deployment names are the
   keys of `deploymentInferenceGeo`.
2. **Roles.** The pipeline must be able to grant the APIM identities access to the account:
   the apply runner identity needs Owner, User Access Administrator or Role Based Access Control
   Administrator on the account, or the account owner assigns Cognitive Services User to both APIM
   identities (A and B) beforehand. The preview runner identity needs Reader on the account.
3. **Private link.** With public network access Disabled, the account needs a private endpoint in the
   workload VNet with a DNS zone group on the shared `privatelink.cognitiveservices.azure.com`,
   `privatelink.services.ai.azure.com` and `privatelink.openai.azure.com` zones. For an account in
   another subscription or resource group (`privateEndpoint: false`) the network team creates it and the
   Foundry owner approves the connection; the pipeline waits at the `<env>-gate-privatelink`
   environment. Region B reaches the endpoint through VNet peering and the same zones.
4. **Descriptor writer.** Add the apply runner identity's principal id to
   `automation.backendWriterPrincipalIds` and apply Stage 3 once (see [Least privilege](#least-privilege)).
5. **Settings preservation.** If the admin console uses Graph group search or user names, set
   `admin.graphEnabled` / `admin.userNamesEnabled` to `true` first (see [Stage 5 and live settings](#stage-5-and-live-settings)).

## Run it

1. Open a pull request that appends the backend to `backends[]` in `deploy/<env>/staged.config.json`.
   Existing entries stay unchanged and in order. Example:

   ```json
   {
     "id": "foundry-team02",
     "subscriptionId": "<subscription id>",
     "resourceGroup": "<resource group>",
     "accountName": "<account>",
     "url": "https://<account>.services.ai.azure.com/anthropic",
     "resource": "https://cognitiveservices.azure.com",
     "deploymentInferenceGeo": { "claude-haiku-4-5": "global" },
     "assignCognitiveServicesUser": true,
     "privateEndpoint": false
   }
   ```

   The `pr-check` job runs an offline check on a GitHub-hosted runner: only additions, unique ids, field
   formats, the URL host matches the account. It has no Azure access and no driver state.
2. Review and merge. Then run **Actions > onboard-foundry > Run workflow** on `main` with
   `environment` = `<env>`, `backend_ids` = the new ids, `apply` = false. Read the job summaries and the
   evidence artifact: `validate` (Azure reads: account, deployments, private endpoint connections,
   DNS from the runner, role prerequisite, region A records, region B readiness) and `preview` (what-if of Stage 3, 5, 6,
   region B Backends, descriptor preview).
3. Run again with `apply` = true. If `validate` reported `needs-privatelink-gate`, the run waits at
   `<env>-gate-privatelink`: approve it only after the endpoint exists and the Foundry owner approved the
   connection. The gate job then proves both (Approved connection, private DNS answer).
4. Approve `<env>-apply`. The apply job runs, stopping at the first failure:
   validate with the private link required, Stage 3, Stage 5, Stage 6, region B `-Phase Backends`,
   region B `-Phase Verify`, Front Door `-Phase Verify` (when Front Door is deployed), descriptor create,
   smoke (APIM backend entity and policy id in A and B, descriptor present).
5. Select the backend for a project in the admin console and run the acceptance tests in
   ADMIN-OPERATIONS section 7 C. A live request needs a user entitled to that project.

Every step can also run by hand from a runner shell, with the same guards:

```bash
pwsh scripts/cicd/Invoke-CicdOnboardingStep.ps1 -Environment <env> -Step validate -BackendIds foundry-team02
pwsh scripts/cicd/Invoke-CicdOnboardingStep.ps1 -Environment <env> -Step stage5 -Apply
pwsh scripts/cicd/Invoke-CicdOnboardingStep.ps1 -Environment <env> -Step standby-backends -BackendIds foundry-team02 -Apply
```

Steps: `validate`, `stage3`, `stage5`, `stage6`, `standby-backends`, `standby-verify`,
`frontdoor-verify`, `descriptor`, `smoke`. Logs go to `evidence/<env>/onboard-<step>-<mode>.log`.

## Runner security

- Sign-in uses the runner host's managed identity (`az login --identity`, `.github/actions/azure-login-mi`).
  GitHub holds no Azure secret, variable or federated credential (runner setup: `docs/runbooks/CICD-SETUP.md`, added with the runner infrastructure).
- Pull request code never runs on the self-hosted runners: `pr-check` is GitHub-hosted. If the
  organization disables GitHub-hosted runners, the pull request check is skipped and the dispatch
  `validate` is the first check.
- Every self-hosted job runs only for `workflow_dispatch` on `main` and inside a GitHub environment:
  `<env>-preview` (no reviewers), `<env>-gate-privatelink` and `<env>-apply` (required reviewers). Set
  the deployment branch policy of all three to `main` only.
- Previews run on the apply runner because Azure what-if needs the same permissions as a deployment
  ([Learn: what-if permissions](https://learn.microsoft.com/azure/azure-resource-manager/templates/deploy-what-if)).
- `Invoke-CicdOnboardingStep.ps1` refuses an apply in GitHub Actions unless the runner reports
  `CCOF_RUNNER_ROLE=apply`. This is defense in depth only: any workflow that targets the runner labels
  gets the runner's identity. Restrict the runners at the runner level: an organization runner group
  limited to this repository and to `onboard-foundry.yml` and the deployment workflows at `refs/heads/main`;
  branch protection and CODEOWNERS on `.github/workflows/**` and `deploy/**`; no forks. A runner
  registered to a user-owned repository cannot be limited to workflows, so use an organization repository
  for production ([GitHub: self-hosted runner security](https://docs.github.com/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners)).

## Merge order

The workflow uses files from the runner and state branches: `scripts/cicd/Test-RunnerHost.sh` and
`.github/actions/azure-login-mi` (runner infrastructure), and `scripts/cicd/Sync-CicdState.ps1` with
`CicdState.psm1` (deployment pipeline). Merge those first; until then the self-hosted jobs fail at their
first step and change nothing. `pr-check` does not use them.

## Driver state

The staged and standby drivers keep state in `deploy/<env>/.staged-state` and `.dr-state` (git-ignored).
Each self-hosted job restores it from the `cicd-state/<env>` branch with
`scripts/cicd/Sync-CicdState.ps1 -Action Restore` (job token in `CCOF_STATE_TOKEN`; the read-only jobs check out without stored credentials); only the apply job saves it back (`-Action Save`, also
after a failure). Runs for one environment share the concurrency group `ccof-env-<env>` and never run
at the same time.

## Stage 5 and live settings

Stage 5 replaces each Function App's complete app settings. A setting added by hand after the last
Stage 5 apply (for example `ADMIN_GRAPH_ENABLED` after Graph consent) would be removed. Stage 5 now
lists the live settings first: a preview warns and an apply refuses (`stage5_settings_would_drop`) when a
live setting that the last apply did not leave and the configuration does not write would be removed.

- `admin.graphEnabled` and `admin.userNamesEnabled` (true or false) make Stage 5 write
  `ADMIN_GRAPH_ENABLED` and `ADMIN_USER_NAMES_ENABLED`. A configuration without them writes exactly the
  same settings as before.
- `stage5.allowDroppedSettings` (`"KEY"` or `"<app>:KEY"`) acknowledges a removal.

The guard covers all four apps (resolver, sync, reconciler, admin). Stage 7 can turn off the sync
`snapshotApply` timer (`AzureWebJobs.snapshotApply.Disabled=true`, delegated snapshot mode). When that
setting is live, Stage 5 writes it again as `true` instead of removing it; when it is absent, Stage 5
parameters are unchanged.

## Least privilege

`automation.backendWriterPrincipalIds` (GUID list) in the staged configuration makes Stage 3 assign
the custom Cosmos role `onbProjectWriter` (create and read items, no replace or delete) on the
`backends` container only, to each listed principal. `Set-CicdBackendDescriptor.ps1` creates a missing
descriptor, reports `present` for an identical one and stops with `descriptor_mismatch` for a different
one; it never overwrites. It runs from the private runner (Cosmos private endpoint, Entra token).

## Region B

`Invoke-DrStandby.ps1 -Phase Backends -BackendIds <ids>` reruns the region B Stage 3 and Stage 5 with
the primary configuration. It refuses when region B inputs changed in any other way since the verified
build (`standby_backends_scope`), when region B writers are on (it may be serving after a failover,
`standby_backends_region_active`), or when the standby is incomplete. Only after these checks pass does
an apply clear the prior Verify and Front Door evidence, so a refused run leaves it intact. Run
`-Phase Verify` afterwards; the pipeline does both.

Region A has the same rule in `validate` (`primary_scope`): the Stage 3, 5 and 6 records must match the
configuration, or the configuration without the named backends. Any other unapplied change is refused,
because the onboarding applies would deploy it without its own review. A rerun after a partial apply
passes, so a failed run can be repeated with the same ids.

## Effect on later stages

Stages 7 and 8 record hashes of the Stage 5 and Stage 6 outputs they depend on (`Get-StgDependencyHashes`
in `Staged.Common.ps1`). Those hashes leave out `verify`, which holds the policy hash, and the other
Stage 5 outputs do not depend on backends, so Stage 5 for a new backend keeps Stages 7 and 8 current. A new
Foundry private endpoint (Stage 6 with `privateEndpoint: true`) adds to `foundryPrivateEndpointIds`, so
the driver then reports Stages 7 and 8 as stale. That is expected: do not rerun Stage 7 for onboarding.

## Rollback

On failure the apply job prints the completed steps and the undo list
(`Get-CicdOnboardingRollback`). Every applied step is additive and safe to rerun, so the usual action is
to fix the cause and rerun. To withdraw the backend:

1. Revert the `backends[]` change by pull request.
2. From a runner shell, rerun Stage 3 and Stage 5 for region A, and `Invoke-DrStandby.ps1 -Phase Grants`
   then `-Phase Config` for region B (`-Phase Backends` refuses removals). The policy no longer lists the id.
3. Disable the descriptor in the admin console or delete `backends/<id>` in Cosmos Data Explorer.
4. APIM backend entities and role assignments remain (incremental deployments); remove them only if the
   Foundry owner asks.
5. Run `-Phase Verify` for region B and the Front Door verify.

Sources: [`onboard-foundry.yml`](../../.github/workflows/onboard-foundry.yml),
[`CicdOnboarding.psm1`](../../scripts/cicd/CicdOnboarding.psm1),
[`Staged.SettingsGuard.ps1`](../../infra/staged/Staged.SettingsGuard.ps1),
[`DrStandbyBackends.psm1`](../../infra/dr/DrStandbyBackends.psm1),
[`backend.ts`](../../src/resolver/backend.ts).
