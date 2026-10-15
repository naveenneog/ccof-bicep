# Manual modular deployment

For resource creation through Portal wizards rather than Bicep module deployment,
use the separate [Azure Portal-first workbook](runbooks/AZURE-PORTAL-DEPLOYMENT.md).
It includes UI configuration, one-app code publishing, per-app runtime-access grants,
and Cloud Shell disconnect recovery. Quickstart and this modular path remain available.

## Contract and integration boundary

Packet: new staged entrypoints at frozen baseline
`cb6967e2c90a77238a18b3a586b609d7d5ca5d0c`. Acceptance: executable resource-specific
inputs, private access from creation, separate configuration, no workbook-shell overwrite,
fail-closed stage ordering, and offline compilation/tests. No live Azure changes in this packet.
The coordinator owns ADR reconciliation, council, shared ledgers and the full gate.

**Do not confuse `Deploy-Quickstart.ps1 -Only` with individual resource modules.**
Those numbers select wrapper stages; `-Only 3` deploys the entire quickstart template.
This manual path instead exports inputs for actual `infra/prereqs` modules and deploys
`infra/manual/configuration.bicep` against existing resources.

### Researched dependencies and open integration questions

Source inspection, 2026-10-13:

* `infra/prereqs/cosmos-account.bicep` creates its SQL private endpoint and zone group with
  the account, always `publicNetworkAccess: Disabled`, `disableLocalAuth: true`.
* `infra/prereqs/function-app.bicep` creates private/keyless blob storage, its PE/zone group,
  Flex plan and VNet-integrated app together. It requires the subnet and DNS zone first.
* `infra/prereqs/network.bicep` replaces the authoritative subnet list. Create it **once**;
  never rerun after customer networking adds subnets. Existing network mode avoids this writer.
* `infra/prereqs/apim.bicep` creates APIM with outbound integration and a system identity.
  Reusing an existing APIM means do not deploy this module over it.
* ADR-0019 places remaining private networking at D5, not an exemption from the minimal
  private prerequisites above. Accepted ADR-0013 covers Foundry DNS; ADR-0009 Resolver auth.
  The coordinator must reconcile this supplemental manual path with proposed ADR-0024.
* Family/CYB seed and single-registration helpers are separate agents' integration dependencies.
  The baseline does not contain their completed behavior. Do not claim a family-enabled
  production deployment until those commits and their tests are integrated.
* **Not proved here:** Azure policy/quota, Cloud Shell package access, PE approval latency,
  private data-plane reachability, or five-hour completion. Live proof belongs to the live agent.

No resource-shell-only switch exists for Cosmos or Flex in the reused modules. Splitting them
would require changes to those owned modules; request that change from their owners rather than
copying account/site definitions or temporarily enabling public access/local auth.

The five-hour hard deadline includes load testing. Cosmos SQL RBAC, Microsoft Graph grants,
function packaging and configuration seed cannot be completed as a UI-only flow.

## Five-hour execution window and stop rules

| Elapsed | Owner/action | Exit evidence |
|---|---|---|
| 0–30 min | Directory/platform: approved sizing, IDs, groups, existing APIM/Foundry quotas, PIM activated | Reviewed inputs; required roles active |
| 30–100 min | Infrastructure: independent shells, minimum network, then private-dependent modules | ARM Succeeded; Cosmos/storage still private/keyless |
| 100–145 min | Network/backend owner: remaining connections, approvals, DNS, APIM outbound path | Approved PEs; private DNS from actual caller networks |
| 145–205 min | Platform/access: grants, configuration, packages, seed, client artifacts | Functions listed; seed equal/created; sync entitlement |
| 205–230 min | QA: authenticated E2E and negative checks | 401 anonymous; 200 synthetic user; expected denials |
| 230–270 min | QA/platform: bounded load and telemetry/workbook checks | Explicit p95 budget, all requests accounted for |
| 270–300 min | Coordinator: fix/retest or stop, evidence/handoff | No unverified promotion; next owner/failed stage named |

These are a budget, not Azure provisioning SLAs. Start APIM creation/PE approvals early.
If APIM, Graph propagation (cached identity tokens can outlast the window), policy/quotas,
or missing family integration blocks the next gate, report **blocked**, never open Cosmos
public access, enable keys, bypass auth, silently select a different backend, or call 401 smoke
an E2E/load pass. APIM SKU availability and model capacity are customer prerequisites, not created
by these entrypoints. No WAF/SIPA edge or HA topology is provisioned here: retain the customer's
approved ingress controls; don't call this the full enterprise topology in `NETWORK.md`.

