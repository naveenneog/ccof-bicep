# Quick-start: one administrator, one Bicep, one parameters file

The quick-start (ADR-0024, Proposed) deploys the whole core for ONE administrator who holds every
Azure role: a proof of concept, a demo, a single team. It does not replace the checkpointed stages
of ADR-0019, which separate teams run (`docs/adr/0024-single-administrator-quick-start.md`).

## What it creates

`infra/quickstart/main.bicep` creates, in one resource group (sources: the modules it calls):

- a VNet with subnets for private endpoints, Functions (delegated to `Microsoft.App/environments`)
  and, with the runner, the runner, an NSG, and the private DNS zones for Cosmos and blob storage with their links
  (`infra/prereqs/network.bicep`); or it uses existing subnets (`network.mode = 'existing'`);
- Log Analytics (`infra/prereqs/log-analytics.bicep`), Application Insights for the resolver and
  the sync, and the sync and reconciler user-assigned identities (`infra/prereqs/identities.bicep`);
- the Cosmos account with local authentication and public access off and a private endpoint
  (`infra/prereqs/cosmos-account.bicep`), the database, all 8 containers of D2's schema step, the
  3 custom data-plane roles and the assignments of D3's data, plus the quick-start's own: the sync
  identity's create-only writer role on `projects` and `backends` for step 5 (ADR-0024, D-7)
  (`infra/quickstart/modules/cosmos-data.bicep`);
- three Flex Consumption apps (resolver, sync, reconciler), each with its storage account,
  deployment container, blob private endpoint and VNet integration (`infra/prereqs/function-app.bicep`),
  the application settings of D2's settings step, and the resolver's App Service Authentication that
  admits only the APIM's managed identity (`infra/quickstart/modules/app-settings.bicep`, ADR-0009);
- the Azure role assignments of D3's data for these resources (`infra/quickstart/modules/rbac.bicep`);
- optionally (`runner.enabled`, default false), a private runner VM (no public IP, system-assigned
  identity) for Cosmos data-plane writes (`infra/quickstart/modules/runner.bicep`); only the
  runner-based delegated-snapshot mode can use it (step 5 does not). A no-VM snapshot apply through
  the sync Function App is also available in `docs/SYNC.md`; its new-path live acceptance is separate.
  The runner subnet is optional when the runner is off;
- in the EXISTING APIM, only child resources: the API, its operation, one backend per Foundry
  account, the policy (`infra/quickstart/modules/apim-api.bicep`), the logger, the API diagnostics
  and a resource diagnostic setting (`infra/poc/phase4-apim-telemetry.bicep`);
- Cognitive Services User for the APIM identity on each Foundry account, in any subscription
  (`infra/quickstart/modules/foundry-role.bicep`), unless `assignCognitiveServicesUser` is false;
- the complete chargeback workbook (`infra/workbook/main.bicep`) from the reviewed step-2 artifact.
  The quickstart does not deploy an empty workbook shell; `-Only 3` requires the verified full artifact.

### Existing database identity is not a rename operation

A live-proof run reported that changing `names.cosmosDatabase` on an existing deployment fails
step 3 with `Updating SQL Role Assignment Scope is not permitted`. Existing assignment identifiers
cannot simply be reused with a different SQL scope. Keep the original database name for a resume.
For a different database, ask its resource owner to plan a reviewed migration or a fresh deployment
identity; do not silently remove assignments, overwrite registry documents or delete data.
This is an observed deployment limitation, not a newly implemented migration feature.

## Three phases, three roles

| Phase | Who | What |
| --- | --- | --- |
| 1. Prerequisites | Entra application or groups administrator, or a member user while the tenant settings allow it (`docs/DEPLOYMENT-GUIDE.md:67`, `:96`) | App registrations and groups; their ids go into `main.bicepparam` |
| 2. Deployment | Owner, or Contributor plus Role Based Access Control Administrator or User Access Administrator, on the resource group and on each backend Foundry account. No Entra directory role | `Deploy-Quickstart.ps1` |
| 3. Post-deployment | Privileged Role Administrator (activated through PIM) or Global Administrator (`docs/DEPLOYMENT-GUIDE.md:398-417`) | `Grant-SyncGraphPermissions.ps1` |

### Phase 1 (before any Bicep)

