# Quick-start: one administrator, one Bicep, one parameters file

The quick-start (ADR-0024, Proposed) deploys the whole core for ONE administrator who holds every
Azure role: a proof of concept, a demo, a single team. It does not replace the checkpointed stages
of ADR-0019, which separate teams run (`docs/adr/0024-single-administrator-quick-start.md`).

## What it creates

`infra/quickstart/main.bicep` creates, in one resource group (sources: the modules it calls):

- a VNet with subnets for private endpoints, Functions (delegated to `Microsoft.App/environments`)
  and the runner, an NSG, and the private DNS zones for Cosmos and blob storage with their links
  (`infra/prereqs/network.bicep`); or it uses existing subnets (`network.mode = 'existing'`);
- Log Analytics (`infra/prereqs/log-analytics.bicep`), Application Insights for the resolver and
  the sync, and the sync and reconciler user-assigned identities (`infra/prereqs/identities.bicep`);
- the Cosmos account with local authentication and public access off and a private endpoint
  (`infra/prereqs/cosmos-account.bicep`), the database, all 8 containers of D2's schema step, the
  3 custom data-plane roles and the assignments of D3's data (`infra/quickstart/modules/cosmos-data.bicep`);
- three Flex Consumption apps (resolver, sync, reconciler), each with its storage account,
  deployment container, blob private endpoint and VNet integration (`infra/prereqs/function-app.bicep`),
  the application settings of D2's settings step, and the resolver's App Service Authentication that
  admits only the APIM's managed identity (`infra/quickstart/modules/app-settings.bicep`, ADR-0009);
- the Azure role assignments of D3's data for these resources (`infra/quickstart/modules/rbac.bicep`);
- a private runner VM (no public IP, system-assigned identity) for Cosmos data-plane writes
  (`infra/quickstart/modules/runner.bicep`);
- in the EXISTING APIM, only child resources: the API, its operation, one backend per Foundry
  account, the policy (`infra/quickstart/modules/apim-api.bicep`), the logger, the API diagnostics
  and a resource diagnostic setting (`infra/poc/phase4-apim-telemetry.bicep`);
- Cognitive Services User for the APIM identity on each Foundry account, in any subscription
  (`infra/quickstart/modules/foundry-role.bicep`), unless `assignCognitiveServicesUser` is false;
- the chargeback workbook (`infra/workbook/main.bicep`, or the shell `infra/workbook/resource.bicep`).

## Three phases, three roles

| Phase | Who | What |
| --- | --- | --- |
| 1. Prerequisites | Entra application or groups administrator, or a member user while the tenant settings allow it (`docs/DEPLOYMENT-GUIDE.md:67`, `:96`) | App registrations and groups; their ids go into `main.bicepparam` |
| 2. Deployment | Owner, or Contributor plus Role Based Access Control Administrator or User Access Administrator, on the resource group and on each backend Foundry account. No Entra directory role | `Deploy-Quickstart.ps1` |
| 3. Post-deployment | Privileged Role Administrator (activated through PIM) or Global Administrator (`docs/DEPLOYMENT-GUIDE.md:398-417`) | `Grant-SyncGraphPermissions.ps1` |

### Phase 1 (before any Bicep)

The Gateway API (scope `access_as_user`, `requestedAccessTokenVersion` set explicitly), the
Developer Sign-in public client (redirect URIs, delegated permission), the Resolver API
(`api://<appId>`, token version 2), any tenant consent, and the groups with their owners. Each one,
with who does it, the steps, a scripted alternative (`scripts/client/Set-DeveloperSignInRedirects.ps1`,
`Initialize-ResolverApiRegistration` in `infra/poc/resolver-auth.ps1:155`) and the `main.bicepparam` value to
hand back: `docs/QUICKSTART-PREREQUISITES.md`. Step 1 only reads them through Microsoft Graph and refuses
with a named reason (for example `resolver_api_token_version`); it never creates or changes an Entra object.