## 0. Prepare inputs (Azure Cloud Shell, PowerShell)

Use the private checkout in Cloud Shell's PowerShell mode; do not publish artifacts or secrets.
Paths below use PowerShell separators; generated absolute module paths are native to the host.
Existing helper scripts support Linux Cloud Shell. **Ordinary Cloud Shell has no customer VNet
data-plane reachability**. ARM deployment/OneDeploy are control-plane; registry seed executes
inside the already VNet-integrated sync app. DNS/approved-plan Cosmos apply needs a customer
private runner or network-isolated Cloud Shell. No jumpbox VM is created by this manual path.

```powershell
$ErrorActionPreference = 'Stop'
# Start at the integrated, reviewed checkout, not an arbitrary latest branch.
Copy-Item infra\quickstart\customer-form.bicepparam infra\quickstart\.env.manual.bicepparam
$par = (Resolve-Path infra\quickstart\.env.manual.bicepparam).Path
$inputsDir = Join-Path $PWD '.env.manual-inputs'
New-Item -ItemType Directory -Path .env.manual-work -Force | Out-Null
# Existing Graph/packaging helpers must use a project-owned working directory, not system temp.
$env:TEMP = $env:TMP = $env:TMPDIR = (Resolve-Path .env.manual-work).Path
# Edit $par using Cloud Shell editor; keep its using 'main.bicep' reference.
az cloud show --query name --output tsv   # this manual exporter supports AzureCloud only
```

Replace every placeholder, including groups; choose every sizing/model/quota decision explicitly.
Use `network.mode = 'existing'` with `privateEndpointSubnetId`, `functionsSubnetId`,
`privateDnsZoneIds.cosmos` and `.blob` for customer-owned networks/zones; select verified IDs.
Functions subnet delegates to `Microsoft.App/environments`; APIM v2 outbound subnet delegates
to `Microsoft.Web/serverFarms` and has the required NSG. PE subnet has appropriate PE policy.
For greenfield `network.mode='create'`, the network module creates those subnets and DNS links.
APIM and Functions subnets must be distinct. Do not link duplicate DNS namespaces to one VNet.

**Registrations:** the integrated single-app contract uses one single-tenant gateway/public-client
app (`gatewayApi.appId = developerSignIn.appId`), enabled `access_as_user`, URI `api://<appId>`,
token version 2, localhost/native-client and WAM redirects. Device-code needs public-client
flows enabled. A **separate Resolver API** uses `api://<resolverId>`, v2, no client redirects or
secret. Two mandatory registrations, not three. Helpers normalize token-to-self scope at request
time; keep the exported API URI scope. Optional third registration exists only for a cross-tenant
backend and lives in that backend tenant. Old separate-client input remains compatibility only.
Use the auth owner's integrated prerequisite instructions; no app registration creation here.

**Routing/families:** each group names its project/classification and, with multiple backends,
an explicit `backendId`, consistent across that project's groups. The designated subscription is
the chosen backend's subscription, never "first backend". Fill `familyPolicy` with exact deployment
IDs and explicit model-to-family entries and family quotas. Read `config/model-families.json`:
haiku/sonnet/opus/fable/mythos; fable/mythos are CYB-only. Prefix alone never admits, no wildcard,
unknown deployment fails closed, and non-CYB cannot admit CYB-only families. STD/PRM/CYB group
membership is a policy decision, not a new app registration. Add integrated `client` selection
(`projectId`, `classification`, `models.default/opus/sonnet/haiku`) for generated onboarding/client
artifacts. Every alias must be admitted on the selected backend; don't invent deployment names,
prices, capacities or quotas. Baseline client helper has fixed aliases: **integration is required**.

Directory team needs Application Administrator/Cloud Application Administrator or permitted
app-owner rights, plus Groups Administrator/group-owner rights for membership. Azure Reader alone
cannot read Graph applications/groups. Grant required Graph delegated reads/admin consent for
the operator, per the existing prerequisite preflight; no Entra write is hidden in this path.

## 1. Deploy resources, with unavoidable minimum network prerequisites

RBAC: Contributor on target RG for shells/resources and `deployments/write`; Network Contributor
on customer VNet/subnets, Private DNS Zone Contributor on customer zones plus VNet link/join rights.
RG creation requires Contributor at subscription scope. Activate PIM first; denied/unreadable rights
are a stop, not evidence of absence. Register required resource providers using the existing D1
prerequisite workbook; do not register providers blindly on someone else's subscription.

