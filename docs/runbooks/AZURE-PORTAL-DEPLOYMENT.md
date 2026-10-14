# Azure Portal-first deployment workbook

**Create and connect resources in the UI. Deploy application code separately.**
Keep [Quickstart](../QUICKSTART.md) for customers who want automation; this is a
different execution path. Do not run the Quickstart deployment dispatcher or the
all-resources template while following this workbook.

This workbook targets the public v0.2.0 resource/runtime contracts, Azure public
cloud, three Linux Node.js 22 Flex Consumption apps, and same-tenant managed-identity
Foundry access. It is source-checked and offline-tested, **not a completed customer
Portal deployment**. Portal labels can vary. If a required control is missing, use
the narrowly scoped exception below, not a different hosting plan or a security bypass.
Cross-tenant credentials, sovereign clouds, customer WAF/ingress topology and production
HA need their separately approved designs; see [network](../NETWORK.md) and the
[prerequisite sizing workbook](../PREREQUISITES-WORKBOOK.md).

**No Azure resource is created by the new helper scripts.** The artifact exporter
only writes local files; the package builder only builds a ZIP. The access helper
reads by default and grants one existing app's access only with `-Apply`.

## How to use and resume this workbook

Each module has a UI task and an exit check. Complete its check before the next
dependent module. Save evidence in the customer's approved private location:
resource IDs, deployment result, assignment IDs, package hash, and test result.
Do not save tokens, secrets, prompts or responses. Mark the module complete in
your private copy of this checklist, not in the public repository.

| Module | Primary interface | Who | Finish when |
|---|---|---|---|
| 01 Decisions and access | Portal / Entra / PIM | Customer owners | Sizing, tenant, CIDRs and active roles approved |
| 02 Providers and resource group | Portal | Platform | Providers Registered; RG exists |
| 03 Network and DNS | Portal | Network | Dedicated subnets, NSG, DNS links and egress approved |
| 04 Workspace and monitoring | Portal | Platform | LAW and two Insights resources recorded |
| 05 Managed identities | Portal | Platform | Two user identities recorded |
| 06 Entra applications and groups | Entra UI | Directory | Two app registrations; groups and owners recorded |
| 07 Foundry | Foundry / Azure Portal | Backend owner | Exact deployments and private path verified |
| 08 Cosmos account and containers | Portal | Platform | Private/keyless account and eight correct partition keys |
| 09 Storage and deployment containers | Portal | Platform | Three private/keyless stores and containers |
| 10 Function Apps | Portal | Platform | Three Flex apps; identity, integration and deployment storage correct |
| 11 API Management | Portal | Gateway owner | Approved tier, outbound integration, system identity |
| 12 Private ingress checks | Portal + customer network | Network | Actual callers reach private dependencies |
| 13 Private input record | Portal copies + local editor | Platform | Form and evidence match actual resources |
| 14 Generate configuration | Local / short Cloud Shell | Platform | Settings, policy, seed and workbook artifacts reviewed |
| 15 Runtime access grants | IAM UI; necessary Cosmos helper | Access admin | One app at a time, required grants verified |
| 16 Graph application consent | Necessary short Graph helper | Entra privileged admin | Three Graph permissions verified; sync still disabled |
| 17 App settings and resolver auth | Portal; narrow auth exception | Platform | Managed-identity settings; only APIM allowed into resolver |
| 18 Publish code | VS Code UI or one `az` upload per app | Platform | Three packages deployed and functions listed |
| 19 API and gateway policy | Portal | Gateway owner | API, operation, backends and rendered policy saved |
| 20 Diagnostics and chargeback | Portal | Platform | Logs enabled; complete workbook saved |
| 21 Registry seed and timers | Portal | Platform / directory | Seed equal/created; cleanup done; entitlement sync runs |
| 22 Client and acceptance | Workstation / Portal | Developer / QA | Authorized request and negative checks verified |

### Cloud Shell timeout is not deployment failure

Do not keep a shell open while APIM or a Function App provisions. Start the UI
operation, close the shell, and track **Notifications** or **Resource group >
Deployments > deployment > Operation details**. For code upload, use the app's
deployment status. A closed terminal can leave an Azure operation running.
Inspect that operation before resubmitting; do not recreate resources or delete data.

Cloud Shell filesystem persistence depends on whether persistent storage is mounted.
Store the private form, evidence, hashes and receipts in approved durable storage;
download them before disconnecting. Never assume the temporary filesystem or a
background process survives. A normal Cloud Shell is **not inside your VNet**.
Use an approved network-isolated Cloud Shell, VPN-connected workstation or existing
private runner for private data-plane operations. Do not temporarily open Cosmos
or storage to the internet to work around this.

After reconnecting, return to the same checkout/version, restore the two private
input files, reload the variables in module 13, and run **only the unfinished module**.
The access helper is repeatable and recognizes existing grants. Packages are independent
per app. UI changes are persistent in Azure; there is no hidden Quickstart resume state.

## 01. Decide names, capacity and operator access

**UI:** Subscription > Access control (IAM); Entra admin center > Identity
governance > Privileged Identity Management > My roles > Activate.

Use [permissions](../PERMISSIONS.md) and customer role policy. Platform creation
needs Contributor at its target scope; Azure role grants need Role Based Access
Control Administrator/User Access Administrator or Owner at the relevant scope.
Creating Cosmos SQL roles needs the account's `sqlRoleDefinitions/write` and
`sqlRoleAssignments/write` management actions. Directory application/group work
requires the tenant's allowed user/owner rights or the appropriate directory role.
Granting Microsoft Graph **application** permissions requires an active Privileged
Role Administrator or Global Administrator; Azure Owner alone cannot do it.

