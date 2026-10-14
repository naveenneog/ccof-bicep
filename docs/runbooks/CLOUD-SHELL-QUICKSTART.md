# Cloud Shell quick-start runbook (existing network)

Deploy the gateway core with `infra/quickstart/Deploy-Quickstart.ps1` from **Azure Cloud Shell →
PowerShell**, into a VNet, subnets and private DNS zones that already exist. Every step is a block
you copy and paste as-is. Steps marked **read-only** change nothing in Azure.

How to use it:

1. Paste **block 0.1** once, after replacing the `<...>` values. Every later block uses those
   variables, so paste nothing else by hand.
2. Run the blocks in order. Each one ends with an **Expect** line; stop if you see something else.
3. Cloud Shell drops variables when it times out. After a reconnect, paste **block 0.1** again.

Reference: [QUICKSTART.md](../QUICKSTART.md) (form fields),
[QUICKSTART-PREREQUISITES.md](../QUICKSTART-PREREQUISITES.md) (Entra apps and groups),
[NETWORK.md](../NETWORK.md), [SYNC.md](../SYNC.md), [ONBOARDING.md](../ONBOARDING.md).

| Step | What | Changes Azure? |
|---|---|---|
| 0 | Variables, subscription, source code | No |
| 1 | Discover IDs (network, APIM, Foundry, apps, groups) | No (read-only) |
| 2 | Fill the private form | No |
| 3 | Validate the form and preview | No |
| 4 | Deploy | **Yes** |
| 5 | Load group members (delegated snapshot) | **Yes** (registry data) |
| 6 | Client file and checks | No |
| D | Diagnostics when something fails | No |

> Do not rerun `infra/prereqs/network.bicep` or any network-creation script against an existing
> VNet: it can remove subnets that were added later.

---

## 0. Setup

### 0.1 Variables (edit, then paste; re-paste after every Cloud Shell reconnect)

```powershell
$tenant   = '<tenant-id>'                 # Microsoft Entra ID > Overview > Tenant ID
$sub      = '<subscription-id>'           # subscription for the gateway core
$coreRg   = '<core-resource-group>'       # existing RG that will hold the core resources
$netRg    = '<network-resource-group>'    # RG of the existing VNet and private DNS zones
$vnet     = '<vnet-name>'
$peSubnet = '<private-endpoint-subnet-name>'
$fnSubnet = '<functions-subnet-name>'     # delegated to Microsoft.App/environments
$apimRg   = '<apim-resource-group>'
$apim     = '<apim-name>'
$prefix   = '<prefix>'                    # 3-12 lowercase letters/digits; same as the form's prefix
$tag      = 'main'                        # branch or release tag to deploy
$p        = 'infra/quickstart/.env.customer.bicepparam'
```

### 0.2 Select the subscription (read-only)

```powershell
az account set --subscription $sub
if ($LASTEXITCODE -ne 0) { throw 'Cannot select the subscription: run az login --tenant $tenant first.' }
az account show --query "{tenant:tenantId, subscription:id, user:user.name}" -o table
```

**Expect:** your tenant and subscription. On `AuthorizationFailed` later, Cloud Shell has probably
switched back to its default subscription, so run this block again.

### 0.3 Get the source code

```powershell
cd $HOME
if (-not (Test-Path ccof-source)) { git clone https://github.com/naveenneog/ccof-bicep.git ccof-source }
cd $HOME/ccof-source
git fetch --tags --quiet
git checkout $tag
git log -1 --oneline
npm ci --ignore-scripts --include=dev
```

**Expect:** `HEAD` at the release tag and `npm ci` finishing without errors.

---

## 1. Discover the values (read-only)

### 1.1 Context

```powershell
az network vnet show -g $netRg -n $vnet --query location -o tsv
az group show -n $coreRg --query "{name:name, location:location}" -o table
az functionapp list-flexconsumption-locations --query "[].name" -o tsv | Select-String -SimpleMatch (az network vnet show -g $netRg -n $vnet --query location -o tsv)
```

**Expect:** the VNet region, the core RG, and the same region in the Flex Consumption list.
Portal: **Resource groups** → core RG → **Overview**.

### 1.2 Network IDs (form section 2, Option B `mode: 'existing'`)

