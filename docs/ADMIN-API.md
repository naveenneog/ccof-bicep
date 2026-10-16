# Project admin console and API

A separate Function App that lists, creates and edits CCOF projects in the private Cosmos
`projects` registry. It has two parts:

- **API:** `/api/projects...`
- **Browser console:** `/api/console`, served by the same app.

All writes to Cosmos happen inside the Function App, using its own managed identity. Browsers
and scripts never connect to Cosmos. Directory lookups such as Entra group search are left out
on purpose, so no Microsoft Graph permission is involved. Admins paste the group's **Object ID**
from the Entra admin center.

It adds **new resources only**. The deployed APIM, Cosmos account, resolver, sync and reconciler
apps, and their code, settings, identities and permissions, are not changed.

| Part | Location |
|---|---|
| API and console server (separate package; the root build is unchanged) | `admin/src` |
| Console UI (HTML, CSS, JS bundled with MSAL) | `admin/ui` → built to `admin/ui-dist` |
| Unit tests | `admin/tests` (`npm test` in `admin/`) |
| Local demo server, never deployed | `admin/dev/serve.ts` (`npm run demo`) |
| API contract | `admin/openapi.yaml` |
| New Azure resources: app, storage, Log Analytics, Application Insights | `infra/admin/admin-resources.bicep` |
| New private network for the admin storage, in its own resource group | `infra/admin/admin-network.bicep` |
| Package build | `admin/Build-AdminPackage.ps1` (build, test, zip; does not deploy) |

## Console

The console is designed for an administrator at a desk who adjusts quotas between other work and
needs confidence before saving.

- **Project list:** projects with search.
- **Project page:** the access group (Object ID, with a copy button), budgets (read-only), and a
  limits table. The table has one row for all models plus one per model family, with person and
  group columns.
- **Edit → Review → Save:** edits happen inline. *Review changes* lists every change as a
  before → after line, and nothing is saved until you confirm. Saving sends the version you
  loaded (`If-Match`).
  - If someone else saved in the meantime, the console says so and offers *Load latest version*.
    Nothing is overwritten.
- **New project:**
  - Fields are validated when you leave them (ID pattern, GUIDs, whole numbers).
  - You can preview the exact registry document before creating it.
  - The server re-validates with the deployed sync's own rules.
- **Roles:**
  - Readers see no edit controls.
  - Editors need the `CCOF.Projects.Write` app role.
  - The API enforces both; the page only reflects them.
- **States:**
  - **No sign-in settings:** a setup screen.
  - **Signed in but not an admin:** a clear refusal.
  - **Registry unreachable:** "Can't reach the project registry", with the request ID and a retry.
  - **Empty registry:** what you need before creating the first project.
  - Loading skeletons while data loads; mobile layout below 820px.
- **Security headers:**
  - Strict Content-Security-Policy (`default-src 'none'`, scripts only from the app,
    `frame-ancestors 'none'`).
  - No inline script or style; API values are inserted as text only.
- **What the browser receives:** only tenant ID, client ID and scope. No keys, allow-lists or tokens.

Run it locally without Azure, using an in-memory registry and a demo sign-in:

```powershell
cd admin; npm ci; npm run build
npm run demo                       # http://127.0.0.1:7171/api/console  (?as=reader for read-only)
$env:DEMO_REGISTRY='down'; npm run demo    # shows the "registry unreachable" state
```

## API

| Request | Role | Behaviour |
|---|---|---|
| `GET /api/projects` | Reader | Summaries with ETags |
| `GET /api/projects/{id}` | Reader | The project and its `ETag` |
| `POST /api/projects` | Editor | Create-only; 409 if the ID exists |
| `PUT /api/projects/{id}/classifications/{code}/family-policy` | Editor | Replace models and limits; needs `If-Match` |
| `PATCH /api/projects/{id}/classifications/{code}/limits` | Editor | Change limits only; needs `If-Match` |
| `GET /api/console`, `/api/console/config`, `/api/console/me` | Anonymous; `me` needs a token | Console assets, public sign-in settings, caller's write permission |
| `GET /api/health?code=<function key>` | Function key | Auth configuration and Cosmos reachability, as codes |