Record tenant ID, target subscription, platform RG, region, APIM subscription/RG,
Foundry account IDs, approved VNet/address space/subnets, DNS ownership, RU capacity,
storage redundancy, app memory/max instances/always-ready counts, log retention,
model IDs, inference geography and budget enforcement choice. Values in examples
are not capacity or price recommendations.

**Check:** The responsible owner approves every decision. A restricted tenant does
not justify weakening authentication or private networking.

## 02. Register providers and create the resource group

**UI:** Subscriptions > subscription > Resource providers. Register
`Microsoft.ApiManagement`, `Microsoft.Web`, `Microsoft.App`, `Microsoft.DocumentDB`,
`Microsoft.Network`, `Microsoft.Storage`, `Microsoft.ManagedIdentity`,
`Microsoft.OperationalInsights`, and `Microsoft.Insights`.

Resource groups > Create > approved Subscription, Resource group, Region > Tags >
Review + create. For an existing RG, inspect it; do not create a replacement.

**Check:** All required providers show Registered. RG Overview > JSON view contains
the expected subscription/resource ID. Record its name and region.

## 03. Create or connect the network and private DNS

**UI:** Virtual networks > Create > IP addresses, or existing VNet > Settings > Subnets.
Do not overwrite an existing VNet or its full subnet list.

| Subnet | Required configuration |
|---|---|
| APIM outbound integration | Dedicated to one Standard v2/Premium v2 APIM; `Microsoft.Web/serverFarms` delegation; attached NSG; not the Functions subnet |
| Functions integration | `Microsoft.App/environments` delegation; not used for private endpoints, Container Apps environments or another hosting plan |
| Private endpoints | No service delegation; approved private endpoint network-policy setting |

Use nonoverlapping customer-approved CIDRs. APIM and its integration VNet must be
in the same subscription and region. Flex apps and their integration subnet must
be in the same region. Current Learn guidance recommends /24 for APIM integration
and /26 for multiple Flex apps; review customer scale rather than copying these
as a universal capacity guarantee.

Network security groups > Create > approved NSG > Outbound security rules. Permit
APIM's documented platform dependency on `AzureKeyVault` TCP 443 and approved
backend destinations. Review customer firewall, routes and DNS rules. Classic
APIM VNet-injection NSG rules are not automatically the rules for v2 outbound integration.

Private DNS zones > Create `privatelink.documents.azure.com` and
`privatelink.blob.core.windows.net`. For each: Virtual network links > Add >
select caller VNet > auto-registration **Off**. Use existing authoritative zones
where supplied by the network team; do not link two competing zones for a namespace.
With custom DNS, arrange conditional forwarding through the customer's private DNS
resolver. Record zone/subnet **resource IDs**, not their names alone.

**Check:** Approved subnet delegations, NSG, routes and DNS links are visible.
Outbound rules must allow sync to `graph.microsoft.com`, reconciler to the approved
Log Analytics query endpoint (normally `api.loganalytics.io`), and each telemetry
app to its Application Insights ingestion endpoint. These are egress dependencies,
not values to invent as private DNS-zone IDs. Customer Azure Monitor Private Link
Scope designs require their own corresponding DNS/endpoints.

## 04. Workspace and Application Insights

**UI:** Log Analytics workspaces > Create > approved RG/region/name. Usage and
estimated costs > Data retention > approved period. Properties > record **Workspace ID**
(customer ID GUID) and **Resource ID**; they are different.

Application Insights > Create, once for resolver and once for sync >
workspace-based resource > select that LAW. Disable local authentication under
the available Properties/settings control. Overview > copy each Connection String
and Application ID into the private record. If the tenant UI omits the local-auth
control, an administrator must set the resource's `DisableLocalAuth` property using
the supported management API; do not leave it enabled silently.

The baseline reconciler uses LAW diagnostic logs, not another Insights component.
Do not invent a third connection string or populate its evidence `appInsightsId`.

**Check:** Both Insights resources reference the intended workspace. Connection
strings stay in the private evidence file; generated configuration is never committed.

## 05. Create sync and reconciler identities

**UI:** Managed identities > Create > approved subscription/RG/region/name.
Create one identity for sync and one for reconciler. Overview > record **Client ID**,
**Principal/Object ID**, and **Resource ID** separately.

**Check:** Two user-assigned identities exist. No client secret is needed. Do not
use their client ID where a role-assignment principal/object ID is requested.

## 06. Entra applications and classification groups

**UI:** Entra admin center > Identity > Applications > App registrations > New registration.
Default is **two registrations**, not one per project/classification.

| Registration | UI settings |
|---|---|
| Combined Gateway API + developer sign-in | Single tenant. Expose an API > `api://<client-id>` > enabled scope `access_as_user`, consent according to tenant policy. Manifest > `api.requestedAccessTokenVersion` = `2`. Authentication > Mobile and desktop applications: `http://localhost`, `https://login.microsoftonline.com/common/oauth2/nativeclient`, `ms-appx-web://Microsoft.AAD.BrokerPlugin/<client-id>`. Allow public client flows only if approved device-code use needs it. No secret; no implicit grants. |
| Resolver API | Another single-tenant registration. Expose an API > URI `api://<resolver-client-id>`; Manifest token version `2`. No delegated scope, redirect URI or secret. Its client ID must differ from the gateway/developer app. |

Apply tenant consent/preauthorization and Conditional Access requirements; combined-app
token-to-self is not a blanket consent exemption. Legacy separate developer/gateway
registrations are supported by [prerequisites](../QUICKSTART-PREREQUISITES.md).

Entra > Groups > All groups > New group > **Security**, **Assigned** membership >
approved display name > Owners > initial test members. Create STD, PRM and CYB
only where approved. Record each group's **Object ID**.

