# Project admin API

A separate Function App that lists, creates and edits CCOF projects in the private Cosmos `projects`
registry. The API writes to Cosmos only from the Function App, using its own managed identity;
callers never connect to Cosmos. Directory lookups such as Entra group names and members belong
in a future UI and are not part of the API.

It adds **new resources only**. The deployed APIM, Cosmos account, resolver, sync and reconciler
apps, and their code, settings and permissions are not changed.

| Part | Location |
|---|---|
| Code (separate package; the root build is unchanged) | `admin/src` |
| Unit tests | `admin/tests` (`npm test` in `admin/`) |
| API contract for a UI | `admin/openapi.yaml` |
| New Azure resources | `infra/admin/admin-resources.bicep` |
| Package build | `admin/Build-AdminPackage.ps1` (build, test, zip; does not deploy) |

## Phase 1 operations

| Request | Role | Behaviour |
|---|---|---|
| `GET /api/projects` | Reader | Summaries with ETags |
| `GET /api/projects/{id}` | Reader | The project and its `ETag` |
| `POST /api/projects` | Editor | Create-only; 409 if the id exists |
| `PUT /api/projects/{id}/classifications/{code}/family-policy` | Editor | Replace models and limits; needs `If-Match` |
| `PATCH /api/projects/{id}/classifications/{code}/limits` | Editor | Change limits only; needs `If-Match` |
| `GET /api/admin-health` | Function key | Auth configuration and Cosmos reachability, as codes |

**Validation:** documents are validated with the deployed sync's own project reader and
family-policy parser (`src/sync/projects.ts`, `src/contracts/model-families.ts`). The API therefore
can't save a project that the sync would refuse.

**Not changeable here:** project id, groups, backend, budgets and status. Delete, rename, group
replacement and backend moves are not in phase 1. Deleting a project document removes access
on the next sync run, while a non-`active` status freezes the project.

**Writes:** every write needs the current ETag. A stale one returns 412 and nothing is written.

**Audit:** each write or refusal logs one `ccof.admin.audit.v1` line to the app's own Application
Insights. It contains the actor's object id, operation, project, classification, ETags, and the
before and after value of each changed limit or model list. No tokens are logged.

**When changes take effect:** the API updates the project record, and the deployed sync then copies
it into each member's entitlement record.

## Caller authentication

The app validates Entra access tokens itself, so APIM is not required. If any `ADMIN_*` setting is
missing, every request returns 503 (fails closed).

| Setting | Value |
|---|---|
| `ADMIN_TENANT_ID` | Tenant id |
| `ADMIN_AUDIENCE` | The admin API app registration's Application ID URI or client id |
| `ADMIN_SCOPE` | Delegated scope, for example `Projects.Manage` |
| `ADMIN_ALLOWED_CLIENT_IDS` | Client ids allowed to call (the UI's app, an admin CLI) |
| `ADMIN_READER_IDS`, `ADMIN_EDITOR_IDS` | Object ids, or use the app roles `CCOF.Projects.Read` and `CCOF.Projects.Write` |

This needs a **new** app registration, "CCOF Admin API", with that scope and those roles. No
existing app registration is changed.

## Deploy

```powershell
az deployment group create -g <rg> -n ccof-admin-api --template-file infra/admin/admin-resources.bicep `
  --parameters functionAppName=<app> storageAccountName=<storage> `
               cosmosEndpoint=https://<cosmos>.documents.azure.com:443/ cosmosDatabase=ccof
pwsh admin/Build-AdminPackage.ps1
az functionapp deployment source config-zip -g <rg> -n <app> --src admin/admin.zip
```

## Network configuration (phase 2, required before the app can run)

Live finding: tenant policy forces `publicNetworkAccess=Disabled` on every storage account (a
"modify" policy), and the Cosmos registry is private. Until the steps below are done, the
Function App cannot start or receive its package, and the package upload fails with a storage 403.

| # | Change | Where | Changes something existing? |
|---|---|---|---|
| 1 | New subnet, for example `snet-admin-functions` 10.0.4.0/27, delegated to `Microsoft.App/environments` | Existing VNet | Adds a subnet to the VNet |
| 2 | Blob private endpoint for the new storage in `snet-private-endpoints`, registered in the existing `privatelink.blob.core.windows.net` zone | New endpoint | Adds one DNS A record |
| 3 | Redeploy the template with `integrationSubnetId` set to the subnet from step 1 and `storagePublicNetworkAccess=Disabled` | New app | No |
| 4 | Confirm `privatelink.documents.azure.com` is linked to the VNet and resolves the Cosmos account to its private IP | Existing zone | No; read-only check |
| 5 | New Cosmos custom role (`items/read`, `items/create`, `items/replace` and `readMetadata`; no delete, no upsert), assigned to the admin app's identity on `dbs/<db>/colls/projects` only | Existing Cosmos account | Adds a role definition and assignment |
| 6 | Inbound: restrict the app with access restrictions to approved admin networks, or put it behind a private endpoint and reach it from the corporate network or an APIM product | New app | No, unless APIM is used |
| 7 | Create the admin API app registration, set the `ADMIN_*` settings, assign roles | Entra and the new app | No |

After the network steps, `GET /api/admin-health` should return `cosmos: ok`. Before the Cosmos role
(step 5) it returns `forbidden_data_role`; without network reach it returns `blocked_by_network`.
