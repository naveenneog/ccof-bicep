# Admin app: quick, modular customer deployment

Use this only if the customer now permits an approved administrator to clone the repository.
The no-clone, Portal-first option remains the [Public Access Workbook, Modules 18-24](runbooks/PUBLIC-ACCESS-WORKBOOK.md#admin-hand-configuration).
This is an optional faster path, not a replacement for that in-progress workbook.

## Boundaries

- The resources stage creates **only** a new admin Function App, Flex plan, storage/container,
  Log Analytics and Application Insights, settings and two IAM assignments on those new resources.
- No VNet, private endpoint, APIM policy, existing Function code/settings, native Cosmos role,
  or Entra registration is changed by that template.
- Native Cosmos grants **can** be automated with Bicep, but are deliberately kept as a separate
  privileged operation here; Entra setup is separate too. This is a permission boundary, not a
  claim that Cosmos RBAC cannot be deployed with Bicep.
- Blank ADMIN_* authentication settings leave all registry operations failing closed. The UI
  can be deployed before authentication/data access is complete, but it cannot manage projects yet.
- These resources have ongoing charges. Names, region, subscription and changes require approval.

Use **Cloud Shell PowerShell 7**. At each stage stop on nonzero exit and inspect state before rerun.
Do not run the resources template over names belonging to an existing inference deployment.

## Stage 0 - Clone the feature branch and pin the reviewed source

```powershell
git clone --branch feat/project-admin-api --single-branch https://github.com/naveenneog/ccof-bicep.git
if ($LASTEXITCODE -ne 0) { throw 'Clone failed.' }
Set-Location ccof-bicep
git rev-parse HEAD
```

Record/approve the printed commit before building/deploying. If already cloned, back up local
changes and use `git switch feat/project-admin-api`; don't discard changes or reset the branch.

## Stage 1 - Set the customer's resource values

```powershell
$sub = 'REPLACE-customer-subscription-guid'
$rg = 'REPLACE-new-admin-resource-group'
$loc = 'REPLACE-approved-flex-region'
$app = 'REPLACE-unique-new-admin-function'
$storage = 'REPLACE-unique-new-adminstorage'
$cosmosEndpoint = 'https://REPLACE-existing-cosmos.documents.azure.com:443/'
$db = 'REPLACE-actual-existing-database'
if (@($sub,$rg,$loc,$app,$storage,$cosmosEndpoint,$db) -match 'REPLACE-') { throw 'Fill the approved customer values first.' }
az account show --subscription $sub --query '{id:id,tenant:tenantId,name:name}' -o json
if ($LASTEXITCODE -ne 0) { throw 'Subscription read failed.' }
```

The exact database might be `registry` or another customer-chosen name; don't copy the lab's
`ccof`. Check `az functionapp list-flexconsumption-locations` if the chosen region is uncertain.

## Stage 2 - Create the new admin resource group (once)

```powershell
az group create --subscription $sub -n $rg -l $loc --output none
if ($LASTEXITCODE -ne 0) { throw 'Admin resource-group create failed.' }
```

If it already exists, verify its identity/location and skip create.

## Stage 3 - Create the admin resources with ONE deployment command

```powershell
az deployment group create --subscription $sub -g $rg -n ccof-admin-resources `
  --template-file infra/admin/admin-resources.bicep `
  --parameters "location=$loc" "functionAppName=$app" "storageAccountName=$storage" `
               "cosmosEndpoint=$cosmosEndpoint" "cosmosDatabase=$db" `
  --query properties.outputs -o json
if ($LASTEXITCODE -ne 0) { throw 'Admin resources not verified; inspect deployment operations before rerun.' }
```

This creates the app first with no VNet integration and no configured user authentication;
the API refuses requests until Stage 4. Keep the output resource IDs/principal/hostname privately.
The template targets only the approved new names; no old CCOF app is redeployed.

### Network gate - can publishing proceed now?

Read the effective new storage setting (policy can override the requested setting):

```powershell
az storage account show --subscription $sub -g $rg -n $storage --query '{publicNetworkAccess:publicNetworkAccess,allowSharedKeyAccess:allowSharedKeyAccess}' -o json
if ($LASTEXITCODE -ne 0) { throw 'Storage configuration read failed.' }
```

- **If storage public network access is permitted and deployment storage is reachable:**
  the package can be published without first adding an admin VNet.
- **If storage is forced private by tenant policy:** its private endpoint, DNS and Function
  VNet integration must be configured **before publishing**. Staging networks later cannot
  bypass that dependency. Use workbook 18.4-18.6 and 19.3-19.7, or the separately approved
  `infra/admin/admin-network.bicep` template. Do not weaken the policy or enable account keys.
- **For Cosmos:** public network access Enabled alone is not sufficient: IP/VNet firewalls
  must permit this Function App too. Preserve the customer's current exposure settings. If
  Cosmos is private or firewalled, its approved network path is required before registry tests.
  A console page can still load while the registry is unavailable.

If using the network template, it creates a separate admin VNet, blob zone/link/endpoint only.
It does not connect Cosmos. Pass its `integrationSubnetId` output into a reviewed redeployment
of **the new admin resources only**, with `storagePublicNetworkAccess=Disabled` and all intended
ADMIN_* parameters preserved. Do not blindly redeploy after configuring authentication, because
empty template defaults can overwrite the new admin app's settings.

## Stage 4 - Separate admin identity setup and application settings

Follow workbook **20.1-20.11** for the new single-tenant CCOF Admin registration:
`Projects.Manage` scope, v2 tokens, Read/Write roles, SPA redirect, self-client preauthorization,
enterprise application, approved users and Assignment required.
No runtime Graph lookup permissions are needed. The redirect must use the actual hostname
reported in Stage 3, followed by `/api/console`.

Then merge settings on the **new admin app only**:

```powershell
$tenant = 'REPLACE-customer-tenant-guid'
$client = 'REPLACE-new-admin-registration-client-guid'
if ($tenant -match 'REPLACE-' -or $client -match 'REPLACE-') { throw 'Fill the new admin registration IDs.' }
az functionapp config appsettings set --subscription $sub -g $rg -n $app --settings `
  "ADMIN_TENANT_ID=$tenant" "ADMIN_AUDIENCE=$client" 'ADMIN_SCOPE=Projects.Manage' `
  "ADMIN_ALLOWED_CLIENT_IDS=$client" "ADMIN_UI_CLIENT_ID=$client" `
  "ADMIN_UI_SCOPE=api://$client/Projects.Manage" --output none
if ($LASTEXITCODE -ne 0) { throw 'New admin settings merge failed.' }
```

This is the console registration, not the existing inference gateway registration. The
resource template already supplies identity-based host storage, Cosmos names and Insights.
Prefer assigned roles to object-ID allow-lists. Verify values privately, not only setting names.

## Stage 5 - Build ONLY the admin code, or use the reviewed prebuilt ZIP

On an approved build machine with npm access, PowerShell 7 and Node.js 22.18+ (or a later
supported Node version):

```powershell
pwsh -NoProfile -File admin/Build-AdminPackage.ps1
if ($LASTEXITCODE -ne 0) { throw 'Admin build/tests failed.' }
$zip = Join-Path (Get-Location) 'admin/admin.zip'
Get-FileHash $zip -Algorithm SHA256
```

No root application build or inference code deployment occurs. If Cloud Shell has an unsuitable
Node version or npm is blocked, an approved operator can build elsewhere. Alternatively upload
an already reviewed ready-to-run ZIP and set `$zip` to its uploaded absolute path; compare its
SHA256 with the release manifest before publishing. No dependency install is needed for that path.

## Stage 6 - Publish ONLY the admin app

```powershell
az functionapp deployment source config-zip --subscription $sub -g $rg -n $app --src $zip
if ($LASTEXITCODE -ne 0) { throw 'Admin package publishing failed. Do not infer success from an old running UI.' }
```

**Use this exact command for the Flex app.** It detects Flex and uses its managed publishing
endpoint (`/api/publish`). The generic preview `az functionapp deploy --type zip` failed with
415 on CLI 2.91.0 in the lab. Don't use direct Kudu ZIP deploy, a blob upload alone, or
`WEBSITE_RUN_FROM_PACKAGE`; none is a replacement for the Flex-aware command.

[Microsoft's Flex CLI deployment instructions](https://learn.microsoft.com/azure/azure-functions/deployment-zip-push#deploy-by-using-azure-cli).

## Stage 7 - Verify the new host; grant data access separately

```powershell
az functionapp function list --subscription $sub -g $rg -n $app --query '[].name' -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Handler read failed.' }
az functionapp show --subscription $sub -g $rg -n $app --query 'properties.defaultHostName || defaultHostName' -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Hostname read failed.' }
```

Wait for trigger synchronization; require `projects`, `project`, `classificationPolicy`,
`adminUi`, and `adminHealth`. Open `https://<actual-host>/api/console`; verify the UI is the
reviewed version, then sign in. A working old page is not proof of a successful package upload.

**Cosmos grant:** workbook **22.1-22.5** is the separately approved native custom role and
assignment on `/dbs/<actual-db>/colls/projects`, to this Function's principal ID. Six actions:
metadata read, item read/create/replace, executeQuery and readChangeFeed. No delete/upsert.
Do not substitute subscription IAM access or copy a grant to the wrong identity.

**Private access:** workbook **23.1-23.8** when required. Its Function-side health probe verifies
private Cosmos reachability and read access. Inbound console restrictions are **24.8-24.13**.
Do not open Cosmos/storage to the internet to make the console load.

**Final acceptance:** console sign-in, actual project list, an approved test-project create/update,
ETag conflict/reader refusal, admin audit, and separately verified entitlement sync. A ready health
probe is only a point read, and neither preauthorizes the tests nor proves developer enforcement.

## Validation boundary

With Azure CLI **2.91.0**, the documented `deployment source config-zip` command was
retested on the existing lab Flex admin app: the deployment succeeded, all five handlers
registered, the console returned HTTP 200, and the served JavaScript SHA256 matched the
reviewed ZIP entry. The generic `functionapp deploy --type zip` preview command failed
with 415 and is not recommended by these instructions. This is lab evidence only, not
proof of a fresh customer resource deployment, customer networking or customer data access.