Each `(projectId, classification)` has its own explicit entry and group ID.
A project name does not infer three groups. Example: `projectId = SAMPLE01`,
with separate STD/PRM/CYB entries. Every classification of that project uses the
same registered `backendId`; different projects can use different backends.
Group display names are labels, not IDs or authorization.

**Check:** Two different app IDs, correct URI/scope/manifest/redirects, owned security
groups, real member(s) for the acceptance test. An empty group cannot pass user access.

## 07. Foundry account, deployments and gateway grant

**UI:** Use the customer's approved Foundry portal > resource/project >
Models + endpoints / Deployments > deploy each licensed, available Claude model.
Record the exact **deployment ID**, account's resource ID, endpoint, and approved
inference geography. A model catalog name is not necessarily a deployment ID.
Check subscription/model quota; the gateway cannot manufacture Foundry capacity.

Azure Portal > Foundry/Cognitive Services account > Networking > Private endpoint
connections. Create/connect its private endpoint from the approved network and
have the backend owner approve it. Follow the endpoint's offered DNS zone-group
configuration and [network guide](../NETWORK.md); do not substitute the Cosmos zone.
Private DNS and routes must work from APIM's outbound network.

After module 11, Foundry account > Access control (IAM) > Add role assignment >
**Cognitive Services User** > Managed identity > API Management > intended APIM >
Review + assign. Repeat for every same-tenant Foundry backend at that account scope.
Do not grant the app Owner, and do not use an account key.

**Check:** Exact deployments exist, connection Approved, backend caller route works,
and account-scoped assignment names APIM's **principal** ID. Cross-tenant backends
require their separate credential/Key Vault design; this same-tenant grant is not a substitute.

## 08. Cosmos DB account, database and eight containers

**UI:** Azure Cosmos DB > Create > Azure Cosmos DB for NoSQL.
Basics > approved account/name/region/capacity mode. Security > Key-based
authentication **Disabled**. Networking > private endpoint on the PE subnet >
integrate with `privatelink.documents.azure.com`; public network access **Disabled**.
Availability/zones/throughput follow the approved decision.

Account > Data Explorer > New database > approved database ID. For serverless,
do not add provisioned RU/s. For provisioned shared autoscale, set the approved
database-level maximum; avoid accidentally assigning throughput to all containers.
New container > existing database > create each below. Partition keys are case-sensitive
and cannot be changed in place.

| Container | Partition key |
|---|---|
| entitlement | `/personId` |
| projects | `/projectId` |
| subscriptionIndex | `/subscriptionId` |
| budgetState | `/personId` |
| aggregateBudgetState | `/scopeId` |
| syncLease | `/id` |
| reconcilerLease | `/id` |
| backends | `/backendId` |

**Private Data Explorer boundary:** browser/operator network and native Cosmos
data permissions must be sufficient. Azure IAM Contributor is not a native SQL data
role. If Data Explorer cannot create schema under the customer's private/keyless
policy, use the short **management-plane** fallback below after module 13. It does
not enable public access or keys; item seeding remains inside the Function App.

```powershell
# Necessary only when Data Explorer cannot create the private/keyless schema.
# Serverless example; provisioned mode needs its reviewed database throughput settings.
az cosmosdb sql database create --subscription $sub -g $rg -a $p.names.cosmosAccount -n $p.names.cosmosDatabase -o none
if ($LASTEXITCODE) { throw 'database creation failed; inspect the error' }
Import-Module ./scripts/Core.D2Steps.psm1
$containers = Get-CoreCosmosContainers
foreach ($name in $containers.Keys) {
    az cosmosdb sql container create --subscription $sub -g $rg -a $p.names.cosmosAccount `
        -d $p.names.cosmosDatabase -n $name --partition-key-path $containers[$name] -o none
    if ($LASTEXITCODE) { throw "container creation failed: $name" }
}
```

**Check:** Account private/keyless, endpoint Approved, database and all eight partition
keys correct. Do not rename a database on a resume: existing SQL assignment scopes
are not an in-place migration.

## 09. Storage accounts and deployment containers

**UI:** Storage accounts > Create, once for each Function App.
StorageV2, approved LRS/ZRS, TLS 1.2 minimum; Advanced > shared-key access **Disabled**,
anonymous blob access **Disabled**. Networking > public access **Disabled** >
private endpoint for **blob**, PE subnet, `privatelink.blob.core.windows.net`.

Data storage > Containers > + Container > exact approved deployment-container name >
private access. Data-plane container creation through the UI requires operator
Storage Blob Data permissions and a permitted network path. If that UI is blocked,
ask the storage owner to create the container over their approved private path,
or use the blob container management resource through **Resource Explorer**.
Do not enable keys/public networking. The app access helper is not an operator-role grant.

**Check:** Three accounts and three deployment containers, each matching its app.
Private endpoint connections Approved and private DNS records present. Blob-only
storage connectivity matches this repository's Flex host/runtime contracts; changing
hosting plan/triggers can introduce additional storage dependencies.

## 10. Create and connect the three Function Apps

**UI:** Function App > Create > **Flex Consumption** > Linux > **Node.js 22**.
Create resolver, sync and reconciler sequentially, not parallel subnet joins.
Pick the approved memory/max instances/always-ready settings and existing storage.
Networking > outbound VNet integration > Functions subnet.

Authentication/Identity wizard: choose managed-identity storage, not a connection string.
Current wizards can create an extra user-assigned identity automatically. Inspect the
result and explicitly align it with this repository:

| App | Runtime/deployment identity | Monitoring |
|---|---|---|
| resolver | System-assigned identity On; record principal ID; deployment auth SystemAssignedIdentity | Resolver Insights from module 04 |
| sync | Attach approved sync UAMI; host settings select its client ID; deployment auth UserAssignedIdentity using its resource ID | Sync Insights |
| reconciler | Attach approved reconciler UAMI; host settings select its client ID; deployment auth UserAssignedIdentity using its resource ID | LAW diagnostics, module 20 |

App > Settings > Identity: turn on/attach the intended identity. Configure deployment
storage via the app's Deployment settings control where offered: own storage/container
and correct managed identity. If the UI does not expose this choice, use only this
deployment-storage command after module 13 (repeat with the right app):

```powershell
$app = 'resolver'
az functionapp deployment config set --subscription $sub -g $rg -n $p.names.apps[$app].functionApp `
    --deployment-storage-name $p.names.apps[$app].storageAccount `
    --deployment-storage-container-name $p.names.apps[$app].deploymentContainer `
    --deployment-storage-auth-type SystemAssignedIdentity -o none
if ($LASTEXITCODE) { throw 'resolver deployment-storage configuration failed' }
# Sync/reconciler use the actual attached UAMI resource ID, not its client ID:
$app = 'sync'
$identityResourceId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($p.names.identities[$app])"
az functionapp deployment config set --subscription $sub -g $rg -n $p.names.apps[$app].functionApp `
    --deployment-storage-name $p.names.apps[$app].storageAccount `
    --deployment-storage-container-name $p.names.apps[$app].deploymentContainer `
    --deployment-storage-auth-type UserAssignedIdentity --deployment-storage-auth-value $identityResourceId -o none