```powershell
$peSubnetId = az network vnet subnet show -g $netRg --vnet-name $vnet -n $peSubnet --query id -o tsv
$fnSubnetId = az network vnet subnet show -g $netRg --vnet-name $vnet -n $fnSubnet --query id -o tsv
$cosmosZone = az network private-dns zone show -g $netRg -n privatelink.documents.azure.com --query id -o tsv
$blobZone   = az network private-dns zone show -g $netRg -n privatelink.blob.core.windows.net --query id -o tsv
"privateEndpointSubnetId: $peSubnetId"; "functionsSubnetId:       $fnSubnetId"; "cosmos zone: $cosmosZone"; "blob zone:   $blobZone"
```

```powershell
az network vnet subnet show --ids $fnSubnetId --query "delegations[].serviceName" -o tsv
az network private-dns link vnet list -g $netRg -z privatelink.documents.azure.com --query "[].virtualNetwork.id" -o tsv
az network private-dns link vnet list -g $netRg -z privatelink.blob.core.windows.net --query "[].virtualNetwork.id" -o tsv
```

**Expect:** four IDs; `Microsoft.App/environments`; your VNet in both link lists.
Portal: **Virtual networks** → VNet → **JSON View** → `properties.subnets[].id`;
**Private DNS zones** → zone → **JSON View** (ID) and **Virtual network links**.

Paste the IDs into this block of the form (section 2), replacing the Option A block:

```bicep
param network = {
  mode: 'existing'
  existing: {
    privateEndpointSubnetId: '<privateEndpointSubnetId>'
    functionsSubnetId: '<functionsSubnetId>'
    privateDnsZoneIds: { cosmos: '<cosmos zone>', blob: '<blob zone>' }
  }
}
```

Address ranges are needed only for Option A (`mode: 'create'`, a new VNet). Do not use them with an
existing network.

**Outbound access:** the functions need Microsoft Graph (sync), the Log Analytics query endpoint
(reconciler) and Application Insights ingestion. These are firewall rules, not form values. This
block shows whether anything restricts outbound traffic:

```powershell
az network vnet subnet show --ids $fnSubnetId --query "{routeTable:routeTable.id, nat:natGateway.id, nsg:networkSecurityGroup.id}" -o table
```

If a route table or NAT points at a firewall, allow `graph.microsoft.com`,
`login.microsoftonline.com`, `api.loganalytics.io`, `*.in.applicationinsights.azure.com` and
`dc.services.visualstudio.com`, or the `AzureActiveDirectory` and `AzureMonitor` service tags.

### 1.3 API Management (form section 3)

```powershell
az apim list --query "[].{name:name, rg:resourceGroup, sku:sku.name, identity:identity.type}" -o table
az apim show -g $apimRg -n $apim --query "{sku:sku.name, identity:identity.type, principal:identity.principalId, gateway:gatewayUrl, vnet:virtualNetworkType}" -o table
az apim api list -g $apimRg -n $apim --query "[].{id:name, path:path}" -o table
```

**Expect:** a system-assigned identity, and no existing API with ID `claude-messages` or path
`anthropic`. Portal: **API Management services** → instance → **Overview**, **Managed identities**,
**APIs**.

### 1.4 Foundry accounts and deployments (form section 3 `backends`)

```powershell
az cognitiveservices account list --query "[?kind=='AIServices'].{name:name, rg:resourceGroup, subdomain:properties.customSubDomainName}" -o table
```

Set the account you will use, then list its deployments:

```powershell
$foundryRg = '<foundry-resource-group>'; $foundry = '<foundry-account>'
az cognitiveservices account deployment list -g $foundryRg -n $foundry --query "[].{deployment:name, model:properties.model.name, sku:sku.name}" -o table
```

Map the SKU to `deploymentInferenceGeo`: `GlobalStandard` → `'global'`; `DataZoneStandard` (US) →
`'us'`. The keys are the exact **deployment** names. Set `assignCognitiveServicesUser: false` only if
the block below already shows the role:

```powershell
$apimPrincipal = az apim show -g $apimRg -n $apim --query identity.principalId -o tsv
$foundryId = az cognitiveservices account show -g $foundryRg -n $foundry --query id -o tsv
az role assignment list --assignee $apimPrincipal --scope $foundryId --query "[].roleDefinitionName" -o tsv
```

Repeat 1.4 for each Foundry account (`foundry-1`, `foundry-2`, …). For an account in another
subscription, add `--subscription <that-subscription-id>` to each command.

### 1.5 Entra app registrations (form section 4 `registrations`)

