# ccof-bicep: single-administrator quick-start for Claude on Azure AI Foundry behind API Management

This repository holds the quick-start deployment of the claude-code-on-foundry gateway: one Bicep
template with every setting in one parameters file, a rerunnable wrapper script, and the guides for
the prerequisites. It is exported from a private working repository (branch `wp/quickstart`,
commit `1201de0`, 2026-10-13) and contains only the files the quick-start uses.

> [!IMPORTANT]
> Status on 2026-10-13: version 1 with two deployment fixes (telemetry with alerts off, one Function
> App at a time). `bicep build` is clean and an `az deployment what-if` against a validation
> subscription succeeded (`docs/adr/0024-single-administrator-quick-start.md`). A live run with a
> smoke test is in progress. Steps 4 (function code), 5 (Cosmos seed) and 7 (smoke with a developer
> token) are not yet proven live. In this version step 5 writes
> `infra/quickstart/.generated/seed-documents.json` and stops with `seed_not_automated`; the
> automated seed follows in a later commit. The prerequisites guide
> `docs/QUICKSTART-PREREQUISITES.md` follows in a later commit.

## What it deploys

Into one resource group, next to an **existing** API Management instance that has a
system-assigned managed identity (`infra/quickstart/main.bicep`):

- a virtual network with private DNS zones and private endpoints;
- a Log Analytics workspace and Application Insights;
- a Cosmos DB account (private, local authentication off) with the registry database and its
  containers, and the data-plane role assignments;
- three Flex Consumption Function Apps (resolver, group sync, reconciler) with their settings and
  the resolver's App Service Authentication;
- optionally (`runner.enabled`, off by default), a private runner VM; only the delegated-snapshot
  sync mode needs it, so a tenant whose policy denies marketplace VM images deploys without it;
- in the existing API Management: the API, its operation, the Foundry backends reached with the
  managed identity, the rendered gateway policy, and diagnostics;
- the chargeback workbook;
- Cognitive Services User for the API Management identity on each Foundry account, which can be
  in another subscription, and can be skipped per account (`assignCognitiveServicesUser`).

## Three phases, by role

| Phase | Who | What | Guide |
|---|---|---|---|
| 1. Prerequisites | Entra application administrator, or a member user when the tenant settings allow it | Three app registrations (Gateway API, Developer Sign-in, Resolver API), consent if the tenant requires it, and the Entra groups with their owners | `docs/PREREQUISITES-WORKBOOK.md` D1-16 to D1-18; `docs/DEPLOYMENT-GUIDE.md` "People and roles" and "Tenant settings" |
| 2. Deployment | Contributor or Owner on the resource group; Role Based Access Control Administrator or User Access Administrator there and on each Foundry account | `infra/quickstart/Deploy-Quickstart.ps1` | `docs/QUICKSTART.md` |
| 3. Post-deployment | Privileged Role Administrator, activated through Privileged Identity Management, or Global Administrator | Microsoft Graph application permissions for the sync identity (`GroupMember.Read.All`, and `User.Read.All` and `Application.Read.All` for disabled members) | `infra/quickstart/Grant-SyncGraphPermissions.ps1`; `docs/DEPLOYMENT-GUIDE.md` Step 7b; `docs/SYNC.md` (the delegated-snapshot mode needs no application permission) |

## Start with the prerequisites