if ($LASTEXITCODE) { throw 'sync deployment-storage configuration failed' }
# Repeat the second block with $app = 'reconciler'.
```

Disable timers before code deployment in module 17. Remove obsolete key-based
`AzureWebJobsStorage` configuration once identity-based host configuration is saved;
do not retain both mechanisms ambiguously. No `WEBSITE_RUN_FROM_PACKAGE` workaround
or classic Consumption app replaces Flex.

**Check:** Runtime, plan, app identity, subnet, deployment container and MI selector
all correct. A portal-added storage grant may already exist; module 15 verifies/reuses it.
For required private resolver ingress, complete module 12 before disabling its public access.

## 11. API Management

**UI:** API Management services > Create, or open the approved existing instance.
Select the approved **Standard v2/Premium v2** tier, units, publisher and zones.
Basic v2 does not offer the outbound VNet integration used here. Do not change a
customer's existing tier/topology without approval.

APIM > Network / Virtual network > outbound integration > dedicated APIM subnet >
Apply. Security > Managed identities > System assigned > **On** > Save. Record the
principal/object ID. APIM Overview > Gateway URL; Properties/JSON view > resource ID.
Entra > Enterprise applications > include managed identities/application-type filter >
locate that object ID > record its **Application ID** (managed-identity client ID).

If the UI cannot find it, this read-only CLI lookup is sufficient:

```powershell
az ad sp show --id $e.apim.principalId --query appId -o tsv
if ($LASTEXITCODE) { throw 'APIM managed-identity client ID could not be read' }
```

**Check:** APIM Succeeded, correct outbound subnet, system identity On. Return to
module 07 for its Foundry grants. Do not run `az apim update` as an identity shortcut.
Outbound integration alone **does not make gateway ingress private**; preserve the
customer's approved WAF/private-endpoint/edge controls.

## 12. Private resolver ingress and network acceptance

**UI:** Resolver Function App > Networking > Inbound traffic > Private endpoints >
Add > PE subnet > supported `sites` subresource and DNS integration, normally
`privatelink.azurewebsites.net`. Link the offered zone to APIM's caller network.
Customer-approved public-access disable/access-restriction controls follow their
ingress design. Restrict the sync/reconciler inbound surfaces according to that design
too; their outbound VNet integration is not an inbound firewall.

For private publishing, plan access to the deployment/SCM endpoint as well as the
runtime endpoint. Ordinary Cloud Shell may fail to publish to a private-only app.
Use the customer's approved network-connected workstation/runner instead; do not
turn public access back on.

**Check:** From the actual caller networks, Cosmos/blob/resolver/Foundry names resolve
and route to approved private destinations. DNS-zone existence is not proof of caller
DNS. APIM can reach resolver HTTPS; Functions can reach private Cosmos/blob and
their approved Graph/Monitor egress.

## 13. Record values once; reload after each shell reconnect

The existing parameter **form is only a structured configuration input here**.
Retain its `using 'main.bicep'` reference for local compilation; no template is deployed.
Copy it to a private `.env` file and fill actual names/IDs even for manually created resources.
Set `runner.enabled=false`, `sync.mode='application-permission'`,
`syncTimerEnabled=false`, `reconciler.timerEnabled=false`. Use the real existing
network IDs, real resource names, exact models and explicit classification/backend entries.
Give the customer control of region, CIDRs, rates, capacity and settings.

Open Cloud Shell **PowerShell**, not Bash, or use PowerShell 7 on the approved workstation.
Choose a reviewed repository commit containing this guide; do not execute an arbitrary future
`main` without review. Local artifact rendering runs TypeScript directly and requires a Node
version with the repository's supported native TypeScript handling (Node 26 used by release tests);
deployed Function Apps remain Node 22. `node --version`, `pwsh --version`, `az version` identify
the actual tools. If Cloud Shell lacks the needed Node version, build locally/CI and upload the
reviewed artifacts rather than changing global machine settings.

```powershell
# First time only, from the repository root. Do not overwrite an existing private form.
Copy-Item ./infra/quickstart/customer-form.bicepparam ./infra/quickstart/.env.portal.bicepparam
Copy-Item ./scripts/portal/evidence.example.json ./.env.portal-evidence.json
# Edit both copies with the Cloud Shell editor or your approved local editor.
```

Evidence file: copy Resource ID from each resource's **Properties / JSON view**,
LAW Workspace ID from Properties, MI IDs from Identity/Managed identities,
APIM Gateway URL from Overview and gateway Application ID URI from Expose an API.
Keep resolver `clientId` empty; sync/reconciler use their UAMI client IDs.
Copy the resolver's actual **Default domain** from its app Overview into
`apps.resolver.defaultHostName`; do not infer it from the app name when Azure adds
a unique hostname suffix.
Leave reconciler `appInsightsId` empty for the baseline configuration.
Cosmos evidence URI uses `https://<account>.documents.azure.com:443/`.