Routes must not start with `admin`: the Functions host reserves that prefix for its own API.

- **Validation:** uses the deployed sync's own project reader and family-policy parser
  (`src/sync/projects.ts`, `src/contracts/model-families.ts`).
- **Not changeable here:** project ID, groups, backend, budgets and status. There is no delete.
- **Registry failures:** a missing network path or data role, or an outage, returns `503
  registry_unavailable` with no provider detail.
- **Audit:** each write or refusal logs one `ccof.admin.audit.v1` line to the app's own
  Application Insights. It records the actor's object ID, operation, project, classification,
  ETags, and the before and after value of each changed limit or model list. Tokens are never
  logged.

## Sign-in

A new app registration, "CCOF Admin", serves both the console and the API. It has **no Graph or
other API permissions**.

| Setting | Value |
|---|---|
| Exposed scope | `Projects.Manage` (`requestedAccessTokenVersion: 2`) |
| App roles | `CCOF.Projects.Read`, `CCOF.Projects.Write`, assigned to admin users or groups |
| Platform | Single-page application, redirect URI `https://<admin-app>/api/console` |
| Pre-authorized clients | The app itself, so no consent prompt; optionally Azure CLI (`04b07795-8ddb-461a-bbee-02f9e1bf7b46`) for scripted calls |

| App setting | Value |
|---|---|
| `ADMIN_TENANT_ID` | Tenant ID |
| `ADMIN_AUDIENCE` | The app registration's client ID (v2 tokens) |
| `ADMIN_SCOPE` | `Projects.Manage` |
| `ADMIN_ALLOWED_CLIENT_IDS` | The app's client ID, plus Azure CLI's only if scripted access is wanted |
| `ADMIN_UI_CLIENT_ID`, `ADMIN_UI_SCOPE` | Client ID and `api://<client-id>/Projects.Manage`, served to the console |
| `ADMIN_READER_IDS`, `ADMIN_EDITOR_IDS` | Optional object-ID lists; app roles are preferred |

If any required value is missing, the API returns 503 and the console shows its setup screen
(fails closed).

## Deploy

```powershell
# 1. New app, storage and logs (resource group of your choice)
az deployment group create -g <rg> -n ccof-admin-api --template-file infra/admin/admin-resources.bicep `
  --parameters functionAppName=<app> storageAccountName=<storage> `
               cosmosEndpoint=https://<cosmos>.documents.azure.com:443/ cosmosDatabase=ccof
# 2. If policy forces storage to private (it does in the lab): a new network resource group
az group create -n <admin-net-rg> -l <region>
az deployment group create -g <admin-net-rg> -n ccof-admin-network --template-file infra/admin/admin-network.bicep `
  --parameters adminStorageAccountId=<storage resource id from step 1>
# 3. Redeploy step 1 with integrationSubnetId=<output of step 2>, storagePublicNetworkAccess=Disabled
#    and the ADMIN_* sign-in parameters
# 4. Build and deploy the package
pwsh admin/Build-AdminPackage.ps1
az functionapp deployment source config-zip -g <rg> -n <app> --src admin/admin.zip
```

## Lab status (2026-10-16)

| Item | State |
|---|---|
| Console page, CSP, public configuration | Live; served by the app |
| Entra sign-in | Live; redirects to the tenant's v2 authorize endpoint |
| Token validation and roles | Live; with a real Entra token, `/api/console/me` returned `canWrite: true`; with no token, 401 |
| Write without `If-Match` | Live; 428 |
| Registry read and write | **Blocked:** 503 `registry_unavailable`. The health probe log shows Cosmos refusing the admin identity because it has no data role (`readMetadata`). |

## Remaining steps to read and write the registry (each needs approval)

Both steps add to the existing Cosmos account. Nothing existing is modified.

1. **Data role for the admin identity only**, scoped to the `projects` container. Use a custom
   role with `readMetadata`, `items/read`, `items/create`, `items/replace` and
   `executeQuery`. No delete and no upsert.

   ```powershell
   az cosmosdb sql role definition create -g <rg> -a <cosmos> -b '{
     "RoleName":"ccof-admin-project-editor","Type":"CustomRole","AssignableScopes":["/"],
     "Permissions":[{"DataActions":[
       "Microsoft.DocumentDB/databaseAccounts/readMetadata",
       "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/executeQuery",
       "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/read",
       "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create",
       "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/replace"]}]}'
   az cosmosdb sql role assignment create -g <rg> -a <cosmos> --role-definition-name ccof-admin-project-editor `
     --principal-id <admin app principal id> --scope /dbs/ccof/colls/projects
   ```

