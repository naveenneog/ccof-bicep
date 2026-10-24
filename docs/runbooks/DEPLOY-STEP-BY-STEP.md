# Deploy CCOF step by step

**For:** someone deploying CCOF for the first time. **Time:** about one hour of commands once the
prerequisites below are ready; approvals, model capacity and network work can take longer
([deployment runbook](DEPLOYMENT-RUNBOOK.md#readiness-and-the-one-hour-target)).
**Result:** developers can call Claude through your own API Management gateway, with project access,
token limits, budgets and reports. Terms such as APIM, Foundry, resolver and reconciler are explained
in the [glossary](../GLOSSARY.md).

CCOF is deployed in nine steps, numbered 0 to 8. Each step below has the same parts:

| Part | Meaning |
| --- | --- |
| **What it does** | The Azure or Entra objects the step creates or checks |
| **Who runs it** | The permission the person running the step needs |
| **Script** | The deployment driver runs the step, checks the result in Azure and records it. This is the path tested end to end in the lab. |
| **Azure CLI** | The same work with `az` commands |
| **Portal** | The same work, or the check of its result, in the Azure Portal |
| **Check** | What a correct result looks like, with screenshots from a lab deployment |

Screenshots come from the **Fabrikam lab** deployment. Run outputs are read-only previews taken on
24 October 2026; Portal pages were captured live from the signed-in Portal on the same day. Names, IDs
and subscriptions in them are pseudonyms with the same shape as the real values.

## How the three ways fit together

- The driver keeps a record of each finished step in `<config folder>\.staged-state\state.json`.
  A step will not start before the steps it depends on are recorded
  ([driver reference](STAGED-DEPLOYMENT-V2.md#how-a-stage-runs)).
- Steps 1, 2, 3 and 5 are Bicep deployments. The driver's preview writes the exact parameter file
  it uses to `.staged-state\<deployment name>.parameters.json`. The Azure CLI and Portal routes for
  these steps deploy the same template with that file.
- After a step is done with the Azure CLI or the Portal, running the driver's apply for the same step
  redeploys the same template and parameters. Deployments are incremental, so Azure makes no further
  change; the driver then reads the result back and records the step
  ([deployment modes](https://learn.microsoft.com/azure/azure-resource-manager/templates/deployment-modes)).
  Step 1 accepts this only when the earlier deployment is named `stage1-services`.
- Steps 4 and 7 are scripts that call Microsoft Graph and the Function Apps. Their Azure CLI routes
  below reproduce the main objects; the driver also verifies them and writes the client file.
- Mixing routes within one step was not run in the lab; each route on its own was.

## Before you start

### Tools

| Tool | Check | Source |
| --- | --- | --- |
| PowerShell 7.2 or later | `$PSVersionTable.PSVersion` | [Install PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) |
| Node.js 22 or later and npm | `node --version` | [nodejs.org](https://nodejs.org/) |
| Git | `git --version` | [git-scm.com](https://git-scm.com/) |
| Azure CLI with Bicep | `az version` and `az bicep version` | [Install the Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) |

Azure Cloud Shell (PowerShell) has all four; it reaches Azure management endpoints, not private
endpoints inside your network ([Cloud Shell quickstart](CLOUD-SHELL-QUICKSTART.md)).

### Source code

```powershell
git clone https://github.com/naveenneog/ccof-bicep.git
cd ccof-bicep
git checkout feat/budget-soft-limit        # the branch named in README "Current release"
npm ci --ignore-scripts --no-audit --no-fund
npm run build
```

**Expect:** both npm commands end without `ERR!`.

### A separate Azure CLI sign-in

The driver never runs `az login`; it uses whichever account the Azure CLI is signed in with. A
separate profile folder keeps this deployment's sign-in apart from any other work on the machine.

The commands in this guide use the variables below. Paste this block once in each new PowerShell
window, with your own values between the quotes.

```powershell
$env:AZURE_CONFIG_DIR = "$HOME\.ccof-az"           # separate Azure CLI profile for this deployment
$tenant    = '<tenant-id>'                         # Microsoft Entra ID > Overview > Tenant ID
$sub       = '<subscription-id>'                   # Subscriptions > your subscription
$rg        = '<resource-group>'                    # new, empty resource group for CCOF
$location  = 'eastus2'
$foundryRg = '<foundry-resource-group>'            # resource group of the Foundry account
$foundry   = '<foundry-account>'                   # Foundry (AI Services) account name
$cfg       = 'C:\private\ccof\staged.config.json'  # configuration file (next section)
$state     = 'C:\private\ccof\.staged-state'       # the driver writes its records here
```

```powershell
az login --tenant $tenant
az account set --subscription $sub
az account show --query "{tenant:tenantId, subscription:id, user:user.name}" -o table
```

**Expect:** your tenant, subscription and account.

On Windows, `az` passes its arguments through `cmd.exe`. Values containing `( ) | & < > ^` are
interpreted by `cmd.exe`, so this guide keeps them out of `az` arguments and puts request bodies in
files ([driver reference](STAGED-DEPLOYMENT-V2.md#how-a-stage-runs)).

### The configuration file

One JSON file holds every value the steps use. Copy the example to a private folder outside the
repository and replace each value that starts with `REPLACE`; the driver refuses a file that still
contains one.

```powershell
New-Item -ItemType Directory C:\private\ccof -Force | Out-Null
Copy-Item infra\staged\staged.config.example.json $cfg
notepad $cfg
```

| Field | What to enter | Where to find it |
| --- | --- | --- |
| `tenantId` | Directory (tenant) ID | Portal: **Microsoft Entra ID > Overview** |
| `subscriptionId` | Subscription for CCOF | Portal: **Subscriptions** |
| `resourceGroup`, `location` | A new, empty resource group and its region (for example `eastus2`) | Your naming standard |
| `stage1.prefix` | 3 to 12 lowercase letters or digits used in resource names | Your choice |
| `stage1.foundry` | `create: true` for a new Foundry account with Claude deployments, or `false` to use an existing one | [Foundry section](STAGED-DEPLOYMENT-V2.md#stage-1-foundry-optional) |
| `backends` | Each Foundry account, its deployment names and inference geography | Portal: Foundry account > **Models + endpoints** |
| `groups` | Project, classification and Entra group for each team, with allowed model families and budgets | [Admin operations](ADMIN-OPERATIONS.md#limits-and-budgets) |
| `network` | `mode: verify` and the three subnet IDs your network team provides | Step 6 below |
| `acceptance` | One allowed and one denied project/model pair for the final test | Step 8 below |

The full list of sections is in the [driver reference](STAGED-DEPLOYMENT-V2.md#configuration-file).

---

## Step 0: check the subscription (read-only)

**What it does.** Reads the tenant and subscription you are signed in to, the resource group, the
resource providers CCOF needs, whether the region offers Flex Consumption Function Apps, and the
Foundry model deployments. It creates nothing in Azure; it records the results in `state.json`.

**Who runs it.** Reader on the subscription, the resource group and each Foundry account.

**Script**

```powershell
pwsh -File infra\staged\Invoke-StagedDeployment.ps1 -Stage 0 -ConfigPath $cfg
```

**Azure CLI**

```powershell
az account show --query "{tenant:tenantId, subscription:id, user:user.name}" -o table
az group show -n $rg --query "{name:name, location:location}" -o table
foreach ($p in 'Microsoft.Web','Microsoft.DocumentDB','Microsoft.Storage','Microsoft.Network',
               'Microsoft.OperationalInsights','Microsoft.Insights','Microsoft.ManagedIdentity',
               'Microsoft.ApiManagement','Microsoft.AlertsManagement') {
    az provider show -n $p --query "{provider:namespace, state:registrationState}" -o tsv
}
az functionapp list-flexconsumption-locations --query "[].name" -o tsv
az cognitiveservices account deployment list -g $foundryRg -n $foundry `
    --query "[].{name:name, model:properties.model.name, version:properties.model.version, sku:sku.name}" -o table
```

**Expect:** your account, the resource group, each provider `Registered`, your region in the Flex
Consumption list, and the Claude deployments named in `backends`.

![Step 0 checks with the Azure CLI](../images/guide/cli-step0-checks.png)

A provider that is not `Registered` is registered with `az provider register -n <name>`, which needs
Contributor on the subscription.

**Portal**

1. **Subscriptions** > your subscription > **Access control (IAM)** > **Check access** > **View my access**:
   your role and its scope.
2. Same subscription > **Settings** > **Resource providers**: each provider above shows **Registered**.
3. **Resource groups** > your group: empty for a new deployment.

![Subscription Access control: the operator's Reader assignment](images/staged-portal/00-subscription-access.png)

![Subscription Resource providers with Registered status](images/staged-portal/00-resource-providers.png)

**Check.** The run ends with `stage 0 completed and verified`. A warning that the resource group is
not empty means Step 1 will refuse it unless `sharedResourceGroup` is set
([shared resource group](STAGED-DEPLOYMENT-V2.md#stage-1-in-a-shared-resource-group)).

![Step 0 output: subscription, providers, Flex region, Foundry deployments and operator](../images/guide/run-stage0-preview.png)

---

## Step 1: create the resources

**What it does.** Creates the Log Analytics workspace, the Cosmos DB account, two managed identities,
four Function Apps (resolver, sync, reconciler, admin) each with its own storage account and
Application Insights, and, if configured, a new API Management (APIM) instance and a Foundry account
with Claude deployments. No settings, data, permissions, network connections or code yet.

**Who runs it.** Contributor on the resource group (plus permission to create the group if it does
not exist). For a new Foundry account with Claude: permission to accept the Marketplace offer on the
subscription.

**Script**

```powershell
pwsh -File infra\staged\Invoke-StagedDeployment.ps1 -Stage 1 -ConfigPath $cfg          # preview
pwsh -File infra\staged\Invoke-StagedDeployment.ps1 -Stage 1 -ConfigPath $cfg -Apply   # create and verify
```

The preview lists every resource as `Create`. Apply took 156 and 273 seconds in the two lab runs of
20 October 2026 ([run report](../STAGED-STDV2-RUNS-2026-10-20.md)); creating a new APIM instance can
take longer.

**Azure CLI.** Run the driver preview first; it writes the parameter file.

```powershell
az group create -n $rg -l $location
az deployment group what-if -g $rg -n stage1-services `
    -f infra\staged\main.bicep -p "@$state\stage1-services.parameters.json"
az deployment group create -g $rg -n stage1-services --mode Incremental `
    -f infra\staged\main.bicep -p "@$state\stage1-services.parameters.json"
```

**Portal.** The Portal deploys ARM JSON templates, so the Bicep file is converted first:
`az bicep build -f infra\staged\main.bicep --outfile main.json`.

1. Search for **Deploy a custom template** > **Build your own template in the editor** > **Load file**
   > `main.json` > **Save**.
2. **Edit parameters** > **Load file** > `stage1-services.parameters.json` > **Save**.
3. Select the subscription and resource group > **Review + create** > **Create**.

To create each resource through its own Portal form instead, the
[Azure Portal deployment guide](AZURE-PORTAL-DEPLOYMENT.md) lists every form and value.

![Deploy a custom template in the Azure Portal](images/staged-portal/01-custom-template.png)

**Check**

- **Resource groups** > your group > **Overview**: the new resources.
- **Deployments**: `stage1-services` (or the Portal deployment) shows **Succeeded**.
- APIM > **Managed identities**: **System assigned** is **On**.

![Resource group overview, filtered to the Cosmos DB account and its private endpoint](images/staged-portal/01-rg-overview.png)

![Resource group Deployments: each step's deployments Succeeded](images/staged-portal/01-rg-deployments.png)

![API Management overview: Standard v2](images/staged-portal/01-apim-overview.png)

![API Management Managed identities: system assigned identity on](images/staged-portal/01-apim-identity.png)

![Foundry account overview](images/staged-portal/01-foundry-overview.png)

A run that has already finished Step 1 reports that no resource write will occur:

![Step 1 preview after Step 1 was applied](../images/guide/run-stage1-preview.png)

The first apply, from the 20 October lab run:

![Step 1 apply output from the earlier lab run](../images/staged/01b-stage1-apply.png)

**Names for the later steps.** Step 1 names each resource `<prefix>-<suffix>-<role>`, where the
suffix is generated from the resource group and prefix. The later Azure CLI commands use these
variables; paste this block after Step 1 and in each new PowerShell window.

```powershell
$apps          = az functionapp list -g $rg --query "[].name" -o tsv
$resolverApp   = $apps | Where-Object { $_ -like '*-resolver' }
$syncApp       = $apps | Where-Object { $_ -like '*-sync' }
$reconcilerApp = $apps | Where-Object { $_ -like '*-reconciler' }
$adminApp      = $apps | Where-Object { $_ -like '*-admin' }
$cosmos        = az cosmosdb list -g $rg --query "[0].name" -o tsv
$cosmosId      = az cosmosdb show -g $rg -n $cosmos --query id -o tsv
$apim          = az apim list -g $rg --query "[0].name" -o tsv     # or the existing APIM's name
$apimId        = az apim show -g $rg -n $apim --query id -o tsv
$foundryId     = az cognitiveservices account show -g $foundryRg -n $foundry --query id -o tsv
"$resolverApp $syncApp $reconcilerApp $adminApp $cosmos $apim"
```

**Expect:** four app names, the Cosmos account and the APIM name. The image below shows this block
and the read-only checks of the later steps, run against the lab after all steps were complete.

![Resource names and read-only checks with the Azure CLI](../images/guide/cli-names-and-checks.png)

---

## Step 2: create the database containers

**What it does.** Creates the Cosmos DB database (default `ccof`) and its containers: `projects`,
`backends`, `entitlement`, `subscriptionIndex`, `syncLease`, `budgetState`, `aggregateBudgetState`,
`reconcilerLease` and, with the admin app, `adminConfig`.

**Who runs it.** Contributor on the Cosmos DB account.

**Script**

```powershell
pwsh -File infra\staged\Invoke-StagedDeployment.ps1 -Stage 2 -ConfigPath $cfg
pwsh -File infra\staged\Invoke-StagedDeployment.ps1 -Stage 2 -ConfigPath $cfg -Apply
```

**Azure CLI**

```powershell
az deployment group what-if -g $rg -n stage2-schema `
    -f infra\staged\stage2-schema.bicep -p "@$state\stage2-schema.parameters.json"
az deployment group create -g $rg -n stage2-schema --mode Incremental `
    -f infra\staged\stage2-schema.bicep -p "@$state\stage2-schema.parameters.json"
az cosmosdb sql container list -g $rg -a $cosmos -d ccof `
    --query "[].{container:name, partitionKey:resource.partitionKey.paths[0]}" -o table
```

The same what-if run against the lab with the driver's parameter file returned `Succeeded` with the
same counts as the driver's preview (24 October 2026).

**Portal.** Deploy a custom template as in Step 1, with `stage2-schema.bicep` converted by
`az bicep build` and `stage2-schema.parameters.json`. The Cosmos account has public network access
disabled, so the Portal's Data Explorer cannot list the containers from outside the network; the
`az cosmosdb sql container list` command above reads them through Azure Resource Manager.

![Cosmos DB account overview](images/staged-portal/02-cosmos-overview.png)

**Check.** On a later rerun, the preview can list containers as `Modify`: Azure stores default
indexing and conflict-resolution values that the template leaves unset, and the template does not
change them.

![Step 2 preview: database unchanged, containers listed](../images/guide/run-stage2-preview.png)

---

## Step 3: give each app its permissions

**What it does.** Gives each managed identity only the access it uses:

| Identity | Access |
| --- | --- |
| Each Function App | Storage Blob Data Owner on its own storage; Monitoring Metrics Publisher on its own Application Insights |
| Resolver | Read the Cosmos database |
| Sync | Write group membership; create projects and backends once; read `adminConfig` |
| Reconciler, admin | Read the Log Analytics workspace; reconciler writes budget state |
| Admin | Read, create and replace projects and `adminConfig` (no delete) |
| APIM | Cognitive Services User on each Foundry account |

The full table is in the [driver reference](STAGED-DEPLOYMENT-V2.md#stage-3-runtime-grants).

**Who runs it.** Role Based Access Control Administrator (or Owner) on the resource group and each
Foundry account, and Cosmos DB role-definition and role-assignment write on the Cosmos account.

**Script**

```powershell
pwsh -File infra\staged\Invoke-StagedDeployment.ps1 -Stage 3 -ConfigPath $cfg
pwsh -File infra\staged\Invoke-StagedDeployment.ps1 -Stage 3 -ConfigPath $cfg -Apply
```

**Azure CLI**

```powershell
az deployment group create -g $rg -n stage3-grants --mode Incremental `
    -f infra\staged\stage3-grants.bicep -p "@$state\stage3-grants.parameters.json"
az role assignment list --scope $foundryId `
    --query "[].{principal:principalName, role:roleDefinitionName}" -o table
az cosmosdb sql role assignment list -g $rg -a $cosmos `
    --query "[].{principal:principalId, scope:scope}" -o table
```

`az role assignment list` with an empty `--scope` falls back to the whole subscription, so the scope
value is checked before the command runs.

**Portal.** Azure role assignments are on each resource's **Access control (IAM)** > **Add role
assignment** > role > **Managed identity** > the app or APIM. Cosmos DB data-plane role assignments
cannot be managed in the Azure Portal ([Cosmos DB role-based access](https://learn.microsoft.com/azure/cosmos-db/how-to-connect-role-based-access-control));
use the script or Azure CLI for those.

![Foundry account IAM filtered to the APIM identity: Cognitive Services User](images/staged-portal/03-foundry-iam.png)

![Storage account IAM filtered to the resolver identity: Storage Blob Data Owner](images/staged-portal/03-storage-iam.png)

**Check.** Existing grants show `NoChange`; a grant in the template that does not exist yet shows
`Create`.

![Step 3 preview: existing grants NoChange, one new grant Create](../images/guide/run-stage3-preview.png)

---

## Step 4: register the apps and groups in Entra ID

**What it does.** Creates, or merges into existing, three app registrations and the project groups:

| Registration | Used for |
| --- | --- |
| Gateway (also developer sign-in) | Token audience for APIM; delegated scope `access_as_user`; v2 tokens; public client redirects for sign-in |
| Resolver | Token audience that only APIM's managed identity calls |
| Admin | Admin console sign-in; scope `Projects.Manage`; app roles `CCOF.Projects.Read` and `CCOF.Projects.Write`; assignment required |

Each project classification (for example `PILOT1` / `STD`) has one security group; its direct members
get access to that project. Full settings: [deployment runbook](DEPLOYMENT-RUNBOOK.md#1-entra-administrator-handoff).

**Who runs it.** Application owner or Application Administrator; group owner or Groups Administrator.

**Script**

```powershell
pwsh -File infra\staged\Invoke-StagedDeployment.ps1 -Stage 4 -ConfigPath $cfg
pwsh -File infra\staged\Invoke-StagedDeployment.ps1 -Stage 4 -ConfigPath $cfg -Apply
```

**Azure CLI.** The commands below create the gateway registration and one group. They were run in the
Contoso test tenant on 24 October 2026, read back, and deleted. Request bodies are in files because of
the `cmd.exe` rule above.

```powershell
# Gateway app: single tenant, public client for sign-in
$gw = az ad app create --display-name 'CCOF Gateway <environment>' --sign-in-audience AzureADMyOrg `
    --is-fallback-public-client true --public-client-redirect-uris http://localhost --query appId -o tsv
az ad app update --id $gw --identifier-uris "api://$gw" `
    --public-client-redirect-uris http://localhost "ms-appx-web://Microsoft.AAD.BrokerPlugin/$gw"
$obj = az ad app show --id $gw --query id -o tsv

# v2 tokens and the access_as_user scope
$scopeId = [guid]::NewGuid().ToString()
@{ api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = @(@{
    id = $scopeId; value = 'access_as_user'; type = 'User'; isEnabled = $true
    adminConsentDisplayName = 'Access the CCOF gateway'; adminConsentDescription = 'Call the CCOF gateway as the signed-in user'
    userConsentDisplayName = 'Access the CCOF gateway'; userConsentDescription = 'Call the CCOF gateway as you' }) } } |
    ConvertTo-Json -Depth 6 | Set-Content gateway-api.json
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$obj" `
    --headers Content-Type=application/json --body '@gateway-api.json'

# Preauthorize the app itself and Azure CLI for the scope
@{ api = @{ preAuthorizedApplications = @(
    @{ appId = $gw; delegatedPermissionIds = @($scopeId) },
    @{ appId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'; delegatedPermissionIds = @($scopeId) }) } } |
    ConvertTo-Json -Depth 6 | Set-Content gateway-preauth.json
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$obj" `
    --headers Content-Type=application/json --body '@gateway-preauth.json'
az ad sp create --id $gw

# Read back
az ad app show --id $gw --query "{uri:identifierUris[0], tokenVersion:api.requestedAccessTokenVersion, scope:api.oauth2PermissionScopes[0].value, preauthorized:api.preAuthorizedApplications[].appId}" -o json

# One project group and one member
$group = az ad group create --display-name 'CCOF-PILOT1-STD' --mail-nickname 'ccof-pilot1-std' --query id -o tsv
$memberId = az ad user show --id '<user@your-domain>' --query id -o tsv
az ad group member add --group $group --member-id $memberId
```

The admin registration uses the same pattern: `az ad app create --app-roles '@admin-roles.json'` for
the two roles, a Graph PATCH with `spa.redirectUris` for `https://<admin-host>/api/console` and
`/api/console-v3`, and `az ad sp update --id <service-principal-id> --set appRoleAssignmentRequired=true`.
These were also run in the Contoso test tenant. Record each app ID in `entra.existing` in the
configuration file; the driver's Step 4 then merges into those registrations instead of creating new ones.

**Portal.** **Microsoft Entra ID** > **App registrations** > **New registration**, then
**Expose an API**, **Authentication**, **App roles** and **Manifest** (`requestedAccessTokenVersion: 2`)
as listed in the [deployment runbook](DEPLOYMENT-RUNBOOK.md#app-registrations). Groups:
**Microsoft Entra ID** > **Groups** > **New group** (type **Security**) > **Members** > **Add members**.

![Gateway app Expose an API: access_as_user scope and the authorized clients](images/staged-portal/04-gateway-expose-api.png)

![Admin app App roles: CCOF.Projects.Write and CCOF.Projects.Read](images/staged-portal/04-admin-roles.png)

![Project group Members](images/staged-portal/04-group-members.png)

**Check**

![Step 4 preview: existing registrations and groups reused](../images/guide/run-stage4-preview.png)

Unattended group sync also needs Microsoft Graph application permissions, granted by a Privileged
Role Administrator. Step 4 does not grant them; the default `sync.mode: delegated-snapshot` does not
need them ([permissions](../PERMISSIONS.md)).

---

## Step 5: configure the apps and the gateway

**What it does.** Writes each Function App's settings, turns on Entra sign-in for the resolver
(only APIM's identity may call it), and creates the gateway API at path `anthropic`, its policy,
the developer usage API, API logging and the chargeback workbook. Timers stay off unless the
configuration turns them on.

**Who runs it.** Website Contributor on the Function Apps, API Management Service Contributor on APIM,
and workbook write on the resource group.

**Script (recommended for this step)**

```powershell
pwsh -File infra\staged\Invoke-StagedDeployment.ps1 -Stage 5 -ConfigPath $cfg
pwsh -File infra\staged\Invoke-StagedDeployment.ps1 -Stage 5 -ConfigPath $cfg -Apply
```

The script renders the gateway policy from the configuration and checks it before deploying. Step 5
writes each app's settings as a complete set, so settings added by hand are replaced on the next run.

**Azure CLI.** The driver preview writes the rendered policy and the parameter file; the same
deployment then runs with:

```powershell
az deployment group create -g $rg -n stage5-config --mode Incremental `
    -f infra\staged\stage5-config.bicep -p "@$state\stage5-config.parameters.json"
az functionapp config appsettings list -g $rg -n $resolverApp --query "[].name" -o tsv
```

**Portal.** The parameter file holds the full gateway policy and is several hundred kilobytes; the
Portal route for this step was not tested. The Portal shows the result:

1. Function App > **Settings** > **Environment variables**: the setting names.
2. Resolver Function App > **Settings** > **Authentication**: **Require authentication**.
3. APIM > **APIs**: **Claude Messages (staged)**.

![Function App Environment variables: setting names, values hidden](images/staged-portal/05-function-settings.png)

![Resolver Authentication: require authentication](images/staged-portal/05-resolver-auth.png)

![API Management APIs: Claude Messages (staged)](images/staged-portal/05-apim-apis.png)

**Check**

![Step 5 preview: app settings, API, policy fragments and workbook](../images/guide/run-stage5-preview.png)

---

## Step 6: connect the network

**What it does.** With the default `network.mode: verify`, your network team builds the network and
Step 6 only checks it. The network needs:

- one VNet with three subnets: private endpoints (no delegation), Functions (delegated to
  `Microsoft.App/environments`) and APIM (delegated to `Microsoft.Web/serverFarms`, with a network
  security group);
- private endpoints for the Cosmos account (`Sql`), each app's storage (`blob`) and each private
  Foundry account (`account`), each approved and with a DNS zone group;
- private DNS zones `privatelink.documents.azure.com`, `privatelink.blob.core.windows.net` and, for
  private Foundry, `privatelink.cognitiveservices.azure.com`, `privatelink.openai.azure.com` and
  `privatelink.services.ai.azure.com`, linked to the VNet;
- each Function App joined to the Functions subnet, and APIM outbound integration on the APIM subnet.

Details: [driver reference](STAGED-DEPLOYMENT-V2.md#stage-6-network-last-setup-stage) and
[network](../NETWORK.md).

**Who runs it.** Checking: Reader on the VNet, endpoints, DNS zones and apps. Building: Network
Contributor on the VNet, private DNS zone write and link, and site write on the Function Apps.

**Script**

```powershell
pwsh -File infra\staged\Invoke-StagedDeployment.ps1 -Stage 6 -ConfigPath $cfg -Apply   # verify mode: checks only
```

The check alone, without the driver:
[`scripts\manual\Test-NetworkConfiguration.ps1`](../../scripts/manual/Test-NetworkConfiguration.ps1).

**Azure CLI: build**

```powershell
$netRg = '<network-resource-group>'; $vnet = '<vnet-name>'; $apimNsg = '<apim-nsg-name>'
$vnetId = az network vnet show -g $netRg -n $vnet --query id -o tsv
az network vnet subnet create -g $netRg --vnet-name $vnet -n snet-private-endpoints --address-prefixes 10.64.2.0/24
az network vnet subnet create -g $netRg --vnet-name $vnet -n snet-functions --address-prefixes 10.64.3.0/24 `
    --delegations Microsoft.App/environments
az network vnet subnet create -g $netRg --vnet-name $vnet -n snet-apim --address-prefixes 10.64.1.0/24 `
    --delegations Microsoft.Web/serverFarms --network-security-group $apimNsg

# One private endpoint, its DNS zone, link and zone group (repeat per endpoint)
az network private-endpoint create -g $netRg -n "$cosmos-sql-pe" --vnet-name $vnet --subnet snet-private-endpoints `
    --private-connection-resource-id $cosmosId --group-id Sql --connection-name "$cosmos-sql"
az network private-dns zone create -g $netRg -n privatelink.documents.azure.com
az network private-dns link vnet create -g $netRg -z privatelink.documents.azure.com -n ccof-link `
    --virtual-network $vnetId --registration-enabled false
az network private-endpoint dns-zone-group create -g $netRg --endpoint-name "$cosmos-sql-pe" -n default `
    --private-dns-zone privatelink.documents.azure.com --zone-name documents

# Function Apps: one at a time
foreach ($app in $resolverApp, $syncApp, $reconcilerApp, $adminApp) {
    az functionapp vnet-integration add -g $rg -n $app --vnet $vnetId --subnet snet-functions
}

# APIM Standard v2 outbound integration, through ARM (keeps the managed identity)
@{ properties = @{ virtualNetworkType = 'External'; virtualNetworkConfiguration = @{
    subnetResourceId = "$vnetId/subnets/snet-apim" } } } | ConvertTo-Json -Depth 5 | Set-Content apim-vnet.json
az rest --method PATCH --uri "https://management.azure.com${apimId}?api-version=2024-05-01" --body '@apim-vnet.json'
```

`az apim update` is not used here: without `--enable-managed-identity true` it removes APIM's
managed identity, which the gateway needs to call Foundry and the resolver
([azure-cli source](https://github.com/Azure/azure-cli/blob/dev/src/azure-cli/azure/cli/command_modules/apim/custom.py)).
Joining several Function Apps to a subnet at the same time failed with `ServiceAssociationLinkLease`
in the lab, so they are joined one at a time.

**Azure CLI: check**

```powershell
az network vnet subnet show --ids "$vnetId/subnets/snet-functions" --query "delegations[].serviceName" -o tsv
az network private-endpoint list -g $netRg --query "[].{name:name, state:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}" -o table
az network private-dns link vnet list -g $netRg -z privatelink.documents.azure.com --query "[].virtualNetwork.id" -o tsv
az functionapp vnet-integration list -g $rg -n $resolverApp -o table
```

**Portal**

1. Foundry account > **Networking**: public access **Disabled**, private endpoint **Approved**.
2. APIM > **Network**: outbound virtual network integration on the APIM subnet.
3. Function App > **Networking**: outbound VNet integration on the Functions subnet.
4. Private DNS zone > **Virtual network links**: linked to the VNet.

![Foundry Networking: public access disabled, private endpoint](images/staged-portal/06-foundry-networking.png)

![API Management Network: outbound virtual network integration](images/staged-portal/06-apim-network.png)

![Function App Networking: VNet integration on snet-functions](images/staged-portal/06-function-networking.png)

![Private DNS zone Virtual network links](images/staged-portal/06-dns-links.png)

**Check.** In verify mode, Step 6 stops with `verify_failed` and lists each failing row. The lab ran
`network.mode: create`, where the driver also builds the network; on a rerun it only verifies:

![Step 6 preview in the lab](../images/guide/run-stage6-preview.png)

---

## Step 7: publish the code and load the first data

**What it does.** Publishes the four Function App packages, waits until each app lists its functions,
creates the project and backend records once from the configuration, loads group membership with a
one-time snapshot read with your own Entra sign-in, and writes the developer client file `config.json`.

**Who runs it.** Website Contributor on the Function Apps, and read access to the project groups in
Entra ID. Step 6 comes first: with private storage, each app reads its package from its own storage
account through its VNet integration.

**Script**

```powershell
pwsh -File infra\staged\Invoke-StagedDeployment.ps1 -Stage 7 -ConfigPath $cfg
pwsh -File infra\staged\Invoke-StagedDeployment.ps1 -Stage 7 -ConfigPath $cfg -Apply
```

Only one Step 7 runs at a time per checkout; a second one stops with `stage7_busy`.

**Azure CLI: packages**

```powershell
foreach ($app in 'resolver','sync','reconciler') {
    pwsh -File scripts\portal\Build-PortalPackage.ps1 -App $app     # writes .env.portal-artifacts\<app>.zip
}
pwsh -File admin\Build-AdminPackage.ps1 -OutFile .env.portal-artifacts\admin.zip
az functionapp deployment source config-zip -g $rg -n $resolverApp --src .env.portal-artifacts\resolver.zip
# repeat for the sync, reconciler and admin apps
az functionapp function list -g $rg -n $resolverApp --query "[].name" -o tsv
```

`config-zip` is the zip deployment (OneDeploy) used for Flex Consumption apps by the driver and the
quickstart ([Flex Consumption plan](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan#deployment)).
The project/backend records and the membership snapshot without the driver are described in the
[Cloud Shell quickstart, step 5](CLOUD-SHELL-QUICKSTART.md) and the
[public access workbook](PUBLIC-ACCESS-WORKBOOK.md).

**Portal.** Function App > **Functions**: the resolver lists `health`, `myUsage` and `resolve`.

![Resolver functions after publishing](images/staged-portal/07-functions-list.png)

**Check**

![Step 7 preview: packages, seed, snapshot and client file](../images/guide/run-stage7-preview.png)

![Step 7 apply output from the earlier lab run](../images/staged/07-stage7-code-data.png)

---

## Step 8: test end to end

**What it does.** Sends requests through the gateway: without a token (expect 401), for each allowed
project and model (expect 200) and for each denied pair (expect the configured status, usually 403).
It also checks the admin console and that each successful request appears in the
`ApiManagementGatewayLlmLog` table within 15 minutes. Allowed requests use a few tokens of Claude.

**Who runs it.** A member of an allowed project group, with Azure CLI allowed as a client of the
gateway app (`entra.allowAzureCliClient: true`), and Log Analytics Reader on the workspace.

**Script**

```powershell
pwsh -File infra\staged\Invoke-StagedDeployment.ps1 -Stage 8 -ConfigPath $cfg -Apply
```

**Azure CLI and PowerShell**

```powershell
$gatewayAppId = '<gateway-app-id>'      # Application (client) ID of the gateway app from Step 4
$project = '<project>'                  # a project in the acceptance.allowed list
$gateway = (az apim show -g $rg -n $apim --query gatewayUrl -o tsv) + '/anthropic'
$token = az account get-access-token --scope "api://$gatewayAppId/access_as_user" --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $token"; 'x-ccof-project' = $project; 'anthropic-version' = '2023-06-01' }
$body = @{ model = 'claude-haiku-4-5'; max_tokens = 24; messages = @(@{ role = 'user'; content = 'Reply with OK' }) } |
    ConvertTo-Json -Depth 5
(Invoke-WebRequest -Uri "$gateway/v1/messages" -Method Post -Headers $headers -Body $body `
    -ContentType application/json -SkipHttpErrorCheck).StatusCode          # 200 for an allowed model
(Invoke-WebRequest -Uri "$gateway/v1/messages" -Method Post -Body $body `
    -ContentType application/json -SkipHttpErrorCheck).StatusCode          # 401 without a token
```

**Portal.** Log Analytics workspace > **Logs**:

```kusto
ApiManagementGatewayLlmLog
| where TimeGenerated > ago(1h)
| project TimeGenerated, CorrelationId, ModelName, PromptTokens, CompletionTokens
```

**Check**

![Step 8 output: 401 without a token, 200 for allowed models, 403 for denied ones, telemetry rows](../images/staged/08-stage8-acceptance.png)

---

## After deployment

| Next | Guide |
| --- | --- |
| Add projects, people, models, limits and budgets | [Admin console operations](ADMIN-OPERATIONS.md) |
| Set up developers' machines and Claude Code | [User onboarding](USER-ONBOARDING.md) |
| Budget warnings at 80% and spend pacing | [Budgets and spend pacing](../BUDGETS.md) |

## When a step fails

| Message | Meaning | What to do |
| --- | --- | --- |
| `verify_failed: <reason>` | The step ran, but the read-back found something different | Fix the named item; rerun the same step |
| `stage_order` | A step it depends on is not recorded | Run the earlier step first |
| `stage_dependency_changed` | An earlier step was rerun with different results | Rerun this step |
| `stage_config_changed` | The configuration for an already-verified step changed | Preview and apply that step again |
| `state_target_mismatch` | The state folder belongs to another tenant, subscription or resource group | Use a separate configuration folder per environment |
| `stage7_busy` | Another Step 7 is running from this checkout | Wait for it to finish |
| `'charmap' codec` from `az` | The Azure CLI on Windows met a non-ASCII character | [`scripts/diagnostics/windows-az-utf8`](../../scripts/diagnostics/) |
| `AuthorizationFailed` | The signed-in account lacks the permission in **Who runs it** | Ask the owner of that scope; check `az account show` |

No step deletes resources, Entra objects or earlier permission grants
([recovery](STAGED-DEPLOYMENT-V2.md#recovery)).