```powershell
# Run in every new session, from the restored repository root:
$ErrorActionPreference = 'Stop'
$form = './infra/quickstart/.env.portal.bicepparam'
$evidenceFile = './.env.portal-evidence.json'
$artifacts = './.env.portal-artifacts'
$e = Get-Content $evidenceFile -Raw | ConvertFrom-Json -AsHashtable -Depth 100
$compiled = az bicep build-params --file $form --stdout | ConvertFrom-Json -Depth 100
if ($LASTEXITCODE) { throw 'private form did not compile' }
$values = ($compiled.parametersJson | ConvertFrom-Json -AsHashtable -Depth 100).parameters
$p = @{}; foreach ($key in $values.Keys) { $p[$key] = $values[$key].value }
$sub = $p.names.subscriptionId
$rg = $p.names.resourceGroup
az account set --subscription $sub
if ($LASTEXITCODE) { throw 'subscription selection failed' }
$account = az account show -o json | ConvertFrom-Json
if ($LASTEXITCODE -or $account.tenantId -ine $p.tenantId) { throw 'wrong tenant; sign in to the approved tenant' }
```

**Check:** No unresolved placeholders, correct tenant/subscription, actual resource
names and IDs. Do not publish either private file or the generated artifacts.

## 14. Generate UI configuration artifacts, without deploying

```powershell
# Dependencies only on first checkout or lockfile change:
npm ci --ignore-scripts --no-audit --no-fund
if ($LASTEXITCODE) { throw 'dependency restore failed' }
pwsh -NoProfile -File ./scripts/portal/Export-PortalArtifacts.ps1 `
    -ParametersPath $form -EvidencePath $evidenceFile -OutputDirectory $artifacts
if ($LASTEXITCODE) { throw 'artifact export failed; do not apply partial output' }
```

This calls shared **pure configuration/schema helpers**, not Quickstart's deploy,
state/resume dispatcher, Azure discovery, seed execution or code publication.
`az bicep build-params` is local compilation. Review each file:

| Artifact | UI destination |
|---|---|
| `resolver-settings.json`, `sync-settings.json`, `reconciler-settings.json` | Function App > Environment variables > App settings > Advanced edit |
| `gateway-config.json` | Private review record for gateway renderer inputs |
| `gateway/<apiId>.policy.xml` | APIM API > Design > All operations > Inbound policy code editor |
| `registry-documents.json` | Review one project per ID, explicit classifications and backend descriptors |
| `seed-payload.txt`, `seed-id.txt` | Temporary sync seed settings / correlation ID in module 21 |
| `chargeback.workbook.json` | LAW > Workbooks > New > Advanced Editor |

**Check:** Export exits 0. Exact model/family limits and routing agree with the approved
form. Budget amount alone does not enforce a dollar ceiling. `token-limits-only`
enforces token quotas/TPM, not cost-weighted cached usage. `budget-state` adds delayed
reconciler-based budget enforcement only after telemetry and its timer work.
See [chargeback](../CHARGEBACK.md); cached-cost assumptions are estimates, not guarantees.
Do not treat individual family caps as permission to exceed the aggregate cap.

## 15. Administrator grants app access, one app at a time

**Meaning of "automatic admin grant":** an authorized administrator applies a reviewed
runtime-access plan to an existing managed identity. The app does **not** become an
admin, request its own consent, use a secret, or bypass PIM.

Azure IAM parts can be done entirely in UI:
resource > Access control (IAM) > Add role assignment > role > Managed identity >
select the intended Function App system identity or UAMI > Review + assign.

| Identity | Role | Scope |
|---|---|---|
| Each app | Storage Blob Data Owner | Its own host/deployment storage account |
| Resolver and sync | Monitoring Metrics Publisher | Its own Application Insights component |
| Reconciler | Log Analytics Reader | The ledger LAW |
| APIM | Cognitive Services User | Each approved same-tenant Foundry account (module 07) |

Cosmos **native SQL** role definitions/assignments are distinct from Azure IAM.
Use the necessary helper below; it also verifies/reuses the Azure IAM grants above.
Choose one `$app`, review its plan, then authorize that app's `-Apply` only:

```powershell
$app = 'resolver'  # Then repeat these two commands with 'sync', then 'reconciler'.
pwsh -NoProfile -File ./scripts/portal/Grant-PortalAppAccess.ps1 `
    -ParametersPath $form -EvidencePath $evidenceFile -App $app -OutputDirectory $artifacts
if ($LASTEXITCODE) { throw 'access plan failed; nothing should be applied' }

# WRITE: run only after the responsible access administrator reviewed this plan:
pwsh -NoProfile -File ./scripts/portal/Grant-PortalAppAccess.ps1 `
    -ParametersPath $form -EvidencePath $evidenceFile -App $app -OutputDirectory $artifacts -Apply
