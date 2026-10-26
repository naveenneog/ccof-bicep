# Build the DR standby region (region B) in Azure Cloud Shell

**For:** an operator who finished the single-region deployment ([Deploy CCOF step by step](DEPLOY-STEP-BY-STEP.md))
and wants to build the second-region ("region B") copy of the CCOF services with the staged DR driver.
**Time:** one to two hours of commands, spread over several Cloud Shell sessions.
**Result after sections 1-10:** a standby APIM and four Function Apps in the standby region, Cosmos DB
with a second read region, region B grants, settings and private networking, the same code as region
A, and a read-only check that both writers are off. These build steps do not change Front Door routing
or promote a writer. Section 11 records the live failover and failback drill.

> **Drilled, not production-qualified.** On **2026-10-26** the lab ran the whole cycle: traffic to
> region B, region B promoted as the only writer, Log Analytics workspace switchover, then failback of
> the workspace, Cosmos DB, the writers and Front Door to region A (section 11). Three items remain open
> and block a production claim: DR-15, DR-16 and DR-17 in [UNKNOWNS](../UNKNOWNS.md) (summary in 11.7).

State of the work on **2026-10-26** (read this first):

| Part | State | Source |
| --- | --- | --- |
| P0-P2: standby network, DNS links, identity shells | Implemented; proven live in two lab environments by 2026-10-23 | [DR-CLOUD-SHELL.md](DR-CLOUD-SHELL.md), [ROADMAP](../ROADMAP.md) (DR-06) |
| Region B driver, phases `Data`, `Shells`, `Grants`, `Config`, `Network`, `Code`, `Verify` | Run live in the lab on 2026-10-25; `Code` re-run on 2026-10-26. Offline tests in `tests/Test-DrStandby.ps1` | [`infra/dr/Invoke-DrStandby.ps1`](../../infra/dr/Invoke-DrStandby.ps1), section 11 |
| Front Door Premium with private origins | Deployed; failover to region B and failback to region A both observed | Sections 11.1, 11.2, 11.6 |
| Region B promotion under the continuity gate | Done: region B wrote budget states with the gate `on` after a one-time baseline adoption | Section 11.3, [ADR 0036 amendment](../adr/0036-continuity-coverage-baseline.md#amendment-2026-10-26-one-time-baseline-adoption) |
| Workspace switchover and failback | Done; while switched over, the ledger lacked history from before replication began and the gate refused (DR-17) | Sections 11.4, 11.5 |
| Live lab state after the drill | Front Door serves region A; Cosmos writes in East US 2; region A writers on with the gate `on`; region B writers fenced; workspace back in East US 2 | Section 11.6 |
So after sections 1-10 the standby stack **exists and is fenced**, but the DR design as a whole is not
finished. The standby Foundry fallback is a different mechanism (backends and project pools in
[DR-CLOUD-SHELL.md Step 6](DR-CLOUD-SHELL.md#step-6-per-project-backend-failover-admin-console-33)); it is
not part of a region B app deployment. The design is in [DR design](../DR-ACTIVE-PASSIVE.md); the
contracts are [ADR 0033](../adr/0033-dr-active-passive.md) and [ADR 0034](../adr/0034-dr-project-routing-and-prerequisites.md).

The driver's own error text points to `docs/runbooks/DR-STANDBY.md`; that file does not exist, and this
guide is its replacement.

## 1. How the pieces fit

```text
dr.config.json  (one file, in Cloud Shell clouddrive)
   |-- tenantId ... entra              -> Invoke-DrPrerequisites.ps1   P0 Discover, P1/P2 Bootstrap, Verify
   |-- secondary, dnsZones, identities -> (network, DNS links, identity shells in region B)
   |-- standby, cosmos                 -> Invoke-DrStandby.ps1         Data, Shells, Grants, Config, Network, Code, Verify
   |-- standby.stagedConfigPath/...    -> READS the primary's staged.config.json and .staged-state (never writes them)
                                          WRITES region B state to standby.stateDirectory
```

Facts from the code ([`Invoke-DrStandby.ps1`](../../infra/dr/Invoke-DrStandby.ps1),
[`DrStandby.psm1`](../../infra/dr/DrStandby.psm1)):

- One phase runs per command. Without `-Apply` a phase is a preview (no Azure change); with `-Apply` it
  changes Azure, reads the result back and records it in `standby.stateDirectory`.
- Region B shares region A's resource group, Cosmos account and Log Analytics workspace. The driver
  refuses to run when `secondary.resourceGroup` differs from the primary's resource group
  (`standby_resource_group`).
- Region B's names are the primary stem plus `-<nameSuffix>` (for example `...-resolver` becomes
  `...-resolver-b`); storage names add the suffix before the 3-letter app code.
- Both writers (`syncEntitlement`, `reconcileBudgets`) are created disabled and timers off. `Verify`
  fails when either is not disabled. Nothing in this repository promotes them: that is a deliberate,
  separate step (DR-08, not built).
- Phase order enforced by the driver: `Grants` needs `Shells`; `Config` needs `Grants`; `Network`
  needs `Shells`; `Code` needs `Config` and `Network` (error `phase_order`). `Data` is not required by
  the others in code; run it first anyway, because the standby apps read the shared Cosmos account.

## 2. Azure Cloud Shell: what lasts and what does not

| Item | Behaviour | Source |
| --- | --- | --- |
| Idle timeout | A session ends after **20 minutes without interactive activity**; the machine behind it is recycled | [Cloud Shell FAQ](https://learn.microsoft.com/azure/cloud-shell/faq-troubleshooting) |
| A running Azure change | A timeout stops **your CLI process**, not necessarily the Azure operation it started: the ARM or Cosmos operation can keep running on the service. Never assume either "it finished" or "it was cancelled": read the state (section 8) | Driver design: every phase "can be run again" ([`Invoke-DrStandby.ps1`](../../infra/dr/Invoke-DrStandby.ps1) header) |
| `clouddrive` (`$HOME/clouddrive`) | An Azure Files share mounted in every session: **durable** | [Persist files](https://learn.microsoft.com/azure/cloud-shell/persisting-shell-storage) |
| `$HOME` outside `clouddrive` | Kept in a disk image on the same file share when storage is mounted | [Persist files](https://learn.microsoft.com/azure/cloud-shell/persisting-shell-storage) |
| Ephemeral session (no storage account) | Everything, including `clouddrive`, is lost at session end. **Do not use ephemeral sessions for this guide** | [Ephemeral sessions](https://learn.microsoft.com/azure/cloud-shell/get-started/ephemeral) |
| Shell variables, `cd`, `az account set`, a running `pwsh` | **Ephemeral**: lost at every timeout. The session file in section 4 restores them | Cloud Shell behaviour above |
| Sign-in | Cloud Shell is already signed in with your Portal account. Do not run `az login` (device-code sign-in is refused by many Conditional Access policies) | [DR-CLOUD-SHELL.md Step 1](DR-CLOUD-SHELL.md#step-1-prepare-cloud-shell), N-04 |

Keep these three things on `clouddrive` and nothing important elsewhere: `dr.config.json`, the primary's
staged configuration and state, and the region B state folder. Treat them as confidential (resource IDs
and deployment outputs): do not commit them, and restrict access to the storage account
([Securing storage access](https://learn.microsoft.com/azure/cloud-shell/persisting-shell-storage#securing-storage-access)).

To check that storage is mounted: `Test-Path "$HOME/clouddrive"` must print `True`. If it prints
`False`, open Cloud Shell **Settings > Reset user settings**, then mount an existing or new storage
account ([persist files](https://learn.microsoft.com/azure/cloud-shell/persisting-shell-storage)).

## 3. Prerequisites checklist

| # | Requirement | How to check |
| --- | --- | --- |
| 1 | A single-region deployment with Stages 1-7 applied; its `staged.config.json` and `.staged-state` folder (with `state.json`) | The state folder is `<folder of staged.config.json>/.staged-state` unless the driver ran with `-StateDirectory` ([`Invoke-StagedDeployment.ps1`](../../infra/staged/Invoke-StagedDeployment.ps1)). Stage 1 outputs must be in it |
| 2 | The standby region offers APIM, Function Apps, Container Apps environments, Cosmos DB and Log Analytics | `Discover` checks resource providers per region. It does not check APIM v2 SKU availability or Flex Consumption: check Flex with `az functionapp list-flexconsumption-locations --query "value[].name" -o tsv` ([CLI reference](https://learn.microsoft.com/cli/azure/functionapp#az-functionapp-list-flexconsumption-locations)) and APIM v2 in the [region table](https://learn.microsoft.com/azure/api-management/api-management-region-availability) |
| 3 | Cosmos DB decision recorded: the account is serverless today or already provisioned | Section 6, "Cosmos DB" |
| 4 | Permissions: Contributor on the resource group; Network Contributor on the primary VNet (peering); Private DNS Zone Contributor on the zones' group; Reader on Foundry accounts; read in Entra for the 3 app registrations; the rights the staged Stages 3, 5 and 6 need, and permission to edit the admin app registration (the `Config` phase adds redirect URIs to it) | [Permissions table](DR-CLOUD-SHELL.md#before-you-start), [Stage 3-6 notes](STAGED-DEPLOYMENT-V2.md#stage-notes) |
| 5 | The admin app preauthorizes Azure CLI (`entra.admin:azure_cli_not_preauthorized` otherwise in `Discover`) | [DR-CLOUD-SHELL.md Step 2.0](DR-CLOUD-SHELL.md#20-azure-cli-as-an-admin-client-workstation-n-17) |
| 6 | A repository checkout that **contains** `infra/dr/Invoke-DrStandby.ps1` | As of 2026-10-25 the driver is on branch `feat/dr-standby`, not on `main` (`git branch --contains 7162dd3`). Use the branch or commit your team gives you; section 4 tests for the file |
| 7 | Node.js and `npm` in Cloud Shell, for the `Code` phase (`npx tsc`, admin package build) | `node --version; npm --version`; install the dependencies with `npm ci` in the repository (section 4) |

## 4. Set up Cloud Shell

Open Cloud Shell (Portal top bar > **Cloud Shell** > **PowerShell**), then run the blocks in order.

**Block 1: durable folders and the session file.** Run once. The session file restores your
variables after every timeout; later sessions need only block 2.

```powershell
$base = "$HOME/clouddrive/ccof-dr"
if (-not (Test-Path "$HOME/clouddrive")) { throw 'No clouddrive: this is an ephemeral session. Mount storage first (section 2).' }
New-Item -ItemType Directory -Force -Path "$base/primary", "$base/standby-state", "$base/evidence", "$base/logs" | Out-Null
@'
$base     = "$HOME/clouddrive/ccof-dr"
$cfg      = "$base/dr.config.json"
$evidence = "$base/evidence"
$logs     = "$base/logs"
$repo     = "$HOME/ccof-bicep"
function Use-DrSession {
    if (-not (Test-Path $cfg)) { throw "No $cfg yet: finish section 5." }
    $c = Get-Content $cfg -Raw | ConvertFrom-Json
    az account set --subscription $c.subscriptionId
    az account show --query "{tenant:tenantId, subscription:id, user:user.name}" -o table
    Set-Location $repo
}
function Invoke-DrPhase {
    param([Parameter(Mandatory)] [ValidateSet('Data','Shells','Grants','Config','Network','Code','Verify')] [string]$Phase, [switch]$Apply)
    $a = @(); if ($Apply) { $a += '-Apply' }
    $log = "$logs/standby-$Phase-$(Get-Date -Format yyyyMMddTHHmmss)-$(if ($Apply) {'apply'} else {'preview'}).log"
    pwsh -NoProfile -File "$repo/infra/dr/Invoke-DrStandby.ps1" -Phase $Phase -ConfigPath $cfg @a 2>&1 | Tee-Object -FilePath $log
    "exit code $LASTEXITCODE (log: $log)"
}
'@ | Set-Content -Path "$base/session.ps1"
```

**Block 2: every new or resumed session.**

```powershell
. "$HOME/clouddrive/ccof-dr/session.ps1"
```

**Block 3: the code.** `$repo` is outside `clouddrive` on purpose: building `node_modules` on an SMB share is
slow. It is rebuilt cheaply after a recycle if storage is not mounted. Replace `REPLACE-branch-or-commit`
with the branch or commit that contains the DR driver (section 3, row 6).

```powershell
if (-not (Test-Path $repo)) { git clone https://github.com/naveenneog/ccof-bicep.git $repo }
Set-Location $repo
git fetch --all --prune
git checkout REPLACE-branch-or-commit
git log -1 --oneline
Test-Path infra/dr/Invoke-DrStandby.ps1
az bicep install
npm ci --ignore-scripts --include=dev
```

**Expect:** the commit line, `True`, and `npm ci` without errors. `False` means the checkout does not
have the DR driver.

**Block 4: the primary's staged files on `clouddrive`.** The driver reads them; it never writes them.
Copy, do not move: the originals stay where the primary deployment is managed.

From a workstation: zip the folder that holds `staged.config.json` and `.staged-state`
(`Compress-Archive -Path .\staged.config.json, .\.staged-state -DestinationPath primary.zip`), then in
Cloud Shell choose **Manage files > Upload** for `primary.zip` and run:

```powershell
Expand-Archive -Path "$HOME/primary.zip" -DestinationPath "$base/primary" -Force
Get-ChildItem "$base/primary" -Force | Select-Object Name
Test-Path "$base/primary/.staged-state/state.json"
```

**Expect:** `staged.config.json`, `.staged-state` and `True`. If the primary was deployed from Cloud Shell,
copy its two items into `$base/primary` the same way (`Copy-Item -Recurse`).

## 5. Fill `dr.config.json` from values you already have

One file serves P0-P2 and region B. Start from
[`infra/dr/dr.config.example.json`](../../infra/dr/dr.config.example.json):

```powershell
. "$HOME/clouddrive/ccof-dr/session.ps1"
Set-Location $repo
Copy-Item infra/dr/dr.config.example.json $cfg
```

Edit `$cfg` (Cloud Shell has `code` for its built-in editor, or use the full JSON in section 5.3 and
paste it with your values). Replace **every** `REPLACE-` value; the drivers refuse a placeholder in the
`standby` section, and `Select-String` in section 5.4 finds any left.

### 5.1 Read the values (read-only commands)

```powershell
$sub = 'REPLACE-subscription-id'
$rg  = 'REPLACE-ccof-resource-group'
$p   = Get-Content "$base/primary/staged.config.json" -Raw | ConvertFrom-Json
$p.tenantId; $p.subscriptionId; $p.resourceGroup; $p.location; $p.tags | ConvertTo-Json -Compress
$p.stage1.apimSku; $p.stage1.apimUnits; $p.stage1.includeAdmin; $p.cosmos.databaseName
$p.network.existing.functionsSubnetId
az group show --subscription $sub -n $rg --query "{location:location, tags:tags}" -o json
az cosmosdb list --subscription $sub -g $rg --query "[].{name:name, capacity:capacityMode, regions:locations[].locationName}" -o json
az apim list --subscription $sub -g $rg --query "[].{name:name, sku:sku.name, units:sku.capacity, email:publisherEmail, publisher:publisherName}" -o json
az identity list --subscription $sub -g $rg --query "[].name" -o tsv
az network vnet show --ids ($p.network.existing.functionsSubnetId -split '/subnets/')[0] --query "{id:id, spaces:addressSpace.addressPrefixes}" -o json
az network private-dns zone list --subscription $sub --query "[?starts_with(name,'privatelink.')].{name:name, rg:resourceGroup}" -o table
az cognitiveservices account list --subscription $sub --query "[?kind=='AIServices'].{name:name, rg:resourceGroup}" -o table
az ad app list --display-name CCOF --query "[].{name:displayName, appId:appId}" -o table
```

If your primary has no `network.existing` (it was built in `create` mode), read `network.create` and the
VNet it created. The detailed Step 2 queries (primary VNet, DNS links per VNet, Foundry and app lists) are in
[DR-CLOUD-SHELL.md Step 2](DR-CLOUD-SHELL.md#step-2-fill-the-dr-configuration). The Cosmos
account name and the APIM list also exist in `.staged-state/state.json` (Stage 1 outputs); do not paste
IDs from the state file into documents or tickets.

### 5.2 Field reference

All paths are in `dr.config.json`. Rules come from `Get-DrConfigProblems`
([`DrPrerequisites.psm1`](../../infra/dr/DrPrerequisites.psm1)) and `Get-DrStandbyProblems`
([`DrStandby.psm1`](../../infra/dr/DrStandby.psm1)); every problem is reported as `path:reason` before any Azure call.
A "name" below means `^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$`; a "region" means lowercase letters and digits,
3-31 characters (`eastus2`, `centralus`).

| JSON path | Example | Accepted values | What to decide, and where to read it |
| --- | --- | --- | --- |
| `tenantId` | `11111111-1111-4111-8111-111111111111` | GUID | The Microsoft Entra tenant that owns the identities and app registrations. Same value as the primary's `tenantId`. Cloud Shell: `az account show --query tenantId -o tsv`. The check compares it with the signed-in account (`account:tenant_mismatch`) |
| `subscriptionId` | `22222222-2222-4222-8222-222222222222` | GUID | The subscription that holds the **resources** (it can be a different one from the tenant's default). Must equal the primary's `subscriptionId`: region B shares its resource group, so a different subscription cannot work |
| `tags` | `{ "workload": "ccof", "stage": "dr-prerequisites" }` | Tag names are names; values `^[A-Za-z0-9._:/-]{1,256}$` | Tags for the P1/P2 resources and a created resource group. Follow your standard; no spaces or `@` |
| `primary.location` | `eastus2` | Region; must differ from `secondary.location` | Region of the primary deployment: `az group show -n $rg --query location -o tsv` (or the primary's `location`) |
| `primary.vnetId` | `/subscriptions/2222.../resourceGroups/rg-ccof-network/providers/Microsoft.Network/virtualNetworks/vnet-ccof-primary` | A VNet resource ID, or omit | The VNet that holds the primary's subnets: the part of `network.existing.functionsSubnetId` before `/subnets/`. Needed for the overlap check and peering. Region B reaches the primary's Foundry private endpoints over this peering ([`DrStandby.psm1`](../../infra/dr/DrStandby.psm1), comment on `New-DrStandbyStagedConfig`), so keep peering on |
| `primary.addressSpaces` | `["10.64.0.0/16"]` | CIDRs | Every address prefix of that VNet (`az network vnet show --ids <id> --query addressSpace.addressPrefixes`) **and** of every network peered with it, which the tool cannot see. Used only for the overlap check |
| `primary.peer` | `true` | `true` / `false` | `true`: the Bootstrap creates both peerings (needs Network Contributor on the primary VNet). `false`: only when your network team connects the VNets some other way (hub); then region B still needs a path to the primary's private endpoints |
| `secondary.location` | `centralus` | Region; not equal to `primary.location` | The standby region. Check services per region (section 3 row 2). Workspace replication has its own pairing rules ([Learn](https://learn.microsoft.com/azure/azure-monitor/logs/workspace-replication#supported-regions)) |
| `secondary.resourceGroup` | `rg-ccof-prod` | A name | **Must be the primary's resource group** for the region B driver (`standby_resource_group`). Same value as the primary's `resourceGroup` |
| `secondary.allowResourceGroupInOtherRegion` | `true` | `true` / `false` | `true` when the existing group is in the primary region: P1/P2 then reuse it and only the group's metadata stays in the primary region ([`Get-DrResourceGroupLocationBlocker`](../../infra/dr/DrPrerequisites.psm1)). Without it `resourceGroup:location_is_...` stops Bootstrap |
| `secondary.vnetName` | `vnet-ccof-standby` | A name | New standby VNet name, created in the shared group. Your naming standard |
| `secondary.apimNsgName` | `nsg-ccof-standby-apim` | A name | New NSG for the standby APIM subnet |
| `secondary.addressSpace` | `10.80.0.0/22` | CIDR; no overlap with the primary or anything peered | Ask the network team. `/22` is the example's size. Overlap is `secondary.addressSpace:overlaps_primary_...` |
| `secondary.subnets.apim.name` / `.prefix` | `snet-apim` / `10.80.0.0/27` | Name; CIDR inside `addressSpace`, at most `/27` (prefix number 27 or smaller) | APIM v2 integration subnet (delegated to `Microsoft.Web/serverFarms`). `too_small` if narrower than /27 |
| `secondary.subnets.functions.name` / `.prefix` | `snet-functions` / `10.80.0.32/27` | Same rules, at most `/27` | Function Apps integration subnet (delegated to `Microsoft.App/environments`) |
| `secondary.subnets.privateEndpoints.name` / `.prefix` | `snet-private-endpoints` / `10.80.1.0/26` | Same rules, at most `/28` | Region B's private endpoints (the Stage 6 template creates three, per [`tests/Test-DrStandby.ps1`](../../tests/Test-DrStandby.ps1)); leave room |
| `dnsZones.subscriptionId` | `22222222-2222-4222-8222-222222222222` | GUID | Who **owns** the private DNS zones: often a platform subscription different from `subscriptionId` |
| `dnsZones.resourceGroup` | `rg-ccof-network` | A name | Resource group of those zones: `az network private-dns zone list --subscription <id> --query "[].{n:name,rg:resourceGroup}"` |
| `dnsZones.zoneNames` | the five names in section 5.3 | Only these six: `privatelink.services.ai.azure.com`, `.cognitiveservices.azure.com`, `.openai.azure.com`, `.documents.azure.com`, `.blob.core.windows.net`, `.azurewebsites.net` | The zones to link to the standby VNet. **For region B list all five of `documents`, `blob`, `services.ai`, `cognitiveservices` and `openai`**: `Invoke-DrStandby.ps1` points region B's private endpoints at these exact zone names in `dnsZones`. `azurewebsites` is allowed by P0-P2 but is not referenced by the region B driver |
| `identityNames` | `["id-ccof-sync-b", "id-ccof-reconciler-b"]` | Names; one must contain `sync`, one `reconciler` | Two new user-assigned identities for region B's sync and reconciler apps. The `Shells` phase picks them by those words (`identity_missing` otherwise) and refuses an app that does not run as them (`standby_identity_mismatch`) |
| `foundryAccounts[].subscriptionId` / `.resourceGroup` / `.name` | `2222...` / `rg-ccof-foundry` / `foundry-ccof-prod` | GUID / name / name | Each Foundry account in the primary's `backends`. P0 only checks it has a Claude deployment; region B does not create Foundry resources. Read: `az cognitiveservices account list` |
| `entra.gatewayAppId` | `33333333-3333-4333-8333-333333333333` | GUID | Application (client) ID of the gateway app registration: the primary's `.staged-state/state.json` Stage 4 outputs or `az ad app list --display-name <entra.gatewayAppDisplayName>` |
| `entra.resolverAppId` | `44444444-4444-4444-8444-444444444444` | GUID | Same for the resolver app. Single-tenant (`AzureADMyOrg`) with `api://<appId>` identifier URI, else a blocker |
| `entra.adminAppId` | `55555555-5555-4555-8555-555555555555` | GUID | Admin app. Needs scope `Projects.Manage`, roles `CCOF.Projects.Read` and `.Write`, and Azure CLI preauthorized |
| `standby.stagedConfigPath` | `primary/staged.config.json` | File path (relative paths start at the folder of `dr.config.json`) | The primary's staged configuration, **copied to clouddrive** (section 4, block 4). Missing file: `Not found: ...` |
| `standby.stagedStateDirectory` | `primary/.staged-state` | Folder with `state.json` | The primary's staged state, copied to clouddrive. Read only |
| `standby.stateDirectory` | `standby-state` | Folder path; created if missing | Region B's own state, generated config and evidence. **Keep it on clouddrive**; it is how a resumed session knows what is done. Never point it at the primary's state folder |
| `standby.nameSuffix` | `b` | 1-2 lowercase letters or digits | Region B names are the primary stem plus `-b`. One letter is safest: a storage account name has 24 characters and the stem plus suffix plus a 3-letter app code must fit (`standby_storage_name_too_long`). Cannot be changed after `Shells` |
| `standby.functionsPublicNetworkAccess` | `Disabled` | `Enabled` / `Disabled` | `Disabled` matches the staged default and keeps the apps private. See the publishing note in section 7 before choosing |
| `standby.storagePublicNetworkAccess` | `Disabled` | `Enabled` / `Disabled` | Same, for the apps' storage accounts |
| `standby.apim.sku` | `StandardV2` | `StandardV2` / `PremiumV2` | Region B's gateway tier. Use the primary's tier unless you decided otherwise (`az apim list` above); it is not copied automatically. Check region availability |
| `standby.apim.units` | `1` | Integer; default 1 | Capacity units; match the primary's `sku.capacity`. Not range-checked by the driver |
| `standby.apim.publisherEmail` | `platform-team@example.com` | Non-empty, not `REPLACE-` | APIM publisher contact (receives service notices). Use the primary's value from `az apim list` or a shared mailbox |
| `standby.apim.publisherName` | `Contoso Platform Team` | Non-empty, not `REPLACE-` | Publisher organisation name; same source |
| `cosmos.convertServerless` | `false` | `true` / `false` | **Consent for an irreversible change.** Needed only when the account is serverless (section 6). `false` makes `Data -Apply` stop with `cosmos_serverless` and change nothing |
| `cosmos.autoscaleMaxThroughput` | `1000` | Integer, multiple of 1000, at least 1000 (default 1000) | Autoscale maximum RU/s **per container**, applied in every region. See section 6 for how to choose it |

### 5.3 Complete valid example

Synthetic values only (GUIDs are made up, names are fictional). Replace each with the value read in
5.1. This file passes
`Get-DrConfigProblems` and `Get-DrStandbyProblems` (checked before this guide was committed).

```json
{
  "tenantId": "11111111-1111-4111-8111-111111111111",
  "subscriptionId": "22222222-2222-4222-8222-222222222222",
  "tags": { "workload": "ccof", "stage": "dr-prerequisites" },
  "primary": {
    "location": "eastus2",
    "vnetId": "/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-ccof-network/providers/Microsoft.Network/virtualNetworks/vnet-ccof-primary",
    "addressSpaces": [ "10.64.0.0/16" ],
    "peer": true
  },
  "secondary": {
    "location": "centralus",
    "resourceGroup": "rg-ccof-prod",
    "allowResourceGroupInOtherRegion": true,
    "vnetName": "vnet-ccof-standby",
    "apimNsgName": "nsg-ccof-standby-apim",
    "addressSpace": "10.80.0.0/22",
    "subnets": {
      "apim": { "name": "snet-apim", "prefix": "10.80.0.0/27" },
      "functions": { "name": "snet-functions", "prefix": "10.80.0.32/27" },
      "privateEndpoints": { "name": "snet-private-endpoints", "prefix": "10.80.1.0/26" }
    }
  },
  "dnsZones": {
    "subscriptionId": "22222222-2222-4222-8222-222222222222",
    "resourceGroup": "rg-ccof-network",
    "zoneNames": [
      "privatelink.documents.azure.com",
      "privatelink.blob.core.windows.net",
      "privatelink.services.ai.azure.com",
      "privatelink.cognitiveservices.azure.com",
      "privatelink.openai.azure.com"
    ]
  },
  "identityNames": [ "id-ccof-sync-b", "id-ccof-reconciler-b" ],
  "foundryAccounts": [
    { "subscriptionId": "22222222-2222-4222-8222-222222222222", "resourceGroup": "rg-ccof-foundry", "name": "foundry-ccof-prod" }
  ],
  "entra": {
    "gatewayAppId": "33333333-3333-4333-8333-333333333333",
    "resolverAppId": "44444444-4444-4444-8444-444444444444",
    "adminAppId": "55555555-5555-4555-8555-555555555555"
  },
  "standby": {
    "stagedConfigPath": "primary/staged.config.json",
    "stagedStateDirectory": "primary/.staged-state",
    "stateDirectory": "standby-state",
    "nameSuffix": "b",
    "functionsPublicNetworkAccess": "Disabled",
    "storagePublicNetworkAccess": "Disabled",
    "apim": { "sku": "StandardV2", "units": 1, "publisherEmail": "platform-team@example.com", "publisherName": "Contoso Platform Team" }
  },
  "cosmos": {
    "convertServerless": false,
    "autoscaleMaxThroughput": 1000
  }
}
```

What changes from the repository example: `secondary.resourceGroup` and `allowResourceGroupInOtherRegion`
(the shared group, section 5.2), the `standby` paths (relative, on clouddrive), `cosmos.convertServerless`
(only after section 6), and every `REPLACE-` value. `example.com` addresses and `Contoso` are fictional.

### 5.4 Check the file offline (no Azure call)

```powershell
Select-String -Path $cfg -Pattern 'REPLACE-'
Import-Module "$repo/infra/dr/DrPrerequisites.psm1", "$repo/infra/dr/DrStandby.psm1" -Force
$c = Get-Content $cfg -Raw | ConvertFrom-Json
@(Get-DrConfigProblems $c) + @(Get-DrStandbyProblems $c)
Test-Path (Join-Path (Split-Path $cfg -Parent) $c.standby.stagedConfigPath)
```

**Expect:** no `REPLACE-` lines, no problems, and `True`. A problem is printed as `field:reason`
(for example `standby.nameSuffix:one_or_two_lowercase_letters_or_digits`); fix it and run the block again.

## 6. Decide before any `-Apply`

**Cosmos DB: serverless to provisioned is one-way.** A serverless account is single-region
([Learn](https://learn.microsoft.com/azure/cosmos-db/serverless#use-serverless-resources)), so `Data`
converts it. The conversion cannot be undone ([Learn: change capacity mode](https://learn.microsoft.com/azure/cosmos-db/how-to-change-capacity-mode)):

- Every container becomes manual throughput of **number of partitions x 5,000 RU/s**; no management
  operation is possible on the account until it finishes, and there is no SLA on its duration.
- The driver then moves each container to autoscale with `cosmos.autoscaleMaxThroughput` as the maximum
  ([autoscale](https://learn.microsoft.com/azure/cosmos-db/provision-throughput-autoscale)). Autoscale
  bills between 10% and 100% of the maximum, and throughput is billed **in each region**, so each added
  region bills its own throughput. Pick the cap from the busiest container's real peak; if
  Azure refuses a container's change as below its minimum, raise the cap and run `Data -Apply` again.
- If your primary was already deployed with provisioned throughput, nothing is converted; the driver
  only sets autoscale, adds the region and enables service-managed failover. In that case keep
  `cosmos.convertServerless` `false`.
- Write consent into the file only when you have decided: set `cosmos.convertServerless` to `true`.

Do the read-only look first (it is also the `Data` preview):

```powershell
Invoke-DrPhase -Phase Data
```

**Expect:** `Cosmos <account>: capacity Serverless|Provisioned; regions ...; steps: ...`, then `preview: then each container autoscale with maximum N RU/s. Rerun with -Apply.` Steps can be `convert_to_provisioned`,
`add_secondary_region`, `enable_service_managed_failover`, `wait_capacity_change` or `none`.

**Log Analytics workspace failover is separate.** Workspace replication is enabled in
[DR-CLOUD-SHELL.md Step 5](DR-CLOUD-SHELL.md#step-5-replicate-the-log-analytics-workspace), not by this
driver. Microsoft says to wait at least **24 hours** after enabling it before a switchover and recommends
**one week** ([Learn](https://learn.microsoft.com/azure/azure-monitor/logs/workspace-replication)).
Region B logs to the primary's workspace.

## 7. Run P0-P2, then region B, one command at a time

Always preview, read the output, then apply the same command. Run only one command at a time and wait
for it to finish before the next.

### 7.1 P0-P2 (standby network and identities)

```powershell
. "$HOME/clouddrive/ccof-dr/session.ps1"
Use-DrSession
pwsh -NoProfile -File infra/dr/Invoke-DrPrerequisites.ps1 -Phase Discover  -ConfigPath $cfg -EvidenceDirectory $evidence
pwsh -NoProfile -File infra/dr/Invoke-DrPrerequisites.ps1 -Phase Bootstrap -ConfigPath $cfg -EvidenceDirectory $evidence
```

**Expect:** `Discover passed.` and a `what-if: Create` list ending in `Bootstrap passed.` What-if
`Modify` or `Delete` of anything the template does not own stops the run. Details and failures:
[DR-CLOUD-SHELL.md Steps 3-4](DR-CLOUD-SHELL.md#step-3-discover-p0-read-only). With the shared group,
`resourceGroup:location_is_...` is absent because `allowResourceGroupInOtherRegion` is `true`. Then:

```powershell
pwsh -NoProfile -File infra/dr/Invoke-DrPrerequisites.ps1 -Phase Bootstrap -ConfigPath $cfg -EvidenceDirectory $evidence -Apply
pwsh -NoProfile -File infra/dr/Invoke-DrPrerequisites.ps1 -Phase Verify    -ConfigPath $cfg -EvidenceDirectory $evidence
```

**Expect:** `Bootstrap passed.` then `Verify passed.` (VNet, subnets, delegations, peering `Connected`,
DNS links `Succeeded`, identities). Do not continue on `BLOCKERS`.

### 7.2 Region B phases

| Phase | What it changes with `-Apply` | State recorded (`standby.state.json`) |
| --- | --- | --- |
| `Data` | Cosmos: convert to provisioned (only with consent), containers to autoscale, add region B, enable service-managed failover | account, capacity mode, regions, write region, autoscale cap, containers |
| `Shells` | [`standby.bicep`](../../infra/dr/standby.bicep): four Function Apps and APIM in region B, logging to the primary workspace, sync and reconciler on the P1 identities | APIM ID and name, app names |
| `Grants` | The primary's Stage 3 template for region B (Cosmos data roles, workspace roles) with salted assignment names | number of Cosmos assignments |
| `Config` | The primary's Stage 5: app settings with **both writers off**, resolver authentication, APIM API and policy for resolver B; adds region B's admin redirect URIs to the admin app registration | gateway URL, admin host, timers |
| `Network` | The primary's Stage 6: private endpoints in the standby subnet, Function App and APIM outbound VNet integration | endpoints, APIM network state |
| `Code` | `npx tsc` then publishes the same packages as region A (`config-zip`); no seed, no snapshot | code hashes, commit |
| `Verify` | Nothing (read-only): functions listed, both writers disabled, APIM API present | `standby.verify.json` evidence |

The driver is documented in its [header](../../infra/dr/Invoke-DrStandby.ps1). Run in this order:

```powershell
. "$HOME/clouddrive/ccof-dr/session.ps1"
Use-DrSession
Invoke-DrPhase -Phase Data                # preview (done in section 6)
Invoke-DrPhase -Phase Data -Apply         # one-way step lives here when convertServerless is true
Invoke-DrPhase -Phase Shells
Invoke-DrPhase -Phase Shells -Apply
Invoke-DrPhase -Phase Grants
Invoke-DrPhase -Phase Grants -Apply
Invoke-DrPhase -Phase Config
Invoke-DrPhase -Phase Config -Apply
Invoke-DrPhase -Phase Network
Invoke-DrPhase -Phase Network -Apply
Invoke-DrPhase -Phase Code
Invoke-DrPhase -Phase Code -Apply
Invoke-DrPhase -Phase Verify
```

Do not paste the whole block at once: run one line, wait for `exit code 0`, read the output, then
run the next. A sign of success for an apply is `phase <Name> completed and verified; state ...` in green
and `exit code 0`. Exit codes: 2 refused configuration or missing input, 3 `phase_order`, 4
`cosmos_serverless`, 5 `cosmos_capacity_change_running`; other failures throw.

Notes per phase:

- **Data -Apply** takes the longest: the capacity change has no SLA, and adding a region copies the
  data (the driver says "typically tens of minutes"). It polls for up to 2 hours. Expect Cloud Shell
  to time out during it; see section 8. Keep the tab active and do not start another phase meanwhile.
- **Shells -Apply** deploys a Bicep template. A failed apply records no state; the same command
  is the retry.
- **Config -Apply** edits the admin app registration, so the account needs that right (section 3 row 4).
- **Code -Apply** uses the same publishing path as Stage 7
  ([Stage 7](STAGED-DEPLOYMENT-V2.md#stage-7-code-and-initial-data)). With
  `functionsPublicNetworkAccess` `Disabled`, whether Cloud Shell, which is not inside your VNet by
  default, can publish to a private Function App depends on your network. **This has not been exercised
  for region B.** If the publish is refused for network reasons, stop and decide with your network team
  between running `Code` from a machine that can reach the apps, or temporarily setting
  `functionsPublicNetworkAccess` to `Enabled` and re-running `Shells` (a change to a public-ingress
  setting needs your own security approval; this guide does not recommend it).
- `Code` needs the same commit as region A. Check `git log -1` against the commit in the primary's state.

## 8. Resume after the 20-minute timeout

A phase is safe to run again: it reads the current Azure state and skips what is already in place
(header of [`Invoke-DrStandby.ps1`](../../infra/dr/Invoke-DrStandby.ps1)). The procedure is the same for
every phase:

1. Open Cloud Shell and select **PowerShell**. Confirm `Test-Path "$HOME/clouddrive"` is `True`.
2. `. "$HOME/clouddrive/ccof-dr/session.ps1"` then `Use-DrSession` (restores variables and subscription).
   If `$repo` is gone, repeat section 4 block 3.
3. Read what the interrupted phase left (commands below). Do **not** assume it failed or finished.
4. Run the same phase **without** `-Apply` and read the plan.
5. Run it **with** `-Apply`. The last green line `phase <Name> completed and verified` is the proof.

| Phase interrupted | Read the real state | If still running | If finished or partly done |
| --- | --- | --- | --- |
| `Data` | `az cosmosdb show --subscription $sub -g $rg -n <account> --query "{state:provisioningState, mode:capacityMode, regions:locations[].locationName, failover:enableAutomaticFailover}" -o json` (the account name is in the `Data` preview) | `state` not `Succeeded`, or a capacity transition running: wait, then rerun. The driver stops with `wait_capacity_change` / `cosmos_capacity_change_running` and changes nothing | Rerun: it lists the remaining steps (`add_secondary_region`, `enable_service_managed_failover`, autoscale per container) and does only those |
| `Shells` | `az deployment group list --subscription $sub -g $rg --query "[?contains(name,'dr-standby-shells')].{name:name, state:properties.provisioningState}" -o table` | `Running`: wait | `Succeeded` but no `Shells` entry in `standby-state/standby.state.json`: rerun (it redeploys the same template and records the state). `Failed`: read the deployment operations, fix, rerun |
| `Grants` | Portal: resource group > **Settings > Deployments**, the newest Stage 3 deployment for region B | `Running`: wait | Rerun: the template is idempotent and uses salted assignment names for region B |
| `Config` | `az functionapp config appsettings list --subscription $sub -g $rg -n REPLACE-region-b-sync-app --query "[?name=='AzureWebJobs.syncEntitlement.Disabled'].value" -o tsv` must print `true` | Wait | Rerun; the admin redirect URIs are added only when missing |
| `Network` | `az network private-endpoint list --subscription $sub -g $rg --query "[?ends_with(name,'-b')].{n:name, s:provisioningState}" -o table` (suffix as configured) | Wait | Rerun |
| `Code` | Run `Invoke-DrPhase -Phase Verify`: it lists the functions of each region B app (read-only) | A zip deployment may still be starting: wait a few minutes | Rerun `Code -Apply`: it rebuilds and publishes the packages again |

What lives where after a timeout: state in `standby-state/` (clouddrive) survives; the log of the
interrupted run is in `$logs` only up to the cut; the Azure operation is judged by the commands above.
If `standby.state.json` has no entry for a phase, the phase has not been recorded as complete, whatever Azure
shows. Do not edit `standby.state.json` by hand and do not delete `standby-state/` while a phase is
mid-way: it is region B's only record (the generated `standby.staged.config.json` is rewritten on every run).
Never run two commands against the same `standby-state` at once.

## 9. Post-checks

```powershell
Invoke-DrPhase -Phase Verify
(Get-Content "$base/standby-state/standby.state.json" -Raw | ConvertFrom-Json -AsHashtable).phases.Keys
az cosmosdb show --subscription $sub -g $rg -n REPLACE-cosmos-account --query "{mode:capacityMode, failover:enableAutomaticFailover, regions:locations[].{r:locationName,p:failoverPriority}}" -o json
```

**Expect:** `Verify` prints a JSON with each app's function names, `writersOff` both `true`, and the
APIM API path; the state file lists `Data`, `Shells`, `Grants`, `Config`, `Network`, `Code`, `Verify`;
Cosmos shows two regions, the primary at priority 0 and `failover` `true`. In the Portal, region B's
Function Apps show the timer functions disabled and APIM B shows the API.

Remaining responsibilities after a green `Verify`:

- Send one test call through APIM B on a private path and compare it with region A. Section 11.2
  shows what the lab saw and how to read the gateway log.
- Keep both writers off until a failover. Nothing automatic promotes them; section 11.3 is the
  promotion procedure and section 11.6 the failback.
- Do not claim production DR until the open items in section 11.7 are closed. The continuity gate
  (`RECONCILER_CONTINUITY_GATE`) stays on for any promotion; never weaken it.

## 10. When a phase refuses or fails

| Message | Meaning | What to do |
| --- | --- | --- |
| `Configuration refused: field:reason` | A field is missing or invalid (section 5.2) | Fix it; section 5.4 prints the same list offline |
| `Not found: ... (standby.stagedConfigPath / standby.stagedStateDirectory ...)` | The primary's files are not where the paths say | Section 4 block 4; relative paths start at the folder of `dr.config.json` |
| `standby_resource_group: region B must use the primary's resource group` | `secondary.resourceGroup` differs | Set it to the primary's group and `allowResourceGroupInOtherRegion` to `true` |
| `primary_names_unexpected` | The primary's apps are not named `...-resolver` with storage `...res` | The driver cannot derive region B names: stop and ask the repository owners |
| `standby_storage_name_too_long` | Stem + suffix + app code exceeds 24 characters | A one-letter `standby.nameSuffix` (before `Shells`) |
| `identity_missing` / `standby_identity_mismatch` | `identityNames` lacks a `sync` or `reconciler` name, or the identity was not created by P1/P2 | Fix `identityNames`; rerun P1/P2 Bootstrap; both identities must exist in the shared group |
| `standby_gateway_id_missing` / `_invalid` | The two APIM resource IDs are not both known | Run `Shells -Apply` first, then continue |
| `cosmos_serverless` (exit 4) | The account is serverless and consent is `false` | Section 6; set `cosmos.convertServerless` to `true` only on purpose |
| `cosmos_capacity_change_running` (exit 5) | The conversion is still running after 2 hours | Wait; check the account state; rerun |
| `Cosmos still needs: ...` | A step finished but the account is not yet `Succeeded` | Wait; rerun `Data -Apply` |
| `phase_order: run -Phase X -Apply first.` (exit 3) | A phase it depends on is not recorded | Run it with `-Apply` |
| `state_target_mismatch` | A state folder belongs to another tenant, subscription or group | Use the right folders; each deployment has its own |
| `...:read_denied` / `AuthorizationFailed` | Missing permission (section 3 row 4) | Grant the scope named in the error, rerun |

No undo script exists for region B. The `Data` phase cannot be reversed for a converted account. Remove
the other resources one by one in the Portal or with `az` only after reviewing what depends on them.

## 11. Live drill record, 2026-10-25/26

The lab ran region A in East US 2, region B in Central US, and a Central US Foundry account as the
fallback pool member. This record contains no real resource names or IDs. No screenshot of the drill
was kept; the evidence is Log Analytics query output, summarised here. Times are UTC unless marked IST.
Code: branch `feat/dr-standby`, commits `cab64da`, `24a6686` and `d5e0108` for the gate changes.

| Step | Result | Section |
| --- | --- | --- |
| Traffic moved to region B | Yes | 11.2 |
| Region B promoted (gate `on`, single writer) | Yes, after a one-time baseline adoption | 11.3 |
| Workspace switchover | Yes; the ledger lost pre-replication history while switched over | 11.4, 11.5 |
| Failback of workspace, Cosmos DB, writers and Front Door to region A | Yes | 11.6 |
| Production-qualified | **No**: DR-15, DR-16, DR-17 open | 11.7 |
### 11.1 Front Door baseline

Front Door Premium with private-link origins to both APIM gateways and both admin apps was deployed
(`786352e`). Public network access on both gateways and both admin apps reads back `Disabled`. Through
the Front Door hostname, the gateway status route and the admin console route both returned **HTTP 200**.
Right after the first deployment both routes returned the generic Front Door 404 for the first two
tries and 200 on the third: wait for global propagation and retry before concluding a route is broken.
The origin group's `deploymentStatus` stayed `NotStarted`; the lab treated the live 200s and the approved
private-link connections as the proof, not that field.

### 11.2 Traffic to region B

The reversible fault (`Invoke-DrFrontDoor.ps1 -Phase DrainPrimary`) sets an invalid origin host header
on region A's origins, so Front Door health probes fail and traffic moves to region B. In the lab the
first two requests still reached region A, then region B served.

**The 2026-10-25 HTTP 504s came from the drill itself.** To simulate a primary model outage, the drill
also pointed region B's pool member 0 at an unreachable address. Before that change member 0 served
6 of 6 calls; after it, every 504 went to that address, and the breaker sent the rest to the Central US
fallback. The fault was removed on 2026-10-26 (UNKNOWNS DR-13). Read a gateway's behaviour with this
query, setting the window and the region B APIM resource ID:
```kusto
let windowStart = datetime(2026-10-25T19:20:00Z);
let windowEnd = datetime(2026-10-25T19:50:00Z);
ApiManagementGatewayLogs
| where TimeGenerated between (windowStart .. windowEnd)
| where _ResourceId =~ '<region-B APIM resource ID>'
| summarize requests=count()
    by ResponseCode, BackendId, BackendResponseCode, LastErrorSource, LastErrorReason
```

For Azure CLI, add `--timespan P30D`; otherwise a historical window is excluded.

Results on 2026-10-26 with region B promoted (11.3):

| Test | Result |
| --- | --- |
| 50 calls in 45 s | 19 × 200; 29 × 429 `RateLimitReached` from the Central US fallback (DR-16); 2 × 502 from member 0 (DR-15) |
| 20 calls, one every 4-7 s | 16 × 200 from the fallback; 4 × 502 from member 0 |

Each 502 is member 0 (the East US 2 Foundry endpoint, reached from region B over global VNet peering)
closing the connection after about 19 s. The breaker then routes to the fallback for 2 minutes and
re-probes member 0. The same endpoint served 45 of 45 calls from region A after failback, so the fault
is in region B's cross-region path (DR-15).

### 11.3 Promote region B

Run only when region A's writers are off and Cosmos DB writes in region B's region. Before 2026-10-26
the gate refused here for three reasons, each fixed and tested on `feat/dr-standby`
([ADR 0036 amendment](../adr/0036-continuity-coverage-baseline.md#amendment-2026-10-26-one-time-baseline-adoption)):

| Run-line `reason` | Cause | Fix |
| --- | --- | --- |
| `ledger_continuity_gap` / `early_history_missing` | Old rule: no ledger record near the month start | Rule replaced by request/usage correlation (`25b77e7`) |
| `ledger_coverage_baseline_missing` | Budget states written with the gate off have no coverage marker | One-time `RECONCILER_LEDGER_BASELINE_ADOPT` (`cab64da`) |
| `ledger_attribution_missing` | Timed-out calls carry no attribution trace | Failed calls with no token count no longer refuse (`d5e0108`) |

Settings on region B's reconciler (`REPLACE-region-b-reconciler-app`). The coverage start is the time
APIM gateway diagnostics were enabled, read from the resource group's activity log; the lab value is shown:

```powershell
$app = 'REPLACE-region-b-reconciler-app'
az functionapp config appsettings set --subscription $sub -g $rg -n $app -o none --settings `
  RECONCILER_CONTINUITY_GATE=on `
  RECONCILER_LEDGER_COVERAGE_START_AT=2026-10-20T15:41:34.000Z `
  RECONCILER_LEDGER_BASELINE_ADOPT=2026-10-20T15:41:34.000Z
az functionapp config appsettings set --subscription $sub -g $rg -n $app -o none --settings 'AzureWebJobs.reconcileBudgets.Disabled=false'
```

App Service stores the timestamp as `2026-10-20T15:41:34Z`; the reconciler accepts both forms
(`24a6686`). Set `RECONCILER_LEDGER_BASELINE_ADOPT` only with evidence that no model API existed on
the gateway before the coverage start (UNKNOWNS DR-14 shows how the lab established it).

Check the run lines (the reconciler runs every 2 minutes; wait 5 minutes):

```kusto
AppTraces
| where TimeGenerated > ago(15m)
| where Message has 'ccof.reconciler.run.v1'
| extend j = parse_json(Message)
| project TimeGenerated, outcome = tostring(j.outcome), reason = tostring(j.reason),
    gate = tostring(j.continuityGate), adopted = tostring(j.continuityBaselineAdopted),
    failedUnattributed = tostring(j.unattributedFailedRequests)
```

**Expect:** `written` with `gate` `passed`. The first written run shows `adopted` greater than 0; later
runs show 0. Then remove the adoption setting:

```powershell
az functionapp config appsettings delete --subscription $sub -g $rg -n $app --setting-names RECONCILER_LEDGER_BASELINE_ADOPT -o none
```

Lab result: first gated write 06:46:02Z, 4 states adopted, 36 token-less failed calls reported, gated
writes every 2 minutes after that. A single `ledger_continuity_gap` / `backend_call_without_llm`
refusal can occur when a gateway row is ingested before its usage row; the next run passes.

### 11.4 Workspace switchover

Allowed 24 hours after replication was enabled, and only then
([workspace replication](https://learn.microsoft.com/azure/azure-monitor/logs/workspace-replication)).
The call needs a JSON content type and an empty JSON body. Without `--body`, the service answers
HTTP 415; in the lab `az rest` then waited 55 minutes without starting anything.

```powershell
$ws = 'REPLACE-workspace-name'
$url = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.OperationalInsights/locations/REPLACE-standby-region/workspaces/$ws/failover?api-version=2025-02-01"
az rest --method post --url $url --headers 'Content-Type=application/json' --body '{}'
az rest --method get --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.OperationalInsights/workspaces/${ws}?api-version=2025-02-01" --query properties.failover
```

**Expect:** `"state": "Active"`. Lab result: the operation ran 08:07:16-08:07:20Z, and 6 of 6 calls
sent afterwards appeared in `ApiManagementGatewayLlmLog` within 136 s.

### 11.5 What the switchover did to the ledger

The secondary workspace holds only data ingested after replication was enabled (2026-10-25T07:09Z in
the lab). After the switchover the earliest ledger row was 2026-10-25T07:23Z instead of 2026-10-20.
Region B's gate then refused `spend_would_decrease` on every run: it would not lower recorded spend
from an incomplete month. Budget state therefore stopped refreshing until failback. A switchover in a
month in which replication was enabled late leaves the ledger incomplete for that month (UNKNOWNS DR-17).

### 11.6 Failback to region A

Order keeps one writer at a time:

| # | Action | Lab result |
| --- | --- | --- |
| 1 | Workspace failback: `POST .../workspaces/<name>/failback?api-version=2025-02-01`, same headers and body as 11.4 | 08:16:47Z; history from 2026-10-20 queryable again |
| 2 | Region B writers off: `AzureWebJobs.reconcileBudgets.Disabled=true` (and `syncEntitlement` if it was promoted) | Read back `true` |
| 3 | Cosmos DB write region back: `az cosmosdb failover-priority-change --subscription $sub -g $rg -n REPLACE-cosmos-account --failover-policies "East US 2=0" "Central US=1"` | 74 s; write region East US 2 |
| 4 | Region A reconciler: same `RECONCILER_CONTINUITY_GATE` and `RECONCILER_LEDGER_COVERAGE_START_AT` as 11.3 (no adoption), then enable `reconcileBudgets` and `syncEntitlement` | Gated writes from 08:22:44Z, 0 adopted (markers matched) |
| 5 | `pwsh infra/dr/Invoke-DrFrontDoor.ps1 -Phase RestorePrimary -ConfigPath $cfg -Apply` | Deployed 08:25Z |
| 6 | Wait for Front Door to mark region A healthy (command below) | 0 % until about 08:50Z, 100 % at 09:13Z |
| 7 | Send test calls through Front Door and check the gateway log | 47 × 200 of 50; 45 logged on region A; 3 × 503 from Front Door during the change |

The restore took about 45 minutes to reach every Front Door edge, the drain about 15. Waiting does not
need an open shell: after a Cloud Shell timeout, restore the session (section 8) and run the check again.

```powershell
$fdProfileId = 'REPLACE-front-door-profile-resource-id'
az monitor metrics list --resource $fdProfileId --metric OriginHealthPercentage --interval PT5M --offset 30m `
  --aggregation Average --filter "Origin eq '*'" -o table
```

**Expect:** the region A gateway and admin origins at 100.

### 11.7 Open items

- **DR-15**: region B's calls to the East US 2 Foundry endpoint are reset after about 19 s. Each breaker
  re-probe returns one 502 to a caller every 2 minutes while region B serves.
- **DR-16**: the lab fallback deployment is sized from leftover quota and returns 429 under a burst.
  Size the fallback for the failed-over load.
- **DR-17**: a workspace switchover in a month in which replication started late leaves the ledger
  incomplete; the reconciler then cannot write until failback.
- Region B's admin package could not be republished after Front Door made the admin app private
  (HTTP 403 from the deployment endpoint). The admin code was unchanged since its last deployment.