```powershell
az ad app list --display-name '<gateway-app-name>'  --query "[].{name:displayName, appId:appId, tokenVersion:api.requestedAccessTokenVersion}" -o table
az ad app list --display-name '<resolver-app-name>' --query "[].{name:displayName, appId:appId, tokenVersion:api.requestedAccessTokenVersion}" -o table
```

Use the **appId** (Application (client) ID), not the object ID. The form's
`gatewayApi.accessTokenVersion` must equal the app's token version (an empty value means 1). For the
app settings themselves (redirect URIs, scope, public client flows), see
[QUICKSTART-PREREQUISITES.md](../QUICKSTART-PREREQUISITES.md).

### 1.6 Groups (form section 4 `groups`)

```powershell
$groupPrefix = '<group-name-prefix>'     # for example PROJ01 for PROJ01STD, PROJ01PRM, PROJ01CYB
az ad group list --filter "startswith(displayName,'$groupPrefix')" --query "[].{name:displayName, id:id, security:securityEnabled}" -o table
(New-Guid).Guid                          # workbook.resourceName
```

**Expect:** `security` = `True` for every group. Portal: **Microsoft Entra ID** → **Groups** → group
→ **Object ID**.

**One `groups` entry per project and classification.** A project name does not expand to STD, PRM and
CYB by itself. For project `PROJ01` with three groups, write three entries with the same `projectId`
and `backendId`:

```bicep
{ groupId: '<PROJ01STD object id>', projectId: 'PROJ01', classification: 'STD', backendId: 'foundry-1', ... }
{ groupId: '<PROJ01PRM object id>', projectId: 'PROJ01', classification: 'PRM', backendId: 'foundry-1', ... }
{ groupId: '<PROJ01CYB object id>', projectId: 'PROJ01', classification: 'CYB', backendId: 'foundry-1', ... }
```

`projectId` is the project only (`PROJ01`, not `PROJ01STD`).

---

## 2. Fill the private form

```powershell
cd $HOME/ccof-source
if (-not (Test-Path $p)) { Copy-Item infra/quickstart/customer-form.bicepparam $p }
code $p
```

This copies the form only once, so a rerun never overwrites a filled form. Fill sections 1–6 with
the values from step 1. Values whose case matters:

| Field | Allowed values |
|---|---|
| `personBudget.period`, `aggregateBudget.period` | `'monthly'` (lowercase) |
| `currency` | `'CCU'` or `'USD'` (1 CCU = USD 0.01) |
| `tokenQuotaPeriod` | `'Hourly'`, `'Daily'`, `'Weekly'`, `'Monthly'`, `'Yearly'`, or `null` |
| `aggregateMode` | `'strict'` or `'notify'` |
| `onboardingMode` | `'block'` or `'warn'` |
| `tokenQuota`, `tokensPerMinute` | a positive integer or `null`; quota and period are both set or both `null` |

### Budgets versus token limits

- **Token limits are enforced** by the gateway: a `429` when the per-minute rate is exceeded, a `403`
  when the quota is used up. They are set in `familyPolicy.aggregateLimits` (all models) and
  `familyPolicy.families.<family>` (one family).
- **Budgets are reported only** while `resolver.budgetEnforcement = 'token-limits-only'`. Setting
  `'budget-state'` also enforces them, through the reconciler, with a delay of several minutes.
- The gateway counts prompt and completion tokens, not cache reads or writes, and it cannot tell
  models apart by price. To turn a dollar budget into a token cap:

```
token cap ≈ budget USD ÷ cost per million counted tokens × 1,000,000
cost per million counted tokens ≈ output price + (cache reads per counted token × cache-read price)
                                + (cache writes per counted token × cache-write price)
```

Use the most expensive model in the classification. Prices are in `config/rate-card.json`.

---

## 3. Validate and preview (no deployment)

### 3.1 Validate the form

```powershell
cd $HOME/ccof-source
pwsh -File scripts/diagnostics/Find-SeedError.ps1 -ParametersPath $p
```

**Expect:** an `ok` line for every group and project. A `FAIL` line names the exact field and the
rule it breaks.

### 3.2 Preview

```powershell
pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -ParametersPath $p -WhatIfOnly
```

**Expect:**

- Steps 1 (checks) and 2 (build) pass.
- Step 3 prints `Resource changes: N to create, M to modify, ...`, with nothing in your network
  shown as deleted.
- The last line, `FAILED step 3 deploy: what_if_only`, is the normal end of a preview.
- A `NestedDeploymentShortCircuited` diagnostic for the Cosmos role assignments is expected.