if ($LASTEXITCODE) { throw 'access grant not verified; inspect the receipt and fix this app only' }
```

| Cosmos identity | Native data access |
|---|---|
| Resolver | Built-in Data Reader on the registry database |
| Sync | Custom read/create/replace writer on entitlement and syncLease; projects reader; create-only seed writer on projects and backends |
| Reconciler | projects/entitlement reader; custom read/create/replace/upsert writer on budgetState, aggregateBudgetState and reconcilerLease |

The helper discovers no new resources, grants no Graph permissions, changes no settings
and publishes no code. It checks the app's **live attached identity** against the UI record,
checks the operator's assignment rights before writes, uses shared staged-D3 permission
definitions, and verifies grants. Existing grants are reused. Existing custom roles
with different actions are refused, not overwritten. Do not add Owner/Contributor
or broad Cosmos Data Contributor as a shortcut.

**Check:** `<app>-access-receipt.json` has only created/existing/inherited results.
Save receipts and `<app>-access-audit.json` privately. A timeout is unverified, not
success; inspect current role assignments and rerun the **same app**. Role propagation
can delay runtime access even after management read-back.

## 16. Graph permissions: a separate privileged approval

A managed identity has no ordinary app-registration API-permissions page where
you can configure these Graph application roles. The Entra privileged administrator
activates PIM, refreshes their sign-in if needed, and runs this existing narrow helper
with the **sync identity's principal/object ID**. No Quickstart state file is needed.

```powershell
pwsh -NoProfile -File ./infra/quickstart/Grant-SyncGraphPermissions.ps1 `
    -SyncPrincipalId $e.apps.sync.principalId -PlanOnly
if ($LASTEXITCODE) { throw 'Graph permission plan failed' }

# WRITE: Entra privileged administrator, after explicit approval:
pwsh -NoProfile -File ./infra/quickstart/Grant-SyncGraphPermissions.ps1 `
    -SyncPrincipalId $e.apps.sync.principalId
if ($LASTEXITCODE) { throw 'Graph grant failed; keep sync disabled' }
```

The helper resolves and verifies `GroupMember.Read.All`, `User.Read.All`,
`Application.Read.All`, skips existing assignments, and prints assignment-specific
rollback commands. Its final message mentions Quickstart; **ignore that deployment
instruction on this path**. Module 21 enables the timer in the UI instead.

**Check:** All three assignments verified. Managed-identity token caches can delay
new permissions; restarting is not a promise of immediate Graph propagation.
Do not swap to `Directory.ReadWrite.All`, create a secret or give the MI an Entra admin role.

## 17. Apply settings and lock the resolver to APIM

**UI:** Each Function App > Settings > Environment variables > App settings.
Export/back up existing settings privately first. Advanced edit > merge the corresponding
generated settings with the existing customer-owned settings > Apply. Do not blindly
replace the whole list or erase unrelated settings. Generated values are strings.

Check identity-based `AzureWebJobsStorage__accountName`, `__credential=managedidentity`;
sync/reconciler also have `__clientId`. Check `COSMOS_ENDPOINT`, `COSMOS_DATABASE`,
`CCOF_APP_ROLE`, the correct Insights connection/authentication settings and all
generated resolver/sync/reconciler parameters. Reconciler workspace setting is
the LAW **Workspace ID GUID**, not an ARM resource ID.

Before uploading code, confirm:

| App setting | Initial value |
|---|---|
| `AzureWebJobs.syncEntitlement.Disabled` | `true` on sync |
| `AzureWebJobs.registrySeed.Disabled` | `true` on sync |
| `AzureWebJobs.reconcileBudgets.Disabled` | `true` on reconciler |

Resolver > Settings > Authentication > Add identity provider > Microsoft >
existing Resolver API registration, current workforce tenant. Require authentication,
HTTP **401** unauthenticated action, HTTPS, issuer
`https://login.microsoftonline.com/<tenant-id>/v2.0`, audiences
`api://<resolver-app-id>` and `<resolver-app-id>`. Token store Off. Under identity
provider validation, **Allowed client applications** = APIM managed-identity app ID
and **Allowed identities** = APIM managed-identity principal/object ID. No excluded
path or empty allow-list. Do not select automatic app registration/browser login.

If the UI cannot expose both allow-lists, the necessary **auth-only** exception is:

```powershell
pwsh -NoProfile -File ./infra/poc/resolver-auth.ps1 -TenantId $p.tenantId `
    -SubscriptionId $sub -ResourceGroup $rg -FunctionAppName $p.names.apps.resolver.functionApp `
    -ResolverAppId $p.registrations.resolverApi.appId `
    -AllowedCallerAppIds $e.apim.appId -AllowedCallerObjectIds $e.apim.principalId
if ($LASTEXITCODE) { throw 'resolver authentication configuration failed' }
```

**Check:** App settings saved; timers disabled; Authentication settings restrict both
APIM identity claims. Resolver anonymous call from an allowed network returns 401.
A network-level denial is a different result, not proof that authentication works.

## 18. Build and publish one app's code

**Why a small code step is necessary:** creating a Function App resource does not
install the repository's compiled code, dependencies, host.json or reconciler ledger/rate
files. Do not paste a standalone function into the portal and assume it is the full app.
Use the per-app packager; no all-resources deployment is involved.

```powershell
$app = 'resolver'  # Repeat with 'sync', then 'reconciler'.
pwsh -NoProfile -File ./scripts/portal/Build-PortalPackage.ps1 -App $app -OutputDirectory $artifacts
if ($LASTEXITCODE) { throw 'local package build failed' }
```

For the reconciler, review the packaged rate card and contract schedule; override
`-RateCardPath` and `-ContractSchedulePath` with approved private files when required.
Keep rate-card inputs consistent with the workbook artifact. Do not publish unreviewed
prices or mistake list-price reporting for negotiated Azure billing.

**GUI publishing option:** on a network-connected workstation, open that app's
generated `packages/<app>` folder in VS Code (not the root multi-app repository),
install/use the approved Azure Functions extension, sign in, then Command Palette >
Azure Functions: Deploy to Function App > select the **existing intended app** >
confirm code overwrite. Review output. If the extension/build path is unsuitable,
use this single upload from Cloud Shell or the approved workstation:

```powershell
# WRITE: publishes code only; storage/IAM/network/settings must already be ready.
az functionapp deployment source config-zip --subscription $sub -g $rg `
    -n $p.names.apps[$app].functionApp --src (Join-Path $artifacts "$app.zip") -o none
if ($LASTEXITCODE) { throw "code upload failed or timed out: $app; inspect deployment status before retrying" }
az functionapp function list --subscription $sub -g $rg -n $p.names.apps[$app].functionApp -o table
if ($LASTEXITCODE) { throw "function discovery failed: $app" }
```