By default two registrations are mandatory: one combined Gateway API / Developer Sign-in app
(scope `access_as_user`, token version 2, public-client redirect URIs), and the distinct Resolver API
(`api://<appId>`, token version 2), any tenant consent, and the groups with their owners. Each one,
with who does it, the steps, a scripted alternative (`scripts/client/Set-DeveloperSignInRedirects.ps1`,
`Initialize-ResolverApiRegistration` in `infra/poc/resolver-auth.ps1:155`) and the `main.bicepparam` value to
hand back: `docs/QUICKSTART-PREREQUISITES.md`. Step 1 only reads them through Microsoft Graph and refuses
with a named reason (for example `resolver_api_token_version`); it never creates or changes an Entra object.
Separate Gateway API and Developer Sign-in registrations remain supported. An optional cross-tenant
backend credential registration is separate from these and does not replace the Resolver API.

## Parameters (`infra/quickstart/main.bicepparam`)

`infra/quickstart/customer-form.bicepparam` holds the same parameters as a form for a customer: every
customer decision says `REPLACE`, the names derive from one prefix, and it creates no VM. Copy it to
the git-ignored `infra/quickstart/.env.customer.bicepparam`, fill the copy, and pass the copy with
`-ParametersPath` (step 1 refuses while a `REPLACE` value is left). The filled copy holds the
customer's tenant, subscription and object ids: it stays out of git.

| Parameter | Meaning |
| --- | --- |
| `tenantId`, `location`, `tags` | Tenant of every Entra object; region; tags |
| `names` | `subscriptionId`, `resourceGroup`, `resourceGroupMode` (`create` or `existing`), prefix and every resource name |
| `apim` | The EXISTING APIM: `name`, `subscriptionId`, `resourceGroup`; the new `apiId`, `apiPath`, `apiDisplayName`. It must have a system-assigned identity |
| `network` | `create` (VNet, address space, subnets) or `existing` (subnet and private DNS zone ids) |
| `registrations` | `gatewayApi` (`appId`, `scope`), `developerSignIn` (`appId`), `resolverApi` (`appId`) |
| `groups` | One object per group: `groupId`, `projectId`, `classification`, `familyPolicy`, budgets, modes; `backendId` selects a registered backend consistently for every group in a project |
| `client` | Step 8 export selection: `projectId`, `classification`, `models` (`default`, `opus`, `sonnet`, `haiku`) explicitly mapped to exact admitted deployments |
| `backends` | `id`, `subscriptionId`, `resourceGroup`, `accountName`, `url`, `resource`, `deploymentInferenceGeo`, `assignCognitiveServicesUser` |
| `cosmos`, `functions`, `storageSku`, `logRetentionDays`, `runner` | Sizing: Cosmos serverless or autoscale; Flex maximum instances and memory; `runner.enabled` (default false) and, when true, VM size and SSH public key |
| `resolver`, `sync`, `reconciler`, `budgetState` | The D2 answers sections (`config/answers/Validation-shape-a.json`) |
| `syncTimerEnabled` | `false` until phase 3 is done; then `true`, and `Deploy-Quickstart.ps1 -Only 3` |
| `gateway` | Admission calls per person and period, token-limit headers, cache, resolver timeout |
| `rateCard`, `workbook`, `enableAlerts` | Rate card path, workbook name (a GUID) and readers; alerts off by default |

### Family policy and per-project routing

Each classification requires `familyPolicy.aggregateLimits` with the existing person/group limits
moved **verbatim**, and `familyPolicy.families` with at least one explicit family. Each family
requires nonempty exact deployment IDs (`models`) plus complete person/group limits. Family ceilings
are additional to aggregate ceilings; changing family or version cannot multiply the aggregate
allowance. The examples use all-null additional ceilings to preserve the prior aggregate behavior.
Removing a family revokes its models; null limits do not revoke access. An unregistered exact ID is
denied even if its prefix looks familiar. Only classification exactly `CYB` may configure Fable/Mythos:
first establish real deployment IDs/backend reachability separately; no default IDs or prices exist.
Old `modelAllowList`/`tokenLimits` documents fail closed; this is not a dual-format migration.

