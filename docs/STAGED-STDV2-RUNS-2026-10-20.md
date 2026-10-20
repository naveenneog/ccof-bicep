# Standard v2 and Foundry staged runs — SASET MSFT FDPO and Contoso, 2026-10-20

Two independent runs of [`Invoke-StagedDeployment.ps1`](../infra/staged/Invoke-StagedDeployment.ps1)
with a **Standard v2** API Management instance, a **new private Foundry account** created by Stage 1,
and a separate configuration and state directory each. Runbook:
[configurable staged deployment](runbooks/STAGED-DEPLOYMENT-V2.md).

| | SASET MSFT FDPO | Contoso |
| --- | --- | --- |
| Tenant / subscription | FDPO tenant, subscription "SASET MSFT FDPO" | Contoso tenant, "ME-MngEnvMCAP189112" subscription |
| Operator access | Reader on the subscription; Owner on one resource group only | Owner at the tenant root management group; directory role Global Reader active (others eligible through PIM) |
| Resource group | Existing shared RG `FoundryEUS2Anthropic` (holds another team's APIM and Foundry); `sharedResourceGroup: true` | New RG `ccof-stdv2-20261020-rg` |
| APIM | New Standard v2, outbound VNet integration on `snet-apim`, public ingress | Same |
| Foundry | New account, public access Disabled, private endpoint; Claude Haiku 4.5 and Sonnet 5 deployed | New account, public access Disabled, private endpoint; **no model**: the subscription cannot buy the Claude offer |
| Entra | Existing lab registrations and groups, merged (operator's directory quota is exhausted) | **New** gateway, resolver and admin registrations and three new security groups |
| Graph application permission | Not attempted (delegated snapshot) | Attempted; refused with no change: no active Privileged Role Administrator or Global Administrator role |
| Result | **Stages 0-8 verified; 200 for admitted models** | Stages 0-8 verified; model calls blocked by the subscription type |

## Results by stage

| Stage | SASET MSFT FDPO | Contoso |
| --- | --- | --- |
| 0 | Pass (53 s): providers, Flex region, Claude models offered in eastus2 | First run failed correctly: `Microsoft.AlertsManagement` NotRegistered. Registered by the subscription Owner, then pass (48 s) |
| 1 | what-if: 37 creates, the 4 existing SASET resources `Ignore`. First apply failed (finding 1); guarded rerun verified (273 s) | Same finding 1; guarded rerun verified (156 s) |
| 2 | 6 private endpoints Approved with DNS; APIM `External` on `snet-apim`, identity unchanged; 4 apps integrated (740 s) | Same (759 s) |
| 3 | 9 containers (196 s) | 9 containers (198 s) |
| 4 | Azure RBAC, 13 Cosmos data grants, Cognitive Services User on the new Foundry (322 s) | Same (322 s) |
| 5 | Merge into existing registrations (48 s) | 3 applications and 3 groups created (83 s); Graph grant refused (no active admin role) |
| 6 | Settings, resolver auth, API, policy, workbook (75 s) | Same (78 s) |
| 7 | First attempt failed (finding 6); rerun: 4 packages, seed, snapshot 1 member admitted, client file (1279 s) | Same failure, rerun verified (1404 s) |
| 8 | 401 anonymous and resolver; **200 Haiku, 200 Sonnet**; 403 Opus (not admitted for STD); 403 non-member project; admin 302/200/401; both request IDs found in `ApiManagementGatewayLlmLog` (300 s) | 401/401; 403/403; admin 302/200/401; no allowed pair (no model). A member's admitted request returned **404 DeploymentNotFound from the private Foundry**: authentication, policy, Standard v2 VNet routing and the Foundry private endpoint all worked (38 s) |

## Evidence

Command-output captures of the live logs and read-back JSON. Identifiers are masked in the middle;
local paths are replaced by `<config-dir>`; no token or setting value is shown.

![SASET Stage 0](images/staged-stdv2/saset-00-stage0.png)
![SASET Stage 1 preview in a shared RG](images/staged-stdv2/saset-01a-shared-rg-preview.png)
![SASET Stage 1](images/staged-stdv2/saset-01-stage1.png)
![Foundry setup findings](images/staged-stdv2/both-01x-foundry-marketplace.png)
![SASET Stage 2](images/staged-stdv2/saset-02-stage2.png)
![SASET Stage 4](images/staged-stdv2/saset-04-stage4.png)
![SASET Stage 8](images/staged-stdv2/saset-08-stage8.png)
![Contoso Stage 0](images/staged-stdv2/contoso-00-stage0.png)
![Contoso Stage 1](images/staged-stdv2/contoso-01-stage1.png)
![Contoso Stage 2](images/staged-stdv2/contoso-02-stage2.png)
![Contoso Stage 4](images/staged-stdv2/contoso-04-stage4.png)
![Contoso Stage 5 Entra](images/staged-stdv2/contoso-05-entra.png)
![Contoso Graph consent attempt](images/staged-stdv2/contoso-05b-graph-consent.png)
![Contoso Stage 8](images/staged-stdv2/contoso-08-stage8.png)

## Findings and changes

| # | Observed | Change |
| --- | --- | --- |
| 1 | Claude deployments failed with `InvalidModelProviderData`. Preflight passed; the deployment failed. API versions 2025-06-01, 2025-07-01-preview and 2025-09-01 ignore `modelProviderData` | [`foundry-account.bicep`](../infra/staged/foundry-account.bicep) deploys models with `2025-10-01-preview` and `properties.modelProviderData`. `stage1.foundry.modelProviderData` (organizationName, countryCode, industry) is required configuration with no default: it is the Anthropic attestation that accepts the Marketplace offer for the real organization. The lab runs used `Microsoft`, `US`, `technology` |
| 2 | Contoso subscription: "This subscription is internal or sandbox. Only $0.00 products or test products can be purchased." | Subscription limit, not a template defect. `stage1.foundry.modelDeploymentsBlocked` records the reason; Stage 0 warns and Stage 8 records telemetry as not applicable |
| 3 | Standard v2 alone did not integrate APIM with the VNet | Stage 2 PATCHes APIM to `virtualNetworkType: External` on the APIM subnet (keeping its identity), waits for `Succeeded`, and verifies subnet and identity |
| 4 | Foundry provisioning and its private path were outside the stages | Stage 1 optionally creates the account and deployments; Stage 2 creates its private endpoint with the cognitiveservices, openai and services.ai zones |
| 5 | SASET allows writes only in an RG that holds another team's resources | `sharedResourceGroup: true`: Stage 1 applies only when what-if shows no Modify or Delete for any resource whose name does not start with the prefix. The same guard allows a rerun after a failed Stage 1 |
| 6 | Stage 7 of both runs, started at the same time from one checkout, failed: `npm ci` EPERM on `admin/node_modules` | Run Stage 7 for one target at a time per checkout (documented). Sequential reruns passed |
| 7 | State could be reused across targets | `state.json` now records tenant, subscription and RG; a mismatch stops with `state_target_mismatch`. Offline test with a negative control |
| 8 | Telemetry acceptance counted any recent rows | Stage 8 queries `ApiManagementGatewayLlmLog` for exactly this run's `x-ccof-request-id` values (APIM `context.RequestId` = `CorrelationId`) and requires every one |
| 9 | Graph application consent needs an active Privileged Role Administrator or Global Administrator. Azure CLI cannot activate PIM (token lacks the RoleManagement scopes) | Unchanged: interactive PIM activation, then `Grant-SyncGraphPermissions.ps1`. The script refused safely |
| 10 | A direct call to the private Foundry from outside the VNet returned `PermissionDenied` (RBAC), not a network error | Inconclusive about the network: the service checked RBAC first, and no model role was granted to the operator. Account read-back shows public access `Disabled`, default action `Deny` |

## Portal walkthrough with Playwright

The guide's manual Portal steps were turned into 20 Portal deep links per run (generated from each
run's real resource IDs, with the text each page is expected to show). Two dedicated Edge
profiles were signed in to FDPO and Contoso by the account owner during the run. Those sessions
used session-only cookies and ended when the automation closed the windows, so the walkthrough
did not reach the Portal. The windows were reopened; a watcher runs the walkthrough as soon as a
sign-in completes. No authentication was intercepted or bypassed. Walkthrough status per run is
recorded below when available.

| Check | Result |
| --- | --- |
| Guide and reports rendered in Edge (Playwright) | 39 images load, 26 local links and 1 anchor resolve, 0 page errors; a hidden image was reported broken (negative control) |
| Guide PowerShell blocks | Parse without errors |
| Manual Portal steps covered by deep links | Every section 0-8 and the Foundry section maps to 1-4 deep links (20 per run) |
| Portal walkthrough, FDPO | **Not run: Portal sign-in pending** (window open on the sign-in page until the end of the session) |
| Portal walkthrough, Contoso | **Not run: Portal sign-in pending** |

Rerun steps: [tests/playwright](../tests/playwright/README.md).

## Retained resources

Both deployments remain and incur charges (Standard v2 APIM, Flex apps, Cosmos, Foundry). SASET
resources share `FoundryEUS2Anthropic` with another team: removal must name the `sas1020-*`
resources individually, never the RG. Contoso objects: RG `ccof-stdv2-20261020-rg`, three
`CCOF ... con1020` app registrations, three `CCOF-CONLAB*` groups. Removal is a separate approval.