**Check:** Correct app's Functions blade lists its handlers; runtime logs contain no
storage/identity/startup errors. Package SHA-256 recorded. Empty function list is not success.
Only the resolver package runs resolver handlers, sync runs sync/seed handlers, and
reconciler runs reconciler handlers. A code upload overwrites that app's previous code;
retain the previous reviewed ZIP for rollback.

## 19. Create the API, operation, backend entities and policy

**UI:** APIM > APIs > Add API > HTTP / manually define.
API identifier = form `apim.apiId`, URL suffix = `apim.apiPath`, display name =
`apim.apiDisplayName`, HTTPS. Settings > Subscription required **Off**; Entra
validation in the rendered policy supplies developer authentication, not a subscription key.

API > Design > Add operation: identifier `create-message`, display name Create message,
**POST**, URL `/v1/messages`. Save. APIM > Backends > Add each backend:
identifier exactly matches its registry `backendId`, URL exactly the approved
Foundry descriptor URL ending `/anthropic`, HTTP protocol with HTTPS URL, TLS
certificate chain/name validation On. Do not add a secret for same-tenant MI.

API > Design > All operations > policy code editor > paste **the entire generated**
`gateway/<apiId>.policy.xml` > Save. Do not paste the unrendered template or remove
token validation/limit/cache/telemetry policy sections. Use a new API revision for a
change to an existing live API, test it, then Revisions > Make current.

**Check:** Correct API URL, POST operation, backend identifiers, intended policy and
no unresolved placeholder. An unknown model/backend/project must fail closed, not
fall through to a default backend.

## 20. Diagnostics and complete chargeback workbook

**UI:** APIM > Monitoring > Diagnostic settings > Add > enable **GatewayLogs**
and **GatewayLlmLogs** > Send to Log Analytics workspace > intended LAW >
resource-specific tables where offered > Save.

API > Settings > Diagnostics > Azure Monitor: enable; all errors; sampling 100%;
verbosity information; client IP logging Off; request/response payload byte count 0
and no sensitive header logging for frontend/backend. Enable **large language model
logs** where the UI offers it. Do not enable prompt/response bodies.
APIM resource diagnostics and **API diagnostics are separate controls**.

For each Function App > Monitoring > Diagnostic settings > enable **FunctionAppLogs**
> same LAW > Save. Resolver/sync also use their Insights resources.

If the UI does not expose APIM's LLM API diagnostic setting, deploy only the reviewed
telemetry child-resource module; it does not create the core infrastructure:

```powershell
# Necessary only for missing telemetry UI controls. Review these child-resource writes.
az deployment group create --subscription $p.apim.subscriptionId -g $p.apim.resourceGroup `
    --name "$($p.names.deploymentPrefix)-portal-telemetry" `
    --template-file ./infra/poc/phase4-apim-telemetry.bicep `
    --parameters workspaceResourceId=$e.workspace.id apimServiceName=$p.apim.name `
    apiName=$p.apim.apiId location=$p.location enableAlerts=false -o none
if ($LASTEXITCODE) { throw 'telemetry child configuration failed' }
```

LAW > Workbooks > New > Edit > Advanced Editor > replace the notebook JSON with
`chargeback.workbook.json` > Apply > Done editing > Save in the approved RG/name/location.
Record the **actual saved workbook Resource ID**; the Portal can allocate a different
GUID than the form's candidate. Do not create/redeploy an empty workbook shell over this content.
Grant intended readers Workbook Reader on the saved workbook and Log Analytics Reader on LAW.

**Check:** After a synthetic authorized request and ingestion delay, LAW Logs has
`ApiManagementGatewayLogs`, `ApiManagementGatewayLlmLog` and `FunctionAppLogs`
observations. Workbook shows real query results or an explicit no-data/unpriced state.
Absence of logs blocks budget-state enforcement and chargeback acceptance.

## 21. Seed the registry inside the VNet, then enable approved timers

Do not use ordinary Cloud Shell to write private Cosmos items. The deployed sync
app can do create-only seeding using its managed identity and VNet integration.
Review `registry-documents.json` first: project IDs, classification group object IDs,
exact family models/limits, backend URLs/resource audience/geography and budgets.

**UI:** Sync Function App > Environment variables:
add `CCOF_SEED_DOCUMENTS` = **entire** `seed-payload.txt` value;
set `AzureWebJobs.registrySeed.Disabled=false`; save together.
Keep `AzureWebJobs.syncEntitlement.Disabled=true`.
If a payload exceeds the platform's setting limits, stop and use the reviewed
private-runner onboarding path; do not truncate it.

The seed handler is conditionally registered at startup. Ensure its trigger is synced
after this settings change. If the Functions blade lacks `registrySeed`, this necessary
short management call resynchronizes it:

```powershell
$syncSite = $e.apps.sync.functionAppId
az rest --method post --url "https://management.azure.com$syncSite/syncfunctiontriggers?api-version=2024-04-01" -o none
if ($LASTEXITCODE) { throw 'sync trigger synchronization failed' }
```

**UI:** Sync Insights > Logs > run, replacing the correlation ID with `seed-id.txt`:

```kusto
traces
| where timestamp > ago(1h)
| where message contains "ccof.seed.result"
| where message contains "REPLACE-seed-id-from-seed-id.txt"
| project timestamp, message
| order by timestamp desc
```

The result for that exact seed ID must cover every expected document as **created**
or **present-equal**. `present-differs`, failed/missing document, startup failure or
timeout is a stop: the seed does not overwrite differing documents. Use the approved
project-update/onboarding path for changes, not a delete-and-recreate shortcut.

**Mandatory cleanup even on failure/disconnect:** Sync > Environment variables >
`AzureWebJobs.registrySeed.Disabled=true` > delete `CCOF_SEED_DOCUMENTS` > Save.
If Cloud Shell closed, do this in the UI; no shell `finally` is relied upon.
Verify both controls. Do not regenerate/reapply another seed ID while an unresolved
seed is still enabled.

After verified seed, Graph grant and test group membership: set
`AzureWebJobs.syncEntitlement.Disabled=false` in UI. Confirm successful sync telemetry
and entitlement creation from an approved private data view. For `budget-state`,
only after verified usage logs/rate inputs/grants: set
`AzureWebJobs.reconcileBudgets.Disabled=false` and verify budget-state updates.
No timer should be enabled merely because the app resource exists.

**Check:** Seed verified and disabled/payload removed; sync has an actual successful
membership run. Reconciler and budget-state runtime proof are separate from seed success.

## 22. Client configuration and customer acceptance

Use [client configuration](../CLIENTS.md) and the strict `client/config.example.json`
shape. Fill only the approved gateway tenant/client/scope, gateway URL, selected
project header/ID and exact admitted aliases. Run the existing config validator on
the private file before handing it to a developer. This guide does not auto-select
the first project/backend or configure the Cloud Shell machine as the developer workstation.

```powershell
# On the developer workstation, with its reviewed private config:
node ./client/bin/validate-config.mjs './.env.onboarding.json'
if ($LASTEXITCODE) { throw 'client config invalid' }
pwsh -File ./scripts/client/Set-ClaudeCodeGateway.ps1 -ConfigPath './.env.onboarding.json' -Confirmed
```

Use an approved real test developer in the intended classification. Verify:
anonymous gateway request denied; authorized exact-model request succeeds;
unregistered model/project, disallowed classification/family and wrong resolver
caller denied; a small controlled quota/rate threshold behaves as configured;
cache accounting/telemetry and budget-state delay behave as documented.
Verify silent sign-in refresh and membership-removal behavior separately.
Test requests can incur Foundry charges; get approval before traffic.

**Final acceptance:** require authenticated end-to-end evidence, correct routing,
entitlement, limits, logs and reporting. A 401 smoke response, ARM Succeeded, a green
offline test or a saved workbook alone is not proof of a working customer deployment.

## Troubleshooting and handoff

| Symptom | Next action; do not weaken controls |
|---|---|
| Cloud Shell disconnected | Restore inputs/artifacts; inspect Azure operation; resume this module only |
| Portal wizard requests keys/extra identities | Choose managed identity; align host/deployment identity; use the narrow deployment-config command if needed |
| Private Data Explorer cannot open | Check client network/native data RBAC; use management-plane schema fallback or approved private operator |
| Function deployment cannot reach SCM | Publish from approved private-connected workstation/runner |
| Access helper refuses evidence | Correct the actual resource/principal/client IDs; do not bypass the validator |
| Custom role differs | Reviewed role migration or new role name; no automatic rewrite |
| Cosmos 403 | Native SQL grant, propagation and selected identity; IAM Owner is not data access |
| Graph 403 | Separate Entra app-role consent and cached tokens; leave sync disabled |
| Resolver 403 for APIM | Check resolver audience, APIM client AND object allow-lists |
| No registrySeed function | Payload/disabled setting saved, correct sync ZIP, trigger resync, host logs |
| Seed present-differs | Correct configuration or reviewed update; no overwrite/delete workaround |
| No LLM ledger | Both APIM resource and API diagnostics, correct LAW, ingestion delay |
| Budget not blocking | Check enforcement mode, reconciler/ledger, freshness and documented delay; token caps are not dollar caps |

Rollback is module-specific: restore the previous reviewed code ZIP, previous UI
settings, previous API revision; remove only the exact newly authorized assignments
using their receipts. Do not delete Cosmos data or an entire RG to recover a partial step.
Record the blocked module, current Azure state and next owner.

## Sources and validation boundary

Official documentation consulted 2026-10-14:

- [Flex creation, managed identities, VNet integration and deployment](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-how-to)
- [Deployment-storage configuration CLI](https://learn.microsoft.com/en-us/cli/azure/functionapp/deployment/config)
- [APIM v2 outbound networking](https://learn.microsoft.com/en-us/azure/api-management/integrate-vnet-outbound)
- [Cosmos management and native data RBAC](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-connect-role-based-access-control)
- [Resolver Authentication controls](https://learn.microsoft.com/en-us/azure/app-service/configure-authentication-provider-aad)

Repository contracts: `infra/prereqs/function-app.bicep`,
`infra/quickstart/modules/app-settings.bicep`, `infra/quickstart/modules/cosmos-data.bicep`,
`scripts/Core.D2Steps.psm1`, `scripts/Core.D2Code.psm1`, staged D3 assignment data,
`infra/poc/phase4-apim-telemetry.bicep`, `infra/poc/resolver-auth.ps1`,
`src/sync/registry-seed.ts`. The exporter imports shared pure Quickstart helpers
with `-DotSourceOnly`; it never executes their dispatcher.

Screenshots are **not included or claimed captured**. Use the exact UI paths and
record sanitized screenshots during customer execution. This repository contains
no private tenant/subscription/group values, customer screenshots or completed
customer deployment evidence.