## Parameters (`infra/quickstart/main.bicepparam`)

| Parameter | Meaning |
| --- | --- |
| `tenantId`, `location`, `tags` | Tenant of every Entra object; region; tags |
| `names` | `subscriptionId`, `resourceGroup`, `resourceGroupMode` (`create` or `existing`), prefix and every resource name |
| `apim` | The EXISTING APIM: `name`, `subscriptionId`, `resourceGroup`; the new `apiId`, `apiPath`, `apiDisplayName`. It must have a system-assigned identity |
| `network` | `create` (VNet, address space, subnets) or `existing` (subnet and private DNS zone ids) |
| `registrations` | `gatewayApi` (`appId`, `scope`), `developerSignIn` (`appId`), `resolverApi` (`appId`) |
| `groups` | One object per group: `groupId`, `projectId`, `classification`, `modelAllowList`, `tokenLimits` (per person and per group: tokens per minute, quota, period), budgets, modes |
| `backends` | `id`, `subscriptionId`, `resourceGroup`, `accountName`, `url`, `resource`, `deploymentInferenceGeo`, `assignCognitiveServicesUser` |
| `cosmos`, `functions`, `storageSku`, `logRetentionDays`, `runner` | Sizing: Cosmos serverless or autoscale; Flex maximum instances and memory; VM size and SSH public key |
| `resolver`, `sync`, `reconciler`, `budgetState` | The D2 answers sections (`config/core.answers.schema.json`) |
| `syncTimerEnabled` | `false` until phase 3 is done |
| `gateway` | Admission calls per person and period, token-limit headers, cache, resolver timeout |
| `rateCard`, `workbook`, `enableAlerts` | Rate card path, workbook name (a GUID) and readers; alerts off by default |

## Commands

```powershell
# Phase 2, from the repository root (az signed in to the tenant and subscription of the parameters)
npm ci --ignore-scripts
pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -WhatIfOnly   # steps 1-3, what-if only
pwsh -File infra/quickstart/Deploy-Quickstart.ps1                # resumes at the first step not completed
pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -From 3        # restart at step 3
pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -Only 8 -ConfigureClient   # configure this machine

# Phase 3, possibly another person, after step 3
pwsh -File infra/quickstart/Grant-SyncGraphPermissions.ps1 -PlanOnly
pwsh -File infra/quickstart/Grant-SyncGraphPermissions.ps1
```

Steps: 1 checks (read-only), 2 build (render the policy with `infra/gateway/render.ts`, compile),
3 Bicep deployment, 4 code (packages as `scripts/Core.D2Code.psm1` builds them), 5 seed the
`projects` and `backends` documents, 6 print the phase 3 command, 7 smoke (401 without a token),
8 client (`scripts/client/Set-ClaudeCodeGateway.ps1 -ConfigPath <file> -Confirmed`).

## Rerun and rollback

- State: `infra/quickstart/.env.quickstart.state.json` (git-ignored by `.env.*`). A rerun skips the
  completed steps; `-From <n>` forgets steps `n` and later. Bicep deployments are incremental, so
  step 3 converges on a rerun.
- Rollback: delete the quick-start resource group; in the APIM, delete the API `apiId`, the backends
  of `backends` and the diagnostic setting `<workspace>-apim`; delete the Foundry role assignments;
  revoke the Graph permissions with the DELETE commands phase 3 prints.

## Without the Graph application permission

Set `sync.mode = 'delegated-snapshot'`: an administrator's delegated sign-in reads the groups and
the runner applies the snapshot (`docs/SYNC.md:190`). The template then gives the runner the sync
writer roles, as D3's data does in that mode (`infra/sync/sync.assignments.json`).

## Not in the quick-start

Team hand-offs and checkpoints (ADR-0019); creating the APIM; second-tenant backends; onboarding
stages with approvals (ADR-0012, ADR-0015); non-current policy revisions (the quick-start writes
the current revision); alert configuration.