1. Clone the repository and install the Node.js packages:

   ```powershell
   git clone https://github.com/naveenneog/ccof-bicep.git
   cd ccof-bicep
   npm ci --ignore-scripts
   ```

   Tools: PowerShell 7, Azure CLI 2.60.0 or later with Bicep (`az bicep upgrade`), Node.js 24 or
   later. Step 2 runs `node infra/gateway/render.ts`, which relies on Node.js running TypeScript
   files by type stripping ([Modules: TypeScript](https://nodejs.org/api/typescript.html)).

2. The Entra administrator creates the three app registrations
   (`docs/PREREQUISITES-WORKBOOK.md`, D1-16 to D1-18):
   - Gateway API: single tenant, an Application ID URI, the scope `access_as_user`, and
     `requestedAccessTokenVersion` set to 1 in the manifest.
   - Developer Sign-in: a public client with the redirect URIs
     `https://login.microsoftonline.com/common/oauth2/nativeclient` and `http://localhost`, and the
     delegated permission to the Gateway API scope.
   - Resolver API: single tenant, Application ID URI `api://<appId>`, `requestedAccessTokenVersion` 2,
     and its enterprise application.

3. Collect the tenant id, the three app ids and the object ids of the Entra groups (one group per
   project and classification), and put them into `infra/quickstart/main.bicepparam`. Every value
   to change is marked `REPLACE`; each parameter is described in `docs/QUICKSTART.md`.

## Deploy

```powershell
az login --tenant <tenant-id>
az account set --subscription <subscription-id>
pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -ParametersPath infra/quickstart/main.bicepparam
```

The wrapper runs eight numbered steps (checks, build, Bicep deployment, function code, Cosmos seed,
Graph permission instructions, smoke, client) and records each completed step in a state file. A
rerun resumes at the first step that did not complete; `-From <step>` restarts at a chosen step and
`-Only <step>` runs one step. `-WhatIfOnly` previews the Bicep deployment.

After the deployment, the Privileged Role Administrator runs (it reads the sync identity from the
wrapper's state file `infra/quickstart/.env.quickstart.state.json`, or takes `-SyncPrincipalId`;
`-PlanOnly` shows what it would grant):

```powershell
pwsh -File infra/quickstart/Grant-SyncGraphPermissions.ps1 -PlanOnly
pwsh -File infra/quickstart/Grant-SyncGraphPermissions.ps1
```

Then the deployer sets `syncTimerEnabled = true` in the parameters file and runs the wrapper with
`-Only 3`. The grant script's closing message says `-From 3`, which also reruns steps 4 and 5.

## Deploy from Azure Cloud Shell

Azure Cloud Shell has PowerShell 7, the Azure CLI, git and Node.js 24
([Cloud Shell image](https://github.com/Azure/CloudShell/blob/master/linux/base.Dockerfile)), so the
whole deployment runs there, signed in as the Cloud Shell user. Use a session with a storage account:
an ephemeral session loses its files, including the filled form and the wrapper's state file, when it
ends ([Ephemeral sessions](https://learn.microsoft.com/azure/cloud-shell/get-started/ephemeral)).

In the Azure portal, open Cloud Shell in PowerShell mode:

```powershell
git clone https://github.com/naveenneog/ccof-bicep.git
cd ccof-bicep
# Cloud Shell sets NODE_ENV=production, so a plain npm ci would leave out the TypeScript compiler (step 2).
npm ci --ignore-scripts --include=dev
# The form: every customer decision is marked REPLACE. The copy is git-ignored (.env.*).
cp infra/quickstart/customer-form.bicepparam infra/quickstart/.env.customer.bicepparam
code infra/quickstart/.env.customer.bicepparam
```

`code` opens the Cloud Shell editor. Fill every `REPLACE` value and save. The form creates no VM
(`param runner = { enabled: false }`). Then, from the repository root:

```powershell
az account set --subscription <subscription id>
pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -ParametersPath infra/quickstart/.env.customer.bicepparam -WhatIfOnly
pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -ParametersPath infra/quickstart/.env.customer.bicepparam
```

- `pwsh -File` starts the script in the current folder. Called directly inside the session, the
  wrapper would resolve the relative `-ParametersPath` against the folder where the session started:
  `cd` (Set-Location) does not change the process working directory that
  `[System.IO.Path]::GetFullPath` uses (`Deploy-Quickstart.ps1`, last lines).
- The `-WhatIfOnly` run lists every value that is wrong or still `REPLACE` (step 1 reads the APIM, the
  app registrations and the groups back), then previews the deployment (step 3) and ends with
  `what_if_only`.
- Cloud Shell ends a session after 20 minutes without interactive activity
  ([Cloud Shell overview](https://learn.microsoft.com/azure/cloud-shell/overview)); step 3 can take
  longer. A deployment that ARM has accepted continues in Azure, visible under the resource group's
  **Deployments**. After it shows Succeeded or Failed, the same command resumes at the first step not
  completed.
- The filled file stays in the Cloud Shell storage. It holds the customer's tenant, subscription and
  object ids: it stays out of git and out of public repositories.
- Step 8 writes `infra/quickstart/.generated/client-config.json` for the developer machines; Cloud
  Shell's **Manage files** > **Download** copies it out.
- The Privileged Role Administrator can run `Grant-SyncGraphPermissions.ps1` in Cloud Shell as well,
  after activating the role and signing in again with `az login`.

## Developer machines

`scripts/client/Set-ClaudeCodeGateway.ps1` configures Claude Code on a workstation for the gateway
(the wrapper's step 8 with `-ConfigureClient`); `docs/CLIENTS.md` describes the client settings,
the token helper in `client/`, and the support path for 401, 403 and 429 answers.

## Known limits

- The guides were written for the private repository and cite some files that are not part of this
  export (status records under `docs/status/`, other decision records); those links do not resolve here.
- Step 5 (Cosmos seed) is not automated in this version (see the status note above).
- Step 3 deploys only the workbook shell (`workbookShell` in `infra/quickstart/main.bicep`): the
  wrapper does not build the workbook content yet. The usage records are in the Log Analytics tables
  `ApiManagementGatewayLogs` and `ApiManagementGatewayLlmLog` (`analytics/ledger.kql`).
- `sync.mode = 'delegated-snapshot'` is not usable from this repository: its apply script
  (`infra/sync/Invoke-SnapshotApply.ps1`) is not part of the export, and the runner VM has no
  Node.js. Use `application-permission` with the post-deployment Graph grant.
- The repository has no license file yet.
- The Cloud Shell path is written from the Cloud Shell image contents and Microsoft Learn; it has not
  been run end to end in Cloud Shell yet.