```powershell
pwsh -NoProfile -File infra\manual\Export-ManualInputs.ps1 -ParametersPath $par -OutputDirectory $inputsDir
if ($LASTEXITCODE) { throw 'input export failed' }
$manifest = Get-Content (Join-Path $inputsDir 'manifest.json') -Raw | ConvertFrom-Json -AsHashtable
$first = $manifest[0]
az account show --subscription $first.subscriptionId --query '{tenant:tenantId,subscription:id}' --output json
# Only if resourceGroupMode=create and the owner approved creation:
az group create --subscription $first.subscriptionId --name $first.resourceGroup --location '<approved-region>'
function Deploy-ManualResource([string]$Id, [switch]$Apply) {
    $matches = @($manifest | Where-Object id -CEQ $Id)
    if ($matches.Count -ne 1) { throw "module not exported: $Id" }
    $m = $matches[0]; $verb = if ($Apply) { 'create' } else { 'what-if' }
    az deployment group $verb --subscription $m.subscriptionId --resource-group $m.resourceGroup `
        --name $m.deploymentName --mode Incremental --template-file $m.template --parameters "@$($m.parametersFile)"
    if ($LASTEXITCODE) { throw "module failed: $Id" }
    if ($Apply) {
        $state = az deployment group show --subscription $m.subscriptionId --resource-group $m.resourceGroup `
            --name $m.deploymentName --query properties.provisioningState --output tsv
        if ($LASTEXITCODE -or $state -ne 'Succeeded') { throw "module not verified: $Id" }
    }
}
```

Run each command first without `-Apply` to review what-if, then again with it. No bulk loop:

```powershell
Deploy-ManualResource workspace -Apply
Deploy-ManualResource identities -Apply
# CREATE network only; omit entirely in existing mode, after validating customer IDs.
Deploy-ManualResource network -Apply
Deploy-ManualResource cosmos -Apply
# Sequential: concurrent joins failed live with ServiceAssociationLinkLease.
Deploy-ManualResource app-resolver -Apply
Deploy-ManualResource app-sync -Apply
Deploy-ManualResource app-reconciler -Apply
```

For a **new** APIM only, pass `-ApimCreateSettingsPath` when exporting. The reviewed JSON has
exact module fields `sku` (StandardV2/PremiumV2), `units`, `zones`, `publisherEmail`,
`publisherName`, `subnetId`. `apim.subscriptionId/resourceGroup` must equal the target; its `name`
comes from the parameters. This adds `apim` to the manifest, then `Deploy-ManualResource apim -Apply`.
It creates a system identity and outbound integration together. Existing APIM is never exported;
verify its identity in Portal and its VNet path at stage 2. **Never `az apim update`**: the existing
contract warns it can strip the identity. No workbook shell is exported.

Portal alternative per module: compile `az bicep build --file $m.template --outfile <project-owned.json>`,
then **Deploy a custom template → Build your own template → Load file**, use the target
subscription/RG and the values in that module's `*.parameters.json`. This is a real per-resource
deployment, not `all.bicep` or quickstart `-Only 3`. D1 wizard equivalents and screenshots:
`PREREQUISITES-WORKBOOK.md` D1-03–05 network, D1-06 workspace, D1-07 identities,
D1-08 Cosmos, D1-09–13 Flex, D1-14 APIM. Set private/keyless values at creation; Cosmos and
Flex PE/DNS/integration remain bundled in these templates, not a later attach switch.

Postchecks (Reader at resource scopes):

```powershell
. infra\quickstart\Deploy-Quickstart.ps1 -ParametersPath $par -DotSourceOnly
$p = Read-QsParameters $par
$sub = $p.names.subscriptionId; $rg = $p.names.resourceGroup
$base = "/subscriptions/$sub/resourceGroups/$rg/providers"
az cosmosdb show --subscription $sub -g $rg -n $p.names.cosmosAccount `
    --query '{public:publicNetworkAccess,localAuthDisabled:disableLocalAuth}' --output json
foreach ($app in @('resolver','sync','reconciler')) {
    az storage account show --subscription $sub -g $rg -n $p.names.apps[$app].storageAccount `
        --query '{public:publicNetworkAccess,sharedKeys:allowSharedKeyAccess}' --output json
    az resource show --subscription $sub --ids "$base/Microsoft.Web/sites/$($p.names.apps[$app].functionApp)" `
        --query '{subnet:properties.virtualNetworkSubnetId,identity:identity.type}' --output json
}
az network private-endpoint list --subscription $sub -g $rg `
    --query '[].{name:name,status:(privateLinkServiceConnections[0] || manualPrivateLinkServiceConnections[0]).privateLinkServiceConnectionState.status}' --output table
```

Require Cosmos Disabled/true; each storage Disabled/false; all expected PE connections Approved;
integration subnet exact; resolver SystemAssigned and other apps expected UAMIs. No code expected yet.

## 2. Remaining network wiring (network and backend teams)

APIM must use a reachable outbound VNet, with DNS links/forwarding from **its actual network**,
not merely the new core VNet. Peering alone does not share DNS. Portal: APIM → Network → outbound
VNet integration; review the approved subnet/NSG/route and preserve identity. Verify ARM
`properties.virtualNetworkConfiguration.subnetResourceId`; private backend smoke must then succeed.
Do not create another VNet and assume existing APIM automatically joined it.

RBAC: Network Contributor on PE/VNet scopes; Private DNS Zone Contributor on zones, plus VNet
link permissions; Foundry owner needs privateEndpointConnections approval rights and
account network-setting write. Approval across tenant is separate from authentication.
Create one **hub PE** per backend, including cross-subscription/tenant targets:

```powershell
$backend = $p.backends | Where-Object id -CEQ '<reviewed-backend-id>'
$target = "/subscriptions/$($backend.subscriptionId)/resourceGroups/$($backend.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($backend.accountName)"
$peSubnetId = '<reviewed PE subnet resource id>'
$foundryPe = '<reviewed hub PE name>'
az network private-endpoint create --subscription $sub -g $rg -n $foundryPe --location $p.location `
    --subnet $peSubnetId --private-connection-resource-id $target --group-id account `
    --connection-name "$foundryPe-connection" --manual-request true --request-message 'Approved private gateway onboarding'
# Backend owner reads the target-side connection id, then approves THAT id (not the PE id):
az network private-endpoint-connection list --id $target --output table
az network private-endpoint-connection approve --id '<target-side connection id>' --description 'Reviewed gateway PE'
```

For a simple new hub where VNet/PE/zones all live in this RG, reuse the DNS module:

```powershell
az deployment group create --subscription $sub -g $rg --name manual-foundry-dns `
    --template-file infra\poc\foundry-private-dns.bicep `
    --parameters vnetName='<actual APIM-integrated hub VNet name>' privateEndpointName=$foundryPe
```

It creates/links all three zones and one zone group, with ADR-0013 NxDomainRedirect fallback.
For central existing zones **do not deploy that creator**: use reviewed zone IDs with
`az network private-endpoint dns-zone-group create --endpoint-name $foundryPe -g $rg
--name default --private-dns-zone <cognitiveservices-zone-id> --zone-name cognitiveservices
--subscription $sub`, then `dns-zone-group add` for openai/services.ai zone IDs, same group.
Central DNS team links those zones to the APIM VNet or provides conditional forwarding.
Repeat for each backend. Only disable designated Foundry public access after approval/private
DNS and coordinate with its other callers; never temporarily enable it for validation.

**Resolver inbound privacy is separate from Flex outbound integration.** The reused Flex module
does not disable HTTP public access; ADR-0009 auth must still restrict the caller to APIM.
For private production inbound, create a PE targeting the resolver site with group `sites`
using the above `private-endpoint create` pattern (target the site id, not Foundry). Link the
existing/approved `privatelink.azurewebsites.net` zone to the APIM VNet and attach its zone group.
Portal: Function App → Networking → Private endpoints, then inbound access → disable public access
after approval/DNS. An explicit minimal CLI PATCH, with no identity replacement:

```powershell
$resolverId = "$base/Microsoft.Web/sites/$($p.names.apps.resolver.functionApp)"
$bodyFile = Join-Path $inputsDir 'resolver-private-inbound.json'
'{"properties":{"publicNetworkAccess":"Disabled"}}' | Set-Content $bodyFile -Encoding utf8NoBOM
az rest --method patch --url "https://management.azure.com$resolverId`?api-version=2024-04-01" --body "@$bodyFile"
```

Postcheck: actual customer-network DNS resolves Cosmos, blob, resolver and
`<account>.services.ai.azure.com` to the approved PE IPs; zone groups contain expected IDs;
PEs Approved; resolver public access Disabled if private inbound selected; backend PE traffic
metrics nonzero during E2E. Use `Resolve-DnsName` on a Windows private runner or `nslookup` in
network-isolated Cloud Shell; ordinary Cloud Shell public resolution is not proof of failure/success.

## 3. Apply configuration, permissions, packages and seed

RBAC: Contributor plus Role Based Access Control Administrator/User Access Administrator on core
resource scopes and chosen same-tenant Foundry accounts (or Owner); Cosmos SQL RBAC control-plane
write is required in addition to Azure role assignments. APIM API/policy/diagnostic write rights
apply in its own RG, possibly a different subscription. Reader alone cannot apply configuration.
This template writes schema + grants + settings + API policy + telemetry, **not** resource shells.
Segregated-role customers instead retain D1 Record → D2 → D3 → D2 checkpoints in
`DEPLOYMENT-STAGES.md`; this new wrapper does not fabricate those records.

Privileged directory team, after resource UAMI creation and preferably before first token:
In this manual flow, ignore this helper's printed quickstart `-Only 3` instruction;
continue with the manual stage commands below instead.

```powershell
$syncPrincipal = az identity show --subscription $sub -g $rg -n $p.names.identities.sync --query principalId --output tsv
pwsh -NoProfile -File infra\quickstart\Grant-SyncGraphPermissions.ps1 -SyncPrincipalId $syncPrincipal -PlanOnly
pwsh -NoProfile -File infra\quickstart\Grant-SyncGraphPermissions.ps1 -SyncPrincipalId $syncPrincipal
```

Requires active Privileged Role Administrator/Global Administrator. Require verified
GroupMember.Read.All, User.Read.All, Application.Read.All **on the UAMI service principal**.
A portal enterprise-app display is not a grant; this managed identity grant needs Graph/script.
Ignore the helper's printed quickstart `-Only 3` instruction in this manual flow.
After verified grant set `syncTimerEnabled=true` in `$par`; finish all edits before preparing state.
Do not enable the timer if the grant is pending/unreadable.

```powershell
# Run from this reviewed checkout; missing Node dependencies are installed per repository lockfiles.
pwsh -NoProfile -File infra\manual\Invoke-ManualConfiguration.ps1 -ParametersPath $par -Step 1
pwsh -NoProfile -File infra\manual\Invoke-ManualConfiguration.ps1 -ParametersPath $par -Step 2
pwsh -NoProfile -File infra\manual\Invoke-ManualConfiguration.ps1 -ParametersPath $par -Step 3 -WhatIfOnly
# Re-running step 3 after what-if is allowed: what-if records no success.
pwsh -NoProfile -File infra\manual\Invoke-ManualConfiguration.ps1 -ParametersPath $par -Step 3
pwsh -NoProfile -File infra\manual\Invoke-ManualConfiguration.ps1 -ParametersPath $par -Step 4
pwsh -NoProfile -File infra\manual\Invoke-ManualConfiguration.ps1 -ParametersPath $par -Step 5
```

Check exit code after each `pwsh`; stop on nonzero. Steps 1/2 are checks/offline build; 3 deploys
`manual/configuration.bicep` only; 4 reuses OneDeploy packages and verifies function listings;
5 reuses the sync-hosted private seed, create-only. Existing differing documents refuse; never
overwrite through seed. It disables/removes seed-trigger settings on completion/failure.
Check seed cleanup if a failure reports it. A parameter edit requires re-running checks/build;
rerunning a stage invalidates later stage evidence. State is `.env.manual.state.json`;
generated artifacts are `.env.manual.generated` beside the parameters, ignored by existing git rules.
Treat state as local operational evidence, not a signed/security attestation.

Portal alternative: custom-template configuration is possible with rendered
`configuration.parameters.json`; EasyAuth can be inspected at Function → Authentication and APIM
policy at API → Design. **UI-only impossible:** Cosmos SQL RBAC custom roles/assignments, Graph
UAMI grant, reproducible function packaging, private configuration seed and generated onboarding
artifact validation require the scripts/ARM APIs. Portal cannot replace those verification gates.

**Workbook:** omit `-WorkbookParametersPath` on normal/repeat config deploy: no workbook writer
runs, existing content and grants stay intact. For initial or explicitly reviewed content updates,
prepare the real workbook answers using `docs/CHARGEBACK.md` and its examples, then
`node analytics\workbooks\build.ts --answers <reviewed-workbook-answers.json>`. Pass its generated
`parameters.json` to step 3 via `-WorkbookParametersPath`; target/workspace/name/location must
match. This uses existing `infra/workbook/main.bicep` full content, never its shell. Optional reader
grants apply with that content update. Keep the GUID stable and export existing content before an
intentional change; do not rerun quickstart/all resource templates over a customized workbook.

**Optional cross-tenant backend:** the new helper explicitly refuses a backend subscription whose
tenant differs. Private Link above still works, but APIM MI cannot authenticate across tenant.
Use accepted `DEPLOYMENT-STAGES.md` D1/D2/D3 and `scripts/Stage2-RegisterBackend.ps1
-AnswersFile <reviewed-stage2.json> -CheckpointPath <checkpoint.json> -DiscoverOnly`, then the
same command without DiscoverOnly after confirmation. Its `backendAuthMode=second-tenant`
requires D2's configured backend and secure credential-manager/existing-named-values reference;
Graph/app grant lives with the backend owner. A backend-tenant app (optional third) needs Cognitive
Services User; credential secret stays in approved secret store/APIM secret named value, never
parameters/artifacts. D2 must configure references first; Stage2 is not secret provisioning.
Registry project mapping must select this descriptor through reviewed private onboarding Stage3;
do not run the managed-identity quickstart seed over it. Rotation/federation approval is an explicit
handoff dependency; if absent, omit that backend and fail its project closed.

## 4. E2E, artifacts and load gate

```powershell
pwsh -NoProfile -File infra\manual\Invoke-ManualConfiguration.ps1 -ParametersPath $par -Step 7
pwsh -NoProfile -File infra\manual\Invoke-ManualConfiguration.ps1 -ParametersPath $par -Step 8
$generated = Join-Path (Split-Path $par -Parent) '.env.manual.generated'
$clientConfig = Join-Path $generated 'client-config.json'
$gatewayConfig = Join-Path $generated 'gateway-config.json'
# On the approved developer workstation; normal login/MFA, never copy a token into a file:
$env:CCOF_CONFIG_FILE = $clientConfig
node client\bin\ccof-token.mjs login
pwsh -NoProfile -File scripts\Test-OwnerSmoke.ps1 -GatewayConfigPath $gatewayConfig -ClientConfigPath $clientConfig
# Example budget ONLY: owner/QA must explicitly approve latency and spend before running.
pwsh -NoProfile -File infra\manual\Test-ManualLoad.ps1 -GatewayConfigPath $gatewayConfig `
    -ClientConfigPath $clientConfig -Requests 20 -Concurrency 4 -P95BudgetMilliseconds 10000 `
    -MaximumDurationSeconds 300 -Confirmed
```

Step 7 proves anonymous 401 only. Step 8 on integrated family helpers creates strict-schema
`onboarding.json` and client config for the chosen project/classification; share only those
nonsecret artifacts through approved channels. Install the existing client lockfile dependencies
if missing; configure CLI via `Set-ClaudeCodeGateway.ps1 -ConfigPath $clientConfig -Confirmed`.
Require user 200 plus "OK", correct backend/project/modelFamily attribution, and sync direct
membership projection. Test each enabled family, a disallowed exact model, fable/mythos on
non-CYB, wrong project, and group/family quota exhaustion with dedicated synthetic test identities.
Use the existing family contract tests and approved live cases; do not exhaust real customer quotas.
Logs must contain usage counts/attribution, never prompts, response bodies, credentials or JWTs.

Load entrypoint caps 200 requests/16 concurrency/600s; synthetic 8-token replies only. It reports
status counts and nearest-rank p95, fails partial completion, transport/HTTP errors (including 429),
or budget violation. Run sequential ramps 1 → 4 → approved higher concurrency with reviewed costs;
do not mistake this bounded pilot smoke load for a full production-capacity benchmark.
Read Workbook in Portal, verify new rows/attribution and preservation after a repeat config
deployment without content parameters. Record elapsed time, request IDs/status/latency, module
deployment names, approval/DNS evidence and unresolved blockers in approved operational storage.

## Offline packet verification / remaining gates

Fail-first resource test initially failed `manual resource input module exists`; executable export
regression caught a caller-path reset during helper import and is fixed. Load test initially failed
`bounded manual load entrypoint missing`. Run `pwsh -NoProfile -File tests\Test-ManualDeployment.ps1`
and `pwsh -NoProfile -File tests\Test-ManualLoad.ps1`; both are offline, compile with `az bicep build`
only, and generate/clean test-owned scratch under the checkout. No Azure deployment or live request
was executed by this packet. Coordinator must integrate auth/family/client/workbook commits,
reconcile ADRs, record council verdicts and run full Ironclad gate before approval.