To preview again from the beginning after editing the form:

```powershell
pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -ParametersPath $p -From 1 -WhatIfOnly
```

---

## 4. Deploy (changes Azure)

```powershell
pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -ParametersPath $p
```

The steps are 1 checks, 2 build, 3 Bicep, 4 code, 5 registry seed, 6 phase-3 note, 7 smoke test (401
without a token) and 8 `onboarding.json`. A rerun resumes at the first step that did not finish;
`-From <n>` restarts at step n, and `-Only <n>` runs one step.

```powershell
Get-Content (Join-Path (Split-Path $p) '.env.quickstart.state.json')
```

**Expect:** steps 1–8 listed as completed.

---

## 5. Load group members (delegated snapshot; no Graph application permission)

Run this after step 4, and again whenever group membership changes.

```powershell
$groupIds = @('<group-object-id-1>', '<group-object-id-2>', '<group-object-id-3>')
@{ groupIds = $groupIds } | ConvertTo-Json | Set-Content groups.json
@{ SYNC_TENANT_ID = $tenant; SYNC_GRAPH_MAX_RETRIES = '3'; SYNC_GRAPH_MAX_RETRY_AFTER_SECONDS = '30'; SYNC_GRAPH_TIMEOUT_SECONDS = '30' } | ConvertTo-Json | Set-Content snapshot-settings.json
npx tsc -p tsconfig.json
node dist/sync/cli.js snapshot --credential azure-cli --groups groups.json --settings snapshot-settings.json --out .env.sync-snapshot.json
```

Copy the SHA-256 from the last line of that output, then:

```powershell
$sha = '<sha256 from the line above>'
pwsh -File infra/sync/Invoke-SnapshotApplyThroughFunction.ps1 -Subscription $sub -ResourceGroup $coreRg `
  -FunctionApp "$prefix-sync-func" -AppInsights "$prefix-sync-ai" `
  -SnapshotPath .env.sync-snapshot.json -ExpectedSnapshotSha256 $sha
```

A single apply from Cloud Shell is limited to about 96 KiB of snapshot. For larger directories, see
[SYNC.md](../SYNC.md).

---

## 6. Client file and checks

```powershell
Get-Content infra/quickstart/.generated/onboarding.json
pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -ParametersPath $p -Only 8 -ConfigureClient
```

The first command prints the file to give to developers. The second, optional, configures this shell
as a client. Portal: core RG → **Workbooks** → the workbook's display name (chargeback).

---

## D. Diagnostics

| Symptom | Run |
|---|---|
| `seed_document_invalid: Answers failed schema validation` | `pwsh -File scripts/diagnostics/Find-SeedError.ps1 -ParametersPath $p` |
| `AuthorizationFailed` on a read | Run block 0.2 again (wrong subscription). |
| `Timedout waiting for token from portal. Audience: https://graph.microsoft.com/` | Quickstart tries the existing Azure PowerShell sign-in. If both token routes fail, stop: use the Portal-first guide's modules 06, 13 and 16, or an approved browser-authenticated workstation. Do not log out, reset Cloud Shell, use blocked device-code login, or skip prerequisite checks. |
| `seed_group_duplicate` | Two `groups` entries share the same `projectId` and `classification`. |
| `seed_backend_conflict` | Entries of one project use different `backendId` values. |
| Windows only: `'charmap' codec can't encode '\u2212'` | `$env:PATH = "$PWD/scripts/diagnostics/windows-az-utf8;" + $env:PATH` (makes `az` resolve to the UTF-8 `az.ps1` wrapper), then rerun. Cloud Shell is not affected. |
| `Audience https://api.applicationinsights.io is not a supported MSI token audience` (step 5) | Fixed in `main`: step 5 then queries through ARM. Update the two scripts (`git fetch origin; git checkout origin/main -- infra/quickstart/Deploy-Quickstart.ps1 infra/sync/Invoke-SnapshotApplyThroughFunction.ps1`) and rerun; it resumes at step 5. |
| Token version mismatch in step 1 | Set `gatewayApi.accessTokenVersion` to the app's `requestedAccessTokenVersion` (block 1.5). |

## Keep private

Never commit or share `.env.customer.bicepparam`, `.env.quickstart.state.json`, `.generated/`,
`groups.json`, `snapshot-settings.json` or `.env.sync-snapshot.json`. They contain your tenant,
subscription and group IDs. The repository's `.gitignore` excludes the `.env*` files.