2. **Network path from the admin VNet to Cosmos.** Choose one:
   - **A Cosmos private endpoint in `ccof-admin-vnet`**, with its own
     `privatelink.documents.azure.com` zone in the admin network resource group. This adds a
     private-endpoint connection to the Cosmos account.
   - **VNet peering** between `ccof-admin-vnet` and the CCOF VNet, plus a link from the existing
     documents DNS zone. This changes the existing VNet and DNS zone.

   After both steps, `GET /api/health` reports `cosmos: ok`.

## Access restriction guidelines

Sign-in, roles and ETags already protect the data. Network restrictions add a second layer, so
the console and API are reachable only from where administrators work. Apply them to the
**admin app only**.

**1. Choose one inbound model.**

| Model | When to use | How |
|---|---|---|
| **Private only** (recommended for production) | Admins are on the corporate network, VPN or ExpressRoute, connected to Azure | Inbound private endpoint on the admin app (`sites` sub-resource) in a VNet the corporate network reaches. Set `publicNetworkAccess=Disabled` on the app. Resolve `privatelink.azurewebsites.net` for the app name from corporate DNS. |
| **Allow-list** | There is no private connectivity yet | Access restrictions with default action **Deny**, plus Allow rules only for the organization's egress IP ranges (CIDR). |

**2. Allow-list commands** (example ranges; use the organization's real egress ranges):

```powershell
az functionapp config access-restriction add -g <rg> -n <admin-app> --rule-name corp-egress-1 `
  --action Allow --ip-address 203.0.113.0/24 --priority 100
az functionapp config access-restriction add -g <rg> -n <admin-app> --rule-name corp-egress-2 `
  --action Allow --ip-address 198.51.100.0/24 --priority 110
az resource update -g <rg> -n <admin-app> --resource-type Microsoft.Web/sites `
  --set properties.siteConfig.ipSecurityRestrictionsDefaultAction=Deny
# Deployment (SCM) endpoint: same rules, or stricter
az functionapp config access-restriction set -g <rg> -n <admin-app> --use-same-restrictions-for-scm-site true
```

**3. Rules to keep.**

- Restrict the **admin app only**. Never open Cosmos, storage or the existing gateway apps to make
  the console reachable.
- Never add `0.0.0.0/0`, broad service tags such as `AzureCloud`, or home or guest networks.
- Entra sign-in still happens at `login.microsoftonline.com`, so admin browsers need normal
  internet access to Entra. Only the console and API host are restricted.
- Set **Assignment required = Yes** on the CCOF Admin enterprise application, so only users or
  groups with a CCOF role can get a token at all.
- Assign `CCOF.Projects.Write` to a small admin group, and `CCOF.Projects.Read` to reviewers.
  Review membership regularly.
- Remove Azure CLI from `ADMIN_ALLOWED_CLIENT_IDS` and the pre-authorized clients if scripted
  access isn't wanted.
- Keep `/api/health` on the function key; don't share the key with administrators.
- Send the app's Application Insights audit lines (`ccof.admin.audit.v1`) to the security team's
  workspace or alerting.

**4. Verify after applying.**

- From an allowed network, `GET https://<admin-app>/api/console` returns 200.
- From any other network, it returns 403 (IP restriction) or doesn't resolve (private only).
- The health check, from an allowed network with the function key, still reports `auth: configured`.
