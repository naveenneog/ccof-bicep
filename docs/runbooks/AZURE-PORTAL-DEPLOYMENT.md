# Azure Portal-first deployment workbook

**Create and connect resources in the UI. Deploy application code separately.**

> **Screenshots are being added.** Each step has a `Screenshot:` slot: an image link under
> `./images/portal/` with a `screenshot pending` comment marks where a sanitized lab-tenant capture
> will go. Until it lands, the image does not render; follow the **Where** path and field table.

## Quick path: where am I?

Answer the first question that applies, then jump to the listed step.

| Situation | Start at |
|---|---|
| Nothing deployed yet, Portal path | [Step 01.1](#step-011---activate-the-operator-roles-you-need) and continue in order |
| Nothing deployed yet, you prefer CLI for each step | Steps 13.1-13.5 first (load the form with *planned* names), then Step 01.1 |
| Quickstart steps 1-4 (`checks`, `build`, `deploy`, `code`) already **succeeded** | The ordered list in [Continuing in the UI after a partial Quickstart run](#continuing-in-the-ui-after-a-partial-quickstart-run) |
| Quickstart step 3 (`deploy`) never succeeded | Step 01.1, in order. Skip any step whose **Check** already passes on existing resources |
| Cloud Shell disconnected mid-way | Steps 13.4-13.5 (reload variables), then rerun only the unfinished step |

### Continuing in the UI after a partial Quickstart run

Quickstart steps map to modules. Its local state file does not matter here: check Azure, then
skip each module whose exit check already passes on the existing resources.

Quickstart never creates the prerequisites of modules **01**, **06** (Entra apps and groups),
**07** (Foundry account and deployments) or **11** (API Management); step 1 only reads them.

| Quickstart step | What it does in Azure | UI module |
|---|---|---|
| 1 checks | Reads only | 01, 06, 07, 11 (verify only) |
| 2 build | Nothing (local files, including the workbook content) | 14 |
| 3 deploy | Resource group (create mode); VNet and Cosmos/blob private DNS (network create mode only); LAW and resolver/sync Insights; sync/reconciler UAMIs; Cosmos account, private endpoint, database, containers and native SQL roles; storage, private endpoint and deployment container per app; three VNet-integrated Function Apps; app settings and resolver authentication; APIM API, operation, backends and policy; APIM and Function diagnostics; chargeback workbook; Azure IAM runtime grants; APIM Cognitive Services User on Foundry | 02 (RG), 03, 04, 05, 07 (grant only), 08, 09, 10, 15, 17, 19, 20 |
| 4 code | Publishes the three app packages | 18 |
| 5 seed | Creates the registry documents | 21 (seed part) |
| 6 graph-permission | Nothing: prints the admin command | 16 still required |
| 7 smoke | Reads only (anonymous gateway call returns 401) | 22 (partial) |
| 8 client | Nothing in Azure (local client configuration) | 22 |

Not created by Quickstart: the resolver's inbound private endpoint and
`privatelink.azurewebsites.net` zone (**12**), the Graph permissions (**16**), and the
sync timer (stays disabled until **16** is done; reconciler timer follows its parameter).

If step 3 (`deploy`) and step 4 (`code`) succeeded, do exactly these steps, in this order:

1. **Steps 13.1-13.6** private form plus evidence file (values from the existing resources;
   Step 13.6 can fill the evidence read-only from Azure). This loads `$p`, `$e`, `$sub`, `$rg`
   for every later CLI block.
2. **Verify, do not recreate:** RG > Deployments shows the quick-start deployment Succeeded
   (Step 02.2 **Check**); each Function App's Functions blade lists its handlers (Step 18.3
   **Check**); APIM API has the `create-message` operation and the rendered policy (Steps 19.2
   and 19.4 **Check**).
3. **Steps 12.1-12.6** resolver private endpoint and network acceptance. Later code republishing
   then needs the approved network-connected workstation or runner.
4. **Steps 14.1-14.3** generate artifacts (for `seed-payload.txt`, `seed-id.txt`, the workbook JSON).
5. **Step 15.2** run only the plan command per app: every grant must show existing; do not run
   Step 15.3 (`-Apply`) unless one is missing.
6. **Steps 16.1-16.3** Graph permissions (privileged admin).
7. **Step 21.1** first run the Logs query without the seed-ID line. If an earlier `ccof.seed.result`
   shows every document **created** or **present-equal**, skip Steps 21.2-21.4 and do only the
   cleanup check (Step 21.5) and timer enablement (Steps 21.6-21.7). Otherwise seed through
   Steps 21.2-21.5 as written.
8. **Step 20.6** verify logs arrive; **Steps 22.1-22.3** client and acceptance.

If step 3 never succeeded, follow the modules in order from 01.

## About this workbook

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

### How every step is written

| Part | Meaning |
|---|---|
| **Step NN.M** | One action. Do the steps of a module in order. |
| **Where:** | The Portal navigation path, then a table: **Field** (label in the UI), **Value** (what to enter), **Source of value** (where that value comes from: form `names.apps.resolver.functionApp` is that key in your private form from module 13; evidence `apps.sync.principalId` is that key in your private evidence file). |
| **Screenshot:** | Placeholder for a sanitized capture. |
| **CLI alternative:** | Cloud Shell **PowerShell** block that does the same with `az`. It uses `$p` (form), `$e` (evidence), `$sub`, `$rg`, `$artifacts` and the helpers loaded in Steps 13.4-13.5. Values you must change are on `# EDIT:` lines at the top as `<your-value>`; nothing else in the block needs editing. `# WRITE` marks a command that changes Azure or Entra. Every block stops on a non-zero `$LASTEXITCODE`. |
| **Check:** | How to verify in the UI, plus a read-only `az` command. Do not continue until it passes. |

Run each CLI block in a session where Steps 13.4-13.5 ran. CLI-first operators complete
Steps 13.1-13.5 before module 01 using the **planned** names; the evidence file fills in as
resources are created (Step 13.6 can refill it read-only at any time).

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
input files, reload the variables in module 13 (Steps 13.4-13.5), and run **only the
unfinished step**. The access helper is repeatable and recognizes existing grants.
Packages are independent per app. UI changes are persistent in Azure; there is no hidden
Quickstart resume state. A CLI `az deployment group create` that timed out in the shell
is still running in Azure: inspect **RG > Deployments** before rerunning it.

## 01. Decide names, capacity and operator access

Use [permissions](../PERMISSIONS.md) and customer role policy. Platform creation
needs Contributor at its target scope; Azure role grants need Role Based Access
Control Administrator/User Access Administrator or Owner at the relevant scope.
Creating Cosmos SQL roles needs the account's `sqlRoleDefinitions/write` and
`sqlRoleAssignments/write` management actions. Directory application/group work
requires the tenant's allowed user/owner rights or the appropriate directory role.
Granting Microsoft Graph **application** permissions requires an active Privileged
Role Administrator or Global Administrator; Azure Owner alone cannot do it.

#### Step 01.1 - Activate the operator roles you need

**Where:** Entra admin center > Identity governance > Privileged Identity Management > My roles >
Azure resources (or Microsoft Entra roles) > eligible role > **Activate**.

| Field | Value | Source of value |
|---|---|---|
| Role | Contributor; Role Based Access Control Administrator (or User Access Administrator / Owner) for grant steps | [permissions](../PERMISSIONS.md), customer role policy |
| Scope | Target subscription or platform resource group; APIM and Foundry scopes for their owners | Decision record (Step 01.3) |
| Duration / Reason | Customer policy; change or ticket reference | Customer approval process |

**Screenshot:**
![Step 01.1 - Activate PIM role](./images/portal/01-1-activate-pim-role.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** none. There is no `az` command for PIM activation; activate in the UI.

**Check:** PIM > My roles > **Active assignments** lists the role and scope. Read-only:

```powershell
# EDIT: target subscription ID (module 13 may not have loaded $sub yet).
$targetSub = '<your-subscription-id>'
$me = az ad signed-in-user show --query id -o tsv
if ($LASTEXITCODE) { throw 'cannot read the signed-in user' }
az role assignment list --assignee $me --all --include-inherited --subscription $targetSub `
    --query '[].{role:roleDefinitionName,scope:scope}' -o table
if ($LASTEXITCODE) { throw 'role assignment listing failed' }
```

#### Step 01.2 - Confirm your access at each target scope

**Where:** Portal > Subscriptions > *subscription* > Access control (IAM) > **Check access** >
**View my access**. Repeat on the APIM resource group and each Foundry account.

| Field | Value | Source of value |
|---|---|---|
| Expected roles | Contributor plus an RBAC-granting role where you grant (modules 07, 15, 20) | Step 01.1 |

**Screenshot:**
![Step 01.2 - View my access](./images/portal/01-2-view-my-access.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** read-only.

```powershell
# EDIT: scope to inspect (subscription, resource group or resource ID).
$scope = '/subscriptions/<your-subscription-id>/resourceGroups/<your-resource-group>'
$me = az ad signed-in-user show --query id -o tsv
if ($LASTEXITCODE) { throw 'cannot read the signed-in user' }
az role assignment list --assignee $me --scope $scope --include-inherited `
    --query '[].{role:roleDefinitionName,scope:scope}' -o table
if ($LASTEXITCODE) { throw 'role assignment listing failed' }
```

**Check:** Each required role appears with an active (not only eligible) assignment.

#### Step 01.3 - Record and approve the decisions

**Where:** Your private copy of this checklist (approved private location). No Portal action.

| Field | Value | Source of value |
|---|---|---|
| Tenant ID, target subscription, platform RG, region | Approved values | Customer owners |
| APIM subscription/RG/name; Foundry account IDs; model IDs; inference geography | Approved values | Gateway and backend owners |
| VNet/address space/subnets; DNS ownership | Nonoverlapping customer CIDRs | Network team |
| RU capacity; storage redundancy; app memory/max instances/always-ready; log retention | Approved values | [prerequisite sizing workbook](../PREREQUISITES-WORKBOOK.md) |
| Budget enforcement choice | `token-limits-only` or `budget-state` | [chargeback](../CHARGEBACK.md) |

Record tenant ID, target subscription, platform RG, region, APIM subscription/RG,
Foundry account IDs, approved VNet/address space/subnets, DNS ownership, RU capacity,
storage redundancy, app memory/max instances/always-ready counts, log retention,
model IDs, inference geography and budget enforcement choice. Values in examples
are not capacity or price recommendations.

**Screenshot:** not applicable (no Portal page).

**CLI alternative:** none; this is a decision record. Step 13.3 copies these values into the form.

**Check:** The responsible owner approves every decision. A restricted tenant does
not justify weakening authentication or private networking.

## 02. Register providers and create the resource group

#### Step 02.1 - Register the resource providers

**Where:** Portal > Subscriptions > *subscription* > Settings > **Resource providers** > select
each provider below > **Register**.

| Field | Value | Source of value |
|---|---|---|
| Provider | `Microsoft.ApiManagement`, `Microsoft.Web`, `Microsoft.App`, `Microsoft.DocumentDB`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.ManagedIdentity`, `Microsoft.OperationalInsights`, `Microsoft.Insights` | This guide |
| Subscription | Target subscription | form `names.subscriptionId` |

**Screenshot:**
![Step 02.1 - Register resource providers](./images/portal/02-1-register-providers.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
$providers = 'Microsoft.ApiManagement', 'Microsoft.Web', 'Microsoft.App', 'Microsoft.DocumentDB',
    'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.ManagedIdentity',
    'Microsoft.OperationalInsights', 'Microsoft.Insights'
foreach ($ns in $providers) {
    # WRITE: registers the provider in the subscription (idempotent).
    az provider register --subscription $sub --namespace $ns --wait
    if ($LASTEXITCODE) { throw "provider registration failed: $ns" }
}
```

**Check:** Every provider shows **Registered**. Read-only:

```powershell
foreach ($ns in 'Microsoft.ApiManagement', 'Microsoft.Web', 'Microsoft.App', 'Microsoft.DocumentDB',
    'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.ManagedIdentity',
    'Microsoft.OperationalInsights', 'Microsoft.Insights') {
    $state = az provider show --subscription $sub --namespace $ns --query registrationState -o tsv
    if ($LASTEXITCODE) { throw "provider read failed: $ns" }
    "$ns $state"
}
```

#### Step 02.2 - Create (or inspect) the resource group

**Where:** Portal > Resource groups > **+ Create** > Basics > Tags > **Review + create** > **Create**.
For an existing RG, inspect it; do not create a replacement.

| Field | Value | Source of value |
|---|---|---|
| Subscription | Target subscription | form `names.subscriptionId` |
| Resource group | Platform RG name | form `names.resourceGroup` |
| Region | Approved region | form `location` |
| Tags | `workload`, `environment` | form `tags` |

**Screenshot:**
![Step 02.2 - Create resource group](./images/portal/02-2-create-resource-group.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** only when form `names.resourceGroupMode` is `create`.

```powershell
if ($p.names.resourceGroupMode -ne 'create') { throw 'resourceGroupMode is existing: inspect the RG, do not create it' }
$tagArgs = @($p.tags.Keys | ForEach-Object { "$_=$($p.tags[$_])" })
# WRITE: creates the resource group.
az group create --subscription $sub -n $rg -l $p.location --tags @tagArgs -o none
if ($LASTEXITCODE) { throw 'resource group creation failed' }
```

**Check:** RG Overview > JSON view contains the expected subscription/resource ID. Record its
name and region. After a Quickstart `deploy`, RG > Deployments shows it **Succeeded**. Read-only:

```powershell
az group show --subscription $sub -n $rg --query '{id:id,location:location,state:properties.provisioningState}' -o json
if ($LASTEXITCODE) { throw 'resource group not found' }
az deployment group list --subscription $sub -g $rg --query '[].{name:name,state:properties.provisioningState}' -o table
if ($LASTEXITCODE) { throw 'deployment listing failed' }
```

## 03. Create or connect the network and private DNS

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

**Network mode.** With form `network.mode = 'create'`, do Steps 03.1-03.7 to create a new
VNet in the platform RG; the CLI blocks mirror `infra/prereqs/network.bicep`. With
`network.mode = 'existing'` the network team owns the VNet: skip creation, give them the
subnet table above, and run every step's **Check** against the IDs in form
`network.existing`. The Steps 03.3-03.5 CLI blocks add one subnet without rewriting the others.

#### Step 03.1 - Create the APIM subnet NSG and its rules

**Where:** Portal > Network security groups > **+ Create** > Basics > Review + create. Then
NSG > Settings > **Inbound security rules** / **Outbound security rules** > **+ Add** for each row.

| Field | Value | Source of value |
|---|---|---|
| Name | APIM NSG name | form `network.create.apimNsgName` |
| Region / RG | Platform region / RG | form `location`, `names.resourceGroup` |
| Inbound 100 `Allow-Client-Communication-Inbound` | TCP, source `Internet`, destination `VirtualNetwork`, ports 80, 443 | `infra/prereqs/network.bicep` |
| Inbound 110 `Allow-Management-Endpoint-Inbound` | TCP, `ApiManagement` to `VirtualNetwork`, 3443 | same |
| Inbound 120 `Allow-LoadBalancer-Inbound` | TCP, `AzureLoadBalancer` to `VirtualNetwork`, 6390 | same |
| Inbound 130 `Allow-TrafficManager-Inbound` | TCP, `AzureTrafficManager` to `VirtualNetwork`, 443 | same |
| Outbound 200 `Allow-Cert-Validation-Outbound` | TCP, `VirtualNetwork` to `Internet`, 80 | same |
| Outbound 210 `Allow-Storage-Outbound` | TCP, `VirtualNetwork` to `Storage`, 443 | same |
| Outbound 220 `Allow-SQL-Outbound` | TCP, `VirtualNetwork` to `SQL`, 1433 | same |
| Outbound 230 `Allow-KeyVault-Outbound` | TCP, `VirtualNetwork` to `AzureKeyVault`, 443 | same |
| Outbound 240 `Allow-Monitor-Outbound` | TCP, `VirtualNetwork` to `AzureMonitor`, 1886, 443 | same |

Permit APIM's documented platform dependency on `AzureKeyVault` TCP 443 and approved
backend destinations. Review customer firewall, routes and DNS rules. Classic
APIM VNet-injection NSG rules are not automatically the rules for v2 outbound integration.

**Screenshot:**
![Step 03.1 - APIM NSG rules](./images/portal/03-1-apim-nsg-rules.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** create mode only.

```powershell
$c = $p.network.create
$tagArgs = @($p.tags.Keys | ForEach-Object { "$_=$($p.tags[$_])" })
# WRITE: creates the NSG.
az network nsg create --subscription $sub -g $rg -n $c.apimNsgName -l $p.location --tags @tagArgs -o none
if ($LASTEXITCODE) { throw 'NSG creation failed' }
$rules = @(
    @('Allow-Client-Communication-Inbound', 100, 'Inbound', 'Internet', 'VirtualNetwork', @('80', '443')),
    @('Allow-Management-Endpoint-Inbound', 110, 'Inbound', 'ApiManagement', 'VirtualNetwork', @('3443')),
    @('Allow-LoadBalancer-Inbound', 120, 'Inbound', 'AzureLoadBalancer', 'VirtualNetwork', @('6390')),
    @('Allow-TrafficManager-Inbound', 130, 'Inbound', 'AzureTrafficManager', 'VirtualNetwork', @('443')),
    @('Allow-Cert-Validation-Outbound', 200, 'Outbound', 'VirtualNetwork', 'Internet', @('80')),
    @('Allow-Storage-Outbound', 210, 'Outbound', 'VirtualNetwork', 'Storage', @('443')),
    @('Allow-SQL-Outbound', 220, 'Outbound', 'VirtualNetwork', 'SQL', @('1433')),
    @('Allow-KeyVault-Outbound', 230, 'Outbound', 'VirtualNetwork', 'AzureKeyVault', @('443')),
    @('Allow-Monitor-Outbound', 240, 'Outbound', 'VirtualNetwork', 'AzureMonitor', @('1886', '443'))
)
foreach ($r in $rules) {
    $ports = $r[5]
    # WRITE: one NSG rule.
    az network nsg rule create --subscription $sub -g $rg --nsg-name $c.apimNsgName -n $r[0] --priority $r[1] `
        --direction $r[2] --access Allow --protocol Tcp --source-address-prefixes $r[3] --source-port-ranges '*' `
        --destination-address-prefixes $r[4] --destination-port-ranges @ports -o none
    if ($LASTEXITCODE) { throw "NSG rule failed: $($r[0])" }
}
```

**Check:** NSG > Inbound/Outbound security rules list the nine rules above. Read-only:

```powershell
# EDIT: in existing network mode only, the APIM subnet NSG's resource group and name.
$nsgRg = $rg
$nsgName = if ($p.network.mode -eq 'create') { $p.network.create.apimNsgName } else { '<existing-apim-nsg-name>' }
az network nsg rule list --subscription $sub -g $nsgRg --nsg-name $nsgName `
    --query '[].{name:name,priority:priority,direction:direction,source:sourceAddressPrefix,destination:destinationAddressPrefix}' -o table
if ($LASTEXITCODE) { throw 'NSG rule listing failed' }
```

#### Step 03.2 - Create the virtual network

**Where:** Portal > Virtual networks > **+ Create** > Basics > **IP addresses** (remove the
default subnet; subnets are added in Steps 03.3-03.5) > Review + create.

| Field | Value | Source of value |
|---|---|---|
| Name | VNet name | form `network.create.vnetName` |
| Region / RG | Platform region / RG | form `location`, `names.resourceGroup` |
| IPv4 address space | Approved CIDR | form `network.create.addressSpace` |

**Screenshot:**
![Step 03.2 - Create virtual network](./images/portal/03-2-create-vnet.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** create mode only; refuses to touch an existing VNet.

```powershell
$c = $p.network.create
az network vnet show --subscription $sub -g $rg -n $c.vnetName -o none 2>$null
if ($LASTEXITCODE -eq 0) { throw 'VNet already exists: do not recreate it; continue with the Step 03.3 check' }
$tagArgs = @($p.tags.Keys | ForEach-Object { "$_=$($p.tags[$_])" })
# WRITE: creates the VNet with no subnets.
az network vnet create --subscription $sub -g $rg -n $c.vnetName -l $p.location `
    --address-prefixes $c.addressSpace --tags @tagArgs -o none
if ($LASTEXITCODE) { throw 'VNet creation failed' }
```

**Check:** VNet Overview shows the address space. Read-only:

```powershell
az network vnet show --ids $net.vnetId --query '{space:addressSpace.addressPrefixes,subnets:subnets[].name}' -o json
if ($LASTEXITCODE) { throw 'VNet not found' }
```

#### Step 03.3 - Add the APIM outbound integration subnet

**Where:** Portal > Virtual networks > *VNet* > Settings > **Subnets** > **+ Subnet**.

| Field | Value | Source of value |
|---|---|---|
| Name | APIM subnet name | form `network.create.subnets.apim.name` |
| Starting address / size | APIM subnet CIDR | form `network.create.subnets.apim.prefix` |
| Network security group | APIM NSG | Step 03.1 |
| Subnet delegation | `Microsoft.Web/serverFarms` | `infra/prereqs/network.bicep` |

**Screenshot:**
![Step 03.3 - APIM subnet](./images/portal/03-3-apim-subnet.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
$c = $p.network.create
# WRITE: adds one subnet; other subnets are untouched.
az network vnet subnet create --subscription $sub -g $rg --vnet-name $c.vnetName -n $c.subnets.apim.name `
    --address-prefixes $c.subnets.apim.prefix --nsg $c.apimNsgName --delegations Microsoft.Web/serverFarms -o none
if ($LASTEXITCODE) { throw 'APIM subnet creation failed' }
```

**Check:** Subnets list shows the delegation and NSG. Read-only (in existing network mode, use the
APIM subnet ID the network team gave you):

```powershell
# EDIT: in existing network mode only, the APIM integration subnet resource ID.
$apimSubnetId = if ($net.apimSubnetId) { $net.apimSubnetId } else { '<existing-apim-subnet-resource-id>' }
az network vnet subnet show --ids $apimSubnetId `
    --query '{prefix:addressPrefix,nsg:networkSecurityGroup.id,delegation:delegations[0].serviceName}' -o json
if ($LASTEXITCODE) { throw 'APIM subnet not found' }
```

#### Step 03.4 - Add the Functions integration subnet

**Where:** Portal > Virtual networks > *VNet* > Settings > **Subnets** > **+ Subnet**.

| Field | Value | Source of value |
|---|---|---|
| Name | Functions subnet name | form `network.create.subnets.functions.name` |
| Starting address / size | Functions subnet CIDR | form `network.create.subnets.functions.prefix` |
| Subnet delegation | `Microsoft.App/environments` | `infra/prereqs/network.bicep` |

**Screenshot:**
![Step 03.4 - Functions subnet](./images/portal/03-4-functions-subnet.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
$c = $p.network.create
# WRITE: adds one subnet.
az network vnet subnet create --subscription $sub -g $rg --vnet-name $c.vnetName -n $c.subnets.functions.name `
    --address-prefixes $c.subnets.functions.prefix --delegations Microsoft.App/environments -o none
if ($LASTEXITCODE) { throw 'Functions subnet creation failed' }
```

**Check:** Delegation is `Microsoft.App/environments`. Read-only (both network modes):

```powershell
az network vnet subnet show --ids $net.functionsSubnetId `
    --query '{prefix:addressPrefix,delegation:delegations[0].serviceName}' -o json
if ($LASTEXITCODE) { throw 'Functions subnet not found' }
```

#### Step 03.5 - Add the private endpoint subnet

**Where:** Portal > Virtual networks > *VNet* > Settings > **Subnets** > **+ Subnet**.

| Field | Value | Source of value |
|---|---|---|
| Name | Private endpoint subnet name | form `network.create.subnets.privateEndpoints.name` |
| Starting address / size | PE subnet CIDR | form `network.create.subnets.privateEndpoints.prefix` |
| Subnet delegation | None | This guide |
| Private endpoint network policy | Disabled (or the customer-approved setting) | `infra/prereqs/network.bicep` |

**Screenshot:**
![Step 03.5 - Private endpoint subnet](./images/portal/03-5-private-endpoint-subnet.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
$c = $p.network.create
# WRITE: adds one subnet.
az network vnet subnet create --subscription $sub -g $rg --vnet-name $c.vnetName -n $c.subnets.privateEndpoints.name `
    --address-prefixes $c.subnets.privateEndpoints.prefix --private-endpoint-network-policies Disabled -o none
if ($LASTEXITCODE) { throw 'private endpoint subnet creation failed' }
```

**Check:** No delegation. Read-only (both network modes):

```powershell
az network vnet subnet show --ids $net.peSubnetId `
    --query '{prefix:addressPrefix,policies:privateEndpointNetworkPolicies,delegations:delegations}' -o json
if ($LASTEXITCODE) { throw 'private endpoint subnet not found' }
```

#### Step 03.6 - Create the two private DNS zones

**Where:** Portal > Private DNS zones > **+ Create** > Basics > Review + create. Once per zone.
Use existing authoritative zones where supplied by the network team; do not link two
competing zones for a namespace.

| Field | Value | Source of value |
|---|---|---|
| Name | `privatelink.documents.azure.com` | Cosmos private link (public cloud) |
| Name | `privatelink.blob.core.windows.net` | Blob private link (public cloud) |
| RG | Platform RG (create mode) | form `names.resourceGroup` |

**Screenshot:**
![Step 03.6 - Private DNS zone](./images/portal/03-6-private-dns-zone.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** create mode only.

```powershell
foreach ($zone in 'privatelink.documents.azure.com', 'privatelink.blob.core.windows.net') {
    # WRITE: creates one private DNS zone.
    az network private-dns zone create --subscription $sub -g $rg -n $zone -o none
    if ($LASTEXITCODE) { throw "zone creation failed: $zone" }
}
```

**Check:** Both zones exist. Record zone/subnet **resource IDs**, not their names alone. Read-only:

```powershell
foreach ($zoneId in $net.cosmosZoneId, $net.blobZoneId) {
    az network private-dns zone show --ids $zoneId --query id -o tsv
    if ($LASTEXITCODE) { throw "zone not found: $zoneId" }
}
```

#### Step 03.7 - Link each zone to the caller VNet

**Where:** Portal > Private DNS zones > *zone* > Settings > **Virtual network links** > **+ Add**.
Repeat for both zones and for every caller VNet the network team names.

| Field | Value | Source of value |
|---|---|---|
| Link name | `<vnet>-link` | `infra/prereqs/network.bicep` naming |
| Virtual network | Caller VNet (the new VNet in create mode) | form `network.create.vnetName` |
| Enable auto registration | **Off** | This guide |

With custom DNS, arrange conditional forwarding through the customer's private DNS
resolver.

**Screenshot:**
![Step 03.7 - Virtual network link](./images/portal/03-7-dns-vnet-link.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** create mode only (existing zones: the DNS team links them).

```powershell
$c = $p.network.create
foreach ($zone in 'privatelink.documents.azure.com', 'privatelink.blob.core.windows.net') {
    # WRITE: links the zone to the VNet without auto-registration.
    az network private-dns link vnet create --subscription $sub -g $rg -z $zone -n "$($c.vnetName)-link" `
        -v $net.vnetId -e false -o none
    if ($LASTEXITCODE) { throw "zone link failed: $zone" }
}
```

**Check:** Each zone's Virtual network links shows the VNet, auto registration Disabled. Read-only:

```powershell
foreach ($zoneId in $net.cosmosZoneId, $net.blobZoneId) {
    $parts = $zoneId -split '/'
    az network private-dns link vnet list --subscription $parts[2] -g $parts[4] -z $parts[-1] `
        --query '[].{name:name,vnet:virtualNetwork.id,autoRegistration:registrationEnabled}' -o table
    if ($LASTEXITCODE) { throw "link listing failed: $($parts[-1])" }
}
```

#### Step 03.8 - Approve egress, routes and DNS

**Where:** Customer firewall / route tables / DNS forwarders (owned by the network team);
Portal > Network security groups and Route tables to review.

| Field | Value | Source of value |
|---|---|---|
| Sync egress | `graph.microsoft.com` | Sync runtime |
| Reconciler egress | Approved Log Analytics query endpoint (normally `api.loganalytics.io`) | Reconciler runtime |
| Telemetry egress | Each telemetry app's Application Insights ingestion endpoint | Function runtime |
| APIM egress | `AzureKeyVault` TCP 443 and approved backend destinations | APIM platform dependency |

**Screenshot:**
![Step 03.8 - Egress review](./images/portal/03-8-egress-review.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** none for customer firewalls and forwarders (customer-specific design).
The check below reads the route table and NSG on the integration subnets.

**Check:** Approved subnet delegations, NSG, routes and DNS links are visible.
Outbound rules must allow sync to `graph.microsoft.com`, reconciler to the approved
Log Analytics query endpoint (normally `api.loganalytics.io`), and each telemetry
app to its Application Insights ingestion endpoint. These are egress dependencies,
not values to invent as private DNS-zone IDs. Customer Azure Monitor Private Link
Scope designs require their own corresponding DNS/endpoints.

```powershell
foreach ($subnetId in $net.functionsSubnetId, $net.peSubnetId) {
    az network vnet subnet show --ids $subnetId --query '{subnet:name,routeTable:routeTable.id,nsg:networkSecurityGroup.id}' -o json
    if ($LASTEXITCODE) { throw "subnet read failed: $subnetId" }
}
```

## 04. Workspace and Application Insights

The baseline reconciler uses LAW diagnostic logs, not another Insights component.
Do not invent a third connection string or populate its evidence `appInsightsId`.

#### Step 04.1 - Create the Log Analytics workspace

**Where:** Portal > Log Analytics workspaces > **+ Create** > Basics > Tags > Review + create.

| Field | Value | Source of value |
|---|---|---|
| Subscription / RG | Platform | form `names.subscriptionId`, `names.resourceGroup` |
| Name | Workspace name | form `names.logAnalyticsWorkspace` |
| Region | Approved region | form `location` |
| Pricing tier | Pay-as-you-go (`PerGB2018`) | `infra/prereqs/log-analytics.bicep` |

**Screenshot:**
![Step 04.1 - Create Log Analytics workspace](./images/portal/04-1-create-workspace.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** deploys only the repository's workspace module (`PerGB2018`, retention,
local authentication disabled).

```powershell
$params = Save-CcofParameters 'log-analytics' @{
    location = $p.location; tags = $p.tags; name = $p.names.logAnalyticsWorkspace; retentionInDays = $p.logRetentionDays
}
# WRITE: creates or updates the workspace.
az deployment group create --subscription $sub -g $rg -n "$($p.names.deploymentPrefix)-portal-workspace" `
    -f ./infra/prereqs/log-analytics.bicep -p $params -o none
if ($LASTEXITCODE) { throw 'workspace deployment failed; inspect RG > Deployments' }
```

**Check:** Workspace Overview shows Succeeded. Read-only:

```powershell
az monitor log-analytics workspace show --subscription $sub -g $rg -n $p.names.logAnalyticsWorkspace `
    --query '{id:id,customerId:customerId,retention:retentionInDays,sku:sku.name}' -o json
if ($LASTEXITCODE) { throw 'workspace not found' }
```

#### Step 04.2 - Set the data retention

**Where:** Portal > Log Analytics workspaces > *workspace* > Settings > **Usage and estimated costs** >
**Data retention**.

| Field | Value | Source of value |
|---|---|---|
| Data retention (days) | Approved period (30-730) | form `logRetentionDays` |

**Screenshot:**
![Step 04.2 - Data retention](./images/portal/04-2-data-retention.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** the Step 04.1 block already sets `retentionInDays`; rerun it after changing the form.

**Check:** `retention` in the Step 04.1 check output equals form `logRetentionDays`.

#### Step 04.3 - Record the workspace IDs

**Where:** Portal > Log Analytics workspaces > *workspace* > Settings > **Properties** (or Overview >
JSON view). **Workspace ID** (customer ID GUID) and **Resource ID** are different.

| Field | Value | Source of value |
|---|---|---|
| Resource ID | `/subscriptions/.../workspaces/<name>` | evidence `workspace.id` |
| Workspace ID | GUID | evidence `workspace.customerId` |

**Screenshot:**
![Step 04.3 - Workspace properties](./images/portal/04-3-workspace-properties.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** reads the IDs and saves them in the private evidence file.

```powershell
$law = az monitor log-analytics workspace show --subscription $sub -g $rg -n $p.names.logAnalyticsWorkspace -o json | ConvertFrom-Json
if ($LASTEXITCODE) { throw 'workspace not found' }
$e.workspace.id = $law.id; $e.workspace.customerId = $law.customerId
Save-CcofEvidence
```

**Check:** Evidence `workspace.customerId` is a GUID, not a resource ID.

#### Step 04.4 - Create the resolver Application Insights

**Where:** Portal > Application Insights > **+ Create** > Basics > Review + create. Then
*component* > Configure > **Properties** (or the local-authentication control) > Local authentication
**Disabled**.

| Field | Value | Source of value |
|---|---|---|
| Name | Resolver Insights | form `names.apps.resolver.appInsights` |
| Region / RG | Platform | form `location`, `names.resourceGroup` |
| Resource mode | Workspace-based | This guide |
| Log Analytics workspace | Step 04.1 workspace | evidence `workspace.id` |
| Local authentication | Disabled | `infra/prereqs/function-app.bicep` (`DisableLocalAuth: true`) |

If the tenant UI omits the local-auth control, an administrator must set the resource's
`DisableLocalAuth` property using the supported management API (the CLI block below sets it);
do not leave it enabled silently.

**Screenshot:**
![Step 04.4 - Create Application Insights](./images/portal/04-4-create-app-insights.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** same resource shape as `infra/prereqs/function-app.bicep`.

```powershell
$app = 'resolver'
$body = @{ location = $p.location; tags = $p.tags; kind = 'web'
    properties = @{ Application_Type = 'web'; WorkspaceResourceId = $e.workspace.id; DisableLocalAuth = $true } }
$bodyFile = Join-Path $artifacts "$app-insights.json"
$body | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM
# WRITE: creates or updates the component.
az resource create --subscription $sub -g $rg -n $p.names.apps[$app].appInsights `
    --resource-type Microsoft.Insights/components --api-version 2020-02-02 --is-full-object --properties "@$bodyFile" -o none
if ($LASTEXITCODE) { throw "Application Insights creation failed: $app" }
```

**Check:** Component Overview shows the workspace. Read-only:

```powershell
$app = 'resolver'
az resource show --subscription $sub -g $rg -n $p.names.apps[$app].appInsights --resource-type Microsoft.Insights/components `
    --query '{workspace:properties.WorkspaceResourceId,localAuthDisabled:properties.DisableLocalAuth}' -o json
if ($LASTEXITCODE) { throw "component not found: $app" }
```

#### Step 04.5 - Create the sync Application Insights

**Where:** As Step 04.4, with the sync name.

| Field | Value | Source of value |
|---|---|---|
| Name | Sync Insights | form `names.apps.sync.appInsights` |
| Other fields | As Step 04.4 | As Step 04.4 |

**Screenshot:**
![Step 04.5 - Sync Application Insights](./images/portal/04-5-sync-app-insights.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
$app = 'sync'
$body = @{ location = $p.location; tags = $p.tags; kind = 'web'
    properties = @{ Application_Type = 'web'; WorkspaceResourceId = $e.workspace.id; DisableLocalAuth = $true } }
$bodyFile = Join-Path $artifacts "$app-insights.json"
$body | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM
# WRITE: creates or updates the component.
az resource create --subscription $sub -g $rg -n $p.names.apps[$app].appInsights `
    --resource-type Microsoft.Insights/components --api-version 2020-02-02 --is-full-object --properties "@$bodyFile" -o none
if ($LASTEXITCODE) { throw "Application Insights creation failed: $app" }
```

**Check:** Run the Step 04.4 check with `$app = 'sync'`.

#### Step 04.6 - Record connection strings and component IDs

**Where:** Portal > Application Insights > *component* > **Overview** > Connection String (copy);
Overview > JSON view > Resource ID. Both components.

| Field | Value | Source of value |
|---|---|---|
| Resolver connection string / resource ID | Copied values | evidence `apps.resolver.connectionString`, `apps.resolver.appInsightsId` |
| Sync connection string / resource ID | Copied values | evidence `apps.sync.connectionString`, `apps.sync.appInsightsId` |
| Reconciler | Leave `appInsightsId` empty | evidence `apps.reconciler.appInsightsId` |

**Screenshot:**
![Step 04.6 - Connection string](./images/portal/04-6-connection-string.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** reads both components into the private evidence file.

```powershell
foreach ($app in 'resolver', 'sync') {
    $ai = az resource show --subscription $sub -g $rg -n $p.names.apps[$app].appInsights `
        --resource-type Microsoft.Insights/components -o json | ConvertFrom-Json
    if ($LASTEXITCODE) { throw "component not found: $app" }
    $e.apps[$app].appInsightsId = $ai.id; $e.apps[$app].connectionString = $ai.properties.ConnectionString
}
$e.apps.reconciler.appInsightsId = ''
Save-CcofEvidence
```

**Check:** Both Insights resources reference the intended workspace. Connection
strings stay in the private evidence file; generated configuration is never committed.

## 05. Create sync and reconciler identities

#### Step 05.1 - Create the sync managed identity

**Where:** Portal > Managed Identities > **+ Create** > Basics > Tags > Review + create.

| Field | Value | Source of value |
|---|---|---|
| Subscription / RG / Region | Platform | form `names.subscriptionId`, `names.resourceGroup`, `location` |
| Name | Sync identity | form `names.identities.sync` |

**Screenshot:**
![Step 05.1 - Create managed identity](./images/portal/05-1-create-managed-identity.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
$app = 'sync'
$tagArgs = @($p.tags.Keys | ForEach-Object { "$_=$($p.tags[$_])" })
# WRITE: creates the user-assigned identity.
az identity create --subscription $sub -g $rg -n $p.names.identities[$app] -l $p.location --tags @tagArgs -o none
if ($LASTEXITCODE) { throw "identity creation failed: $app" }
```

**Check:** Identity Overview shows Client ID and Object (principal) ID. Read-only:

```powershell
$app = 'sync'
az identity show --subscription $sub -g $rg -n $p.names.identities[$app] --query '{id:id,clientId:clientId,principalId:principalId}' -o json
if ($LASTEXITCODE) { throw "identity not found: $app" }
```

#### Step 05.2 - Create the reconciler managed identity

**Where:** As Step 05.1.

| Field | Value | Source of value |
|---|---|---|
| Name | Reconciler identity | form `names.identities.reconciler` |

**Screenshot:**
![Step 05.2 - Reconciler managed identity](./images/portal/05-2-reconciler-identity.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
$app = 'reconciler'
$tagArgs = @($p.tags.Keys | ForEach-Object { "$_=$($p.tags[$_])" })
# WRITE: creates the user-assigned identity.
az identity create --subscription $sub -g $rg -n $p.names.identities[$app] -l $p.location --tags @tagArgs -o none
if ($LASTEXITCODE) { throw "identity creation failed: $app" }
```

**Check:** Run the Step 05.1 check with `$app = 'reconciler'`.

#### Step 05.3 - Record each identity's three IDs

**Where:** Portal > Managed Identities > *identity* > **Overview** (Client ID, Object (principal) ID) and
Settings > **Properties** (Resource ID).

| Field | Value | Source of value |
|---|---|---|
| Client ID | GUID | evidence `apps.<app>.clientId` |
| Object (principal) ID | GUID | evidence `apps.<app>.principalId` |
| Resource ID | `/subscriptions/.../userAssignedIdentities/<name>` | Used in Step 10.3 |

**Screenshot:**
![Step 05.3 - Identity IDs](./images/portal/05-3-identity-ids.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** reads both identities into the private evidence file.

```powershell
foreach ($app in 'sync', 'reconciler') {
    $mi = az identity show --subscription $sub -g $rg -n $p.names.identities[$app] -o json | ConvertFrom-Json
    if ($LASTEXITCODE) { throw "identity not found: $app" }
    $e.apps[$app].clientId = $mi.clientId; $e.apps[$app].principalId = $mi.principalId
}
Save-CcofEvidence
```

**Check:** Two user-assigned identities exist. No client secret is needed. Do not
use their client ID where a role-assignment principal/object ID is requested.

## 06. Entra applications and classification groups

Default is **two registrations**, not one per project/classification.

| Registration | UI settings |
|---|---|
| Combined Gateway API + developer sign-in | Single tenant. Expose an API > `api://<client-id>` > enabled scope `access_as_user`, consent according to tenant policy. Manifest > `api.requestedAccessTokenVersion` = `2`. Authentication > Mobile and desktop applications: `http://localhost`, `https://login.microsoftonline.com/common/oauth2/nativeclient`, `ms-appx-web://Microsoft.AAD.BrokerPlugin/<client-id>`. Allow public client flows only if approved device-code use needs it. No secret; no implicit grants. |
| Resolver API | Another single-tenant registration. Expose an API > URI `api://<resolver-client-id>`; Manifest token version `2`. No delegated scope, redirect URI or secret. Its client ID must differ from the gateway/developer app. |

Apply tenant consent/preauthorization and Conditional Access requirements; combined-app
token-to-self is not a blanket consent exemption. Legacy separate developer/gateway
registrations are supported by [prerequisites](../QUICKSTART-PREREQUISITES.md).

After each registration, write its Application (client) ID into the private form
(Step 13.3) and reload (Step 13.4) before running later CLI blocks that read it.

#### Step 06.1 - Register the combined Gateway API + developer sign-in app

**Where:** Entra admin center > Identity > Applications > **App registrations** > **+ New registration**.

| Field | Value | Source of value |
|---|---|---|
| Name | Approved display name | Customer naming |
| Supported account types | Accounts in this organizational directory only (single tenant) | This guide |
| Redirect URI | Leave empty here (Step 06.4) | This guide |
| Application (client) ID (after Register) | Copy | form `registrations.gatewayApi.appId` and `registrations.developerSignIn.appId` (same value) |

**Screenshot:**
![Step 06.1 - New app registration](./images/portal/06-1-new-app-registration.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
# EDIT: display name of the combined registration.
$displayName = '<your-gateway-app-display-name>'
# WRITE: creates the single-tenant app registration.
$gatewayAppId = az ad app create --display-name $displayName --sign-in-audience AzureADMyOrg --query appId -o tsv
if ($LASTEXITCODE -or -not $gatewayAppId) { throw 'app registration failed' }
# WRITE: the Portal creates the service principal (enterprise application) automatically; az does not.
az ad sp create --id $gatewayAppId -o none
if ($LASTEXITCODE) { throw 'service principal creation failed' }
"Put $gatewayAppId in form registrations.gatewayApi.appId and registrations.developerSignIn.appId, then rerun Step 13.4."
```

**Check:** App registrations > All applications lists it; Overview shows **My organization only**. Read-only:

```powershell
az ad app show --id $p.registrations.gatewayApi.appId --query '{appId:appId,audience:signInAudience}' -o json
if ($LASTEXITCODE) { throw 'gateway registration not found' }
az ad sp show --id $p.registrations.gatewayApi.appId --query id -o tsv
if ($LASTEXITCODE) { throw 'gateway service principal not found' }
```

#### Step 06.2 - Set the Application ID URI and token version

**Where:** App registrations > *gateway app* > **Expose an API** > Application ID URI > **Add** > Save;
then **Manifest** > `api.requestedAccessTokenVersion` > Save.

| Field | Value | Source of value |
|---|---|---|
| Application ID URI | `api://<client-id>` | form `registrations.gatewayApi.appId` |
| `api.requestedAccessTokenVersion` | `2` | form `registrations.gatewayApi.accessTokenVersion` |

**Screenshot:**
![Step 06.2 - Application ID URI](./images/portal/06-2-application-id-uri.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
$gatewayAppId = $p.registrations.gatewayApi.appId
# WRITE: sets the identifier URI and v2 access tokens.
az ad app update --id $gatewayAppId --identifier-uris "api://$gatewayAppId" --requested-access-token-version 2
if ($LASTEXITCODE) { throw 'gateway registration update failed' }
```

**Check:** Expose an API shows `api://<client-id>`; Manifest shows `2`. Read-only:

```powershell
az ad app show --id $p.registrations.gatewayApi.appId `
    --query '{uris:identifierUris,tokenVersion:api.requestedAccessTokenVersion}' -o json
if ($LASTEXITCODE) { throw 'gateway registration not found' }
```

#### Step 06.3 - Add the `access_as_user` scope

**Where:** App registrations > *gateway app* > **Expose an API** > **+ Add a scope**.

| Field | Value | Source of value |
|---|---|---|
| Scope name | `access_as_user` | form `registrations.gatewayApi.scope` |
| Who can consent | According to tenant consent policy | Customer policy |
| Admin/user consent display name and description | Customer wording | Customer policy |
| State | Enabled | This guide |

**Screenshot:**
![Step 06.3 - Add a scope](./images/portal/06-3-add-scope.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** none. The repository has no reviewed Graph body for a delegated scope
(a new scope needs a generated ID and consent wording); add it in the UI.

**Check:** Expose an API lists `api://<client-id>/access_as_user`, Enabled. Read-only:

```powershell
az ad app show --id $p.registrations.gatewayApi.appId `
    --query 'api.oauth2PermissionScopes[].{value:value,enabled:isEnabled}' -o table
if ($LASTEXITCODE) { throw 'gateway registration not found' }
```

#### Step 06.4 - Add the public client redirect URIs

**Where:** App registrations > *gateway app* > **Authentication** > **+ Add a platform** > **Mobile and
desktop applications** > Custom redirect URIs > Configure. Advanced settings > **Allow public
client flows** only if approved device-code use needs it. No secret; no implicit grants.

| Field | Value | Source of value |
|---|---|---|
| Redirect URI 1 | `http://localhost` | This guide |
| Redirect URI 2 | `https://login.microsoftonline.com/common/oauth2/nativeclient` | This guide |
| Redirect URI 3 | `ms-appx-web://Microsoft.AAD.BrokerPlugin/<client-id>` | form `registrations.gatewayApi.appId` |
| Allow public client flows | No, unless device-code use is approved | Customer approval |

**Screenshot:**
![Step 06.4 - Public client redirect URIs](./images/portal/06-4-redirect-uris.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
# EDIT: set to 'true' only if approved device-code use needs public client flows.
$allowPublicClient = 'false'
$gatewayAppId = $p.registrations.gatewayApi.appId
# WRITE: replaces the public client redirect URI list with the three approved URIs.
az ad app update --id $gatewayAppId --is-fallback-public-client $allowPublicClient --public-client-redirect-uris `
    'http://localhost' 'https://login.microsoftonline.com/common/oauth2/nativeclient' "ms-appx-web://Microsoft.AAD.BrokerPlugin/$gatewayAppId"
if ($LASTEXITCODE) { throw 'redirect URI update failed' }
```

**Check:** Authentication shows the three URIs and no web/SPA implicit grant. Read-only:

```powershell
az ad app show --id $p.registrations.gatewayApi.appId `
    --query '{redirects:publicClient.redirectUris,publicFlows:isFallbackPublicClient,implicitAccess:web.implicitGrantSettings.enableAccessTokenIssuance,implicitId:web.implicitGrantSettings.enableIdTokenIssuance}' -o json
if ($LASTEXITCODE) { throw 'gateway registration not found' }
```

#### Step 06.5 - Register the Resolver API app

**Where:** App registrations > **+ New registration** (single tenant) > Register; then **Expose an API** >
Application ID URI > Add; **Manifest** > `api.requestedAccessTokenVersion` = `2`. No scope, redirect
URI or secret.

| Field | Value | Source of value |
|---|---|---|
| Name | Approved display name (helper default `ccof-resolver-api`) | Customer naming |
| Supported account types | Single tenant | This guide |
| Application ID URI | `api://<resolver-client-id>` | Its own Application (client) ID |
| `api.requestedAccessTokenVersion` | `2` | This guide |
| Application (client) ID | Copy; must differ from Step 06.1 | form `registrations.resolverApi.appId` |

**Screenshot:**
![Step 06.5 - Resolver API registration](./images/portal/06-5-resolver-api-registration.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** the repository's registration helper (creates once, sets the URI and token
version, creates the service principal, verifies by reading back).

```powershell
# EDIT: display name of the resolver registration.
$resolverName = '<your-resolver-app-display-name>'
. ./infra/poc/resolver-auth.ps1 -DotSourceOnly
# WRITE: creates (or reuses the single exact-name match of) the resolver registration.
$resolverAppId = Initialize-ResolverApiRegistration -DisplayName $resolverName
az ad sp show --id $resolverAppId --query appId -o tsv
if ($LASTEXITCODE) { throw 'resolver service principal not found' }
"Put $resolverAppId in form registrations.resolverApi.appId, then rerun Step 13.4."
```

**Check:** Two different app IDs. Read-only:

```powershell
az ad app show --id $p.registrations.resolverApi.appId `
    --query '{appId:appId,uris:identifierUris,tokenVersion:api.requestedAccessTokenVersion,scopes:api.oauth2PermissionScopes,redirects:publicClient.redirectUris}' -o json
if ($LASTEXITCODE) { throw 'resolver registration not found' }
if ($p.registrations.resolverApi.appId -eq $p.registrations.gatewayApi.appId) { throw 'resolver and gateway app IDs must differ' }
```

#### Step 06.6 - Create one security group per approved classification

**Where:** Entra admin center > Identity > Groups > **All groups** > **New group**.
Create STD, PRM and CYB only where approved.

| Field | Value | Source of value |
|---|---|---|
| Group type | **Security** | This guide |
| Group name | Approved display name (a label, not authorization) | form `groups[].displayName` |
| Membership type | **Assigned** | This guide |
| Object ID (after Create) | Copy | form `groups[].groupId` |

Each `(projectId, classification)` has its own explicit entry and group ID.
A project name does not infer three groups. Example: `projectId = SAMPLE01`,
with separate STD/PRM/CYB entries. Every classification of that project uses the
same registered `backendId`; different projects can use different backends.
Group display names are labels, not IDs or authorization.

**Screenshot:**
![Step 06.6 - New security group](./images/portal/06-6-new-security-group.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** one group per run.

```powershell
# EDIT: approved display name and mail nickname (letters/digits, unique) of ONE group.
$groupName = '<your-group-display-name>'
$nickname = '<your-group-mail-nickname>'
# WRITE: creates an assigned-membership security group.
$groupId = az ad group create --display-name $groupName --mail-nickname $nickname --query id -o tsv
if ($LASTEXITCODE -or -not $groupId) { throw "group creation failed: $groupName" }
"Put $groupId in the matching form groups[].groupId entry."
```

**Check:** Groups lists it as Security, Assigned. Read-only:

```powershell
foreach ($g in $p.groups) {
    az ad group show --group $g.groupId --query '{id:id,name:displayName,security:securityEnabled,mail:mailEnabled}' -o json
    if ($LASTEXITCODE) { throw "group not found: $($g.groupId)" }
}
```

#### Step 06.7 - Add owners and initial test members

**Where:** Groups > *group* > **Owners** > **+ Add owners**; then **Members** > **+ Add members**.

| Field | Value | Source of value |
|---|---|---|
| Owners | Approved group owners | Customer directory owners |
| Members | Real test developer(s) for the acceptance test (module 22) | Customer QA |

**Screenshot:**
![Step 06.7 - Group owners and members](./images/portal/06-7-group-owners-members.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
# EDIT: group object ID, owner object ID and test member object ID.
$groupId = '<your-group-object-id>'
$ownerId = '<owner-user-object-id>'
$memberId = '<test-member-user-object-id>'
# WRITE: adds one owner and one member.
az ad group owner add --group $groupId --owner-object-id $ownerId
if ($LASTEXITCODE) { throw 'owner add failed' }
az ad group member add --group $groupId --member-id $memberId
if ($LASTEXITCODE) { throw 'member add failed' }
```

**Check:** Owners and Members tabs list the people. Read-only:

```powershell
foreach ($g in $p.groups) {
    $owners = az ad group owner list --group $g.groupId --query 'length(@)' -o tsv
    if ($LASTEXITCODE) { throw "owner list failed: $($g.groupId)" }
    $members = az ad group member list --group $g.groupId --query 'length(@)' -o tsv
    if ($LASTEXITCODE) { throw "member list failed: $($g.groupId)" }
    "$($g.projectId)/$($g.classification): owners=$owners members=$members"
}
```

**Check (module 06):** Two different app IDs, correct URI/scope/manifest/redirects, owned security
groups, real member(s) for the acceptance test. An empty group cannot pass user access.

## 07. Foundry account, deployments and gateway grant

#### Step 07.1 - Deploy each licensed Claude model

**Where:** Customer's approved Foundry portal > resource/project > **Models + endpoints** (or
**Deployments**) > **+ Deploy model** > select the licensed, available Claude model > Deploy.

| Field | Value | Source of value |
|---|---|---|
| Deployment name | Exact **deployment ID** to admit | form `backends[].deploymentInferenceGeo` keys, `groups[].familyPolicy` models |
| Deployment type / geography | Approved inference geography (`global` or `us`) | form `backends[].deploymentInferenceGeo` values |
| Quota | Within subscription/model quota | Backend owner |

A model catalog name is not necessarily a deployment ID. Check subscription/model quota;
the gateway cannot manufacture Foundry capacity.

**Screenshot:**
![Step 07.1 - Deploy model](./images/portal/07-1-deploy-model.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** none. Model name, version, format and SKU of a Claude deployment are
not recorded in this repository; deploy in the Foundry UI.

**Check:** Deployments lists every exact deployment ID. Read-only:

```powershell
foreach ($b in $p.backends) {
    az cognitiveservices account deployment list --subscription $b.subscriptionId -g $b.resourceGroup -n $b.accountName `
        --query '[].{name:name,state:properties.provisioningState}' -o table
    if ($LASTEXITCODE) { throw "deployment list failed: $($b.id)" }
}
```

#### Step 07.2 - Record the account, endpoint and geography

**Where:** Azure Portal > Foundry (Cognitive Services) account > Overview > JSON view (Resource ID);
Keys and Endpoint / Endpoints (custom subdomain endpoint; do not copy keys).

| Field | Value | Source of value |
|---|---|---|
| Subscription / RG / account name | Account location | form `backends[].subscriptionId`, `.resourceGroup`, `.accountName` |
| Backend URL | `https://<custom-subdomain>.services.ai.azure.com/anthropic` | form `backends[].url` |
| Backend ID | Registry backend identifier | form `backends[].id` |

**Screenshot:**
![Step 07.2 - Foundry account overview](./images/portal/07-2-foundry-account.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** read-only.

```powershell
foreach ($b in $p.backends) {
    az cognitiveservices account show --subscription $b.subscriptionId -g $b.resourceGroup -n $b.accountName `
        --query '{id:id,subdomain:properties.customSubDomainName,public:properties.publicNetworkAccess}' -o json
    if ($LASTEXITCODE) { throw "account read failed: $($b.id)" }
}
```

**Check:** Each form `backends[].url` uses that account's custom subdomain and ends `/anthropic`.

#### Step 07.3 - Create the Foundry private endpoint

**Where:** Azure Portal > Foundry account > Resource Management > **Networking** > **Private endpoint
connections** > **+ Private endpoint** > Basics > Resource (target sub-resource `account`) > Virtual
Network > DNS > Review + create.

| Field | Value | Source of value |
|---|---|---|
| Name | Reviewed hub PE name | Network team |
| Target sub-resource | `account` | [manual deployment](../MANUAL-DEPLOYMENT.md) |
| Virtual network / subnet | Approved APIM-reachable private endpoint subnet | form `network.*` PE subnet |
| Private DNS integration | Offered Foundry zone configuration (Step 07.5); not the Cosmos zone | [network guide](../NETWORK.md) |

**Screenshot:**
![Step 07.3 - Foundry private endpoint](./images/portal/07-3-foundry-private-endpoint.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** from [manual deployment](../MANUAL-DEPLOYMENT.md); one backend per run.

```powershell
# EDIT: backend id from the form and the reviewed hub PE name.
$backendId = '<your-backend-id>'
$foundryPe = '<your-foundry-pe-name>'
$backend = $p.backends | Where-Object id -CEQ $backendId
if (-not $backend) { throw "backend not in form: $backendId" }
$target = "/subscriptions/$($backend.subscriptionId)/resourceGroups/$($backend.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($backend.accountName)"
# WRITE: creates a manual-approval private endpoint in the platform RG.
az network private-endpoint create --subscription $sub -g $rg -n $foundryPe --location $p.location `
    --subnet $net.peSubnetId --private-connection-resource-id $target --group-id account `
    --connection-name "$foundryPe-connection" --manual-request true --request-message 'Approved private gateway onboarding' -o none
if ($LASTEXITCODE) { throw 'Foundry private endpoint creation failed' }
```

**Check:** The PE exists; its connection is Pending until Step 07.4. Read-only:

```powershell
# EDIT: the reviewed hub PE name.
$foundryPe = '<your-foundry-pe-name>'
az network private-endpoint show --subscription $sub -g $rg -n $foundryPe `
    --query '{state:provisioningState,status:manualPrivateLinkServiceConnections[0].privateLinkServiceConnectionState.status}' -o json
if ($LASTEXITCODE) { throw 'private endpoint not found' }
```

#### Step 07.4 - Backend owner approves the connection

**Where:** Azure Portal > Foundry account > Networking > **Private endpoint connections** > select the
Pending connection > **Approve** > Description > Yes.

| Field | Value | Source of value |
|---|---|---|
| Connection | The target-side connection created in Step 07.3 | Foundry account |
| Description | `Reviewed gateway PE` | Backend owner |

**Screenshot:**
![Step 07.4 - Approve private endpoint connection](./images/portal/07-4-approve-pe-connection.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** backend owner; approve the **target-side connection ID**, not the PE ID.

```powershell
# EDIT: backend id from the form, then the target-side connection id printed by the list command.
$backendId = '<your-backend-id>'
$connectionId = '<target-side-connection-id>'
$backend = $p.backends | Where-Object id -CEQ $backendId
$target = "/subscriptions/$($backend.subscriptionId)/resourceGroups/$($backend.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($backend.accountName)"
az network private-endpoint-connection list --id $target --output table
if ($LASTEXITCODE) { throw 'connection listing failed' }
# WRITE: approves the reviewed connection.
az network private-endpoint-connection approve --id $connectionId --description 'Reviewed gateway PE' -o none
if ($LASTEXITCODE) { throw 'approval failed' }
```

**Check:** The connection shows **Approved**. Read-only:

```powershell
foreach ($b in $p.backends) {
    $target = "/subscriptions/$($b.subscriptionId)/resourceGroups/$($b.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($b.accountName)"
    az network private-endpoint-connection list --id $target --query '[].{name:name,status:properties.privateLinkServiceConnectionState.status}' -o table
    if ($LASTEXITCODE) { throw "connection listing failed: $($b.id)" }
}
```

#### Step 07.5 - Attach the Foundry private DNS configuration

**Where:** Portal > Private endpoints > *Foundry PE* > Settings > **DNS configuration** > **+ Add
configuration** (zone group). Follow the endpoint's offered DNS zone-group configuration and
[network guide](../NETWORK.md); do not substitute the Cosmos zone. Private DNS and routes must
work from APIM's outbound network.

| Field | Value | Source of value |
|---|---|---|
| Zones | `privatelink.cognitiveservices.azure.com`, `privatelink.openai.azure.com`, `privatelink.services.ai.azure.com` | `infra/poc/foundry-private-dns.bicep` |
| Zone owner | Central DNS team zones where they exist | Network team |

**Screenshot:**
![Step 07.5 - Foundry DNS configuration](./images/portal/07-5-foundry-dns.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** for a simple new hub where VNet/PE/zones all live in this RG, the repository's
DNS module creates/links all three zones and one zone group (NxDomainRedirect fallback). For
central existing zones **do not deploy that creator**: use `az network private-endpoint
dns-zone-group create` with the reviewed zone IDs as in [manual deployment](../MANUAL-DEPLOYMENT.md).

```powershell
# EDIT: actual APIM-integrated hub VNet name (in this RG) and the Foundry PE name.
$hubVnet = '<your-hub-vnet-name>'
$foundryPe = '<your-foundry-pe-name>'
# WRITE: creates/links the Foundry zones and the PE zone group.
az deployment group create --subscription $sub -g $rg --name manual-foundry-dns `
    --template-file ./infra/poc/foundry-private-dns.bicep `
    --parameters vnetName=$hubVnet privateEndpointName=$foundryPe -o none
if ($LASTEXITCODE) { throw 'Foundry DNS deployment failed' }
```

**Check:** The PE's DNS configuration lists the account FQDNs with private IPs. Read-only:

```powershell
# EDIT: the Foundry PE name.
$foundryPe = '<your-foundry-pe-name>'
az network private-endpoint dns-zone-group list --subscription $sub -g $rg --endpoint-name $foundryPe `
    --query '[].privateDnsZoneConfigs[].{zone:privateDnsZoneId,records:recordSets[].fqdn}' -o json
if ($LASTEXITCODE) { throw 'zone group listing failed' }
```

#### Step 07.6 - Grant APIM Cognitive Services User on each Foundry account (after module 11)

**Where:** Azure Portal > Foundry account > **Access control (IAM)** > **+ Add** > **Add role assignment** >
Role **Cognitive Services User** > Members: **Managed identity** > + Select members > API Management >
intended APIM > Review + assign. Repeat for every same-tenant Foundry backend at that account scope.
Do not grant the app Owner, and do not use an account key.

| Field | Value | Source of value |
|---|---|---|
| Role | Cognitive Services User (`a97b65f3-24c7-4388-baec-2e87135dc908`) | `infra/quickstart/modules/foundry-role.bicep` |
| Scope | Foundry account | form `backends[]` |
| Member | APIM system-assigned identity (principal ID) | evidence `apim.principalId` |

**Screenshot:**
![Step 07.6 - Cognitive Services User for APIM](./images/portal/07-6-apim-cognitive-services-user.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** same-tenant backends only; skips a backend whose form entry says the
assignment already exists (`assignCognitiveServicesUser: false`).

```powershell
foreach ($b in $p.backends | Where-Object assignCognitiveServicesUser) {
    $scope = "/subscriptions/$($b.subscriptionId)/resourceGroups/$($b.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($b.accountName)"
    # WRITE: one account-scoped role assignment for the APIM identity.
    az role assignment create --role a97b65f3-24c7-4388-baec-2e87135dc908 --scope $scope `
        --assignee-object-id $e.apim.principalId --assignee-principal-type ServicePrincipal -o none
    if ($LASTEXITCODE) { throw "Foundry grant failed: $($b.id)" }
}
```

**Check:** IAM > Role assignments shows Cognitive Services User for the APIM identity. Read-only:

```powershell
foreach ($b in $p.backends) {
    $scope = "/subscriptions/$($b.subscriptionId)/resourceGroups/$($b.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($b.accountName)"
    az role assignment list --scope $scope --assignee-object-id $e.apim.principalId --query '[].roleDefinitionName' -o tsv
    if ($LASTEXITCODE) { throw "assignment listing failed: $($b.id)" }
}
```

**Check (module 07):** Exact deployments exist, connection Approved, backend caller route works,
and account-scoped assignment names APIM's **principal** ID. Cross-tenant backends
require their separate credential/Key Vault design; this same-tenant grant is not a substitute.

## 08. Cosmos DB account, database and eight containers

#### Step 08.1 - Create the private, keyless Cosmos DB account

**Where:** Portal > Azure Cosmos DB > **+ Create** > **Azure Cosmos DB for NoSQL** > Basics >
Global Distribution > Networking > Backup Policy > Encryption > Security > Review + create.

| Field | Value | Source of value |
|---|---|---|
| Subscription / RG | Platform | form `names.subscriptionId`, `names.resourceGroup` |
| Account name | Cosmos account | form `names.cosmosAccount` |
| Location | Approved region | form `location` |
| Capacity mode | Serverless or Provisioned throughput | form `cosmos.capacityMode` |
| Availability zones | Approved decision | form `cosmos.zoneRedundant` |
| Connectivity method | **Private endpoint**; public network access **Disabled** | `infra/prereqs/cosmos-account.bicep` |
| Private endpoint | Name, PE subnet, target sub-resource `Sql`, integrate with `privatelink.documents.azure.com` | form `names.cosmosPrivateEndpoint`; Step 03.5/03.6 |
| Key-based authentication (Security tab) | **Disabled** | `infra/prereqs/cosmos-account.bicep` |

Availability/zones/throughput follow the approved decision.

**Screenshot:**
![Step 08.1 - Create Cosmos DB account](./images/portal/08-1-create-cosmos-account.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** deploys only the repository's account module (Session consistency, local
auth disabled, public access disabled, `Sql` private endpoint and zone group).

```powershell
$params = Save-CcofParameters 'cosmos-account' @{
    location = $p.location; tags = $p.tags; accountName = $p.names.cosmosAccount
    capacityMode = $p.cosmos.capacityMode; zoneRedundant = $p.cosmos.zoneRedundant
    privateEndpointName = $p.names.cosmosPrivateEndpoint; privateEndpointSubnetId = $net.peSubnetId
    cosmosPrivateDnsZoneId = $net.cosmosZoneId
}
# WRITE: creates or updates the account and its private endpoint (can take 10+ minutes).
az deployment group create --subscription $sub -g $rg -n "$($p.names.deploymentPrefix)-portal-cosmos" `
    -f ./infra/prereqs/cosmos-account.bicep -p $params -o none
if ($LASTEXITCODE) { throw 'Cosmos deployment failed or timed out; inspect RG > Deployments before rerunning' }
```

**Check:** Account Overview Succeeded; Networking shows public access Disabled. Read-only:

```powershell
az cosmosdb show --subscription $sub -g $rg -n $p.names.cosmosAccount `
    --query '{public:publicNetworkAccess,localAuthDisabled:disableLocalAuth,endpoint:documentEndpoint}' -o json
if ($LASTEXITCODE) { throw 'Cosmos account not found' }
```

#### Step 08.2 - Confirm the private endpoint and DNS record

**Where:** Cosmos account > Settings > **Networking** > **Private access** tab > connection state;
private endpoint > DNS configuration.

| Field | Value | Source of value |
|---|---|---|
| Connection state | **Approved** | Azure |
| DNS zone | `privatelink.documents.azure.com` | form network zone ID |

**Screenshot:**
![Step 08.2 - Cosmos private access](./images/portal/08-2-cosmos-private-access.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** created by the Step 08.1 block; nothing else to run.

**Check:** Read-only:

```powershell
az network private-endpoint show --subscription $sub -g $rg -n $p.names.cosmosPrivateEndpoint `
    --query '{status:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status,group:privateLinkServiceConnections[0].groupIds[0]}' -o json
if ($LASTEXITCODE) { throw 'Cosmos private endpoint not found' }
az network private-endpoint dns-zone-group list --subscription $sub -g $rg --endpoint-name $p.names.cosmosPrivateEndpoint `
    --query '[].privateDnsZoneConfigs[].recordSets[].fqdn' -o tsv
if ($LASTEXITCODE) { throw 'Cosmos zone group not found' }
```

#### Step 08.3 - Create the database

**Where:** Cosmos account > **Data Explorer** > **New Database**.

| Field | Value | Source of value |
|---|---|---|
| Database id | Approved database ID | form `names.cosmosDatabase` |
| Provision throughput | Serverless: not offered/do not add. Provisioned: **Autoscale**, database-level maximum | form `cosmos.capacityMode`, `cosmos.autoscaleMaxThroughput` |

For serverless, do not add provisioned RU/s. For provisioned shared autoscale, set the approved
database-level maximum; avoid accidentally assigning throughput to all containers.

**Private Data Explorer boundary:** browser/operator network and native Cosmos
data permissions must be sufficient. Azure IAM Contributor is not a native SQL data
role. If Data Explorer cannot create schema under the customer's private/keyless
policy, use the short **management-plane** fallback below (it needs the module 13
variables). It does not enable public access or keys; item seeding remains inside the
Function App.

**Screenshot:**
![Step 08.3 - New database](./images/portal/08-3-new-database.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
# Necessary only when Data Explorer cannot create the private/keyless schema.
$throughputArgs = if ($p.cosmos.capacityMode -eq 'provisioned-autoscale') { @('--max-throughput', $p.cosmos.autoscaleMaxThroughput) } else { @() }
# WRITE: creates the database (serverless: no throughput; provisioned: database-level autoscale).
az cosmosdb sql database create --subscription $sub -g $rg -a $p.names.cosmosAccount -n $p.names.cosmosDatabase @throughputArgs -o none
if ($LASTEXITCODE) { throw 'database creation failed; inspect the error' }
```

**Check:** Data Explorer lists the database. Read-only:

```powershell
az cosmosdb sql database show --subscription $sub -g $rg -a $p.names.cosmosAccount -n $p.names.cosmosDatabase --query id -o tsv
if ($LASTEXITCODE) { throw 'database not found' }
```

#### Step 08.4 - Create the eight containers

**Where:** Data Explorer > **New Container** > Use existing database > for each row below.
Partition keys are case-sensitive and cannot be changed in place.

| Container id | Partition key | Source of value |
|---|---|---|
| entitlement | `/personId` | `infra/quickstart/modules/cosmos-data.bicep` |
| projects | `/projectId` | same |
| subscriptionIndex | `/subscriptionId` | same |
| budgetState | `/personId` | same |
| aggregateBudgetState | `/scopeId` | same |
| syncLease | `/id` | same |
| reconcilerLease | `/id` | same |
| backends | `/backendId` | same |

**Screenshot:**
![Step 08.4 - New container](./images/portal/08-4-new-container.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** the management-plane fallback; container names and keys come from the
shared module, not retyped.

```powershell
# Necessary only when Data Explorer cannot create the private/keyless schema.
Import-Module ./scripts/Core.D2Steps.psm1
$containers = Get-CoreCosmosContainers
foreach ($name in $containers.Keys) {
    # WRITE: creates one container.
    az cosmosdb sql container create --subscription $sub -g $rg -a $p.names.cosmosAccount `
        -d $p.names.cosmosDatabase -n $name --partition-key-path $containers[$name] -o none
    if ($LASTEXITCODE) { throw "container creation failed: $name" }
}
```

**Check:** Account private/keyless, endpoint Approved, database and all eight partition
keys correct. Do not rename a database on a resume: existing SQL assignment scopes
are not an in-place migration. Read-only:

```powershell
az cosmosdb sql container list --subscription $sub -g $rg -a $p.names.cosmosAccount -d $p.names.cosmosDatabase `
    --query '[].{name:name,key:resource.partitionKey.paths[0]}' -o table
if ($LASTEXITCODE) { throw 'container listing failed' }
```

## 09. Storage accounts and deployment containers

One storage account per Function App. Do steps 09.1-09.3 for `resolver`, `sync` and `reconciler`.

#### Step 09.1 - Create the private, keyless storage account

**Where:** Portal > Storage accounts > **+ Create** > Basics > Advanced > Networking > Review + create.

| Field | Value | Source of value |
|---|---|---|
| Storage account name | Per app | form `names.apps.<app>.storageAccount` |
| Region / RG | Platform | form `location`, `names.resourceGroup` |
| Primary service / kind | StorageV2 (general purpose v2) | `infra/prereqs/function-app.bicep` |
| Redundancy | Approved LRS/ZRS | form `storageSku` |
| Minimum TLS version | TLS 1.2 | same bicep |
| Allow storage account key access (Advanced) | **Disabled** | same bicep |
| Allow anonymous blob access (Advanced) | **Disabled** | same bicep |
| Public network access (Networking) | **Disabled** | same bicep |

**Screenshot:**
![Step 09.1 - Create storage account](./images/portal/09-1-create-storage-account.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
$tagArgs = @($p.tags.Keys | ForEach-Object { "$_=$($p.tags[$_])" })
foreach ($app in 'resolver', 'sync', 'reconciler') {
    # WRITE: creates one private, keyless StorageV2 account.
    az storage account create --subscription $sub -g $rg -n $p.names.apps[$app].storageAccount -l $p.location `
        --kind StorageV2 --sku $p.storageSku --min-tls-version TLS1_2 --https-only true `
        --allow-shared-key-access false --allow-blob-public-access false `
        --public-network-access Disabled --default-action Deny --bypass AzureServices --tags @tagArgs -o none
    if ($LASTEXITCODE) { throw "storage creation failed: $app" }
}
```

**Check:** Configuration shows key access Disabled; Networking shows public access Disabled. Read-only:

```powershell
foreach ($app in 'resolver', 'sync', 'reconciler') {
    az storage account show --subscription $sub -g $rg -n $p.names.apps[$app].storageAccount `
        --query '{name:name,public:publicNetworkAccess,sharedKeys:allowSharedKeyAccess,blobPublic:allowBlobPublicAccess,tls:minimumTlsVersion}' -o json
    if ($LASTEXITCODE) { throw "storage not found: $app" }
}
```

#### Step 09.2 - Add the blob private endpoint

**Where:** Storage account > Security + networking > **Networking** > **Private endpoint connections** >
**+ Private endpoint** > Resource (target sub-resource **blob**) > Virtual Network (PE subnet) > DNS
(integrate with `privatelink.blob.core.windows.net`) > Review + create.

| Field | Value | Source of value |
|---|---|---|
| Name | Per app | form `names.apps.<app>.storagePrivateEndpoint` |
| Target sub-resource | `blob` | `infra/prereqs/function-app.bicep` |
| Subnet | Private endpoint subnet | form network PE subnet |
| Private DNS zone | `privatelink.blob.core.windows.net` | form network blob zone ID |

**Screenshot:**
![Step 09.2 - Blob private endpoint](./images/portal/09-2-blob-private-endpoint.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
foreach ($app in 'resolver', 'sync', 'reconciler') {
    $n = $p.names.apps[$app]
    $storageId = "$base/Microsoft.Storage/storageAccounts/$($n.storageAccount)"
    # WRITE: creates the blob private endpoint.
    az network private-endpoint create --subscription $sub -g $rg -n $n.storagePrivateEndpoint -l $p.location `
        --subnet $net.peSubnetId --private-connection-resource-id $storageId --group-id blob `
        --connection-name "$($n.storagePrivateEndpoint)-connection" -o none
    if ($LASTEXITCODE) { throw "blob private endpoint failed: $app" }
    # WRITE: attaches the blob private DNS zone.
    az network private-endpoint dns-zone-group create --subscription $sub -g $rg --endpoint-name $n.storagePrivateEndpoint `
        -n blob-dns-zone-group --zone-name blob --private-dns-zone $net.blobZoneId -o none
    if ($LASTEXITCODE) { throw "blob DNS zone group failed: $app" }
}
```

**Check:** Connection **Approved**; DNS configuration lists `<account>.privatelink.blob...`. Read-only:

```powershell
foreach ($app in 'resolver', 'sync', 'reconciler') {
    az network private-endpoint show --subscription $sub -g $rg -n $p.names.apps[$app].storagePrivateEndpoint `
        --query '{name:name,status:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}' -o json
    if ($LASTEXITCODE) { throw "blob private endpoint not found: $app" }
}
```

#### Step 09.3 - Create the deployment container

**Where:** Storage account > Data storage > **Containers** > **+ Container**.

| Field | Value | Source of value |
|---|---|---|
| Name | Exact approved deployment-container name | form `names.apps.<app>.deploymentContainer` |
| Anonymous access level | Private (no anonymous access) | This guide |

Data-plane container creation through the UI requires operator Storage Blob Data permissions
and a permitted network path. If that UI is blocked, ask the storage owner to create the
container over their approved private path, or use the blob container management resource
(the CLI block below, or **Resource Explorer**). Do not enable keys/public networking. The app
access helper is not an operator-role grant.

**Screenshot:**
![Step 09.3 - Deployment container](./images/portal/09-3-deployment-container.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** management plane; works without data-plane access or a private path.

```powershell
foreach ($app in 'resolver', 'sync', 'reconciler') {
    $n = $p.names.apps[$app]
    # WRITE: creates the private deployment container.
    az storage container-rm create --subscription $sub -g $rg --storage-account $n.storageAccount `
        -n $n.deploymentContainer --public-access off -o none
    if ($LASTEXITCODE) { throw "container creation failed: $app" }
}
```

**Check:** Three accounts and three deployment containers, each matching its app.
Private endpoint connections Approved and private DNS records present. Blob-only
storage connectivity matches this repository's Flex host/runtime contracts; changing
hosting plan/triggers can introduce additional storage dependencies. Read-only:

```powershell
foreach ($app in 'resolver', 'sync', 'reconciler') {
    $n = $p.names.apps[$app]
    az storage container-rm show --subscription $sub -g $rg --storage-account $n.storageAccount -n $n.deploymentContainer `
        --query '{name:name,publicAccess:publicAccess}' -o json
    if ($LASTEXITCODE) { throw "container not found: $app" }
}
```

## 10. Create and connect the three Function Apps

Create resolver, sync and reconciler **sequentially**, not parallel subnet joins.

#### Step 10.1 - Create one Flex Consumption Function App

**Where:** Portal > Function App > **+ Create** > **Flex Consumption** > Select > Basics > Storage >
Networking > Monitoring > Authentication > Deployment > Tags > Review + create.

| Field | Value | Source of value |
|---|---|---|
| Function App name | Per app | form `names.apps.<app>.functionApp` |
| Region | Same region as the Functions subnet | form `location` |
| Runtime stack / version | **Node.js** / **22** | `infra/prereqs/function-app.bicep` |
| Instance size (memory) | 512 / 2048 / 4096 MB | form `functions.<app>.instanceMemoryMB` |
| Maximum instance count | Approved value | form `functions.<app>.maximumInstanceCount` |
| Always ready | resolver `http`; sync `function:syncEntitlement`; reconciler `function:reconcileBudgets` with the approved count | form `functions.<app>.alwaysReady` |
| Storage account | Existing account from Step 09.1 | form `names.apps.<app>.storageAccount` |
| Enable public access / VNet integration (Networking) | Outbound VNet integration **On** > Functions subnet | form network Functions subnet |
| Application Insights (Monitoring) | resolver/sync: existing component from Step 04.4/04.5; reconciler: **No** | form `names.apps.<app>.appInsights` |
| Authentication type (storage) | **Managed identity**, not a connection string | This guide |

Authentication/Identity wizard: choose managed-identity storage, not a connection string.
Current wizards can create an extra user-assigned identity automatically. Inspect the
result and explicitly align it with this repository (Step 10.2):

| App | Runtime/deployment identity | Monitoring |
|---|---|---|
| resolver | System-assigned identity On; record principal ID; deployment auth SystemAssignedIdentity | Resolver Insights from module 04 |
| sync | Attach approved sync UAMI; host settings select its client ID; deployment auth UserAssignedIdentity using its resource ID | Sync Insights |
| reconciler | Attach approved reconciler UAMI; host settings select its client ID; deployment auth UserAssignedIdentity using its resource ID | LAW diagnostics, module 20 |

**Screenshot:**
![Step 10.1 - Create Flex Consumption app](./images/portal/10-1-create-flex-function-app.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** deploys the repository's per-app module (plan FC1, Node 22, HTTPS only,
FTPS off, VNet integration, identity-based deployment storage). It also re-applies the same
storage account, blob private endpoint and Insights settings as Steps 04.4-04.5 and 09.1-09.3
(idempotent). Run once per app, waiting for each to finish.

```powershell
# EDIT: which app to create: 'resolver', then 'sync', then 'reconciler'.
$app = 'resolver'
$n = $p.names.apps[$app]
$alwaysReadyNames = @{ resolver = 'http'; sync = 'function:syncEntitlement'; reconciler = 'function:reconcileBudgets' }
$identityId = if ($app -eq 'resolver') { '' } else { "$base/Microsoft.ManagedIdentity/userAssignedIdentities/$($p.names.identities[$app])" }
$params = Save-CcofParameters "function-app-$app" @{
    location = $p.location; tags = $p.tags; functionAppName = $n.functionApp; planName = $n.plan
    storageAccountName = $n.storageAccount; storageSku = $p.storageSku; deploymentContainerName = $n.deploymentContainer
    storagePrivateEndpointName = $n.storagePrivateEndpoint; privateEndpointSubnetId = $net.peSubnetId
    blobPrivateDnsZoneId = $net.blobZoneId; integrationSubnetId = $net.functionsSubnetId
    appInsightsName = [string]$n.appInsights; logAnalyticsWorkspaceId = $e.workspace.id
    userAssignedIdentityId = $identityId; alwaysReadyName = $alwaysReadyNames[$app]
    alwaysReadyInstanceCount = $p.functions[$app].alwaysReady; maximumInstanceCount = $p.functions[$app].maximumInstanceCount
    instanceMemoryMB = $p.functions[$app].instanceMemoryMB; zoneRedundant = $false
}
# WRITE: creates or updates this app, its plan, storage, blob PE and (resolver/sync) Insights.
az deployment group create --subscription $sub -g $rg -n "$($p.names.deploymentPrefix)-portal-app-$app" `
    -f ./infra/prereqs/function-app.bicep -p $params -o none
if ($LASTEXITCODE) { throw "Function App deployment failed or timed out: $app; inspect RG > Deployments before rerunning" }
```

**Check:** App Overview: Flex Consumption, Linux, Node 22. Read-only:

```powershell
# EDIT: which app to check.
$app = 'resolver'
az functionapp show --subscription $sub -g $rg -n $p.names.apps[$app].functionApp `
    --query '{state:state,subnet:virtualNetworkSubnetId,runtime:functionAppConfig.runtime,scale:functionAppConfig.scaleAndConcurrency,identity:identity.type}' -o json
if ($LASTEXITCODE) { throw "Function App not found: $app" }
```

#### Step 10.2 - Align the app identity

**Where:** Function App > Settings > **Identity** > **System assigned** tab (resolver: Status **On** >
Save) or **User assigned** tab (sync/reconciler: **+ Add** > approved UAMI). Remove any extra
wizard-created user-assigned identity only after Step 10.3 no longer references it.

| Field | Value | Source of value |
|---|---|---|
| resolver | System assigned **On** | `infra/prereqs/function-app.bicep` |
| sync | User assigned: sync UAMI | form `names.identities.sync` |
| reconciler | User assigned: reconciler UAMI | form `names.identities.reconciler` |

**Screenshot:**
![Step 10.2 - Function App identity](./images/portal/10-2-function-app-identity.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** not needed after the Step 10.1 CLI block (it sets the identity). For a
Portal-created app:

```powershell
# EDIT: which app to align.
$app = 'resolver'
$identity = if ($app -eq 'resolver') { '[system]' } else { "$base/Microsoft.ManagedIdentity/userAssignedIdentities/$($p.names.identities[$app])" }
# WRITE: turns on / attaches the intended identity.
az functionapp identity assign --subscription $sub -g $rg -n $p.names.apps[$app].functionApp --identities $identity -o none
if ($LASTEXITCODE) { throw "identity assignment failed: $app" }
```

**Check:** Identity blade shows only the intended identity. Read-only:

```powershell
# EDIT: which app to check.
$app = 'resolver'
az functionapp identity show --subscription $sub -g $rg -n $p.names.apps[$app].functionApp `
    --query '{type:type,principalId:principalId,userAssigned:userAssignedIdentities}' -o json
if ($LASTEXITCODE) { throw "identity read failed: $app" }
```

#### Step 10.3 - Configure identity-based deployment storage

**Where:** Function App > Settings > **Deployment** (or Deployment settings) > deployment storage:
own storage account/container and correct managed identity > Save.

| Field | Value | Source of value |
|---|---|---|
| Storage account | Own account | form `names.apps.<app>.storageAccount` |
| Container | Own deployment container | form `names.apps.<app>.deploymentContainer` |
| Authentication | resolver: System assigned identity; sync/reconciler: User assigned identity (its **resource ID**, not its client ID) | Step 05.3 |

**Screenshot:**
![Step 10.3 - Deployment storage](./images/portal/10-3-deployment-storage.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** if the UI does not expose this choice, use only this deployment-storage
command (repeat with the right app):

```powershell
$app = 'resolver'
# WRITE: resolver deployment storage with its system identity.
az functionapp deployment config set --subscription $sub -g $rg -n $p.names.apps[$app].functionApp `
    --deployment-storage-name $p.names.apps[$app].storageAccount `
    --deployment-storage-container-name $p.names.apps[$app].deploymentContainer `
    --deployment-storage-auth-type SystemAssignedIdentity -o none
if ($LASTEXITCODE) { throw 'resolver deployment-storage configuration failed' }
# Sync/reconciler use the actual attached UAMI resource ID, not its client ID:
$app = 'sync'
$identityResourceId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($p.names.identities[$app])"
# WRITE: sync deployment storage with its UAMI.
az functionapp deployment config set --subscription $sub -g $rg -n $p.names.apps[$app].functionApp `
    --deployment-storage-name $p.names.apps[$app].storageAccount `
    --deployment-storage-container-name $p.names.apps[$app].deploymentContainer `
    --deployment-storage-auth-type UserAssignedIdentity --deployment-storage-auth-value $identityResourceId -o none
if ($LASTEXITCODE) { throw 'sync deployment-storage configuration failed' }
# Repeat the second block with $app = 'reconciler'.
```

**Check:** Runtime, plan, app identity, subnet, deployment container and MI selector
all correct. A portal-added storage grant may already exist; module 15 verifies/reuses it. Read-only:

```powershell
foreach ($app in 'resolver', 'sync', 'reconciler') {
    az functionapp deployment config show --subscription $sub -g $rg -n $p.names.apps[$app].functionApp `
        --query 'storage.{container:value,auth:authentication.type,identity:authentication.userAssignedIdentityResourceId}' -o json
    if ($LASTEXITCODE) { throw "deployment config read failed: $app" }
}
```

#### Step 10.4 - Record each app's IDs

**Where:** Function App > **Overview** > JSON view (Resource ID) and **Default domain**; Settings >
Identity > System assigned > Object (principal) ID (resolver).

| Field | Value | Source of value |
|---|---|---|
| Function App resource ID | Per app | evidence `apps.<app>.functionAppId` |
| Storage account resource ID | Per app | evidence `apps.<app>.storageAccountId` |
| Resolver principal ID | System identity object ID | evidence `apps.resolver.principalId` |
| Resolver default domain | Actual default hostname (may include a unique suffix) | evidence `apps.resolver.defaultHostName` |

**Screenshot:**
![Step 10.4 - Function App overview](./images/portal/10-4-function-app-overview.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** Step 13.6 fills every app's evidence from Azure (read-only).

**Check:** Disable timers before code deployment in module 17. Remove obsolete key-based
`AzureWebJobsStorage` configuration once identity-based host configuration is saved
(Step 17.4); do not retain both mechanisms ambiguously. No `WEBSITE_RUN_FROM_PACKAGE`
workaround or classic Consumption app replaces Flex. For required private resolver ingress,
complete module 12 before disabling its public access. Read-only:

```powershell
az functionapp show --subscription $sub -g $rg -n $p.names.apps.resolver.functionApp `
    --query '{id:id,host:defaultHostName,principalId:identity.principalId}' -o json
if ($LASTEXITCODE) { throw 'resolver not found' }
```

## 11. API Management

Select the approved **Standard v2/Premium v2** tier, units, publisher and zones.
Basic v2 does not offer the outbound VNet integration used here. Do not change a
customer's existing tier/topology without approval. Do not run `az apim update` as an
identity shortcut: it can remove the system identity the resolver trusts.

#### Step 11.1 - Create the APIM instance (or open the approved existing one)

**Where:** Portal > API Management services > **+ Create** > Basics > Monitoring + secure >
Virtual network > Managed identity > Tags > Review + install. For an approved existing instance,
open it and go to Step 11.2.

| Field | Value | Source of value |
|---|---|---|
| Subscription / RG / name | APIM location | form `apim.subscriptionId`, `apim.resourceGroup`, `apim.name` |
| Region | Same as its integration VNet | form `location` |
| Pricing tier / units | **Standard v2** or **Premium v2**; approved units | Decision record (Step 01.3) |
| Availability zones | Approved zones (set at creation only) | Decision record |
| Organization name / Administrator email | Publisher name / email | Customer |
| Virtual network (outbound) | APIM subnet | Step 03.3 |
| System assigned managed identity | **On** | This guide |

**Screenshot:**
![Step 11.1 - Create API Management](./images/portal/11-1-create-apim.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** **new instance only**. Never deploy this module over an existing APIM.

```powershell
# EDIT: approved tier, units, zones and publisher.
$apimSku = '<StandardV2-or-PremiumV2>'
$apimUnits = 1
$apimZones = @()
$publisherEmail = '<your-publisher-email>'
$publisherName = '<your-publisher-name>'
az apim show --subscription $p.apim.subscriptionId -g $p.apim.resourceGroup -n $p.apim.name -o none 2>$null
if ($LASTEXITCODE -eq 0) { throw 'APIM already exists: do not redeploy; continue at Step 11.2' }
$params = Save-CcofParameters 'apim' @{
    location = $p.location; tags = $p.tags; name = $p.apim.name; sku = $apimSku; units = $apimUnits; zones = $apimZones
    publisherEmail = $publisherEmail; publisherName = $publisherName; subnetId = $net.apimSubnetId
}
# WRITE: creates the APIM instance with system identity and outbound VNet integration (can take 30+ minutes).
az deployment group create --subscription $p.apim.subscriptionId -g $p.apim.resourceGroup `
    -n "$($p.names.deploymentPrefix)-portal-apim" -f ./infra/prereqs/apim.bicep -p $params --no-wait -o none
if ($LASTEXITCODE) { throw 'APIM deployment submission failed' }
```

**Check:** Notifications / APIM Overview shows the deployment Succeeded (close the shell while
it runs). Read-only:

```powershell
az apim show --subscription $p.apim.subscriptionId -g $p.apim.resourceGroup -n $p.apim.name `
    --query '{state:provisioningState,sku:sku.name,identity:identity.type,subnet:virtualNetworkConfiguration.subnetResourceId}' -o json
if ($LASTEXITCODE) { throw 'APIM not found' }
```

#### Step 11.2 - Set outbound VNet integration

**Where:** APIM > Deployment + infrastructure > **Network** (or Virtual network) > outbound
integration > dedicated APIM subnet > **Apply**.

| Field | Value | Source of value |
|---|---|---|
| Virtual network / subnet | Dedicated APIM subnet | Step 03.3 |

**Screenshot:**
![Step 11.2 - APIM outbound integration](./images/portal/11-2-apim-outbound-integration.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** none for an existing instance. `az apim update` is forbidden here and
`infra/prereqs/apim.bicep` must not be redeployed over an existing APIM; use the UI.

**Check:** `subnet` in the Step 11.1 check equals the APIM subnet ID.

#### Step 11.3 - Turn on the system-assigned identity

**Where:** APIM > Security > **Managed identities** > **System assigned** > Status **On** > Save.

| Field | Value | Source of value |
|---|---|---|
| Status | On | This guide |

**Screenshot:**
![Step 11.3 - APIM system identity](./images/portal/11-3-apim-system-identity.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** none for an existing instance (same reason as Step 11.2).

**Check:** `identity` in the Step 11.1 check includes `SystemAssigned`.

#### Step 11.4 - Record the APIM IDs

**Where:** APIM > Security > Managed identities > Object (principal) ID; APIM **Overview** > Gateway
URL; Properties/JSON view > resource ID. Entra > **Enterprise applications** > include managed
identities/application-type filter > locate that object ID > record its **Application ID**
(managed-identity client ID).

| Field | Value | Source of value |
|---|---|---|
| Resource ID | APIM resource ID | evidence `apim.id` |
| Principal (object) ID | System identity | evidence `apim.principalId` |
| Application ID | Managed-identity client ID | evidence `apim.appId` |
| Gateway URL | `https://<apim>.azure-api.net` (or custom) | evidence `apim.gatewayUrl` |

**Screenshot:**
![Step 11.4 - APIM identity IDs](./images/portal/11-4-apim-identity-ids.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** if the UI cannot find it, this read-only CLI lookup is sufficient
(Step 13.6 also fills the other APIM evidence):

```powershell
az ad sp show --id $e.apim.principalId --query appId -o tsv
if ($LASTEXITCODE) { throw 'APIM managed-identity client ID could not be read' }
```

**Check:** APIM Succeeded, correct outbound subnet, system identity On. Return to
Step 07.6 for its Foundry grants. Outbound integration alone **does not make gateway ingress
private**; preserve the customer's approved WAF/private-endpoint/edge controls.

## 12. Private resolver ingress and network acceptance

Customer-approved public-access disable/access-restriction controls follow their
ingress design. For private publishing, plan access to the deployment/SCM endpoint as well
as the runtime endpoint. Ordinary Cloud Shell may fail to publish to a private-only app.
Use the customer's approved network-connected workstation/runner instead; do not
turn public access back on.

#### Step 12.1 - Create the resolver inbound private endpoint

**Where:** Resolver Function App > Settings > **Networking** > Inbound traffic configuration >
**Private endpoints** > **+ Add** (Express or Advanced) > subnet > Integrate with private DNS zone **Yes**.

| Field | Value | Source of value |
|---|---|---|
| Name | Approved PE name | Network team |
| Target sub-resource | `sites` | [manual deployment](../MANUAL-DEPLOYMENT.md) |
| Virtual network / subnet | Private endpoint subnet reachable from APIM | form network PE subnet |
| Private DNS | `privatelink.azurewebsites.net` (Step 12.2) | Network team |

**Screenshot:**
![Step 12.1 - Resolver private endpoint](./images/portal/12-1-resolver-private-endpoint.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** the `private-endpoint create` pattern of [manual deployment](../MANUAL-DEPLOYMENT.md),
targeting the resolver site.

```powershell
# EDIT: approved resolver PE name.
$resolverPe = '<your-resolver-pe-name>'
# WRITE: creates the resolver inbound private endpoint.
az network private-endpoint create --subscription $sub -g $rg -n $resolverPe --location $p.location `
    --subnet $net.peSubnetId --private-connection-resource-id $e.apps.resolver.functionAppId --group-id sites `
    --connection-name "$resolverPe-connection" -o none
if ($LASTEXITCODE) { throw 'resolver private endpoint creation failed' }
```

**Check:** Networking > Private endpoints shows it **Approved**. Read-only:

```powershell
# EDIT: approved resolver PE name.
$resolverPe = '<your-resolver-pe-name>'
az network private-endpoint show --subscription $sub -g $rg -n $resolverPe `
    --query '{status:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status,group:privateLinkServiceConnections[0].groupIds[0]}' -o json
if ($LASTEXITCODE) { throw 'resolver private endpoint not found' }
```

#### Step 12.2 - Attach the `privatelink.azurewebsites.net` zone to the endpoint

**Where:** Portal > Private endpoints > *resolver PE* > Settings > **DNS configuration** > **+ Add
configuration**. Use the existing/approved zone; create a zone (Private DNS zones > + Create)
only when the DNS team says none exists.

| Field | Value | Source of value |
|---|---|---|
| Private DNS zone | `privatelink.azurewebsites.net` (existing approved zone ID) | Network/DNS team |

**Screenshot:**
![Step 12.2 - Resolver DNS configuration](./images/portal/12-2-resolver-dns-configuration.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
# EDIT: resolver PE name and the approved privatelink.azurewebsites.net zone resource ID.
$resolverPe = '<your-resolver-pe-name>'
$sitesZoneId = '<your-privatelink-azurewebsites-zone-resource-id>'
# WRITE: attaches the zone to the endpoint.
az network private-endpoint dns-zone-group create --subscription $sub -g $rg --endpoint-name $resolverPe `
    -n default --zone-name sites --private-dns-zone $sitesZoneId -o none
if ($LASTEXITCODE) { throw 'resolver DNS zone group failed' }
```

**Check:** DNS configuration lists the resolver and its `scm` FQDNs with private IPs. Read-only:

```powershell
# EDIT: resolver PE name.
$resolverPe = '<your-resolver-pe-name>'
az network private-endpoint dns-zone-group list --subscription $sub -g $rg --endpoint-name $resolverPe `
    --query '[].privateDnsZoneConfigs[].recordSets[].{fqdn:fqdn,ip:ipAddresses[0]}' -o table
if ($LASTEXITCODE) { throw 'zone group listing failed' }
```

#### Step 12.3 - Link the zone to APIM's caller network

**Where:** Portal > Private DNS zones > `privatelink.azurewebsites.net` > **Virtual network links** >
**+ Add**. Link the offered zone to APIM's caller network.

| Field | Value | Source of value |
|---|---|---|
| Link name | `<vnet>-link` | Naming as Step 03.7 |
| Virtual network | VNet APIM integrates with (Step 11.2) | Network team |
| Enable auto registration | Off | This guide |

**Screenshot:**
![Step 12.3 - Sites zone link](./images/portal/12-3-sites-zone-link.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
# EDIT: the zone resource ID and APIM's caller VNet resource ID.
$sitesZoneId = '<your-privatelink-azurewebsites-zone-resource-id>'
$apimVnetId = '<apim-caller-vnet-resource-id>'
$z = $sitesZoneId -split '/'
# WRITE: links the zone without auto-registration.
az network private-dns link vnet create --subscription $z[2] -g $z[4] -z $z[-1] -n "$(($apimVnetId -split '/')[-1])-link" `
    -v $apimVnetId -e false -o none
if ($LASTEXITCODE) { throw 'sites zone link failed' }
```

**Check:** Read-only:

```powershell
# EDIT: the zone resource ID.
$sitesZoneId = '<your-privatelink-azurewebsites-zone-resource-id>'
$z = $sitesZoneId -split '/'
az network private-dns link vnet list --subscription $z[2] -g $z[4] -z $z[-1] `
    --query '[].{vnet:virtualNetwork.id,autoRegistration:registrationEnabled,state:virtualNetworkLinkState}' -o table
if ($LASTEXITCODE) { throw 'link listing failed' }
```

#### Step 12.4 - Disable resolver public access (per the approved ingress design)

**Where:** Resolver Function App > Settings > **Networking** > Inbound traffic configuration >
**Public network access** > **Disabled** > Save. Only after Steps 12.1-12.3 resolve privately
and code publishing has an approved private path.

| Field | Value | Source of value |
|---|---|---|
| Public network access | Disabled | Customer ingress design |

**Screenshot:**
![Step 12.4 - Resolver public access](./images/portal/12-4-resolver-public-access.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** an explicit minimal PATCH from [manual deployment](../MANUAL-DEPLOYMENT.md),
with no identity replacement.

```powershell
$resolverId = $e.apps.resolver.functionAppId
$bodyFile = Join-Path $artifacts 'resolver-private-inbound.json'
'{"properties":{"publicNetworkAccess":"Disabled"}}' | Set-Content $bodyFile -Encoding utf8NoBOM
# WRITE: disables the resolver's public network access.
az rest --method patch --url "https://management.azure.com$resolverId`?api-version=2024-04-01" --body "@$bodyFile" -o none
if ($LASTEXITCODE) { throw 'resolver public access change failed' }
```

**Check:** Read-only:

```powershell
az resource show --ids $e.apps.resolver.functionAppId --query '{public:properties.publicNetworkAccess,identity:identity.type}' -o json
if ($LASTEXITCODE) { throw 'resolver read failed' }
```

#### Step 12.5 - Restrict the sync and reconciler inbound surfaces

**Where:** Sync / reconciler Function App > Settings > **Networking** > Inbound traffic configuration
(public network access / access restrictions) according to the customer's ingress design. Their
outbound VNet integration is not an inbound firewall.

| Field | Value | Source of value |
|---|---|---|
| Inbound controls | Customer-approved design | Network/security team |

**Screenshot:**
![Step 12.5 - Sync and reconciler inbound](./images/portal/12-5-sync-reconciler-inbound.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** none; the controls are customer-specific (no repository default).

**Check:** Read-only:

```powershell
foreach ($app in 'sync', 'reconciler') {
    az resource show --ids $e.apps[$app].functionAppId `
        --query '{public:properties.publicNetworkAccess,restrictions:properties.siteConfig.ipSecurityRestrictions}' -o json
    if ($LASTEXITCODE) { throw "read failed: $app" }
}
```

#### Step 12.6 - Run the network acceptance from the actual caller networks

**Where:** From APIM's integrated network (a private runner or network-isolated Cloud Shell), the
Functions' network and the operator workstation, as the network team arranges.

| Field | Value | Source of value |
|---|---|---|
| Names to resolve | Cosmos, blob (three accounts), resolver, `<account>.services.ai.azure.com` | Evidence and form |
| Expected | Approved private endpoint IPs | Steps 07.5, 08.2, 09.2, 12.2 |

**Screenshot:**
![Step 12.6 - Private DNS resolution](./images/portal/12-6-private-dns-resolution.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** none in `az`; DNS and reachability must be tested from the caller networks
(`Resolve-DnsName` on a Windows private runner or `nslookup` in network-isolated Cloud Shell).

**Check:** From the actual caller networks, Cosmos/blob/resolver/Foundry names resolve
and route to approved private destinations. DNS-zone existence is not proof of caller
DNS. APIM can reach resolver HTTPS; Functions can reach private Cosmos/blob and
their approved Graph/Monitor egress. Read-only (lists every PE and its connection state):

```powershell
az network private-endpoint list --subscription $sub -g $rg `
    --query '[].{name:name,status:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}' -o table
if ($LASTEXITCODE) { throw 'private endpoint listing failed' }
```

## 13. Record values once; reload after each shell reconnect

The existing parameter **form is only a structured configuration input here**.
Retain its `using 'main.bicep'` reference for local compilation; no template is deployed
by this module. Give the customer control of region, CIDRs, rates, capacity and settings.

Open Cloud Shell **PowerShell**, not Bash, or use PowerShell 7 on the approved workstation.
Choose a reviewed repository commit containing this guide; do not execute an arbitrary future
`main` without review. Local artifact rendering runs TypeScript directly and requires a Node
version with the repository's supported native TypeScript handling (Node 26 used by release tests);
deployed Function Apps remain Node 22. `node --version`, `pwsh --version`, `az version` identify
the actual tools. If Cloud Shell lacks the needed Node version, build locally/CI and upload the
reviewed artifacts rather than changing global machine settings.

#### Step 13.1 - Open the shell at the reviewed repository commit

**Where:** Portal > top bar **Cloud Shell** icon > **PowerShell** (or PowerShell 7 on the approved
workstation) > repository root.

| Field | Value | Source of value |
|---|---|---|
| Shell | PowerShell | This guide |
| Repository ref | Reviewed commit or tag containing this guide | Platform reviewer |

**Screenshot:**
![Step 13.1 - Cloud Shell PowerShell](./images/portal/13-1-cloud-shell-powershell.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
# EDIT: the reviewed commit or tag.
$reviewedRef = '<reviewed-commit-or-tag>'
if (-not (Test-Path ./ccof-bicep)) {
    git clone https://github.com/naveenneog/ccof-bicep.git ./ccof-bicep
    if ($LASTEXITCODE) { throw 'clone failed' }
}
Set-Location ./ccof-bicep
git fetch --tags origin
if ($LASTEXITCODE) { throw 'fetch failed' }
git checkout --detach $reviewedRef
if ($LASTEXITCODE) { throw "checkout of $reviewedRef failed" }
node --version
if ($LASTEXITCODE) { throw 'node missing' }
az version -o table
if ($LASTEXITCODE) { throw 'az missing' }
```

**Check:** `git rev-parse HEAD` prints the reviewed commit; `pwsh --version` is 7.x.

```powershell
git rev-parse HEAD
if ($LASTEXITCODE) { throw 'not a repository checkout' }
```

#### Step 13.2 - Copy the private form and evidence file

**Where:** Repository root in the shell.

| Field | Value | Source of value |
|---|---|---|
| Private form | `./infra/quickstart/.env.portal.bicepparam` | Copy of `customer-form.bicepparam` |
| Private evidence | `./.env.portal-evidence.json` | Copy of `scripts/portal/evidence.example.json` |

**Screenshot:**
![Step 13.2 - Copy private files](./images/portal/13-2-copy-private-files.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
# First time only, from the repository root. Do not overwrite an existing private form.
if (Test-Path ./infra/quickstart/.env.portal.bicepparam) { throw 'private form exists: restore/edit it, do not overwrite' }
Copy-Item ./infra/quickstart/customer-form.bicepparam ./infra/quickstart/.env.portal.bicepparam
Copy-Item ./scripts/portal/evidence.example.json ./.env.portal-evidence.json
# Edit both copies with the Cloud Shell editor or your approved local editor.
git check-ignore -q ./infra/quickstart/.env.portal.bicepparam ./.env.portal-evidence.json
if ($LASTEXITCODE) { throw 'private files are not git-ignored: stop and fix before editing' }
```

**Check:** `git status --short` does not list either private file.

```powershell
git status --short
if ($LASTEXITCODE) { throw 'git status failed' }
```

#### Step 13.3 - Fill the private form

**Where:** Cloud Shell > **{ }** editor (or `code <file>`) > `./infra/quickstart/.env.portal.bicepparam`.
Copy it to a private `.env` file and fill actual names/IDs even for manually created resources.

| Field | Value | Source of value |
|---|---|---|
| `tenantId`, `location`, `tags` | Approved values | Step 01.3 |
| `names.*` (subscription, RG, every resource name) | Actual (or, CLI-first, planned) names | Modules 02-11 |
| `network.mode` and `network.create` / `network.existing` | Real CIDRs or real existing subnet and zone **resource IDs** | Module 03 |
| `apim.*` | Real APIM name/subscription/RG; `apiId`, `apiPath`, `apiDisplayName` | Module 11 |
| `backends[]` | Exact account, URL, deployment IDs and geography | Module 07 |
| `registrations.*`, `groups[]` | App IDs and group object IDs; explicit classification/backend entries | Module 06 |
| `runner.enabled` | `false` | This guide |
| `sync.mode` | `'application-permission'` | This guide |
| `syncTimerEnabled`, `reconciler.timerEnabled` | `false`, `false` | This guide |

Set `runner.enabled=false`, `sync.mode='application-permission'`,
`syncTimerEnabled=false`, `reconciler.timerEnabled=false`. Use the real existing
network IDs, real resource names, exact models and explicit classification/backend entries.

**Screenshot:**
![Step 13.3 - Edit private form](./images/portal/13-3-edit-private-form.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** none beyond opening the editor; values are typed by the operator.

```powershell
code ./infra/quickstart/.env.portal.bicepparam
if ($LASTEXITCODE) { throw 'editor did not open; use the Cloud Shell editor button' }
```

**Check:** Step 13.4 compiles it; Step 13.6 finds no `REPLACE-` placeholder.

#### Step 13.4 - Load the variables (every new session)

**Where:** Shell, repository root.

| Field | Value | Source of value |
|---|---|---|
| `$p` | Compiled form values | Private form |
| `$e` | Evidence values | Private evidence file |
| `$sub`, `$rg` | `names.subscriptionId`, `names.resourceGroup` | Private form |

**Screenshot:**
![Step 13.4 - Load variables](./images/portal/13-4-load-variables.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

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

```powershell
az account show --query '{tenant:tenantId,subscription:id}' -o json
if ($LASTEXITCODE) { throw 'not signed in' }
```

#### Step 13.5 - Load the CLI helpers (every new session, after Step 13.4)

**Where:** Shell, same session.

| Field | Value | Source of value |
|---|---|---|
| `$base` | `/subscriptions/<sub>/resourceGroups/<rg>/providers` | `$sub`, `$rg` |
| `$net` | Subnet, VNet and zone IDs for either network mode | form `network` |
| `Save-CcofParameters` | Writes an ARM parameters file under `$artifacts`, returns `@<path>` | This guide |
| `Save-CcofEvidence` | Writes `$e` back to the private evidence file | This guide |

**Screenshot:**
![Step 13.5 - Load CLI helpers](./images/portal/13-5-load-cli-helpers.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
$base = "/subscriptions/$sub/resourceGroups/$rg/providers"
New-Item -ItemType Directory -Force -Path $artifacts | Out-Null
if ($p.network.mode -eq 'create') {
    $c = $p.network.create
    $vnetId = "$base/Microsoft.Network/virtualNetworks/$($c.vnetName)"
    $net = @{
        vnetId = $vnetId; apimSubnetId = "$vnetId/subnets/$($c.subnets.apim.name)"
        peSubnetId = "$vnetId/subnets/$($c.subnets.privateEndpoints.name)"; functionsSubnetId = "$vnetId/subnets/$($c.subnets.functions.name)"
        cosmosZoneId = "$base/Microsoft.Network/privateDnsZones/privatelink.documents.azure.com"
        blobZoneId = "$base/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
    }
} else {
    $x = $p.network.existing
    $net = @{
        vnetId = ($x.functionsSubnetId -split '/subnets/')[0]; apimSubnetId = ''
        peSubnetId = $x.privateEndpointSubnetId; functionsSubnetId = $x.functionsSubnetId
        cosmosZoneId = $x.privateDnsZoneIds.cosmos; blobZoneId = $x.privateDnsZoneIds.blob
    }
}
function Save-CcofParameters([string]$Name, [hashtable]$Values) {
    $file = Join-Path $artifacts "$Name.parameters.json"
    $parameters = [ordered]@{}
    foreach ($key in $Values.Keys) { $parameters[$key] = @{ value = $Values[$key] } }
    [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'; parameters = $parameters
    } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $file -Encoding utf8NoBOM
    return "@$file"
}
function Save-CcofEvidence { $e | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $evidenceFile -Encoding utf8NoBOM }
az bicep version
if ($LASTEXITCODE) { throw 'Bicep CLI missing: run az bicep install' }
```

**Check:** `$net` prints the IDs you expect for your network mode.

```powershell
$net
az network vnet subnet show --ids $net.functionsSubnetId --query id -o tsv
if ($LASTEXITCODE) { throw 'Functions subnet not found yet (expected only before module 03 is done)' }
```

#### Step 13.6 - Fill the evidence file

**Where:** Copy from each resource's Portal blade:

| Field | Value | Source of value |
|---|---|---|
| Every `...Id` | Resource ID from the resource's **Properties / JSON view** | Portal |
| `workspace.customerId` | LAW **Workspace ID** from Properties | Step 04.3 |
| `apps.<app>.principalId`, `clientId` | MI IDs from Identity / Managed identities | Steps 05.3, 10.4 |
| `apim.gatewayUrl` | APIM Overview Gateway URL | Step 11.4 |
| `apim.gatewayIdentifierUri` | Gateway registration **Expose an API** Application ID URI | Step 06.2 |
| `apps.resolver.clientId` | Keep empty | This guide |
| `apps.resolver.defaultHostName` | Resolver app Overview **Default domain** | Step 10.4 |
| `apps.reconciler.appInsightsId` | Keep empty for the baseline configuration | This guide |
| `cosmos.endpoint` | `https://<account>.documents.azure.com:443/` | Step 08.1 |

Evidence file: copy Resource ID from each resource's **Properties / JSON view**,
LAW Workspace ID from Properties, MI IDs from Identity/Managed identities,
APIM Gateway URL from Overview and gateway Application ID URI from Expose an API.
Keep resolver `clientId` empty; sync/reconciler use their UAMI client IDs.
Copy the resolver's actual **Default domain** from its app Overview into
`apps.resolver.defaultHostName`; do not infer it from the app name when Azure adds
a unique hostname suffix.
Leave reconciler `appInsightsId` empty for the baseline configuration.
Cosmos evidence URI uses `https://<account>.documents.azure.com:443/`.

**Screenshot:**
![Step 13.6 - Fill evidence](./images/portal/13-6-fill-evidence.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** read-only; fills every value from the existing resources and saves the
private file (the connection strings stay in that private file only).

```powershell
$e.target.subscriptionId = $sub
$cosmos = az cosmosdb show --subscription $sub -g $rg -n $p.names.cosmosAccount -o json | ConvertFrom-Json
if ($LASTEXITCODE) { throw 'Cosmos account not found' }
$e.cosmos.id = $cosmos.id; $e.cosmos.endpoint = $cosmos.documentEndpoint
$law = az monitor log-analytics workspace show --subscription $sub -g $rg -n $p.names.logAnalyticsWorkspace -o json | ConvertFrom-Json
if ($LASTEXITCODE) { throw 'workspace not found' }
$e.workspace.id = $law.id; $e.workspace.customerId = $law.customerId
$apim = az apim show --subscription $p.apim.subscriptionId -g $p.apim.resourceGroup -n $p.apim.name -o json | ConvertFrom-Json
if ($LASTEXITCODE) { throw 'APIM not found' }
$e.apim.id = $apim.id; $e.apim.principalId = $apim.identity.principalId; $e.apim.gatewayUrl = $apim.gatewayUrl
$e.apim.appId = az ad sp show --id $apim.identity.principalId --query appId -o tsv
if ($LASTEXITCODE) { throw 'APIM managed-identity client ID could not be read' }
$e.apim.gatewayIdentifierUri = az ad app show --id $p.registrations.gatewayApi.appId --query 'identifierUris[0]' -o tsv
if ($LASTEXITCODE) { throw 'gateway registration not found' }
foreach ($app in 'resolver', 'sync', 'reconciler') {
    $n = $p.names.apps[$app]
    $site = az functionapp show --subscription $sub -g $rg -n $n.functionApp -o json | ConvertFrom-Json
    if ($LASTEXITCODE) { throw "Function App not found: $app" }
    $storageId = az storage account show --subscription $sub -g $rg -n $n.storageAccount --query id -o tsv
    if ($LASTEXITCODE) { throw "storage not found: $app" }
    $e.apps[$app].functionAppId = $site.id; $e.apps[$app].storageAccountId = $storageId
    if ($n.appInsights) {
        $ai = az resource show --subscription $sub -g $rg -n $n.appInsights --resource-type Microsoft.Insights/components -o json | ConvertFrom-Json
        if ($LASTEXITCODE) { throw "component not found: $app" }
        $e.apps[$app].appInsightsId = $ai.id; $e.apps[$app].connectionString = $ai.properties.ConnectionString
    } else { $e.apps[$app].appInsightsId = '' }
    if ($app -eq 'resolver') {
        $e.apps[$app].principalId = $site.identity.principalId; $e.apps[$app].clientId = ''
        $e.apps[$app].defaultHostName = $site.defaultHostName
    } else {
        $mi = az identity show --subscription $sub -g $rg -n $p.names.identities[$app] -o json | ConvertFrom-Json
        if ($LASTEXITCODE) { throw "identity not found: $app" }
        $e.apps[$app].principalId = $mi.principalId; $e.apps[$app].clientId = $mi.clientId
    }
}
Save-CcofEvidence
```

**Check:** Neither private file contains a `REPLACE-` placeholder; the form still compiles.

```powershell
$left = Select-String -Path $form, $evidenceFile -Pattern 'REPLACE-' | Where-Object { $_.Line -notmatch '^\s*//' }
if ($left) { $left | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }; throw 'placeholders remain' }
az bicep build-params --file $form --stdout | Out-Null
if ($LASTEXITCODE) { throw 'private form did not compile' }
```

## 14. Generate UI configuration artifacts, without deploying

This calls shared **pure configuration/schema helpers**, not Quickstart's deploy,
state/resume dispatcher, Azure discovery, seed execution or code publication.
`az bicep build-params` is local compilation.

#### Step 14.1 - Restore dependencies

**Where:** Shell, repository root.

| Field | Value | Source of value |
|---|---|---|
| When | First checkout or lockfile change | This guide |

**Screenshot:**
![Step 14.1 - npm ci](./images/portal/14-1-npm-ci.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
# Dependencies only on first checkout or lockfile change:
npm ci --ignore-scripts --no-audit --no-fund
if ($LASTEXITCODE) { throw 'dependency restore failed' }
```

**Check:** `node_modules` exists; `npm ls --depth=0` exits 0.

```powershell
npm ls --depth=0
if ($LASTEXITCODE) { throw 'dependency tree incomplete' }
```

#### Step 14.2 - Export the artifacts

**Where:** Shell, repository root, after Steps 13.4-13.6.

| Field | Value | Source of value |
|---|---|---|
| `-ParametersPath` | `$form` | Step 13.4 |
| `-EvidencePath` | `$evidenceFile` | Step 13.4 |
| `-OutputDirectory` | `$artifacts` (`./.env.portal-artifacts`, git-ignored) | Step 13.4 |

**Screenshot:**
![Step 14.2 - Export artifacts](./images/portal/14-2-export-artifacts.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
pwsh -NoProfile -File ./scripts/portal/Export-PortalArtifacts.ps1 `
    -ParametersPath $form -EvidencePath $evidenceFile -OutputDirectory $artifacts
if ($LASTEXITCODE) { throw 'artifact export failed; do not apply partial output' }
```

**Check:** Export exits 0 and every file in Step 14.3 exists.

```powershell
foreach ($f in 'resolver-settings.json', 'sync-settings.json', 'reconciler-settings.json', 'gateway-config.json',
    "gateway/$($p.apim.apiId).policy.xml", 'registry-documents.json', 'seed-payload.txt', 'seed-id.txt', 'chargeback.workbook.json') {
    if (-not (Test-Path (Join-Path $artifacts $f))) { throw "missing artifact: $f" }
}
git check-ignore -q $artifacts
if ($LASTEXITCODE) { throw 'artifact directory is not git-ignored' }
```

#### Step 14.3 - Review each artifact

**Where:** Cloud Shell editor or approved local editor, `$artifacts` folder.

| Artifact | UI destination |
|---|---|
| `resolver-settings.json`, `sync-settings.json`, `reconciler-settings.json` | Function App > Environment variables > App settings > Advanced edit |
| `gateway-config.json` | Private review record for gateway renderer inputs |
| `gateway/<apiId>.policy.xml` | APIM API > Design > All operations > Inbound policy code editor |
| `registry-documents.json` | Review one project per ID, explicit classifications and backend descriptors |
| `seed-payload.txt`, `seed-id.txt` | Temporary sync seed settings / correlation ID in module 21 |
| `chargeback.workbook.json` | LAW > Workbooks > New > Advanced Editor |

**Screenshot:**
![Step 14.3 - Review artifacts](./images/portal/14-3-review-artifacts.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** none; this is a human review of local files.

**Check:** Exact model/family limits and routing agree with the approved
form. Budget amount alone does not enforce a dollar ceiling. `token-limits-only`
enforces token quotas/TPM, not cost-weighted cached usage. `budget-state` adds delayed
reconciler-based budget enforcement only after telemetry and its timer work.
See [chargeback](../CHARGEBACK.md); cached-cost assumptions are estimates, not guarantees.
Do not treat individual family caps as permission to exceed the aggregate cap.

## 15. Administrator grants app access, one app at a time

**Meaning of "automatic admin grant":** an authorized administrator applies a reviewed
runtime-access plan to an existing managed identity. The app does **not** become an
admin, request its own consent, use a secret, or bypass PIM.

| Identity | Role | Scope |
|---|---|---|
| Each app | Storage Blob Data Owner | Its own host/deployment storage account |
| Resolver and sync | Monitoring Metrics Publisher | Its own Application Insights component |
| Reconciler | Log Analytics Reader | The ledger LAW |
| APIM | Cognitive Services User | Each approved same-tenant Foundry account (module 07) |

| Cosmos identity | Native data access |
|---|---|
| Resolver | Built-in Data Reader on the registry database |
| Sync | Custom read/create/replace writer on entitlement and syncLease; projects reader; create-only seed writer on projects and backends |
| Reconciler | projects/entitlement reader; custom read/create/replace/upsert writer on budgetState, aggregateBudgetState and reconcilerLease |

Cosmos **native SQL** role definitions/assignments are distinct from Azure IAM and have no
Portal UI here. Use the necessary helper (Steps 15.2-15.3); it also verifies/reuses the Azure
IAM grants above. Do not add Owner/Contributor or broad Cosmos Data Contributor as a shortcut.

#### Step 15.1 - Add the Azure IAM runtime grants in the UI (optional)

**Where:** *resource* > **Access control (IAM)** > **+ Add** > **Add role assignment** > Role > Members:
**Managed identity** > + Select members > the intended Function App system identity or UAMI >
**Review + assign**. One row of the first table above per assignment.

| Field | Value | Source of value |
|---|---|---|
| Role | Storage Blob Data Owner / Monitoring Metrics Publisher / Log Analytics Reader | Table above (`infra/quickstart/modules/rbac.bicep`) |
| Scope | Own storage / own Insights / LAW | evidence `apps.<app>.storageAccountId`, `apps.<app>.appInsightsId`, `workspace.id` |
| Member | App identity | evidence `apps.<app>.principalId` |

**Screenshot:**
![Step 15.1 - Add role assignment](./images/portal/15-1-add-role-assignment.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** Steps 15.2-15.3 (the helper plans, creates or reuses exactly these grants).

**Check:** IAM > Role assignments shows the grant. Read-only:

```powershell
# EDIT: which app to check.
$app = 'resolver'
az role assignment list --all --assignee-object-id $e.apps[$app].principalId --query '[].{role:roleDefinitionName,scope:scope}' -o table
if ($LASTEXITCODE) { throw "assignment listing failed: $app" }
```

#### Step 15.2 - Review one app's access plan

**Where:** Shell, repository root. Choose one `$app`, review its plan.

| Field | Value | Source of value |
|---|---|---|
| `-App` | `resolver`, then `sync`, then `reconciler` | This guide |

**Screenshot:**
![Step 15.2 - Access plan](./images/portal/15-2-access-plan.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
$app = 'resolver'  # Then repeat these two commands with 'sync', then 'reconciler'.
pwsh -NoProfile -File ./scripts/portal/Grant-PortalAppAccess.ps1 `
    -ParametersPath $form -EvidencePath $evidenceFile -App $app -OutputDirectory $artifacts
if ($LASTEXITCODE) { throw 'access plan failed; nothing should be applied' }
```

**Check:** The plan names only this app's principal, only the roles in the tables above,
and no Owner/Contributor/Data Contributor.

#### Step 15.3 - Apply that app's plan (access administrator)

**Where:** Shell, same session, after the responsible access administrator reviewed Step 15.2.

| Field | Value | Source of value |
|---|---|---|
| `-App` | Same app as Step 15.2 | Step 15.2 |
| `-Apply` | Present | Approval |

**Screenshot:**
![Step 15.3 - Access apply receipt](./images/portal/15-3-access-apply-receipt.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
$app = 'resolver'  # The same app as the reviewed plan.
# WRITE: run only after the responsible access administrator reviewed this plan:
pwsh -NoProfile -File ./scripts/portal/Grant-PortalAppAccess.ps1 `
    -ParametersPath $form -EvidencePath $evidenceFile -App $app -OutputDirectory $artifacts -Apply
if ($LASTEXITCODE) { throw 'access grant not verified; inspect the receipt and fix this app only' }
```

The helper discovers no new resources, grants no Graph permissions, changes no settings
and publishes no code. It checks the app's **live attached identity** against the UI record,
checks the operator's assignment rights before writes, uses shared staged-D3 permission
definitions, and verifies grants. Existing grants are reused. Existing custom roles
with different actions are refused, not overwritten.

**Check:** `<app>-access-receipt.json` has only created/existing/inherited results.
Save receipts and `<app>-access-audit.json` privately. A timeout is unverified, not
success; inspect current role assignments and rerun the **same app**. Role propagation
can delay runtime access even after management read-back. Read-only:

```powershell
$app = 'resolver'
$receipt = Get-Content (Join-Path $artifacts "$app-access-receipt.json") -Raw | ConvertFrom-Json
@($receipt) | Where-Object { $_.state -notin 'created', 'existing', 'inherited' }
az cosmosdb sql role assignment list --subscription $sub -g $rg -a $p.names.cosmosAccount `
    --query "[?principalId=='$($e.apps[$app].principalId)'].{role:roleDefinitionId,scope:scope}" -o table
if ($LASTEXITCODE) { throw 'Cosmos SQL assignment listing failed' }
```

## 16. Graph permissions: a separate privileged approval

A managed identity has no ordinary app-registration API-permissions page where
you can configure these Graph application roles. The Entra privileged administrator
activates PIM, refreshes their sign-in if needed, and runs this existing narrow helper
with the **sync identity's principal/object ID**. No Quickstart state file is needed.

#### Step 16.1 - Activate the privileged directory role

**Where:** Entra admin center > Identity governance > Privileged Identity Management > My roles >
**Microsoft Entra roles** > Privileged Role Administrator (or Global Administrator) > **Activate**.
Then sign out and back in (Cloud Shell: `az login`) so the token carries the role.

| Field | Value | Source of value |
|---|---|---|
| Role | Privileged Role Administrator or Global Administrator | [permissions](../PERMISSIONS.md) |

**Screenshot:**
![Step 16.1 - Activate Privileged Role Administrator](./images/portal/16-1-activate-privileged-role.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** none (no `az` command for PIM activation).

**Check:** PIM > My roles > Active assignments lists the role.

#### Step 16.2 - Review the Graph permission plan

**Where:** Shell, repository root.

| Field | Value | Source of value |
|---|---|---|
| `-SyncPrincipalId` | Sync UAMI principal/object ID | evidence `apps.sync.principalId` |

**Screenshot:**
![Step 16.2 - Graph permission plan](./images/portal/16-2-graph-permission-plan.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
pwsh -NoProfile -File ./infra/quickstart/Grant-SyncGraphPermissions.ps1 `
    -SyncPrincipalId $e.apps.sync.principalId -PlanOnly
if ($LASTEXITCODE) { throw 'Graph permission plan failed' }
```

**Check:** The plan lists exactly `GroupMember.Read.All`, `User.Read.All`, `Application.Read.All`.

#### Step 16.3 - Grant the three Graph application permissions

**Where:** Shell, same session, after explicit approval.

| Field | Value | Source of value |
|---|---|---|
| `-SyncPrincipalId` | Sync UAMI principal/object ID | evidence `apps.sync.principalId` |

**Screenshot:**
![Step 16.3 - Graph permission grant](./images/portal/16-3-graph-permission-grant.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
# WRITE: Entra privileged administrator, after explicit approval:
pwsh -NoProfile -File ./infra/quickstart/Grant-SyncGraphPermissions.ps1 `
    -SyncPrincipalId $e.apps.sync.principalId
if ($LASTEXITCODE) { throw 'Graph grant failed; keep sync disabled' }
```

The helper resolves and verifies `GroupMember.Read.All`, `User.Read.All`,
`Application.Read.All`, skips existing assignments, and prints assignment-specific
rollback commands. Its final message mentions Quickstart; **ignore that deployment
instruction on this path**. Module 21 enables the timer in the UI instead.

**Check:** All three assignments verified (Entra > Enterprise applications > filter Managed
Identities > sync identity > **Permissions** lists them). Managed-identity token caches can delay
new permissions; restarting is not a promise of immediate Graph propagation.
Do not swap to `Directory.ReadWrite.All`, create a secret or give the MI an Entra admin role. Read-only:

```powershell
az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$($e.apps.sync.principalId)/appRoleAssignments" `
    --query 'value[].{resource:resourceDisplayName,appRoleId:appRoleId,created:createdDateTime}' -o table
if ($LASTEXITCODE) { throw 'Graph read failed' }
```

## 17. Apply settings and lock the resolver to APIM

Generated values are strings. Do not blindly replace the whole list or erase unrelated
settings: `az functionapp config appsettings set` adds or updates only the names it is given.

#### Step 17.1 - Back up each app's existing settings

**Where:** Function App > Settings > **Environment variables** > **App settings** > **Advanced edit** >
copy the JSON into a private file. Export/back up existing settings privately first.

| Field | Value | Source of value |
|---|---|---|
| Backup file | `$artifacts/<app>-settings.backup.json` (git-ignored) | This guide |

**Screenshot:**
![Step 17.1 - App settings advanced edit](./images/portal/17-1-app-settings-advanced-edit.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** read-only (writes only the private backup file).

```powershell
foreach ($app in 'resolver', 'sync', 'reconciler') {
    $backup = Join-Path $artifacts "$app-settings.backup.json"
    az functionapp config appsettings list --subscription $sub -g $rg -n $p.names.apps[$app].functionApp -o json |
        Set-Content -LiteralPath $backup -Encoding utf8NoBOM
    if ($LASTEXITCODE) { throw "settings backup failed: $app" }
}
```

**Check:** Three backup files exist and are git-ignored.

```powershell
git check-ignore -q (Join-Path $artifacts 'resolver-settings.backup.json')
if ($LASTEXITCODE) { throw 'backup is not git-ignored' }
```

#### Step 17.2 - Merge the generated settings

**Where:** Function App > Settings > **Environment variables** > **App settings** > **Advanced edit** >
merge the corresponding generated settings with the existing customer-owned settings > **OK** >
**Apply** > Confirm.

| Field | Value | Source of value |
|---|---|---|
| Settings to merge | Every entry | `$artifacts/<app>-settings.json` (Step 14.2) |

Check identity-based `AzureWebJobsStorage__accountName`, `__credential=managedidentity`;
sync/reconciler also have `__clientId`. Check `COSMOS_ENDPOINT`, `COSMOS_DATABASE`,
`CCOF_APP_ROLE`, the correct Insights connection/authentication settings and all
generated resolver/sync/reconciler parameters. Reconciler workspace setting is
the LAW **Workspace ID GUID**, not an ARM resource ID.

**Screenshot:**
![Step 17.2 - Merge generated settings](./images/portal/17-2-merge-generated-settings.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** one app per run; adds/updates the generated names only.

```powershell
# EDIT: which app: 'resolver', then 'sync', then 'reconciler'.
$app = 'resolver'
$generated = Get-Content (Join-Path $artifacts "$app-settings.json") -Raw | ConvertFrom-Json
$merge = [ordered]@{}; foreach ($s in $generated) { $merge[$s.name] = [string]$s.value }
$settingsFile = Join-Path $artifacts "$app-settings.object.json"
$merge | ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding utf8NoBOM
# WRITE: merges the generated settings into the app (restarts it).
az functionapp config appsettings set --subscription $sub -g $rg -n $p.names.apps[$app].functionApp --settings "@$settingsFile" -o none
if ($LASTEXITCODE) { throw "settings merge failed: $app" }
```

**Check:** Every generated name has exactly the generated value. Read-only:

```powershell
# EDIT: which app to check.
$app = 'resolver'
$generated = Get-Content (Join-Path $artifacts "$app-settings.json") -Raw | ConvertFrom-Json
$live = az functionapp config appsettings list --subscription $sub -g $rg -n $p.names.apps[$app].functionApp -o json | ConvertFrom-Json
if ($LASTEXITCODE) { throw "settings read failed: $app" }
foreach ($s in $generated) {
    $value = @($live | Where-Object name -CEQ $s.name)[0].value
    if ([string]$value -cne [string]$s.value) { throw "setting differs or missing: $($s.name)" }
}
"settings match: $app"
```

#### Step 17.3 - Confirm the timers are disabled

**Where:** Function App > Environment variables > App settings. Before uploading code, confirm:

| App setting | Initial value | Source of value |
|---|---|---|
| `AzureWebJobs.syncEntitlement.Disabled` | `true` on sync | form `syncTimerEnabled=false` |
| `AzureWebJobs.registrySeed.Disabled` | `true` on sync | `infra/quickstart/modules/app-settings.bicep` |
| `AzureWebJobs.reconcileBudgets.Disabled` | `true` on reconciler | form `reconciler.timerEnabled=false` |

**Screenshot:**
![Step 17.3 - Timers disabled](./images/portal/17-3-timers-disabled.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** sets them explicitly (they are timers disabled until module 21).

```powershell
# WRITE: keeps every timer disabled.
az functionapp config appsettings set --subscription $sub -g $rg -n $p.names.apps.sync.functionApp `
    --settings 'AzureWebJobs.syncEntitlement.Disabled=true' 'AzureWebJobs.registrySeed.Disabled=true' -o none
if ($LASTEXITCODE) { throw 'sync timer settings failed' }
# WRITE:
az functionapp config appsettings set --subscription $sub -g $rg -n $p.names.apps.reconciler.functionApp `
    --settings 'AzureWebJobs.reconcileBudgets.Disabled=true' -o none
if ($LASTEXITCODE) { throw 'reconciler timer setting failed' }
```

**Check:** Read-only:

```powershell
foreach ($app in 'sync', 'reconciler') {
    az functionapp config appsettings list --subscription $sub -g $rg -n $p.names.apps[$app].functionApp `
        --query "[?ends_with(name, '.Disabled')].{name:name,value:value}" -o table
    if ($LASTEXITCODE) { throw "settings read failed: $app" }
}
```

#### Step 17.4 - Remove a key-based `AzureWebJobsStorage` setting

**Where:** Function App > Environment variables > App settings > `AzureWebJobsStorage` (exact name,
if present) > **Delete** > Apply. Only after Step 17.2 saved the identity-based host settings.

| Field | Value | Source of value |
|---|---|---|
| Setting to delete | `AzureWebJobsStorage` (not the `AzureWebJobsStorage__*` settings) | This guide |

**Screenshot:**
![Step 17.4 - Remove key-based storage setting](./images/portal/17-4-remove-key-based-storage.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
foreach ($app in 'resolver', 'sync', 'reconciler') {
    $names = az functionapp config appsettings list --subscription $sub -g $rg -n $p.names.apps[$app].functionApp --query '[].name' -o tsv
    if ($LASTEXITCODE) { throw "settings read failed: $app" }
    if ($names -ccontains 'AzureWebJobsStorage') {
        # WRITE: removes the key-based host storage setting.
        az functionapp config appsettings delete --subscription $sub -g $rg -n $p.names.apps[$app].functionApp `
            --setting-names AzureWebJobsStorage -o none
        if ($LASTEXITCODE) { throw "setting removal failed: $app" }
    }
}
```

**Check:** Only `AzureWebJobsStorage__*` names remain. Read-only:

```powershell
foreach ($app in 'resolver', 'sync', 'reconciler') {
    az functionapp config appsettings list --subscription $sub -g $rg -n $p.names.apps[$app].functionApp `
        --query "[?starts_with(name, 'AzureWebJobsStorage')].name" -o tsv
    if ($LASTEXITCODE) { throw "settings read failed: $app" }
}
```

#### Step 17.5 - Restrict the resolver to the APIM identity

**Where:** Resolver Function App > Settings > **Authentication** > **Add identity provider** >
**Microsoft** > Pick an existing app registration in this directory > Resolver API registration.

| Field | Value | Source of value |
|---|---|---|
| Tenant type / tenant | Workforce, current tenant | form `tenantId` |
| App registration | Existing Resolver API registration | form `registrations.resolverApi.appId` |
| Issuer URL | `https://login.microsoftonline.com/<tenant-id>/v2.0` | form `tenantId` |
| Allowed token audiences | `api://<resolver-app-id>` and `<resolver-app-id>` | form `registrations.resolverApi.appId` |
| Client application requirement > Allowed client applications | APIM managed-identity **app ID** | evidence `apim.appId` |
| Identity requirement > Allowed identities | APIM managed-identity **principal/object ID** | evidence `apim.principalId` |
| Restrict access | **Require authentication** | This guide |
| Unauthenticated requests | **HTTP 401 Unauthorized** | This guide |
| HTTPS only / Token store | On / **Off** | This guide |

No excluded path or empty allow-list. Do not select automatic app registration/browser login.

**Screenshot:**
![Step 17.5 - Resolver authentication](./images/portal/17-5-resolver-authentication.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** if the UI cannot expose both allow-lists, the necessary **auth-only**
exception is the repository helper. Review the plan first (`-PlanOnly` writes nothing):

```powershell
pwsh -NoProfile -File ./infra/poc/resolver-auth.ps1 -TenantId $p.tenantId `
    -SubscriptionId $sub -ResourceGroup $rg -FunctionAppName $p.names.apps.resolver.functionApp `
    -ResolverAppId $p.registrations.resolverApi.appId `
    -AllowedCallerAppIds $e.apim.appId -AllowedCallerObjectIds $e.apim.principalId -PlanOnly
if ($LASTEXITCODE) { throw 'resolver authentication plan failed' }
# WRITE: applies authsettingsV2 and verifies it by reading back.
pwsh -NoProfile -File ./infra/poc/resolver-auth.ps1 -TenantId $p.tenantId `
    -SubscriptionId $sub -ResourceGroup $rg -FunctionAppName $p.names.apps.resolver.functionApp `
    -ResolverAppId $p.registrations.resolverApi.appId `
    -AllowedCallerAppIds $e.apim.appId -AllowedCallerObjectIds $e.apim.principalId
if ($LASTEXITCODE) { throw 'resolver authentication configuration failed' }
```

**Check:** App settings saved; timers disabled; Authentication settings restrict both
APIM identity claims. Resolver anonymous call from an allowed network returns 401.
A network-level denial is a different result, not proof that authentication works. Read-only:

```powershell
az rest --method get --url "https://management.azure.com$($e.apps.resolver.functionAppId)/config/authsettingsV2?api-version=2024-04-01" `
    --query 'properties.{requireAuth:globalValidation.requireAuthentication,unauthenticated:globalValidation.unauthenticatedClientAction,audiences:identityProviders.azureActiveDirectory.validation.allowedAudiences,apps:identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications,principals:identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.identities,tokenStore:login.tokenStore.enabled}' -o json
if ($LASTEXITCODE) { throw 'authsettingsV2 read failed' }
```

## 18. Build and publish one app's code

**Why a small code step is necessary:** creating a Function App resource does not
install the repository's compiled code, dependencies, host.json or reconciler ledger/rate
files. Do not paste a standalone function into the portal and assume it is the full app.
Use the per-app packager; no all-resources deployment is involved.

#### Step 18.1 - Build one app's package

**Where:** Shell, repository root.

| Field | Value | Source of value |
|---|---|---|
| `-App` | `resolver`, then `sync`, then `reconciler` | This guide |
| `-RateCardPath`, `-ContractSchedulePath` (reconciler) | Approved private files when required (defaults `config/rate-card.json`, `config/contract-schedule.json`) | Customer pricing owner |

For the reconciler, review the packaged rate card and contract schedule; override
`-RateCardPath` and `-ContractSchedulePath` with approved private files when required.
Keep rate-card inputs consistent with the workbook artifact. Do not publish unreviewed
prices or mistake list-price reporting for negotiated Azure billing.

**Screenshot:**
![Step 18.1 - Build package](./images/portal/18-1-build-package.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
$app = 'resolver'  # Repeat with 'sync', then 'reconciler'.
pwsh -NoProfile -File ./scripts/portal/Build-PortalPackage.ps1 -App $app -OutputDirectory $artifacts
if ($LASTEXITCODE) { throw 'local package build failed' }
```

**Check:** `$artifacts/<app>.zip` exists; record its SHA-256 privately.

```powershell
$app = 'resolver'
Get-FileHash (Join-Path $artifacts "$app.zip") -Algorithm SHA256
git check-ignore -q (Join-Path $artifacts "$app.zip")
if ($LASTEXITCODE) { throw 'package is not git-ignored' }
```

#### Step 18.2 - Publish that app's package

**Where (GUI option):** on a network-connected workstation, open that app's generated
`packages/<app>` folder in VS Code (not the root multi-app repository), install/use the
approved Azure Functions extension, sign in, then Command Palette > **Azure Functions: Deploy
to Function App** > select the **existing intended app** > confirm code overwrite. Review output.

| Field | Value | Source of value |
|---|---|---|
| Target app | Existing intended app | form `names.apps.<app>.functionApp` |
| Package | `$artifacts/<app>.zip` / `packages/<app>` | Step 18.1 |

**Screenshot:**
![Step 18.2 - Deploy to Function App](./images/portal/18-2-deploy-to-function-app.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** if the extension/build path is unsuitable, use this single upload from
Cloud Shell or the approved workstation (a private-only app needs the approved private path):

```powershell
$app = 'resolver'  # The app whose package Step 18.1 built.
# WRITE: publishes code only; storage/IAM/network/settings must already be ready.
az functionapp deployment source config-zip --subscription $sub -g $rg `
    -n $p.names.apps[$app].functionApp --src (Join-Path $artifacts "$app.zip") -o none
if ($LASTEXITCODE) { throw "code upload failed or timed out: $app; inspect deployment status before retrying" }
az functionapp function list --subscription $sub -g $rg -n $p.names.apps[$app].functionApp -o table
if ($LASTEXITCODE) { throw "function discovery failed: $app" }
```

**Check:** Step 18.3.

#### Step 18.3 - Verify the app's functions

**Where:** Function App > Overview > **Functions** tab; Monitoring > **Log stream**.

| Field | Value | Source of value |
|---|---|---|
| Functions listed | Only that app's handlers | Package |

**Screenshot:**
![Step 18.3 - Functions list](./images/portal/18-3-functions-list.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** read-only, as below.

**Check:** Correct app's Functions blade lists its handlers; runtime logs contain no
storage/identity/startup errors. Package SHA-256 recorded. Empty function list is not success.
Only the resolver package runs resolver handlers, sync runs sync/seed handlers, and
reconciler runs reconciler handlers. A code upload overwrites that app's previous code;
retain the previous reviewed ZIP for rollback.

```powershell
foreach ($app in 'resolver', 'sync', 'reconciler') {
    $names = az functionapp function list --subscription $sub -g $rg -n $p.names.apps[$app].functionApp --query '[].name' -o tsv
    if ($LASTEXITCODE) { throw "function discovery failed: $app" }
    if (-not $names) { throw "no functions listed: $app" }
    "$app : $($names -join ', ')"
}
```

## 19. Create the API, operation, backend entities and policy

APIM resources live in form `apim.subscriptionId` / `apim.resourceGroup`. Use a new API revision
for a change to an existing live API, test it, then Revisions > Make current.

#### Step 19.1 - Create the API

**Where:** APIM > APIs > **+ Add API** > **HTTP** (manually define) > Full > Create; then API >
**Settings** > Subscription required **Off** > Save. Entra validation in the rendered policy
supplies developer authentication, not a subscription key.

| Field | Value | Source of value |
|---|---|---|
| Display name | `Claude Messages` | form `apim.apiDisplayName` |
| Name (API identifier) | `claude-messages` | form `apim.apiId` |
| API URL suffix | `anthropic` | form `apim.apiPath` |
| URL scheme | HTTPS | `infra/quickstart/modules/apim-api.bicep` |
| Subscription required | **Off** | same |

**Screenshot:**
![Step 19.1 - Add API](./images/portal/19-1-add-api.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
# WRITE: creates the HTTP API without a subscription key requirement.
az apim api create --subscription $p.apim.subscriptionId -g $p.apim.resourceGroup --service-name $p.apim.name `
    --api-id $p.apim.apiId --path $p.apim.apiPath --display-name $p.apim.apiDisplayName `
    --protocols https --subscription-required false -o none
if ($LASTEXITCODE) { throw 'API creation failed' }
```

**Check:** Read-only:

```powershell
az apim api show --subscription $p.apim.subscriptionId -g $p.apim.resourceGroup --service-name $p.apim.name --api-id $p.apim.apiId `
    --query '{path:path,protocols:protocols,subscriptionRequired:subscriptionRequired}' -o json
if ($LASTEXITCODE) { throw 'API not found' }
```

#### Step 19.2 - Add the `create-message` operation

**Where:** APIM > APIs > *API* > **Design** > **+ Add operation** > Save.

| Field | Value | Source of value |
|---|---|---|
| Display name | `Create message` | `infra/quickstart/modules/apim-api.bicep` |
| Name (identifier) | `create-message` | same |
| URL method / path | **POST** `/v1/messages` | same |

**Screenshot:**
![Step 19.2 - Add operation](./images/portal/19-2-add-operation.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
# WRITE: creates the single operation.
az apim api operation create --subscription $p.apim.subscriptionId -g $p.apim.resourceGroup --service-name $p.apim.name `
    --api-id $p.apim.apiId --operation-id create-message --display-name 'Create message' --method POST --url-template /v1/messages -o none
if ($LASTEXITCODE) { throw 'operation creation failed' }
```

**Check:** Design lists POST `/v1/messages`. Read-only:

```powershell
az apim api operation list --subscription $p.apim.subscriptionId -g $p.apim.resourceGroup --service-name $p.apim.name `
    --api-id $p.apim.apiId --query '[].{name:name,method:method,url:urlTemplate}' -o table
if ($LASTEXITCODE) { throw 'operation listing failed' }
```

#### Step 19.3 - Add one backend per Foundry descriptor

**Where:** APIM > APIs > **Backends** > **+ Create new backend** > Save. Repeat per form backend.
Do not add a secret for same-tenant MI.

| Field | Value | Source of value |
|---|---|---|
| Name | Exactly the registry `backendId` | form `backends[].id` |
| Backend hosting type / type | Custom URL, **HTTP** protocol with HTTPS URL | `infra/quickstart/modules/apim-api.bicep` |
| Runtime URL | Exact approved Foundry URL ending `/anthropic` | form `backends[].url` |
| Validate certificate chain / name | **On** / **On** | same bicep |
| Credentials | None | This guide |

**Screenshot:**
![Step 19.3 - Create backend](./images/portal/19-3-create-backend.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** the backend body of `apim-api.bicep` (the `az apim backend` command has no
TLS validation flags).

```powershell
foreach ($b in $p.backends) {
    $bodyFile = Join-Path $artifacts "backend-$($b.id).json"
    @{ properties = @{ url = $b.url; protocol = 'http'; tls = @{ validateCertificateChain = $true; validateCertificateName = $true } } } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM
    # WRITE: creates or updates one backend entity.
    az rest --method put --url "https://management.azure.com$($e.apim.id)/backends/$($b.id)?api-version=2024-05-01" --body "@$bodyFile" -o none
    if ($LASTEXITCODE) { throw "backend creation failed: $($b.id)" }
}
```

**Check:** Read-only:

```powershell
az apim backend list --subscription $p.apim.subscriptionId -g $p.apim.resourceGroup --service-name $p.apim.name `
    --query '[].{id:name,url:url,protocol:protocol,chain:tls.validateCertificateChain,name:tls.validateCertificateName}' -o table
if ($LASTEXITCODE) { throw 'backend listing failed' }
```

#### Step 19.4 - Paste the rendered gateway policy

**Where:** APIM > APIs > *API* > **Design** > **All operations** > Inbound processing **</>** (policy
code editor) > select all > paste **the entire generated** `gateway/<apiId>.policy.xml` > **Save**.

| Field | Value | Source of value |
|---|---|---|
| Policy XML | Entire file | `$artifacts/gateway/<apiId>.policy.xml` (Step 14.2) |

Do not paste the unrendered template or remove token validation/limit/cache/telemetry policy
sections.

**Screenshot:**
![Step 19.4 - Policy code editor](./images/portal/19-4-policy-code-editor.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
$xml = Get-Content (Join-Path $artifacts "gateway/$($p.apim.apiId).policy.xml") -Raw
$bodyFile = Join-Path $artifacts 'api-policy.json'
@{ properties = @{ format = 'rawxml'; value = $xml } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM
# WRITE: replaces the API-level policy with the rendered policy.
az rest --method put --url "https://management.azure.com$($e.apim.id)/apis/$($p.apim.apiId)/policies/policy?api-version=2024-05-01" --body "@$bodyFile" -o none
if ($LASTEXITCODE) { throw 'policy update failed' }
```

**Check:** Correct API URL, POST operation, backend identifiers, intended policy and
no unresolved placeholder. An unknown model/backend/project must fail closed, not
fall through to a default backend. Read-only:

```powershell
$policy = az rest --method get --url "https://management.azure.com$($e.apim.id)/apis/$($p.apim.apiId)/policies/policy?api-version=2024-05-01&format=rawxml" --query properties.value -o tsv
if ($LASTEXITCODE) { throw 'policy read failed' }
if ($policy -match 'REPLACE-|\{\{') { throw 'policy contains an unresolved placeholder' }
if (-not $policy.Contains($e.apps.resolver.defaultHostName)) { throw 'policy does not call the actual resolver hostname' }
'policy rendered'
```

## 20. Diagnostics and complete chargeback workbook

APIM resource diagnostics and **API diagnostics are separate controls**. Do not enable
prompt/response bodies.

#### Step 20.1 - APIM resource diagnostic setting

**Where:** APIM > Monitoring > **Diagnostic settings** > **+ Add diagnostic setting** > Save.

| Field | Value | Source of value |
|---|---|---|
| Diagnostic setting name | `<workspace-name>-apim` | `infra/poc/phase4-apim-telemetry.bicep` |
| Logs | **GatewayLogs** and **GatewayLlmLogs** | same |
| Destination | Send to Log Analytics workspace > intended LAW | evidence `workspace.id` |
| Destination table | **Resource specific** where offered | same bicep (`Dedicated`) |

**Screenshot:**
![Step 20.1 - APIM diagnostic setting](./images/portal/20-1-apim-diagnostic-setting.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** the same diagnostic setting body as the telemetry module.

```powershell
$lawName = ($e.workspace.id -split '/')[-1]
$bodyFile = Join-Path $artifacts 'apim-diagnostic-setting.json'
@{ properties = @{ workspaceId = $e.workspace.id; logAnalyticsDestinationType = 'Dedicated'
    logs = @(@{ category = 'GatewayLogs'; enabled = $true }, @{ category = 'GatewayLlmLogs'; enabled = $true }) } } |
    ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM
# WRITE: creates or updates the APIM resource diagnostic setting.
az rest --method put --url "https://management.azure.com$($e.apim.id)/providers/Microsoft.Insights/diagnosticSettings/$lawName-apim?api-version=2021-05-01-preview" --body "@$bodyFile" -o none
if ($LASTEXITCODE) { throw 'APIM diagnostic setting failed' }
```

**Check:** Read-only:

```powershell
az monitor diagnostic-settings list --resource $e.apim.id `
    --query '[].{name:name,workspace:workspaceId,type:logAnalyticsDestinationType,logs:logs[?enabled].category}' -o json
if ($LASTEXITCODE) { throw 'diagnostic setting listing failed' }
```

#### Step 20.2 - API diagnostics with LLM logs

**Where:** APIM > APIs > *API* > **Settings** > **Diagnostics Logs** > **Azure Monitor** tab > Save.

| Field | Value | Source of value |
|---|---|---|
| Enable | On | `infra/poc/phase4-apim-telemetry.bicep` |
| Always log | All errors | same |
| Sampling | 100 % | same |
| Verbosity | Information | same |
| Log client IP | **Off** | same |
| Frontend/backend request/response payload bytes | **0**; no sensitive headers | same |
| Large language model logs | On where the UI offers it (no prompt/response bodies) | same |

**Screenshot:**
![Step 20.2 - API diagnostics](./images/portal/20-2-api-diagnostics.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** if the UI does not expose APIM's LLM API diagnostic setting, deploy only the
reviewed telemetry child-resource module; it does not create the core infrastructure (it also
re-asserts Step 20.1):

```powershell
# Necessary only for missing telemetry UI controls. Review these child-resource writes.
# WRITE:
az deployment group create --subscription $p.apim.subscriptionId -g $p.apim.resourceGroup `
    --name "$($p.names.deploymentPrefix)-portal-telemetry" `
    --template-file ./infra/poc/phase4-apim-telemetry.bicep `
    --parameters workspaceResourceId=$e.workspace.id apimServiceName=$p.apim.name `
    apiName=$p.apim.apiId location=$p.location enableAlerts=false -o none
if ($LASTEXITCODE) { throw 'telemetry child configuration failed' }
```

**Check:** Read-only:

```powershell
az rest --method get --url "https://management.azure.com$($e.apim.id)/apis/$($p.apim.apiId)/diagnostics/azuremonitor?api-version=2024-06-01-preview" `
    --query 'properties.{alwaysLog:alwaysLog,verbosity:verbosity,logClientIp:logClientIp,sampling:sampling.percentage,llm:largeLanguageModel}' -o json
if ($LASTEXITCODE) { throw 'API diagnostic not found' }
```

#### Step 20.3 - Function App diagnostic settings

**Where:** For each Function App > Monitoring > **Diagnostic settings** > **+ Add diagnostic setting** >
Save. Resolver/sync also use their Insights resources.

| Field | Value | Source of value |
|---|---|---|
| Diagnostic setting name | `ccof-tel-<workspace-name>` | `infra/poc/phase4-function-logs.bicep` |
| Logs | **FunctionAppLogs** | same |
| Destination | Same LAW, resource-specific | evidence `workspace.id` |

**Screenshot:**
![Step 20.3 - Function App diagnostic setting](./images/portal/20-3-function-diagnostic-setting.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
foreach ($app in 'resolver', 'sync', 'reconciler') {
    # WRITE: the FunctionAppLogs diagnostic setting for one app.
    az deployment group create --subscription $sub -g $rg -n "$($p.names.deploymentPrefix)-portal-logs-$app" `
        --template-file ./infra/poc/phase4-function-logs.bicep `
        --parameters functionAppName=$($p.names.apps[$app].functionApp) workspaceResourceId=$($e.workspace.id) -o none
    if ($LASTEXITCODE) { throw "function diagnostic setting failed: $app" }
}
```

**Check:** Read-only:

```powershell
foreach ($app in 'resolver', 'sync', 'reconciler') {
    az monitor diagnostic-settings list --resource $e.apps[$app].functionAppId --query '[].{name:name,logs:logs[?enabled].category}' -o json
    if ($LASTEXITCODE) { throw "diagnostic setting listing failed: $app" }
}
```

#### Step 20.4 - Save the complete chargeback workbook

**Where:** LAW > **Workbooks** > **+ New** > **Edit** > **Advanced Editor** (`</>`) > replace the
notebook JSON with `chargeback.workbook.json` > **Apply** > **Done editing** > **Save** (approved
RG/name/location).

| Field | Value | Source of value |
|---|---|---|
| Gallery template JSON | Entire file | `$artifacts/chargeback.workbook.json` |
| Title | Workbook display name | form `workbook.displayName` |
| Resource group / location | Platform RG / region | form `names.resourceGroup`, `location` |

Record the **actual saved workbook Resource ID**; the Portal can allocate a different
GUID than the form's candidate. Do not create/redeploy an empty workbook shell over this content.

**Screenshot:**
![Step 20.4 - Workbook advanced editor](./images/portal/20-4-workbook-advanced-editor.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** deploys the repository workbook module with the **complete** generated
content under the form's GUID `workbook.resourceName`.

```powershell
$content = Get-Content (Join-Path $artifacts 'chargeback.workbook.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
if (-not $content.items) { throw 'workbook content is empty: rerun Step 14.2' }
$params = Save-CcofParameters 'workbook' @{
    workbookResourceName = $p.workbook.resourceName; workbookDisplayName = $p.workbook.displayName
    location = $p.location; workspaceResourceId = $e.workspace.id; workbookContent = $content; contentTags = @{}
}
# WRITE: creates or updates the workbook.
az deployment group create --subscription $sub -g $rg -n "$($p.names.deploymentPrefix)-portal-workbook" `
    -f ./infra/workbook/main.bicep -p $params -o none
if ($LASTEXITCODE) { throw 'workbook deployment failed' }
```

**Check:** Workbook opens with real query results or an explicit no-data/unpriced state. Read-only:

```powershell
# EDIT: actual saved workbook resource ID if the Portal allocated a different GUID.
$workbookId = "$base/Microsoft.Insights/workbooks/$($p.workbook.resourceName)"
az resource show --ids $workbookId --query '{name:properties.displayName,source:properties.sourceId}' -o json
if ($LASTEXITCODE) { throw 'workbook not found' }
```

#### Step 20.5 - Grant workbook readers

**Where:** Workbook resource > **Access control (IAM)** > Add role assignment > **Workbook Reader** >
members; then LAW > Access control (IAM) > **Log Analytics Reader** > same members.

| Field | Value | Source of value |
|---|---|---|
| Role on the saved workbook | Workbook Reader (`b279062a-9be3-42a0-92ae-8b3cf002ec4d`) | `infra/quickstart/modules/rbac.bicep` |
| Role on LAW | Log Analytics Reader (`73c42c96-874c-492b-b04d-ab87d138a893`) | same |
| Members | Intended readers | form `workbook.readerPrincipalIds` |

**Screenshot:**
![Step 20.5 - Workbook readers](./images/portal/20-5-workbook-readers.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
# EDIT: actual saved workbook resource ID if the Portal allocated a different GUID.
$workbookId = "$base/Microsoft.Insights/workbooks/$($p.workbook.resourceName)"
foreach ($reader in $p.workbook.readerPrincipalIds) {
    # WRITE: Workbook Reader on the workbook.
    az role assignment create --role b279062a-9be3-42a0-92ae-8b3cf002ec4d --scope $workbookId --assignee-object-id $reader -o none
    if ($LASTEXITCODE) { throw "Workbook Reader failed: $reader" }
    # WRITE: Log Analytics Reader on the workspace.
    az role assignment create --role 73c42c96-874c-492b-b04d-ab87d138a893 --scope $e.workspace.id --assignee-object-id $reader -o none
    if ($LASTEXITCODE) { throw "Log Analytics Reader failed: $reader" }
}
```

**Check:** Read-only:

```powershell
# EDIT: actual saved workbook resource ID if the Portal allocated a different GUID.
$workbookId = "$base/Microsoft.Insights/workbooks/$($p.workbook.resourceName)"
az role assignment list --scope $workbookId --query '[].{principal:principalId,role:roleDefinitionName}' -o table
if ($LASTEXITCODE) { throw 'assignment listing failed' }
```

#### Step 20.6 - Verify logs arrive

**Where:** LAW > **Logs** > run the query below after a synthetic authorized request and ingestion delay.

| Field | Value | Source of value |
|---|---|---|
| Tables | `ApiManagementGatewayLogs`, `ApiManagementGatewayLlmLog`, `FunctionAppLogs` | Steps 20.1-20.3 |

**Screenshot:**
![Step 20.6 - Log tables](./images/portal/20-6-log-tables.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** read-only, as below.

**Check:** After a synthetic authorized request and ingestion delay, LAW Logs has
`ApiManagementGatewayLogs`, `ApiManagementGatewayLlmLog` and `FunctionAppLogs`
observations. Workbook shows real query results or an explicit no-data/unpriced state.
Absence of logs blocks budget-state enforcement and chargeback acceptance.

```powershell
az monitor log-analytics query --workspace $e.workspace.customerId `
    --analytics-query 'union isfuzzy=true ApiManagementGatewayLogs, ApiManagementGatewayLlmLog, FunctionAppLogs | where TimeGenerated > ago(1d) | summarize count() by Type' -o table
if ($LASTEXITCODE) { throw 'workspace query failed' }
```

## 21. Seed the registry inside the VNet, then enable approved timers

Do not use ordinary Cloud Shell to write private Cosmos items. The deployed sync
app can do create-only seeding using its managed identity and VNet integration.
Review `registry-documents.json` first: project IDs, classification group object IDs,
exact family models/limits, backend URLs/resource audience/geography and budgets.

#### Step 21.1 - Look for an earlier seed result

**Where:** Sync Insights > Monitoring > **Logs** > run (for this seed, add the seed-ID line with the
value of `seed-id.txt`):

```kusto
traces
| where timestamp > ago(1h)
| where message contains "ccof.seed.result"
| where message contains "REPLACE-seed-id-from-seed-id.txt"
| project timestamp, message
| order by timestamp desc
```

After a Quickstart run, first run it **without** the seed-ID line and with a longer
`ago(...)` window. If an earlier `ccof.seed.result` shows every document **created** or
**present-equal**, skip Steps 21.2-21.4.

| Field | Value | Source of value |
|---|---|---|
| Seed ID | Correlation ID | `$artifacts/seed-id.txt` |

**Screenshot:**
![Step 21.1 - Seed result query](./images/portal/21-1-seed-result-query.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** the same query through ARM (works in Cloud Shell, read access on the component).

```powershell
# EDIT: '' for any earlier seed, or the seed ID from seed-id.txt; and the look-back window in days.
$seedId = ''
$days = 30
$filter = if ($seedId) { " | where message has '$seedId'" } else { '' }
$bodyFile = Join-Path $artifacts 'seed-query.json'
@{ query = "traces | where timestamp > ago($($days)d) | where message contains 'ccof.seed.result'$filter | project timestamp, message | order by timestamp desc | take 50"
    timespan = "P$($days)D" } | ConvertTo-Json -Compress | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM
$answer = az rest --method post --url "https://management.azure.com$($e.apps.sync.appInsightsId)/api/query?api-version=2020-02-02" --body "@$bodyFile" -o json | ConvertFrom-Json
if ($LASTEXITCODE) { throw 'seed result query failed' }
@($answer.tables)[0].rows | ForEach-Object { $_[1] }
```

**Check:** Each `ccof.seed.result` line lists every expected document as `created` or `present-equal`.

#### Step 21.2 - Set the seed payload and enable the seed function

**Where:** Sync Function App > Settings > **Environment variables** > App settings:
add `CCOF_SEED_DOCUMENTS` = **entire** `seed-payload.txt` value;
set `AzureWebJobs.registrySeed.Disabled=false`; **Apply** both together.
Keep `AzureWebJobs.syncEntitlement.Disabled=true`.

| Field | Value | Source of value |
|---|---|---|
| `CCOF_SEED_DOCUMENTS` | Entire file content | `$artifacts/seed-payload.txt` |
| `AzureWebJobs.registrySeed.Disabled` | `false` | This guide |
| `AzureWebJobs.syncEntitlement.Disabled` | `true` (unchanged) | Step 17.3 |

If a payload exceeds the platform's setting limits, stop and use the reviewed
private-runner onboarding path; do not truncate it.

**Screenshot:**
![Step 21.2 - Seed settings](./images/portal/21-2-seed-settings.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** passes the payload through a private file, so no command-line length limit applies.

```powershell
$payload = (Get-Content (Join-Path $artifacts 'seed-payload.txt') -Raw).Trim()
$settingsFile = Join-Path $artifacts 'seed-settings.object.json'
[ordered]@{ CCOF_SEED_DOCUMENTS = $payload; 'AzureWebJobs.registrySeed.Disabled' = 'false' } |
    ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding utf8NoBOM
# WRITE: sets the seed payload and enables the seed function (cleanup is Step 21.5, always).
az functionapp config appsettings set --subscription $sub -g $rg -n $p.names.apps.sync.functionApp --settings "@$settingsFile" -o none
if ($LASTEXITCODE) { throw 'seed settings failed: do Step 21.5 cleanup now' }
```

**Check:** Read-only:

```powershell
az functionapp config appsettings list --subscription $sub -g $rg -n $p.names.apps.sync.functionApp `
    --query "[?name=='AzureWebJobs.registrySeed.Disabled' || name=='AzureWebJobs.syncEntitlement.Disabled' || name=='CCOF_SEED_DOCUMENTS'].{name:name,length:length(value)}" -o table
if ($LASTEXITCODE) { throw 'settings read failed' }
```

#### Step 21.3 - Make sure `registrySeed` is registered

**Where:** Sync Function App > Overview > **Functions** tab lists `registrySeed`.
The seed handler is conditionally registered at startup. Ensure its trigger is synced
after this settings change.

| Field | Value | Source of value |
|---|---|---|
| Function | `registrySeed` | `src/sync/registry-seed.ts` |

**Screenshot:**
![Step 21.3 - registrySeed listed](./images/portal/21-3-registry-seed-listed.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** if the Functions blade lacks `registrySeed`, this necessary short management
call resynchronizes it:

```powershell
$syncSite = $e.apps.sync.functionAppId
# WRITE: resynchronizes the sync app's triggers.
az rest --method post --url "https://management.azure.com$syncSite/syncfunctiontriggers?api-version=2024-04-01" -o none
if ($LASTEXITCODE) { throw 'sync trigger synchronization failed' }
```

**Check:** Read-only:

```powershell
$names = az functionapp function list --subscription $sub -g $rg -n $p.names.apps.sync.functionApp --query '[].name' -o tsv
if ($LASTEXITCODE) { throw 'function discovery failed' }
if (-not ($names | Where-Object { $_ -like '*registrySeed' })) { throw 'registrySeed not listed yet: wait a minute and rerun, or resync' }
```

#### Step 21.4 - Read this seed's result

**Where:** Sync Insights > **Logs** > the Step 21.1 query, replacing the correlation ID with
`seed-id.txt`. The function runs every minute once the app restarted with the new settings.

| Field | Value | Source of value |
|---|---|---|
| Seed ID | Correlation ID | `$artifacts/seed-id.txt` |

**Screenshot:**
![Step 21.4 - Seed result](./images/portal/21-4-seed-result.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** read-only; the Step 21.1 query for this seed only.

```powershell
$seedId = (Get-Content (Join-Path $artifacts 'seed-id.txt') -Raw).Trim()
$bodyFile = Join-Path $artifacts 'seed-query.json'
@{ query = "traces | where timestamp > ago(1h) | where message has '$seedId' and message contains 'ccof.seed.result' | project timestamp, message | order by timestamp asc | take 50"
    timespan = 'PT1H' } | ConvertTo-Json -Compress | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM
$answer = az rest --method post --url "https://management.azure.com$($e.apps.sync.appInsightsId)/api/query?api-version=2020-02-02" --body "@$bodyFile" -o json | ConvertFrom-Json
if ($LASTEXITCODE) { throw 'seed result query failed' }
@($answer.tables)[0].rows | ForEach-Object { $_[1] }
```

**Check:** The result for that exact seed ID must cover every expected document as **created**
or **present-equal**. `present-differs`, failed/missing document, startup failure or
timeout is a stop: the seed does not overwrite differing documents. Use the approved
project-update/onboarding path for changes, not a delete-and-recreate shortcut.

#### Step 21.5 - Mandatory cleanup (even on failure or disconnect)

**Where:** Sync > Environment variables > `AzureWebJobs.registrySeed.Disabled=true` > delete
`CCOF_SEED_DOCUMENTS` > **Apply**. If Cloud Shell closed, do this in the UI; no shell `finally`
is relied upon.

| Field | Value | Source of value |
|---|---|---|
| `AzureWebJobs.registrySeed.Disabled` | `true` | This guide |
| `CCOF_SEED_DOCUMENTS` | Deleted | This guide |

**Screenshot:**
![Step 21.5 - Seed cleanup](./images/portal/21-5-seed-cleanup.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
# WRITE: disables the seed function.
az functionapp config appsettings set --subscription $sub -g $rg -n $p.names.apps.sync.functionApp `
    --settings 'AzureWebJobs.registrySeed.Disabled=true' -o none
if ($LASTEXITCODE) { throw 'seed disable failed: do it in the UI now' }
# WRITE: removes the payload.
az functionapp config appsettings delete --subscription $sub -g $rg -n $p.names.apps.sync.functionApp `
    --setting-names CCOF_SEED_DOCUMENTS -o none
if ($LASTEXITCODE) { throw 'payload removal failed: do it in the UI now' }
```

**Check:** Verify both controls. Do not regenerate/reapply another seed ID while an unresolved
seed is still enabled. Read-only:

```powershell
$live = az functionapp config appsettings list --subscription $sub -g $rg -n $p.names.apps.sync.functionApp -o json | ConvertFrom-Json
if ($LASTEXITCODE) { throw 'settings read failed' }
if (@($live | Where-Object name -CEQ 'CCOF_SEED_DOCUMENTS').Count) { throw 'payload still present' }
if (@($live | Where-Object name -CEQ 'AzureWebJobs.registrySeed.Disabled')[0].value -cne 'true') { throw 'seed function still enabled' }
'seed cleanup verified'
```

#### Step 21.6 - Enable entitlement sync

**Where:** Sync > Environment variables > `AzureWebJobs.syncEntitlement.Disabled` = `false` > Apply.
Only after verified seed, Graph grant (module 16) and test group membership (Step 06.7).

| Field | Value | Source of value |
|---|---|---|
| `AzureWebJobs.syncEntitlement.Disabled` | `false` | This guide |

**Screenshot:**
![Step 21.6 - Enable sync timer](./images/portal/21-6-enable-sync-timer.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
# WRITE: enables the entitlement sync timer.
az functionapp config appsettings set --subscription $sub -g $rg -n $p.names.apps.sync.functionApp `
    --settings 'AzureWebJobs.syncEntitlement.Disabled=false' -o none
if ($LASTEXITCODE) { throw 'sync timer enable failed' }
```

**Check:** Confirm successful sync telemetry and entitlement creation from an approved private
data view (Sync Insights > Logs / the `syncEntitlement` function's Invocations). Read-only:

```powershell
az functionapp config appsettings list --subscription $sub -g $rg -n $p.names.apps.sync.functionApp `
    --query "[?name=='AzureWebJobs.syncEntitlement.Disabled'].value" -o tsv
if ($LASTEXITCODE) { throw 'settings read failed' }
```

#### Step 21.7 - Enable budget reconciliation (`budget-state` only)

**Where:** Reconciler > Environment variables > `AzureWebJobs.reconcileBudgets.Disabled` = `false` >
Apply. For `budget-state`, only after verified usage logs/rate inputs/grants.
No timer should be enabled merely because the app resource exists.

| Field | Value | Source of value |
|---|---|---|
| `AzureWebJobs.reconcileBudgets.Disabled` | `false` | Budget enforcement decision (Step 01.3) |

**Screenshot:**
![Step 21.7 - Enable reconciler timer](./images/portal/21-7-enable-reconciler-timer.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
# WRITE: enables the budget reconciler timer.
az functionapp config appsettings set --subscription $sub -g $rg -n $p.names.apps.reconciler.functionApp `
    --settings 'AzureWebJobs.reconcileBudgets.Disabled=false' -o none
if ($LASTEXITCODE) { throw 'reconciler timer enable failed' }
```

**Check:** Seed verified and disabled/payload removed; sync has an actual successful
membership run. Reconciler and budget-state runtime proof are separate from seed success;
verify budget-state updates. Read-only:

```powershell
az functionapp config appsettings list --subscription $sub -g $rg -n $p.names.apps.reconciler.functionApp `
    --query "[?name=='AzureWebJobs.reconcileBudgets.Disabled'].value" -o tsv
if ($LASTEXITCODE) { throw 'settings read failed' }
```

## 22. Client configuration and customer acceptance

Use [client configuration](../CLIENTS.md) and the strict `client/config.example.json`
shape. This guide does not auto-select the first project/backend or configure the Cloud
Shell machine as the developer workstation.

#### Step 22.1 - Fill and validate the private client config

**Where:** Developer workstation, reviewed checkout, private file `./.env.onboarding.json`.
Fill only the approved gateway tenant/client/scope, gateway URL, selected
project header/ID and exact admitted aliases. Run the existing config validator on
the private file before handing it to a developer.

| Field | Value | Source of value |
|---|---|---|
| Tenant / client / scope | Gateway registration | form `tenantId`, `registrations.gatewayApi.appId`, `.scope` |
| Gateway URL | APIM gateway URL + API path | evidence `apim.gatewayUrl`, form `apim.apiPath` |
| Project | Selected project ID | form `groups[].projectId` |
| Models | Exact admitted aliases | form `client.models`, `groups[].familyPolicy` |

**Screenshot:**
![Step 22.1 - Validate client config](./images/portal/22-1-validate-client-config.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
# On the developer workstation, with its reviewed private config:
node ./client/bin/validate-config.mjs './.env.onboarding.json'
if ($LASTEXITCODE) { throw 'client config invalid' }
```

**Check:** The validator exits 0.

#### Step 22.2 - Configure the developer's Claude Code client

**Where:** Developer workstation, PowerShell 7.

| Field | Value | Source of value |
|---|---|---|
| `-ConfigPath` | `./.env.onboarding.json` | Step 22.1 |

**Screenshot:**
![Step 22.2 - Configure client](./images/portal/22-2-configure-client.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:**

```powershell
pwsh -File ./scripts/client/Set-ClaudeCodeGateway.ps1 -ConfigPath './.env.onboarding.json' -Confirmed
if ($LASTEXITCODE) { throw 'client configuration failed' }
```

**Check:** The script reports the configured gateway; see [client configuration](../CLIENTS.md).

#### Step 22.3 - Run the acceptance tests

**Where:** Developer workstation (approved real test developer in the intended classification),
plus LAW > Logs and the workbook for evidence.

| Field | Value | Source of value |
|---|---|---|
| Test developer | Member of the intended group | Step 06.7 |
| Approval | Test requests can incur Foundry charges | Customer approval |

Use an approved real test developer in the intended classification. Verify:
anonymous gateway request denied; authorized exact-model request succeeds;
unregistered model/project, disallowed classification/family and wrong resolver
caller denied; a small controlled quota/rate threshold behaves as configured;
cache accounting/telemetry and budget-state delay behave as documented.
Verify silent sign-in refresh and membership-removal behavior separately.
Test requests can incur Foundry charges; get approval before traffic.

**Screenshot:**
![Step 22.3 - Acceptance evidence](./images/portal/22-3-acceptance-evidence.png)
<!-- screenshot pending: capture from a lab tenant, redact IDs -->

**CLI alternative:** none; acceptance is run by the test developer through the client, not by `az`.

**Final acceptance:** require authenticated end-to-end evidence, correct routing,
entitlement, limits, logs and reporting. A 401 smoke response, ARM Succeeded, a green
offline test or a saved workbook alone is not proof of a working customer deployment.

**Check:** The test developer is in the intended group (read-only), then Step 20.6 shows the traffic:

```powershell
# EDIT: the test developer's object ID and the group object ID under test.
$developerId = '<test-developer-object-id>'
$groupId = '<group-object-id>'
az ad group member check --group $groupId --member-id $developerId --query value -o tsv
if ($LASTEXITCODE) { throw 'membership check failed' }
```

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
| CLI deployment timed out in the shell | RG > Deployments > that deployment: wait for its final state before rerunning the same block |

Rollback is module-specific: restore the previous reviewed code ZIP, previous UI
settings (the Step 17.1 backups), previous API revision; remove only the exact newly
authorized assignments using their receipts. Do not delete Cosmos data or an entire RG
to recover a partial step. Record the blocked module, current Azure state and next owner.

## Sources and validation boundary

Official documentation consulted 2026-10-14:

- [Flex creation, managed identities, VNet integration and deployment](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-how-to)
- [Deployment-storage configuration CLI](https://learn.microsoft.com/en-us/cli/azure/functionapp/deployment/config)
- [APIM v2 outbound networking](https://learn.microsoft.com/en-us/azure/api-management/integrate-vnet-outbound)
- [Cosmos management and native data RBAC](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-connect-role-based-access-control)
- [Resolver Authentication controls](https://learn.microsoft.com/en-us/azure/app-service/configure-authentication-provider-aad)

Repository contracts: `infra/prereqs/network.bicep`, `infra/prereqs/log-analytics.bicep`,
`infra/prereqs/cosmos-account.bicep`, `infra/prereqs/function-app.bicep`, `infra/prereqs/apim.bicep`,
`infra/quickstart/modules/app-settings.bicep`, `infra/quickstart/modules/cosmos-data.bicep`,
`infra/quickstart/modules/apim-api.bicep`, `infra/quickstart/modules/rbac.bicep`,
`infra/quickstart/modules/foundry-role.bicep`, `infra/workbook/main.bicep`,
`scripts/Core.D2Steps.psm1`, `scripts/Core.D2Code.psm1`, staged D3 assignment data,
`infra/poc/phase4-apim-telemetry.bicep`, `infra/poc/phase4-function-logs.bicep`,
`infra/poc/foundry-private-dns.bicep`, `infra/poc/resolver-auth.ps1`,
`src/sync/registry-seed.ts`, [manual deployment](../MANUAL-DEPLOYMENT.md). The exporter imports
shared pure Quickstart helpers with `-DotSourceOnly`; it never executes their dispatcher.
Every `az` flag in the CLI alternatives was checked against `az <command> --help` (Azure CLI 2.86);
the CLI blocks are parse-checked offline, not executed against a customer tenant.

Screenshots are **being added**: each `Screenshot:` placeholder marks where a sanitized capture
from a lab tenant goes; none is claimed captured yet. Use the exact UI paths and record sanitized
screenshots during customer execution. This repository contains no private tenant/subscription/group
values, customer screenshots or completed customer deployment evidence.