With multiple `backends[]`, set `backendId` on every group; all groups of the same project must agree.
Only a single backend allows omission. Unknown IDs, duplicate backend IDs and conflicting project
routing refuse before the first Azure call. Seeded `backendId` and `designatedSubscriptionId` come
from the chosen backend. Bicep creates every backend entity and, where requested, the APIM identity's
Cognitive Services User assignment in each backend's subscription/resource group.
Validation also runs before resumed/`-Only` dispatch and directly before deployment; a previously
completed preflight cannot bypass validation after the parameters change.
Generic form values are samples, not verified live configuration. The existing preflight group read
captures the real Entra `displayName` as optional `classificationGroupDisplayName` for reporting;
its exact snapshot is saved in the step 1 state and reused if step 5 resumes in a new process.
Form labels are not substituted for actual names, and names never authorize.

### After deployment: `onboarding.json` for workstations

Step 8 writes `.generated/onboarding.json` and the identical `.generated/client-config.json`
(existing consumers keep working), next to the filled parameters file. Set `client.projectId` and
`client.classification`, and explicitly map its four `client.models` aliases to admitted deployment
IDs; rerun `-Only 8` for another selection. It does not choose the first project or backend, guess
model names, or export quotas, prices, credentials or tokens. The picker contains only the
intersection of that classification's exact registered models and the chosen backend's explicit
`deploymentInferenceGeo` keys. Fable/Mythos are never added by inference.
The workstation's existing strict schema requires all four aliases; if a family is unavailable,
an administrator may explicitly map that UI alias to another admitted model, or omit this export
until the intended deployments exist. Such mapping grants no family permission.
Both files pass the same `client/bin/validate-config.mjs` used by workstation scripts before export.

Hand the selected export to the project's developer (these settings are not authorization):

```powershell
pwsh -File scripts/client/Set-ClaudeCodeGateway.ps1 -ConfigPath <absolute-path-to-onboarding.json> -Confirmed
pwsh -File scripts/client/Set-ClaudeDesktopGateway.ps1 -ConfigPath <absolute-path-to-onboarding.json> -Confirmed
# CLI/token helper uses the same file:
$env:CCOF_CONFIG_FILE = '<absolute-path-to-onboarding.json>'
node client/bin/ccof-token.mjs login
```

The combined-app `clientId` and original `api://<appId>/access_as_user` scope are preserved in the
export; the token helper normalizes the self-resource scope for Entra during sign-in. The distinct
Resolver API ID is never substituted for the developer client.
For a combined app using a custom identifier URI, the export instead uses `<appId>/access_as_user`
directly to satisfy Entra's token-to-self rule. A separate developer client's custom URI is retained.

## Commands

```powershell
# Phase 2, from the repository root (az signed in to the tenant and subscription of the parameters)
npm ci --ignore-scripts --include=dev
pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -WhatIfOnly   # steps 1-3, what-if only
pwsh -File infra/quickstart/Deploy-Quickstart.ps1                # resumes at the first step not completed
pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -From 3        # restart at step 3
pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -Only 8 -ConfigureClient   # configure this machine

# Phase 3, possibly another person, after step 3
pwsh -File infra/quickstart/Grant-SyncGraphPermissions.ps1 -PlanOnly
pwsh -File infra/quickstart/Grant-SyncGraphPermissions.ps1
# then, by the deployer: set syncTimerEnabled = true in the parameters file and redeploy the template alone
pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -Only 3
```

Steps: 1 checks (read-only), 2 build (render the policy with `infra/gateway/render.ts`, compile),
3 Bicep deployment, 4 code (packages as `scripts/Core.D2Code.psm1` builds them), 5 seed the
`projects` and `backends` documents, 6 print the phase 3 command, 7 smoke (401 without a token),
8 client (`scripts/client/Set-ClaudeCodeGateway.ps1 -ConfigPath <file> -Confirmed`).

### Step 5: the registry seed

Cosmos public access is off, so the `projects` documents (one per project, a classification per
group) and the `backends` documents (one per backend) are written from inside the VNet, create only
(ADR-0024, D-7):

- Without the runner VM (`runner.enabled = false`, the default, and the only choice where Azure
  Policy denies marketplace VM images): the sync app's `registrySeed` timer function
  (`src/sync/registry-seed.ts`) writes them as the sync identity, which holds the create-only role
  `onbProjectWriter` on both containers. The wrapper sets two settings on the sync app,
  `CCOF_SEED_DOCUMENTS` (base64 of `{ seedId, projects, backends }`) and
  `AzureWebJobs.registrySeed.Disabled=false`; the function runs every minute while they are set,
  checks every document before its first write, and logs one `ccof.seed.result.v1` line. The wrapper
  polls the sync app's Application Insights for the line with this seed's id (the Application Insights
  query API, with a token from `az account get-access-token`), up to 10 minutes, prints each
  document's outcome, and then, whatever the outcome, sets `AzureWebJobs.registrySeed.Disabled=true`
  and deletes `CCOF_SEED_DOCUMENTS`. The deployer needs read access to that Application Insights
  (Owner or Contributor on the resource group has it).
