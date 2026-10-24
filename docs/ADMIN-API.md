# Project admin console and API

> **Historical.** This page describes the first admin API. The current console and API are described in [ADMIN-V3](ADMIN-V3.md) and [admin operations](runbooks/ADMIN-OPERATIONS.md).

> **v2 release:** see [Admin v2 capabilities, optional permissions and VDI
> upgrade/rollback](ADMIN-V2.md). The Phase 1 description below documents the
> original baseline. V2 adds optional Graph lookup, tags, reviewed backend/budget
> settings, catalog/pricing and read-only operations panels; no permission is
> granted automatically. Manual group IDs and the existing limits editor remain.

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
  - Include **STD, PRM and CYB** in the same project. Each classification has its own Entra group
    Object ID, display name, model family, deployments, limits and budgets. Unchecked groups are
    omitted from the document; at least one is required, and group Object IDs must be distinct.
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

For **granular hand configuration**, follow the appended
[Public Access Workbook Modules 17-24](runbooks/PUBLIC-ACCESS-WORKBOOK.md#admin-hand-configuration).
They preserve the existing Modules 00-16, consolidate the Step 13 client/desktop material,
and give individually numbered Portal/CLI alternatives and checks for new resources, grants,
Entra sign-in, publishing, private Cosmos access and UI restrictions. The condensed deployment
and Bash commands below are alternative references, not the customer's default hand-config path.

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
# 4. Build and deploy the package (this CLI command detects the Flex package API)
pwsh admin/Build-AdminPackage.ps1
az functionapp deployment source config-zip -g <rg> -n <app> --src admin/admin.zip
```

Flex publishing note: Microsoft documents `az functionapp deployment source config-zip`
for Flex Consumption: the CLI detects the plan and uses the managed package publishing
endpoint. It is **not** a direct Kudu ZIP-deploy request on a Flex app. The generic
`az functionapp deploy --type zip` returned HTTP 415 in the lab with CLI 2.91.0.
Do not set `WEBSITE_RUN_FROM_PACKAGE` or request remote build for this ready-to-run ZIP.
[Microsoft reference](https://learn.microsoft.com/azure/azure-functions/deployment-zip-push#deploy-by-using-azure-cli).

If the customer permits a repository clone, the [quick modular stages](ADMIN-QUICK-STAGES.md) create the admin resources first, then configure sign-in, build/publish code and verify data access independently. Storage/network policy remains a dependency, not something this path bypasses.

## Lab status (2026-10-16)

| Item | State |
|---|---|
| Console page, CSP, public configuration | Live; served by the app |
| Entra sign-in | Live; redirects to the tenant's v2 authorize endpoint |
| Token validation and roles | Live; with a real Entra token, `/api/console/me` returned `canWrite: true`; with no token, 401 |
| Write without `If-Match` | Live; 428 |
| Registry read and write | **Blocked:** 503 `registry_unavailable`. The health probe log shows Cosmos refusing the admin identity because it has no data role (`readMetadata`). |

## Remaining steps to read and write the registry (each needs approval)

Both steps add configuration under the existing Cosmos account: a custom role/assignment and a
private-endpoint connection. Existing apps, their grants, the original endpoint, and the public-access
setting stay unchanged. These are real Azure writes and require the account owner's approval.

### Hand configuration from Azure Cloud Shell

Use **Bash**, not PowerShell. The complete copy-paste procedure is
[`admin/Configure-RegistryAccess.sh`](../admin/Configure-RegistryAccess.sh). It needs no clone,
download, app rebuild, account key or Graph consent. Paste its contents into Cloud Shell after
filling the variables at the top. Cloud Shell configures resources through Azure's management
plane; the **Function App**, not Cloud Shell, subsequently connects to private Cosmos.

Required authority: Cosmos `sqlRoleDefinitions/write` and `sqlRoleAssignments/write`; Network
Contributor-equivalent access to the admin VNet, subnet and private endpoint; Private DNS
Zone Contributor-equivalent access to the admin DNS zone; permission to approve the new
Cosmos private-endpoint connection; and permission to restart/read keys on the admin app.
Owner or appropriately scoped Contributor/custom roles can supply these actions; a Cosmos
data-reader role alone cannot configure them.

The procedure:

1. Checks the selected app's system identity and existing integration with the admin VNet.
2. Adds a custom role permitting metadata read, query, item read/create/replace, assigned
   **only** on `/dbs/<database>/colls/projects`. Includes `readChangeFeed`, which Microsoft requires
   alongside `executeQuery` for SDK queries (the project list). No delete, upsert, entitlement or
   backend writes.
3. Adds a `Sql` Cosmos private endpoint in `snet-admin-private-endpoints`, not the delegated
   Functions subnet. Creates a documents private DNS zone in the **admin network** resource
   group and links it to the **admin VNet only**. Leaves the CCOF VNet/zone alone.
4. Requires connection approval and adds the endpoint's DNS zone group. The group manages the
   global and regional records; do not manually create just one account A record.
5. Restarts **only the admin app** and checks `/api/health` with a key held in memory, never
   printed or put in the URL. No API token or key should be pasted into a ticket or screenshot.

**Expected result:** HTTP 200, `status: ready`, `checks.auth: configured`, `checks.cosmos: ok`.
This is a point-read probe from the app. It does **not** prove list, create, replace, audit
ingestion or propagation into developer entitlements. Sign in to the UI, click **Try again**,
confirm projects load, then separately approve a dedicated test-project create/update test.
Do not change live projects just to test connectivity.

**If it still fails:**

| Result | Action |
|---|---|
| `forbidden_data_role` | Verify the assignment uses the admin app's **principal/Object ID**, correct database/container and custom role; allow a few minutes for propagation. The metadata refusal can occur before networking is fully exercised. |
| `blocked_by_network` / `unreachable` | Confirm PE Approved, DNS zone group and VNet link, app integration, custom-DNS forwarding if any, and NSG/UDR reachability. Private DNS must work inside the Function VNet. |
| HTTP 403 before a health JSON | App inbound restrictions may block ordinary Cloud Shell. Test from an approved network; do not broaden the allow-list just for the probe. |
| Endpoint connection Pending | Cosmos owner: **Cosmos account > Networking > Private access**, approve only this new admin connection; rerun afterwards. |
| Health ready but UI refuses sign-in | Authentication/app-role issue, not Cosmos networking; check the CCOF Admin app assignment and client/scope settings. |

If custom DNS, NSGs or a firewall are in use, allow the Functions host, Entra authentication,
monitoring and deployment dependencies as well. The Cosmos SDK currently uses its default Direct
mode: TCP 443 and the documented private-endpoint Direct-mode port requirements must be considered.
Do not change the endpoint account URL to a private IP. Sources:
[Cosmos Private Link](https://learn.microsoft.com/azure/cosmos-db/how-to-configure-private-endpoints),
[Cosmos data RBAC](https://learn.microsoft.com/azure/cosmos-db/how-to-connect-role-based-access-control).

### Equivalent hand-configured Portal steps

1. **Admin Function App > Identity > System assigned**: copy its Object/principal ID. Do not use
   the Entra UI application client ID or the sync identity.
2. Use the Cloud Shell role-definition/assignment commands for **Cosmos native data RBAC**.
   Ordinary **Access control (IAM)** assignments are not a substitute. Scope only to `projects`.
3. **Private endpoints > Create**: select the admin network resource group and the admin VNet's
   region. Target **Microsoft.DocumentDB/databaseAccounts**, the existing Cosmos account, and
   sub-resource **Sql**. Use a new endpoint name.
4. Select the **admin VNet > snet-admin-private-endpoints**. Do not use the delegated Functions
   integration subnet. Do not edit the CCOF VNet.
5. In DNS, integrate with **privatelink.documents.azure.com in the admin network resource group**.
   If the wizard does not offer a separate zone, create it in **Private DNS zones**, add a virtual
   network link to the admin VNet (auto registration off), then add a **DNS configuration > private
   DNS zone group** on this new endpoint pointing to that zone.
6. Cosmos account > **Networking > Private access**: verify this endpoint connection is
   **Approved**. Leave public network access **Disabled** and keep the original connection.
7. Confirm **Admin Function App > Networking > VNet integration** still points to the admin VNet,
   and restart only the admin app. Its `COSMOS_ENDPOINT` remains the normal account hostname.
8. Run the final Cloud Shell health probe, then reopen the console. Creating a private endpoint is
   not evidence of a successful data read. For a private-only inbound console, test from the
   approved admin network rather than ordinary Cloud Shell.

### Role details and alternative networking

1. **Data role for the admin identity only**, scoped to the `projects` container. Use a custom
   role with `readMetadata`, `items/read`, `items/create`, `items/replace` and
   `executeQuery` and `readChangeFeed`. Both query actions are required for SDK queries. No delete
   and no upsert.

   ```powershell
   az cosmosdb sql role definition create -g <rg> -a <cosmos> -b '{
     "RoleName":"ccof-admin-project-editor","Type":"CustomRole","AssignableScopes":["/"],
     "Permissions":[{"DataActions":[
       "Microsoft.DocumentDB/databaseAccounts/readMetadata",
       "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/executeQuery",
       "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/readChangeFeed",
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
