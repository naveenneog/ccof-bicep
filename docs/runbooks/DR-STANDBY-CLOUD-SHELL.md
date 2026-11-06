# Build the DR standby region (region B) in Azure Cloud Shell

**For:** an operator who finished the single-region deployment ([Deploy CCOF step by step](DEPLOY-STEP-BY-STEP.md))
and wants to build the second-region ("region B") copy of the CCOF services with the staged DR driver.
**Time:** depends on approvals, network preparation, and Azure operations.
**Result after sections 1-10, if all checks pass:** a fenced region B, with shared Cosmos DB, private
Function Apps and published code. These steps do not add region B to Front Door or promote a writer.
The network team must separately provide the Function Apps' inbound private endpoints and DNS.

> **STOP: all Front Door operations are excluded from this standby-only release.** Do not run
> `Deploy`, `Approve`, `Verify`, `Lockdown`, `DrainPrimary`, or `RestorePrimary` for Front Door,
> including the historical examples below. Front Door readiness, ownership and recovery fixes
> require a later independently reviewed release. Promotion and failback also require separate
> authorization; this release approves neither.
>
> **Offline checks are not a live-connectivity claim.** The existing-network, manual-Entra and
> private publisher path has not been exercised end to end in a lab or validated against a customer
> network. The older drill in sections 11 and 12.3 is historical, not evidence for this path.
> DR-15, DR-16 and DR-17 remain open in [UNKNOWNS](../UNKNOWNS.md).

Historical state of the earlier lab work on **2026-10-26**:

| Part | State | Source |
| --- | --- | --- |
| P0-P2: standby network, DNS links, identity shells | Implemented; proven live in two lab environments by 2026-10-23 | [DR-CLOUD-SHELL.md](DR-CLOUD-SHELL.md), [ROADMAP](../ROADMAP.md) (DR-06) |
| Region B driver, phases `Data`, `Shells`, `Grants`, `Config`, `Network`, `Code`, `Verify` | Run live in the lab on 2026-10-25; `Code` re-run on 2026-10-26. Offline tests in `tests/Test-DrStandby.ps1` | [`infra/dr/Invoke-DrStandby.ps1`](../../infra/dr/Invoke-DrStandby.ps1), section 11 |
| Front Door Premium with private origins | Deployed; failover to region B and failback to region A both observed | Sections 11.1, 11.2, 11.6 |
| Region B promotion under the continuity gate | Done: region B wrote budget states with the gate `on` after a one-time baseline adoption | Section 11.3, [ADR 0036 amendment](../adr/0036-continuity-coverage-baseline.md#amendment-2026-10-26-one-time-baseline-adoption) |
| Workspace switchover and failback | Done; while switched over, the ledger lacked history from before replication began and the gate refused (DR-17) | Sections 11.4, 11.5 |
| Scripted promotion and failback (`Invoke-DrFailover.ps1`) | Implemented 2026-10-26 with offline tests (`tests/Test-DrFailover.ps1`); **not yet run against Azure** | Section 12 |
| Live lab state after the drill | Front Door serves region A; Cosmos writes in East US 2; region A writers on with the gate `on`; region B writers fenced; workspace back in East US 2 | Section 11.6 |
The historical drill does not qualify the current build for production. The standby Foundry fallback
is a different mechanism (backends and project pools in
[DR-CLOUD-SHELL.md Step 6](DR-CLOUD-SHELL.md#step-6-per-project-backend-failover-admin-console-33)); it is
not part of a region B app deployment. The design is in [DR design](../DR-ACTIVE-PASSIVE.md); the
contracts are [ADR 0033](../adr/0033-dr-active-passive.md) and [ADR 0034](../adr/0034-dr-project-routing-and-prerequisites.md).

The driver's own error text points to `docs/runbooks/DR-STANDBY.md`; that file does not exist, and this
guide is its replacement.

## 1. How the pieces fit

```text
dr.config.json  (one file, in Cloud Shell clouddrive)
   |-- tenantId, secondary, dnsZones   -> Invoke-DrPrerequisites.ps1   Discover, Bootstrap, Verify
   |-- identities, optional entra     -> (existing-network checks; only missing identities are created)
   |-- standby, cosmos                 -> Invoke-DrStandby.ps1         Data, Shells, Grants, Config, Network, Code, Verify
   |-- standby.stagedConfigPath/...    -> READS the primary's staged.config.json and .staged-state (never writes them)
                                          WRITES region B state to standby.stateDirectory
```

Facts from the code ([`Invoke-DrStandby.ps1`](../../infra/dr/Invoke-DrStandby.ps1),
[`DrStandby.psm1`](../../infra/dr/DrStandby.psm1)):

- One phase runs per command. Changes require `-Apply`; `Verify` reads Azure and records local evidence
  even without `-Apply`. A preview can also write local parameter or evidence files.
- Region B shares region A's resource group, Cosmos account and Log Analytics workspace. The driver
  refuses to run when `secondary.resourceGroup` differs from the primary's resource group
  (`standby_resource_group`). With `secondary.networkMode: "existing"`, the VNet may be in a
  **different resource group** in the same subscription, identified by `secondary.existingVnetId`.
- Existing-network Bootstrap reads the network and deploys only missing identities; it does not
  deploy the VNet, subnets, NSG, DNS links or peerings. Existing identities are checked and reused.
  Later network changes require separate approval (section 7).
- Region B's names are the primary stem plus `-<nameSuffix>` (for example `...-resolver` becomes
  `...-resolver-b`); storage names add the suffix before the 3-letter app code.
- Both writers (`syncEntitlement`, `reconcileBudgets`) are created disabled and timers off. `Verify`
  fails when either is not disabled. Promotion is a separate guarded operation (section 12).
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
| 3 | Cosmos DB capacity and costs reviewed; **separate explicit approval** before a serverless-to-provisioned conversion | Section 6 |
| 4 | Resource-admin permissions: Contributor on the workload group plus scoped role-assignment rights for `Grants`; read access to both VNets, configured DNS zones and Foundry accounts; the Stage 3, 5 and 6 rights, and approved subnet/DNS write and join permissions for `Network`. The private publisher also needs to read each app connection, endpoint and NIC and publish to the apps | [Stage notes](STAGED-DEPLOYMENT-V2.md#stage-notes), [`Invoke-DrPrerequisites.ps1`](../../infra/dr/Invoke-DrPrerequisites.ps1), [`Invoke-DrStandby.ps1`](../../infra/dr/Invoke-DrStandby.ps1) |
| 5 | For **manual Entra**, omit the DR config's entire `entra` section and verify that the primary Stage 4 output records `verification: manual`. `Discover` and `Config` then make no Graph call as the resource admin. The Entra team completes the one batch in section 7.3; runtime managed identities may still need separately approved read-only Graph permissions | [Manual Stage 4](DEPLOY-STEP-BY-STEP.md#step-4-register-the-apps-and-groups-in-entra-id), [`Staged.Application.ps1`](../../infra/staged/Staged.Application.ps1) |
| 6 | Network-team approval for Stage 6 changes and separately for app-specific `sites` endpoints and DNS; security approval for initially public APIM. Keep all standby Function Apps private | Section 7; [ADR 0034](../adr/0034-dr-project-routing-and-prerequisites.md#amendment-existing-standby-network) |
| 7 | A checkout containing the current existing-network and readiness guards, plus PowerShell 7, Azure CLI, Node.js and npm on the relevant hosts | Use the reviewed branch or commit your team supplies; section 4 checks the files. The private publisher needs the same approved checkout and dependencies |

## 4. Set up Cloud Shell

Open Cloud Shell (Portal top bar > **Cloud Shell** > **PowerShell**), then run the blocks in order.

**Block 1: durable folders and the session file.** Run once. The session file restores your
variables after every timeout; later sessions need only block 2.

```powershell
$base = "$HOME/clouddrive/ccof-dr"
if (-not (Test-Path "$HOME/clouddrive")) { throw 'No clouddrive: this is an ephemeral session. Mount storage first (section 2).' }
New-Item -ItemType Directory -Force -Path "$base/primary", "$base/standby-state", "$base/evidence", "$base/logs" | Out-Null
@'
$base     = if ($env:CCOF_DR_BASE) { $env:CCOF_DR_BASE } else { "$HOME/clouddrive/ccof-dr" }
$cfg      = Join-Path $base 'dr.config.json'
$evidence = Join-Path $base 'evidence'
$logs     = Join-Path $base 'logs'
$repo     = if ($env:CCOF_DR_REPO) { $env:CCOF_DR_REPO } else { "$HOME/ccof-bicep" }
function Use-DrSession {
    if (-not (Test-Path $cfg)) { throw "No $cfg yet: finish section 5." }
    $c = Get-Content $cfg -Raw | ConvertFrom-Json
    az account set --subscription $c.subscriptionId
    if ($LASTEXITCODE -ne 0) { throw 'Could not select the configured subscription.' }
    az account show --query "{tenant:tenantId, subscription:id, user:user.name}" -o table
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected account.' }
    Set-Location $repo
}
function Invoke-DrPhase {
    param(
        [Parameter(Mandatory)] [ValidateSet('Data','Shells','Grants','Config','Network','Code','Verify')] [string]$Phase,
        [switch]$Apply, [switch]$ApprovePublicApimBootstrap, [switch]$ApprovePublicFunctionAccess,
        [switch]$ApprovePrivateNetworkChanges, [switch]$ApproveCosmosThroughputReduction, [switch]$PrivatePublisher
    )
    $a = @()
    if ($Apply) { $a += '-Apply' }
    if ($ApprovePublicApimBootstrap) { $a += '-ApprovePublicApimBootstrap' }
    if ($ApprovePublicFunctionAccess) { $a += '-ApprovePublicFunctionAccess' }
    if ($ApprovePrivateNetworkChanges) { $a += '-ApprovePrivateNetworkChanges' }
    if ($ApproveCosmosThroughputReduction) { $a += '-ApproveCosmosThroughputReduction' }
    if ($PrivatePublisher) { $a += '-PrivatePublisher' }
    $log = Join-Path $logs "standby-$Phase-$(Get-Date -Format yyyyMMddTHHmmss)-$(if ($Apply) {'apply'} else {'preview'}).log"
    $driver = [IO.Path]::Combine($repo, 'infra', 'dr', 'Invoke-DrStandby.ps1')
    pwsh -NoProfile -File $driver -Phase $Phase -ConfigPath $cfg @a 2>&1 | Tee-Object -FilePath $log
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Phase $Phase failed with exit code $code (log: $log)." }
    "exit code 0 (log: $log)"
}
'@ | Set-Content -Path "$base/session.ps1"
```

If you already created `session.ps1` with an older runbook, rerun block 1 to update the wrapper,
then reload it with block 2. This replaces the session file, not the configuration or state.

**Block 2: every new or resumed session.**

```powershell
. "$HOME/clouddrive/ccof-dr/session.ps1"
```

**Block 3: the code.** `$repo` is outside `clouddrive` on purpose: building `node_modules` on an SMB share is
slow. Replace `REPLACE-branch-or-commit` with the reviewed branch or commit that contains the current
DR fixes. Record the commit and use the same approved code on the private publisher.

```powershell
if (-not (Test-Path $repo)) { git clone https://github.com/naveenneog/ccof-bicep.git $repo }
Set-Location $repo
git fetch --all --prune
git checkout REPLACE-branch-or-commit
git log -1 --oneline
Test-Path infra/dr/Invoke-DrStandby.ps1
Test-Path infra/dr/DrCosmosThroughput.psm1
Test-Path infra/dr/dr-existing-identities.bicep
Test-Path infra/dr/Invoke-DrFrontDoor.ps1
az bicep install
npm ci --ignore-scripts --include=dev
```

**Expect:** the commit line, four `True` values, and `npm ci` without errors. These file checks do not
prove that a checkout has the new guards: inspect the reviewed commit before proceeding.

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
`standby` section, and `Select-String` in section 5.4 finds any left. The repository example defaults
to **create** mode: for this existing-network procedure set `secondary.networkMode` and
`secondary.existingVnetId` explicitly and remove the entire `entra` section. Do not apply the copied
example unchanged.

### 5.1 Read the values (read-only commands)

```powershell
$sub = 'REPLACE-subscription-id'
$rg  = 'REPLACE-ccof-resource-group'
$standbyVnetId = 'REPLACE-existing-standby-vnet-resource-id'
$p   = Get-Content "$base/primary/staged.config.json" -Raw | ConvertFrom-Json
$pState = Get-Content "$base/primary/.staged-state/state.json" -Raw | ConvertFrom-Json -AsHashtable
if ($pState.stages['4'].outputs.verification -cne 'manual') { throw 'Manual DR requires a primary Stage 4 record with verification: manual.' }
$p.tenantId; $p.subscriptionId; $p.resourceGroup; $p.location; $p.tags | ConvertTo-Json -Compress
$p.stage1.apimSku; $p.stage1.apimUnits; $p.stage1.includeAdmin; $p.cosmos.databaseName
$p.network.existing.functionsSubnetId
az group show --subscription $sub -n $rg --query "{location:location, tags:tags}" -o json
az cosmosdb list --subscription $sub -g $rg --query "[].{name:name, capacity:capacityMode, regions:locations[].locationName}" -o json
az apim list --subscription $sub -g $rg --query "[].{name:name, sku:sku.name, units:sku.capacity, email:publisherEmail, publisher:publisherName}" -o json
az identity list --subscription $sub -g $rg --query "[].name" -o tsv
az network vnet show --ids ($p.network.existing.functionsSubnetId -split '/subnets/')[0] --query "{id:id, spaces:addressSpace.addressPrefixes}" -o json
az network vnet show --ids $standbyVnetId --query "{id:id, location:location, spaces:addressSpace.addressPrefixes, subnets:subnets[].{name:name, prefix:addressPrefix, delegations:delegations[].serviceName}}" -o json
az network private-dns zone list --subscription $sub --query "[?starts_with(name,'privatelink.')].{name:name, rg:resourceGroup}" -o table
az cognitiveservices account list --subscription $sub --query "[?kind=='AIServices'].{name:name, rg:resourceGroup}" -o table
```

If your primary has no `network.existing` (it was built in `create` mode), read `network.create` and the
VNet it created instead of the primary `az network vnet show` command above. Ask the network team to
confirm the existing standby VNet ID, subnet prefixes, delegations, DNS links and any requested
peering. For the manual path, use the primary Stage 4 record and the Entra team's confirmation rather
than `az ad` commands. The Cosmos account name and APIM list also exist in the Stage 1 state. Treat
state and collected IDs as confidential and share them only through an approved handoff.

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
| `primary.vnetId` | `/subscriptions/2222.../resourceGroups/rg-ccof-network/providers/Microsoft.Network/virtualNetworks/vnet-ccof-primary` | A VNet resource ID, or omit | The primary VNet ID, needed for its overlap check and requested peering checks. Region B needs an approved path to the primary's Foundry private endpoints; the network team must verify it ([`DrStandby.psm1`](../../infra/dr/DrStandby.psm1)) |
| `primary.addressSpaces` | `["10.64.0.0/16"]` | CIDRs | Every address prefix of that VNet (`az network vnet show --ids <id> --query addressSpace.addressPrefixes`) **and** of every network peered with it, which the tool cannot see. Used only for the overlap check |
| `primary.peer` | `true` | `true` / `false` | In existing mode, `true` **checks**, but does not create, connected peering in both directions. `false` skips that peering check; the network team must verify any alternative path |
| `secondary.location` | `centralus` | Region; not equal to `primary.location` | The standby region. Check services per region (section 3 row 2). Workspace replication has its own pairing rules ([Learn](https://learn.microsoft.com/azure/azure-monitor/logs/workspace-replication#supported-regions)) |
| `secondary.resourceGroup` | `rg-ccof-prod` | A name | **Must be the primary's resource group** for the region B driver (`standby_resource_group`). Same value as the primary's `resourceGroup` |
| `secondary.allowResourceGroupInOtherRegion` | `true` | `true` / `false` | `true` when the existing group is in the primary region: P1/P2 then reuse it and only the group's metadata stays in the primary region ([`Get-DrResourceGroupLocationBlocker`](../../infra/dr/DrPrerequisites.psm1)). Without it `resourceGroup:location_is_...` stops Bootstrap |
| `secondary.networkMode` | `existing` | `existing` / `create` | Set `existing` for this procedure. An omitted value defaults to `create`, which can deploy an authoritative subnet list |
| `secondary.existingVnetId` | `/subscriptions/2222.../resourceGroups/rg-ccof-network/providers/Microsoft.Network/virtualNetworks/vnet-ccof-standby` | Full VNet resource ID | Existing VNet may be in a different resource group from the workload, but must be in `subscriptionId`; its name must match `secondary.vnetName` |
| `secondary.vnetName` | `vnet-ccof-standby` | A name | Name of the existing VNet, not a request to create it |
| `secondary.apimNsgName` | omitted | Optional in existing mode | The existing APIM subnet must have an NSG; the check does not create or change it |
| `secondary.addressSpace` | `10.80.0.0/22` | CIDR; no overlap with the primary or anything peered | Ask the network team. `/22` is the example's size. Overlap is `secondary.addressSpace:overlaps_primary_...` |
| `secondary.subnets.apim.name` / `.prefix` | `snet-apim` / `10.80.0.0/27` | Name; CIDR inside `addressSpace`, at most `/27` (prefix number 27 or smaller) | The supported Standard v2 standby requires `Microsoft.Web/serverFarms` delegation ([integration requirements](https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound)). `too_small` if narrower than /27. Premium v2 has a different delegation and is not supported by this standby template (DR-BYO-17) |
| `secondary.subnets.functions.name` / `.prefix` | `snet-functions` / `10.80.0.32/27` | Same rules, at most `/27` | Function Apps integration subnet (delegated to `Microsoft.App/environments`) |
| `secondary.subnets.privateEndpoints.name` / `.prefix` | `snet-private-endpoints` / `10.80.1.0/26` | Same rules, at most `/28` | Existing, non-delegated endpoint subnet. Allow capacity for Stage 6 endpoints and the four separately approved app-specific endpoints |
| `dnsZones.subscriptionId` | `22222222-2222-4222-8222-222222222222` | GUID | Who **owns** the private DNS zones: often a platform subscription different from `subscriptionId` |
| `dnsZones.resourceGroup` | `rg-ccof-network` | A name | Resource group of those zones: `az network private-dns zone list --subscription <id> --query "[].{n:name,rg:resourceGroup}"` |
| `dnsZones.zoneNames` | the six names in section 5.3 | Only `privatelink.services.ai.azure.com`, `.cognitiveservices.azure.com`, `.openai.azure.com`, `.documents.azure.com`, `.blob.core.windows.net`, `.azurewebsites.net` | The example includes the five service zones and the App Service zone. Existing-mode checks require a **Succeeded direct VNet link for every listed zone**. The network team supplies App Service app and SCM DNS records; Stage 6 does not create them. A hub-only DNS design may work but this check refuses it |
| `identityNames` | `["id-ccof-sync-b", "id-ccof-reconciler-b"]` | Names; one must contain `sync`, one `reconciler` | Two named user-assigned identities for region B's sync and reconciler apps. Bootstrap checks and reuses matching existing identities or creates the missing ones. `Shells` checks that the apps use them |
| `foundryAccounts[].subscriptionId` / `.resourceGroup` / `.name` | `2222...` / `rg-ccof-foundry` / `foundry-ccof-prod` | GUID / name / name | Each Foundry account in the primary's `backends`. P0 only checks it has a Claude deployment; region B does not create Foundry resources. Read: `az cognitiveservices account list` |
| `entra` | omitted | Optional object | Omit for manual DR. If supplied, `Discover` attempts Graph reads. The primary Stage 4 manual record supplies the application IDs for `Config`; the Entra admin verifies the settings and redirects |
| `standby.stagedConfigPath` | `primary/staged.config.json` | File path (relative paths start at the folder of `dr.config.json`) | The primary's staged configuration, **copied to clouddrive** (section 4, block 4). Missing file: `Not found: ...` |
| `standby.stagedStateDirectory` | `primary/.staged-state` | Folder with `state.json` | The primary's staged state, copied to clouddrive. Read only |
| `standby.stateDirectory` | `standby-state` | Folder path; created if missing | Region B's own state, generated config and evidence. **Keep it on clouddrive**; it is how a resumed session knows what is done. Never point it at the primary's state folder |
| `standby.nameSuffix` | `b` | 1-2 lowercase letters or digits | Region B names are the primary stem plus `-b`. One letter is safest: a storage account name has 24 characters and the stem plus suffix plus a 3-letter app code must fit (`standby_storage_name_too_long`). Cannot be changed after `Shells` |
| `standby.functionsPublicNetworkAccess` | `Disabled` | `Enabled` / `Disabled` | Keep `Disabled` for this existing-network scenario; use the approved private publisher in section 7 |
| `standby.storagePublicNetworkAccess` | `Disabled` | `Enabled` / `Disabled` | Same, for the apps' storage accounts |
| `standby.apim.sku` | `StandardV2` | `StandardV2` | Region B's gateway tier. The standby template does not accept `PremiumV2`; the driver refuses it before deployment. Check regional availability and the approved capacity and cost |
| `standby.apim.units` | `1` | Integer; default 1 | Capacity units; match the primary's `sku.capacity`. Not range-checked by the driver |
| `standby.apim.zoneRedundant` | `false` | `true` / `false`; default `false` | Creates Region B's APIM as zone redundant. Chosen only when the instance is created; cannot be changed later. With fewer than two `standby.apim.units` the driver prints a warning; Microsoft recommends at least two units ([enable availability zones](https://learn.microsoft.com/azure/api-management/enable-availability-zone-support), [reliability in API Management](https://learn.microsoft.com/azure/reliability/reliability-api-management)). The Shells phase reads it back; not yet deployed live ([UNKNOWNS](../UNKNOWNS.md) APIM-ZR-01, APIM-ZR-02) |
| `standby.apim.publisherEmail` | `platform-team@example.com` | Non-empty, not `REPLACE-` | APIM publisher contact (receives service notices). Use the primary's value from `az apim list` or a shared mailbox |
| `standby.apim.publisherName` | `Contoso Platform Team` | Non-empty, not `REPLACE-` | Publisher organisation name; same source |
| `cosmos.convertServerless` | `false` | `true` / `false` | **Separate explicit approval for an irreversible conversion.** Needed only when the account is serverless (section 6). `false` makes `Data -Apply` stop with `cosmos_serverless` before conversion |
| `cosmos.autoscaleMaxThroughput` | `1000` | Integer, multiple of 1000, at least 1000 (default 1000) | Target autoscale maximum RU/s for the database's shared throughput offer, if present, and for each dedicated container offer. Shared containers do not get separate throughput. Applies in every region; see section 6 |
| `failover.ledgerCoverageStartAt` | `2026-11-01T12:34:56.789Z` (fictional format example, not for use) | UTC with exactly three fractional digits and `Z` (`Test-DrCanonicalCoverage` in [`DrFailover.psm1`](../../infra/dr/DrFailover.psm1)); required by `Invoke-DrFailover.ps1 -Phase Promote` and `Failback` only | The independently verified start of complete gateway and LLM diagnostic coverage, before model traffic on both gateways (section 11.3, [ADR 0036](../adr/0036-continuity-coverage-baseline.md)). Corroborate both enabled categories and continuity with retained diagnostic and traffic evidence. An Activity Log write alone does not establish coverage. The driver writes the verified value to `RECONCILER_LEDGER_COVERAGE_START_AT` |

### 5.3 Complete valid example

Synthetic values only (GUIDs are made up, names are fictional). Replace each with the independently
confirmed value. The sample ledger timestamp is fictional and must not be used as evidence.
This example selects the manual-Entra and existing-network path; it does not prove the network or
permissions exist.

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
    "networkMode": "existing",
    "existingVnetId": "/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-ccof-network/providers/Microsoft.Network/virtualNetworks/vnet-ccof-standby",
    "vnetName": "vnet-ccof-standby",
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
      "privatelink.openai.azure.com",
      "privatelink.azurewebsites.net"
    ]
  },
  "identityNames": [ "id-ccof-sync-b", "id-ccof-reconciler-b" ],
  "foundryAccounts": [
    { "subscriptionId": "22222222-2222-4222-8222-222222222222", "resourceGroup": "rg-ccof-foundry", "name": "foundry-ccof-prod" }
  ],
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
  },
  "failover": {
    "ledgerCoverageStartAt": "2026-11-01T12:34:56.789Z"
  },
  "frontDoor": {
    "stem": "ccofexamplefd",
    "wafMode": "Detection",
    "probeIntervalSeconds": 30
  }
}
```

The workload and network resource groups are intentionally different. The Front Door stem is a
fictional example, not a reservation; confirm the actual existing or globally unique value.
`cosmos.convertServerless` stays `false` until separately approved. Relative `standby` paths are
resolved from the directory containing the DR config.

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

**Cosmos costs and throughput require explicit review.** Adding a region affects the whole account,
including any databases not managed by this driver, and throughput is billed in each region. Review
all offers, capacity and regional costs with the owner. Autoscale can bill between 10% and 100% of
its maximum, depending on usage ([Learn](https://learn.microsoft.com/azure/cosmos-db/provision-throughput-autoscale)).
Prevent concurrent account, database and container changes while reviewing and applying this plan;
the preview checks for drift but does not lock Azure resources.

Run the read-only Data preview:

```powershell
Invoke-DrPhase -Phase Data
```

**Expect:** the account capacity, regions and steps. For a provisioned account, the preview lists the
database offer and every container as shared or dedicated, with each current and proposed throughput
value. A database's shared offer and dedicated container offers can coexist; a shared container is
never converted to a dedicated container and no data is moved
([Learn](https://learn.microsoft.com/azure/cosmos-db/set-throughput)). Only the configured primary
database is inventoried: assess any other databases separately before approving the region change.

The target `cosmos.autoscaleMaxThroughput` applies to the shared database offer, if any, and to each
dedicated offer. A lower autoscale maximum requires explicit approval. Every manual-to-autoscale
migration also requires it: Azure chooses the initial maximum, and guaranteed throughput may
temporarily fall even when the final target is higher. After reviewing and approving the exact plan,
use `-ApproveCosmosThroughputReduction` with `-Apply` only if the preview requests it. Azure may
choose an initial migration maximum above the target; the driver then stops for a fresh preview
instead of lowering it silently. Storage or previous settings can raise the minimum permitted maximum;
if Azure refuses a lower target, review the value and cost, change the configuration and preview again
([autoscale FAQ](https://learn.microsoft.com/azure/cosmos-db/autoscale-faq)).

**Serverless conversion is a separate, irreversible decision.** A serverless account is single-region
([Learn](https://learn.microsoft.com/azure/cosmos-db/serverless#use-serverless-resources)); changing
it to provisioned cannot be undone
([Learn](https://learn.microsoft.com/azure/cosmos-db/how-to-change-capacity-mode)). Each container
initially becomes manual throughput of **number of partitions x 5,000 RU/s**; no management operation
is possible until conversion finishes, and there is no SLA on duration. Keep `cosmos.convertServerless`
`false` unless the owner separately approves the conversion and costs. Conversion Apply intentionally
stops with `cosmos_conversion_repreview_required` (exit 6) when finished. Inspect the new offers and
run a fresh Data preview before separately approving any throughput or region changes. Networking or
public APIM approval is not Cosmos approval.

Steps can be `convert_to_provisioned`, `add_secondary_region`, `enable_service_managed_failover`,
`wait_capacity_change` or `none`. The preview records a local digest; an Apply that would change
throughput or regions requires the same current plan. If a read fails, output is ambiguous, or the
account changes, stop and investigate rather than assuming a `NotFound` means shared throughput.

**Log Analytics workspace failover is separate.** Workspace replication is enabled in
[DR-CLOUD-SHELL.md Step 5](DR-CLOUD-SHELL.md#step-5-replicate-the-log-analytics-workspace), not by this
driver. Microsoft says to wait at least **24 hours** after enabling it before a switchover and recommends
**one week** ([Learn](https://learn.microsoft.com/azure/azure-monitor/logs/workspace-replication)).
Region B logs to the primary's workspace.

## 7. Run P0-P2, then region B, one command at a time

Always preview, read the output, then apply the same command. Run only one command at a time and wait
for it to finish before the next.

### 7.1 P0-P2 (read the existing network; create missing identities)

```powershell
. "$HOME/clouddrive/ccof-dr/session.ps1"
Use-DrSession
pwsh -NoProfile -File infra/dr/Invoke-DrPrerequisites.ps1 -Phase Discover  -ConfigPath $cfg -EvidenceDirectory $evidence
if ($LASTEXITCODE -ne 0) { throw 'Discover failed; stop and inspect the evidence.' }
pwsh -NoProfile -File infra/dr/Invoke-DrPrerequisites.ps1 -Phase Bootstrap -ConfigPath $cfg -EvidenceDirectory $evidence
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap preview failed; stop and inspect the evidence.' }
```

**Expect:** `Discover passed.` and `Bootstrap passed.` In existing mode, both read the selected VNet,
subnet prefixes and delegations, APIM subnet NSG, direct DNS links and, when requested, two-way
connected peering. Bootstrap checks identity IDs, locations, principal IDs and client IDs; its
what-if lists only missing identities. If none are missing, it skips the deployment. Any blocker,
read denial or unexpected what-if change means **stop**; the network team resolves missing
prerequisites. A working hub-only DNS arrangement is not accepted by these direct-link checks.

After review, apply the identities-only template and run the read-only verification:

```powershell
pwsh -NoProfile -File infra/dr/Invoke-DrPrerequisites.ps1 -Phase Bootstrap -ConfigPath $cfg -EvidenceDirectory $evidence -Apply
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap apply failed; stop and inspect the evidence.' }
pwsh -NoProfile -File infra/dr/Invoke-DrPrerequisites.ps1 -Phase Verify    -ConfigPath $cfg -EvidenceDirectory $evidence
if ($LASTEXITCODE -ne 0) { throw 'Prerequisite verification failed; stop and inspect the evidence.' }
```

**Expect:** `Bootstrap passed.` then `Verify passed.` No VNet, subnet, NSG, peering or DNS-link
deployment occurs in this mode. Do not continue on `BLOCKERS`. Do not switch to create mode to
bypass a failure: create mode can update an authoritative subnet list and stops on an existing VNet
unless separately approved with `-ApproveExistingVnetUpdate`
([driver](../../infra/dr/Invoke-DrPrerequisites.ps1)).

### 7.2 Region B phases

| Phase | What it changes with `-Apply` | State recorded (`standby.state.json`) |
| --- | --- | --- |
| `Data` | Cosmos: convert only with separate explicit approval; after preview and applicable reduction approval, set database/dedicated autoscale, add region B, enable service-managed failover | account, capacity mode, regions, write region, autoscale cap, database/container throughput |
| `Shells` | Four private Function Apps and an initially **public** APIM; apply requires `-ApprovePublicApimBootstrap` | APIM ID and name, app names |
| `Grants` | The primary's Stage 3 template for region B (Cosmos data roles, workspace roles) with salted assignment names | number of Cosmos assignments |
| `Config` | Stage 5 settings with **both writers off**, resolver authentication and APIM policy. With primary Stage 4 manual, prints admin redirects instead of editing Entra; no resource-admin Graph call | gateway URL, admin host, timers |
| `Network` | Stage 6 creates storage and Cosmos private endpoints and DNS zone groups/records, and attaches Functions and APIM to subnets for outbound integration. Apply requires `-ApprovePrivateNetworkChanges` | endpoints, APIM network state |
| `Code` | Builds and publishes resolver, sync, reconciler and admin packages with `-PrivatePublisher`; no seed or snapshot | code hashes, commit |
| `Verify` | Azure read-only: lists functions, checks both writers off and the APIM API. It writes local evidence and a phase record even without `-Apply` | `standby.verify.json` and `Verify` record |

Obtain each approval before its apply. Run these commands in order, one at a time; the wrapper
forwards the switches to [`Invoke-DrStandby.ps1`](../../infra/dr/Invoke-DrStandby.ps1):

```powershell
. "$HOME/clouddrive/ccof-dr/session.ps1"
Use-DrSession
Invoke-DrPhase -Phase Data                # preview (done in section 6)
Invoke-DrPhase -Phase Data -Apply         # only after review and approvals; see the alternative below
# If the preview requires reduction approval, use this INSTEAD after the owner explicitly approves:
# Invoke-DrPhase -Phase Data -Apply -ApproveCosmosThroughputReduction
Invoke-DrPhase -Phase Shells
Invoke-DrPhase -Phase Shells -Apply -ApprovePublicApimBootstrap
Invoke-DrPhase -Phase Grants
Invoke-DrPhase -Phase Grants -Apply
Invoke-DrPhase -Phase Config
Invoke-DrPhase -Phase Config -Apply
Invoke-DrPhase -Phase Network
Invoke-DrPhase -Phase Network -Apply -ApprovePrivateNetworkChanges
```

Wait for `exit code 0` and review each result before continuing. A successful apply also prints
`phase <Name> completed and verified; state ...`. Exit codes include 2 for refused configuration or
approval, 3 for a phase or readiness guard, 4 for
`cosmos_serverless`, 5 `cosmos_capacity_change_running`, and 6
`cosmos_conversion_repreview_required`; other failures throw.

Before an apply, the driver clears that phase's prior completion record and dependent readiness
records. A Verify attempt clears the prior Verify record even though it does not change Azure.
The driver also clears any saved Front Door verification. Failed or interrupted work therefore
requires the missing phases and Front Door verification to be completed again. Previews leave
these records unchanged; a local record does not establish that Azure changes finished.

`Data -Apply` can run for hours; a timeout or failure does not establish whether Azure finished.
Before resuming, inspect the account, locations and all database/container offers read-only, wait for
pending operations, and review a fresh Data preview. Earlier throughput or region changes may already
have succeeded; never blindly rerun Apply. `Shells` creates
APIM with public network access `Enabled`; the switch records the operator's approval, not approval
to expose the Function Apps. The template would re-enable APIM public access on redeployment, so
Shells **refuses** an existing APIM whose access is `Disabled`, unreadable or unknown, even with
the approval switch. Do not reopen it; restore valid saved state or escalate (section 8).
For a separately approved `functionsPublicNetworkAccess: "Enabled"` configuration, apply also
requires `-ApprovePublicFunctionAccess`. The operator needs resource-group read access to inventory
all `Microsoft.Web/sites`; Shells refuses to reopen an existing site whose public access is
disabled, unknown or unreadable. Run the reviewed deployment with one operator and no concurrent
changes to these resources.

### 7.3 One manual Entra batch

After `Shells` and `Config`, collect the following from the saved state without calling Graph. The
`Config` log also prints the two regional admin SPA redirects. Treat this output as confidential:

```powershell
$b = Get-Content "$base/standby-state/state.json" -Raw | ConvertFrom-Json -AsHashtable
$s = Get-Content "$base/standby-state/standby.state.json" -Raw | ConvertFrom-Json -AsHashtable
$adminHost = [string]$s.phases['Config'].outputs.adminHost
if (-not $adminHost) { throw 'No standby admin host recorded; inspect Config before the handoff.' }
[pscustomobject]@{
    ResolverAppId = $b.stages['4'].outputs.registrations.resolverApi.appId
    AdminAppId = $b.stages['4'].outputs.admin.appId
    ApimResourceId = $b.stages['1'].outputs.apimId
    ApimPrincipalId = $b.stages['1'].outputs.apimPrincipalId
    ApimClientId = $b.stages['5'].outputs.apimIdentityAppId
    SyncPrincipalId = $b.stages['1'].outputs.principals.sync
    SyncClientId = $b.stages['1'].outputs.clientIds.sync
    AdminPrincipalId = $b.stages['1'].outputs.principals.admin
}
"https://$adminHost/api/console"
"https://$adminHost/api/console-v3"
```

Send **one** approved handoff to the Entra team and wait for its confirmation before declaring
standby ready:

- Confirm the shared gateway, resolver and admin registrations, enterprise applications, scopes,
  user/group assignments and approved clients. Confirm that resolver enterprise-app policy permits
  region B's APIM identity, including an assignment if the tenant requires one. Preserve existing
  restrictions and assignments.
- Add the two printed regional admin SPA redirects, preserving existing redirects. If clients will
  use the Front Door admin hostname, include its approved `/api/console` and `/api/console-v3`
  redirects in the same batch if the hostname is independently known. **Do not deploy Front Door**
  to obtain it during this standby-only release. If a full profile already exists, treat B as
  potentially live.
- Confirm each saved B principal against its current ARM resource before requesting a grant.
  For application-permission sync, the two baseline read-only roles are the **sync** identity's
  `GroupMember.Read.All` and `User.Read.All`. `Application.Read.All` is an additional tenant-wide
  option only when `SYNC_MEMBER_TYPES` includes `servicePrincipal` and the owner explicitly
  approves reading disabled service-principal state; otherwise agree a safe leaver process.
  Review disabled-member backlogs and removal limits before enabling this behavior.
- Review actual B feature settings with the app owner. If group search is enabled and approved
  (`ADMIN_GRAPH_ENABLED=true`), the **admin Function App managed identity** needs
  `GroupMember.Read.All`; if V3 user labels are enabled and approved, it needs `User.Read.All`.
  The admin and sync identities are distinct. These roles are tenant-wide and are not granted
  automatically. A/B feature and permission parity is unknown until independently compared.
  The Entra administrator uses the tenant's approved process; the resource admin needs no Graph
  token. See [sync disabled-member policy](../SYNC.md#deleted-and-disabled-members-p-9),
  [admin V2](../ADMIN-V2.md#optional-settings-and-least-scoped-permission-handoff), and
  [admin V3](../ADMIN-V3.md#permissions).

`Config` completing in manual mode prints the handoff and records the admin hostname; it does **not**
prove the Entra team made the changes. Runtime managed identities may still call Graph after their
approved grants.

### 7.4 Private endpoints and code publication

Stage 6 does **not** create inbound `sites` private endpoints for the four Function Apps. After
separate network-team approval, have the team provide an approved, app-specific `sites` endpoint
for **each** resolver, sync, reconciler and admin app in the configured private-endpoint subnet.
Provide `privatelink.azurewebsites.net` DNS for both each app hostname and its SCM hostname; confirm
that APIM B resolves and reaches the resolver privately. DNS zone groups, records, subnet
attachments and any other network changes need explicit approval. See
[`stage6-network.bicep`](../../infra/staged/stage6-network.bicep) and
[App Service private endpoint DNS](https://learn.microsoft.com/azure/app-service/overview-private-endpoint#dns).

Use an approved publisher **inside the network**, with PowerShell 7, Azure CLI, Node.js, npm, the
same reviewed checkout and an authorized Azure profile. Cloud Shell is not assumed to be inside the
VNet. Transfer the complete confidential `$base` folder, including `session.ps1`, the primary copy,
DR config and standby state, to the private runner by an approved secure method. Do not run phases
concurrently on the two copies. Install the same approved dependencies and select the approved code
commit, checking it against region A's recorded code. On the runner, set the paths and run:

```powershell
$env:CCOF_DR_BASE = 'REPLACE-private-runner-base-folder'
$env:CCOF_DR_REPO = 'REPLACE-private-runner-repository-folder'
$env:AZURE_CONFIG_DIR = 'REPLACE-signed-in-azure-profile-folder'
. (Join-Path $env:CCOF_DR_BASE 'session.ps1')
Use-DrSession
Invoke-DrPhase -Phase Code
Invoke-DrPhase -Phase Code -Apply -PrivatePublisher
Invoke-DrPhase -Phase Verify
```

The private-publisher preflight checks an approved `sites` connection to each exact app in the
configured subnet, reads its endpoint NIC addresses, checks that each SCM DNS answer is one of those
addresses and in the subnet, and tests TCP 443. It is not a publish or application-readiness test.
`Code` must publish **all four** packages; an admin skip is an error and does not complete the phase.
Keep Function App public access `Disabled`; do not change it to make publishing work. Return the
latest complete state and evidence to Cloud Shell securely before any subsequent phase.

The earlier [admin VM update runbook](ADMIN-UPDATE-FROM-VM.md) is a lab reference for one admin
app, not proof of this four-app path or customer connectivity; its setup creates resources and needs
separate approval. Its older statement that DR `Code` can complete with admin skipped does not apply
to this driver.

### 7.5 Readiness before Front Door

Before full Front Door deploy **or** primary drain, confirm the one Entra batch is complete, the
private endpoints and DNS are approved and working, code publication succeeded, and both writers
remain fenced. Read back `publicNetworkAccess` and confirm `Disabled` on each of the four standby
Function Apps; neither a config value nor the private-publisher preflight proves their current access
settings. From an approved client/path, test region B's authenticated gateway-to-resolver,
Cosmos and Foundry path and the admin sign-in and application functions; use logs to confirm B
served the tests. Test the approved gateway ingress, whether an explicitly approved public APIM
endpoint or a separately approved private path. Record the results and owner approval.

`Verify` and saved phase records do not prove these end-to-end checks or Entra changes. Region B is
priority 2, **not isolated**: it can receive traffic when A becomes unhealthy. **STOP:** even after
readiness is confirmed, do not use any Front Door command until a later safety release is reviewed.

## 8. Resume after the 20-minute timeout

Do not assume every phase can be rerun safely. Read the actual resource and saved state first,
especially for Shells, whose template would make APIM public.

1. Open Cloud Shell and select **PowerShell**. Confirm `Test-Path "$HOME/clouddrive"` is `True`.
2. `. "$HOME/clouddrive/ccof-dr/session.ps1"` then `Use-DrSession` (restores variables and subscription).
   If `$repo` is gone, repeat section 4 block 3.
3. Reload `$sub` and `$rg` from the configuration, then read the interrupted phase's Azure state
   (table below). Do **not** assume it failed or finished.
4. Preview again, review the plan, and apply only with the still-valid approvals and switches. A
   phase completion record is not a substitute for the private and end-to-end checks in section 7.5.

```powershell
$c = Get-Content $cfg -Raw | ConvertFrom-Json
$sub = $c.subscriptionId
$rg = $c.secondary.resourceGroup
```

| Phase interrupted | Read the real state | If still running | If finished or partly done |
| --- | --- | --- | --- |
| `Data` | `az cosmosdb show --subscription $sub -g $rg -n REPLACE-cosmos-account --query "{state:provisioningState, mode:capacityMode, regions:locations[].locationName, failover:enableAutomaticFailover}" -o json` | Wait for a running transition | Review remaining steps and conversion/cost approvals before rerunning |
| `Shells` | Inspect the deployment and the exact APIM's current public-access state | Wait for a running deployment | Rerun only if the existing APIM is confirmed `Enabled` and public bootstrap remains approved; use `-ApprovePublicApimBootstrap`. If `Disabled`, unknown or unreadable, **do not rerun**: recover the saved Shells state or escalate |
| `Grants` | Portal: resource group > **Settings > Deployments**, the newest Stage 3 deployment for region B | `Running`: wait | Rerun: the template is idempotent and uses salted assignment names for region B |
| `Config` | `az functionapp config appsettings list --subscription $sub -g $rg -n REPLACE-region-b-sync-app --query "[?name=='AzureWebJobs.syncEntitlement.Disabled'].value" -o tsv` must print `true` | Wait | In manual mode, rerunning prints the redirects; the Entra admin must confirm them separately |
| `Network` | Inspect the expected private endpoints, zone groups and integrations | Wait | Review network approval and rerun with `-ApprovePrivateNetworkChanges` |
| `Code` | Inspect deployment results and the saved `Code` record; `Verify` only lists functions | Wait for any in-progress publish | From the private runner, rerun with `-PrivatePublisher`; it republishes all packages |

What lives where after a timeout: state in `standby-state/` (clouddrive) survives; the log of the
interrupted run is in `$logs` only up to the cut; the Azure operation is judged by the commands above.
If `standby.state.json` has no entry for a phase, the phase has not been recorded as complete, whatever Azure
shows. Do not edit `standby.state.json` by hand and do not delete `standby-state/` while a phase is
mid-way: it is region B's only record (the generated `standby.staged.config.json` is rewritten on every run).
Never run two commands against the same `standby-state` at once.

The readiness helper checks saved `Data`, `Shells`, `Grants`, `Config`, `Network`, `Code` and
`Verify` records for valid, timezone-bearing timestamps and dependency order. This helper is not a
Front Door authorization gate in the currently published driver. Reapplying an earlier phase
invalidates dependent records. Rerun the affected dependent phases, with their approvals, then
`Verify`; never edit timestamps. The Shells APIM guard still applies. All Front Door operations
remain **STOP** pending the later safety release.

## 9. Post-checks

```powershell
Invoke-DrPhase -Phase Verify
$standbyRecord = Get-Content "$base/standby-state/standby.state.json" -Raw | ConvertFrom-Json -AsHashtable
$standbyRecord.phases.Keys
Import-Module "$repo/infra/dr/DrStandby.psm1" -Force
$readinessProblem = Get-DrFrontDoorReadinessProblem $standbyRecord
if ($readinessProblem) { throw $readinessProblem }
az cosmosdb show --subscription $sub -g $rg -n REPLACE-cosmos-account --query "{mode:capacityMode, failover:enableAutomaticFailover, regions:locations[].{r:locationName,p:failoverPriority}}" -o json
```

**Expect:** `Verify` prints a JSON with each app's function names, `writersOff` both `true`, and the
APIM API path; the state file lists `Data`, `Shells`, `Grants`, `Config`, `Network`, `Code`, `Verify`;
Cosmos shows two regions, the primary at priority 0 and `failover` `true`. In the Portal, region B's
Function Apps show the timer functions disabled and APIM B shows the API.

The saved-record check does not verify actual Entra settings or traffic. Remaining responsibilities:

- Complete the Entra batch and the private and authenticated end-to-end checks in sections 7.3-7.5.
- Keep both writers off until a failover. Nothing automatic promotes them; section 11.3 is the
  historical promotion record and section 12 describes the guarded procedure.
- Do not claim production DR until the open items in section 11.7 are closed. The continuity gate
  (`RECONCILER_CONTINUITY_GATE`) stays on for any promotion; never weaken it.

## 10. When a phase refuses or fails

| Message | Meaning | What to do |
| --- | --- | --- |
| `Configuration refused: field:reason` | A field is missing or invalid (section 5.2) | Fix it; section 5.4 prints the same list offline |
| `Not found: ... (standby.stagedConfigPath / standby.stagedStateDirectory ...)` | The primary's files are not where the paths say | Section 4 block 4; relative paths start at the folder of `dr.config.json` |
| `standby_resource_group: region B must use the primary's resource group` | `secondary.resourceGroup` differs | Use the primary workload group; the existing VNet may still be in another group via `secondary.existingVnetId` |
| `network_create_existing_vnet` | Create mode would update an existing VNet | Stop; select and validate the existing-network path instead of bypassing the guard |
| `public_apim_bootstrap_approval_required` | Shells would create APIM with public access | Obtain explicit security approval before using `-ApprovePublicApimBootstrap`, or stop |
| `apim_public_access_guard` | Existing APIM is disabled, unreadable, unknown or mismatched | Do not reopen it; inspect the APIM and recover valid state or escalate |
| `function_public_access_guard` | A public-Function configuration would reopen an existing disabled, unknown or mismatched site | Do not reopen it; inspect the site and recover valid state or escalate |
| `network_changes_approval_required` | Stage 6 would change endpoints, DNS and subnet integrations | Obtain network-team approval and use `-ApprovePrivateNetworkChanges` |
| `private_publisher_required` / `private_endpoint_not_verified` / `private_publisher_check_failed` | Private runner, approved app-specific endpoint, matching DNS or TCP check is missing | Keep public access disabled; resolve the private path with the network team, then use `-PrivatePublisher` |
| `primary_names_unexpected` | The primary's apps are not named `...-resolver` with storage `...res` | The driver cannot derive region B names: stop and ask the repository owners |
| `standby_storage_name_too_long` | Stem + suffix + app code exceeds 24 characters | A one-letter `standby.nameSuffix` (before `Shells`) |
| `identity_missing` / `standby_identity_mismatch` | `identityNames` lacks a `sync` or `reconciler` name, or the identity was not created by P1/P2 | Fix `identityNames`; rerun P1/P2 Bootstrap; both identities must exist in the shared group |
| `standby_gateway_id_missing` / `_invalid` | The two APIM resource IDs are not both known | Recover the correct state; rerun Shells only if its public-access guard and approval permit it |
| `cosmos_serverless` (exit 4) | The account is serverless and consent is `false` | Section 6; set `cosmos.convertServerless` to `true` only after separate explicit approval |
| `cosmos_capacity_change_running` (exit 5) | The conversion is still running after 2 hours | Wait; inspect the account read-only; once complete, preview again |
| `cosmos_conversion_repreview_required` (exit 6) | The irreversible conversion completed; no throughput or region changes followed | Inspect the offers and costs, then run a fresh Data preview and seek the necessary approvals |
| `cosmos_preview_required` / `cosmos_preview_stale` / `cosmos_account_changed` | Preview is missing, changed, or account drift was detected | Stop concurrent changes, inspect any partial results and review a fresh Data preview before an approved Apply |
| `cosmos_throughput_reduction_approval_required` | A lower maximum or a manual migration may reduce throughput | Obtain explicit owner approval for the displayed plan before using `-ApproveCosmosThroughputReduction`; otherwise stop |
| `cosmos_migration_repreview_required` / `cosmos_throughput_write_failed` / `cosmos_throughput_readback_failed` | Azure may have changed an offer; the remaining plan was not completed | Inspect all offers and account state read-only, then preview again and obtain any new approvals |
| `cosmos_throughput_scope_unknown` / `cosmos_resource_unverified` / `cosmos_throughput_read_failed` / `cosmos_throughput_invalid` | A resource or offer cannot be verified, or an unexpected read error occurred | Stop; verify the exact account, database, container, permissions and connectivity. Do not treat arbitrary 404, 403, 429 or network errors as shared throughput. For 429, wait as instructed by Azure, then preview again |
| `cosmos_throughput_pending` / `cosmos_target_below_minimum` | An offer is changing or its minimum exceeds the configured target | Wait for the operation or review a higher target and its costs, then preview again |
| `Cosmos still needs: ...` | A step finished but the account is not yet `Succeeded` | Inspect and wait, then review a fresh Data preview; do not blindly rerun Apply |
| `phase_order: run -Phase X -Apply first.` (exit 3) | A phase it depends on is not recorded | Run it with `-Apply` |
| `state_target_mismatch` | A state folder belongs to another tenant, subscription or group | Use the right folders; each deployment has its own |
| `...:read_denied` / `AuthorizationFailed` | Missing permission (section 3 row 4) | Grant the scope named in the error, rerun |

No undo script exists for region B. The `Data` phase cannot be reversed for a converted account. Remove
the other resources one by one in the Portal or with `az` only after reviewing what depends on them.

## 11. Live drill record, 2026-10-25/26

**Historical record only:** these observations and commands used earlier code and a lab network.
They are not acceptance evidence or current instructions for the existing-network path above.

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

Settings on region B's reconciler (`REPLACE-region-b-reconciler-app`). The coverage start must be
independently verified for complete gateway and LLM diagnostics before model traffic, using the
available diagnostic and traffic evidence. An Activity Log entry alone does not establish coverage.
The value in section 5.3 is a fictional format example, not a value for this command.

```powershell
$app = 'REPLACE-region-b-reconciler-app'
$coverage = 'REPLACE-verified-coverage-start-UTC'
if ($app -like 'REPLACE-*' -or $coverage -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$') {
  throw 'Set the app and independently verified coverage start before continuing.'
}
az functionapp config appsettings set --subscription $sub -g $rg -n $app -o none --settings `
  RECONCILER_CONTINUITY_GATE=on `
  "RECONCILER_LEDGER_COVERAGE_START_AT=$coverage"
if ($LASTEXITCODE -ne 0) { throw 'Reconciler settings failed; do not enable the writer.' }
```

`RECONCILER_LEDGER_BASELINE_ADOPT` is not a normal promotion step. Use it only with separate
approval and evidence meeting [ADR 0036](../adr/0036-continuity-coverage-baseline.md#amendment-2026-10-26-one-time-baseline-adoption).
The lab's evidence is recorded in UNKNOWNS DR-14; it is not evidence for another deployment.
If adoption is approved, set it to the same verified `$coverage`:

```powershell
az functionapp config appsettings set --subscription $sub -g $rg -n $app -o none --settings `
  "RECONCILER_LEDGER_BASELINE_ADOPT=$coverage"
if ($LASTEXITCODE -ne 0) { throw 'Baseline adoption setting failed; do not enable the writer.' }
```

After confirming the prerequisites above, enable the region B writer:

```powershell
az functionapp config appsettings set --subscription $sub -g $rg -n $app -o none --settings 'AzureWebJobs.reconcileBudgets.Disabled=false'
if ($LASTEXITCODE -ne 0) { throw 'Reconciler writer enablement failed.' }
```

App Service may omit zero milliseconds from the stored value; the reconciler accepts both forms
(`24a6686`).

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

**Expect:** `written` with `gate` `passed`. If the optional adoption was approved, the first written
run can show `adopted` greater than 0; later runs show 0. Remove that setting after the passing run:

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

## 12. Scripted promotion and failback

[`infra/dr/Invoke-DrFailover.ps1`](../../infra/dr/Invoke-DrFailover.ps1) runs the writer, gate and
Cosmos DB steps of 11.3 and 11.6 with guards. It reads the same `dr.config.json`, the primary's staged
state and region B's state as `Invoke-DrStandby.ps1`. Promote and Failback also need
`failover.ledgerCoverageStartAt` (section 5.2). Offline tests use fake `az`
([`tests/Test-DrFailover.ps1`](../../tests/Test-DrFailover.ps1)). Section 11 records a manual drill;
section 12.3 records an earlier scripted lab run. Neither validates the current existing-network path.

Each phase except `Status` previews without `-Apply` and changes Azure only with `-Apply`. Every app
setting change is read back before the next step (`readback_mismatch` otherwise). Every run writes
`standby.stateDirectory/evidence/failover-<phase>-<UTC time>.json`, also when it refuses.

| Phase | Changes | Refuses (error code) |
| --- | --- | --- |
| `Status` | Nothing. Reports per region `AzureWebJobs.syncEntitlement.Disabled`, `AzureWebJobs.reconcileBudgets.Disabled`, `RECONCILER_CONTINUITY_GATE`, `RECONCILER_LEDGER_COVERAGE_START_AT`, `RECONCILER_LEDGER_BASELINE_ADOPT`; the Cosmos DB write region; the workspace `properties.failover`, the time a switchover is allowed (replication start + 24 h) and the first whole billing month in the replica (warnings `workspace_replication_partial_month` before it, `workspace_replication_off` without replication; ADR 0038); a region whose settings cannot be read as `region_<A\|B>_unreadable`; the Front Door primary origin host headers (`dr-drill.invalid` means the drill fault is on) | Exit 4 with `ERROR: split_brain` when both regions have a writer enabled |
| `Fence -Region A\|B` | Both writers of that region off | - |
| `Promote` | Optional `-FenceSource`: region A writers off. Region B reconciler: gate `on`, coverage start; with `-AdoptBaseline` the adoption setting equal to the coverage start, otherwise any adoption setting is deleted. Then region B reconciler and sync on | Region A writing without `-FenceSource` (`source_writers_enabled`); Cosmos DB not writing in region B (`cosmos_write_region`, with the move command printed; Promote never moves Cosmos DB); coverage not canonical (`coverage_invalid`). Region A and Cosmos DB are checked again just before region B is enabled |
| `Failback` | Region B writers off (first). Cosmos DB to region A only with `-MoveCosmos` (`az cosmosdb failover-priority-change ... --failover-policies <A>=0 <B>=1`, then waits for `Succeeded`). Adoption deleted in both regions. Region A reconciler: gate `on`, coverage start. Then region A reconciler and sync on | Cosmos DB not in region A without `-MoveCosmos` (`cosmos_write_region`, command printed); move not finished after 20 minutes (`cosmos_move_timeout`); region B writing again before region A is enabled (`standby_writers_enabled`). Any stop after the first step leaves both regions fenced |
| `RemoveAdoption -Region A\|B` | Deletes `RECONCILER_LEDGER_BASELINE_ADOPT` from that reconciler | - |

Not changed by this driver: Front Door (`Invoke-DrFrontDoor.ps1`) and the workspace switchover and
failback, which are allowed only 24 hours after replication starts and belong to the monitoring owner.
Promote and Failback print the exact call; it writes `{}` to a body file, because without a body the
service answers HTTP 415 (11.4):

```powershell
Set-Content -Path ws-empty.json -Value '{}'; az rest --method post --headers Content-Type=application/json --body '@ws-empty.json' --url 'https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/locations/<region B>/workspaces/<name>/failover?api-version=2025-02-01'
```

Failback uses `.../providers/Microsoft.OperationalInsights/workspaces/<name>/failback?api-version=2025-02-01`
with the same headers and body. All Azure CLI arguments are refused if they contain `( ) | & < > ^ " %`
(`az_argument_unsafe`): on Windows `az.cmd` passes them through `cmd.exe` again.

Exit codes: 0 done or preview; 2 configuration or state file refused, before any Azure call; 3 a guard
refused or a step failed (message and evidence file name printed); 4 `Status` found split-brain.

### 12.1 Failover to region B

```powershell
$cfg = "$HOME/clouddrive/ccof-dr/dr.config.json"
$fo = "$repo/infra/dr/Invoke-DrFailover.ps1"
pwsh -NoProfile -File $fo -Phase Status -ConfigPath $cfg
```

1. **Traffic. STOP:** do not drain or otherwise change Front Door in this release. Complete the
   Entra, private-path and end-to-end checks in section 7.5, then await the separately reviewed
   Front Door safety release and drill authorization.
2. **Cosmos DB.** Confirm it writes in region B (`Status`), or move it after confirming the outage
   ([DR design](../DR-ACTIVE-PASSIVE.md#failover-runbook-region-a-lost) step 3). Promote prints the
   command when it refuses.
3. **Promote.** Preview, then apply. Add `-AdoptBaseline` only the first time a region writes with the gate
   `on` over budget states that have no coverage marker, and only with the evidence 11.3 describes.

   ```powershell
   pwsh -NoProfile -File $fo -Phase Promote -ConfigPath $cfg -FenceSource
   pwsh -NoProfile -File $fo -Phase Promote -ConfigPath $cfg -FenceSource -Apply
   ```

   **Expect:** lines such as `<region-B reconciler> RECONCILER_CONTINUITY_GATE=on (read back on)`, then
   both `...Disabled=false (read back false)`, the printed workspace call, `region A (...): writing=False`,
   `region B (...): writing=True` and `result: promoted`.

   `Promote` reads region A's app settings first. When region A's management API does not answer,
   it stops with exit 3 (`source_unreachable`) and changes nothing. After Azure Service Health
   confirms the region A outage, rerun with the incident ID as the reason:

   ```powershell
   pwsh -NoProfile -File $fo -Phase Promote -ConfigPath $cfg -SourceUnreachable 'Service Health <incident ID>, <time UTC>'
   pwsh -NoProfile -File $fo -Phase Promote -ConfigPath $cfg -SourceUnreachable 'Service Health <incident ID>, <time UTC>' -Apply
   ```

   **Expect:** `region A unreadable, declared unreachable: ...`, the same region B lines as above, and
   `region A was not fenced (unreadable)`. The evidence file holds `switches.sourceUnreachable` and
   `run.sourceUnreachable` (reason, read error, time). A region A that answers with a writer enabled
   is still refused (`source_writers_enabled`). Before region A comes back:
   `pwsh -NoProfile -File $fo -Phase Fence -Region A -ConfigPath $cfg -Apply`, then `-Phase Status`
   (UNKNOWNS DR-18).
4. **Check the run lines** with the 11.3 query. After one `written` run with gate `passed`, remove the
   adoption: `pwsh -NoProfile -File $fo -Phase RemoveAdoption -Region B -ConfigPath $cfg -Apply`.
5. **Workspace switchover** (optional, owner's decision): run the printed call. Read 11.5 first (DR-17).

### 12.2 Failback to region A

1. **Workspace failback**, if it was switched over: run the call that Failback prints (11.6 row 1).
2. **Failback.** Preview, then apply. Without `-MoveCosmos` it stops after fencing region B and prints the
   Cosmos DB command; region A stays fenced until you rerun.

   ```powershell
   pwsh -NoProfile -File $fo -Phase Failback -ConfigPath $cfg
   pwsh -NoProfile -File $fo -Phase Failback -ConfigPath $cfg -MoveCosmos -Apply
   ```

   **Expect:** region B `...Disabled=true` first, `Cosmos DB writes in East US 2 (region A)`, adoption
   `absent` or `deleted`, region A gate and coverage, region A `...Disabled=false`, `result: failed_back`.
3. **Front Door. STOP:** this release does not establish a safe primary-only recovery operation.
   Do not run `RestorePrimary`; await a separately reviewed Front Door safety release. In an
   incident, follow the organization's existing approved recovery process.
4. **Status** again: region A writing, region B fenced, no `split_brain`, primary host header not
   `dr-drill.invalid`.

### 12.3 Live run of the scripted phases, 2026-10-27

**Historical record:** the following results do not validate the current branch or customer network.

The lab (East US 2 region A, Central US region B, one resource group) ran the phases with the code at
`main` fc53154. Front Door was not drained, so model traffic stayed on region A's APIM throughout; the
run tested the writer handover, not traffic failover (11.2 tests that).

| Step (UTC) | Command | Result |
|---|---|---|
| 18:12 | `-Phase Status` | Region A writing, region B fenced; `warning: workspace_replication_partial_month`, full months from 2026-11-01 (replication enabled 2026-10-25) |
| 18:15 | `Promote` without `-FenceSource`; with `-SourceUnreachable` while region A answers; with a 4-character reason; with `-FenceSource` while Cosmos DB writes in region A | Refused: `source_writers_enabled`, `source_writers_enabled`, `source_unreachable_reason`, `cosmos_write_region` with the move command. Nothing changed |
| 18:19-18:21 | `-Phase Fence -Region A -Apply` | `result: fenced`, 130 s |
| 18:21-18:22 | The printed `az cosmosdb failover-priority-change ... centralus=0 eastus2=1` | 67 s |
| 18:23-18:25 | `-Phase Promote -Apply` | `result: promoted`, 129 s. Region A reconciler's last run 18:20; region B reconciler `written`, gate `passed` from 18:25 |
| 18:31-18:35 | `-Phase Failback -MoveCosmos -Apply` | `result: failed_back`, 219 s, Cosmos DB back in East US 2 |
| 18:35-18:38 | Region A reconciler | `written`, gate `passed` |
| 18:40 | Region A reconciler | `refused`, `ledger_attribution_missing`: four test calls that the client abandoned after 90 s (APIM `ResponseCode` 0, no backend response, no tokens). Fixed in the ledger on 2026-10-27 ([ADR 0036 amendment](../adr/0036-continuity-coverage-baseline.md#amendment-2026-10-27-client-disconnect-before-a-backend-response)) |

Model calls through Front Door during the run: 15 of 22 returned 200 (14 within about 2 s, one after 79 s); three returned 503
`temporary_upstream_failure` ("An unexpected error occurred while getting deployment headers") from
Foundry, and four were abandoned by the client after 90 s. The failures were on region A's APIM and
its East US 2 Foundry member, before and after the handover. They match DR-15 and DR-16 in kind; the
lab's Foundry deployment capacity is 10.

After the run: the reconciler package with the ledger fix was published to both reconcilers at 19:22;
region A's runs from 19:24 were `written` with gate `passed` (55 unattributed requests, all failed without
tokens). The admin console update after Lockdown ([admin updates from a VM](ADMIN-UPDATE-FROM-VM.md))
published commit bcb8151 to region A's locked-down admin app in 225 s.