- With the runner VM (`runner.enabled = true`): the runner writes them through Run Command.

Each document is `created`, `present-equal` (a rerun), `present-differs` or `failed` with a short
code. A document that differs is never overwritten: the step fails with `seed_documents_differ` and
names the fields; change it through onboarding, or correct the parameters. A failed document (for
example `create_http_403` while a new role assignment applies) is retried by the function's next run;
after three runs the step fails with `seed_failed`. Other named reasons: `seed_result_timeout`,
`seed_refused`, `seed_incomplete`, `seed_query_failed`, `seed_cleanup_failed` (it prints the two
`az functionapp config appsettings` commands that finish the cleanup) and `seed_documents_too_large`
(the Windows command line; use Cloud Shell). Rerunning step 5 is safe; it also resets the two
settings if a previous run stopped before its cleanup.
Changing an existing project's family policy requires an approved onboarding update: create-only
seed reruns report `present-differs` and never silently replace the stored policy or routing.

### Azure Cloud Shell

Cloud Shell in PowerShell mode has PowerShell 7, the Azure CLI, git and Node.js, and runs the same
commands, signed in as the Cloud Shell user. Cloud Shell sets `NODE_ENV=production`, so `npm ci`
needs `--include=dev` for the TypeScript compiler of step 2 (the command above has it). With the
customer form:

```powershell
cp infra/quickstart/customer-form.bicepparam infra/quickstart/.env.customer.bicepparam
code infra/quickstart/.env.customer.bicepparam   # the Cloud Shell editor: fill every REPLACE value
pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -ParametersPath infra/quickstart/.env.customer.bicepparam -WhatIfOnly
pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -ParametersPath infra/quickstart/.env.customer.bicepparam
```

Use a session with a storage account: the filled form and the state file must outlive the session.

## Rerun and rollback

Step 2 now builds the full fixed-price chargeback workbook from the canonical
ledger and `config/rate-card.json`, independently of budget events. It reads
each configured Graph group's actual `id,displayName` once, preserving its
exact spelling and spacing; inaccessible metadata is explicitly unknown.
Customer directory metadata and serialized content stay under git-ignored
`.generated` / `.env.qs-workbook`, never in source or a public export.
Source-controlled templates and the deterministic generator are authoritative,
not hand-edited serialized workbooks (`docs/CHARGEBACK.md`, ADR-0025).

Step 3 passes `workbookContent` and content digests to Bicep. A later `-Only 3`
**refuses** if the full step-2 artifact is missing, empty or mismatched; rerun
`-Only 2` then `-Only 3`. A direct incremental Bicep deployment with empty
content does not deploy a shell over an existing report. No live deployment
was performed for this change.

- State: `infra/quickstart/.env.quickstart.state.json` (git-ignored by `.env.*`). A rerun skips the
  completed steps; `-From <n>` forgets steps `n` and later. Bicep deployments are incremental, so
  step 3 converges on a rerun.
- Rollback: delete the quick-start resource group; in the APIM, delete the API `apiId`, the backends
  of `backends` and the diagnostic setting `<workspace>-apim`; delete the Foundry role assignments;
  revoke the Graph permissions with the DELETE commands phase 3 prints.

## Without the Graph application permission

Set `sync.mode = 'delegated-snapshot'`: an administrator's delegated sign-in reads the groups and
the runner applies the snapshot (`docs/SYNC.md:190`). The template then gives the runner the sync
writer roles, as D3's data does in that mode (`infra/sync/sync.assignments.json`). This mode needs
the runner VM: `runner.enabled = true` (with a VM image the tenant allows) and a runner subnet; step 1
refuses it otherwise (`runner_required_for_delegated_snapshot`).

## Not in the quick-start

Team hand-offs and checkpoints (ADR-0019); creating the APIM; second-tenant backends; onboarding
stages with approvals (ADR-0012, ADR-0015); non-current policy revisions (the quick-start writes
the current revision); alert configuration.
