# Configurable staged deployment

CCOF deploys in nine stages, run one at a time by
[`infra/staged/Invoke-StagedDeployment.ps1`](../../infra/staged/Invoke-StagedDeployment.ps1).
Each stage has its own operator permission boundary, a preview, an apply, and a read-back
verification. All nine stages ran end to end in a new lab resource group on 2026-10-20;
the evidence and screenshots are in the [live run report](../STAGED-LIVE-RUN-2026-10-20.md).

The [manual Portal walkthrough](#manual-portal-walkthrough) below separates Portal actions,
CLI-only operations and the available screenshots. The earlier live run used Basic v2 and
an existing Foundry backend. It is not evidence of a new Standard v2/private Foundry setup.

The [four-stage runbook](STAGED-CUSTOMER-DEPLOYMENT.md) and the
[quickstart](../QUICKSTART.md) remain available. This path reuses the quickstart's Bicep modules
and PowerShell functions; it does not change them.

## How a stage runs

The entry script holds parameters and dispatch; the stages live in `Staged.Common.ps1`
(configuration, state, Azure and Graph helpers), `Staged.Resources.ps1` (stages 0-4),
`Staged.Entra.ps1` (stage 5) and `Staged.Application.ps1` (stages 6-8).

```powershell
$cfg = 'C:\private\ccof\staged.config.json'   # private copy of infra\staged\staged.config.example.json
pwsh -File infra\staged\Invoke-StagedDeployment.ps1 -Stage 1 -ConfigPath $cfg          # preview only
pwsh -File infra\staged\Invoke-StagedDeployment.ps1 -Stage 1 -ConfigPath $cfg -Apply   # change, then verify
```

- **Preview** is the default. Bicep stages run `az deployment group what-if`; script stages print
  their plan. Nothing changes.
- **Apply** deploys, then reads the result back from Azure (or Entra). A failed read-back stops
  the stage with `verify_failed: <reason>` and records nothing.
- **State.** Each verified stage writes its outputs to `<config dir>\.staged-state\state.json`.
  A stage refuses to start before the stages it reads (`stage_order`). Read-back evidence is
  written to `.staged-state\evidence\`.
- **Rerun.** Every stage can be rerun; deployments are Incremental with deterministic names.
  Stage 1 alone refuses a non-empty resource group, except to resume and verify a
  `stage1-services` deployment that already succeeded there.
- **Windows.** `az.cmd` passes arguments through cmd.exe, so no argument holds `( ) | & < > ^`;
  bodies and queries travel in files or over REST. Entra display names are limited to letters,
  digits, space, `.`, `_` and `-` for the same reason.
- Use a separate `AZURE_CONFIG_DIR` for the operator profile; the driver never runs `az login`
  or `az account set`.

## Stages and permission boundaries

Operator permissions are the person or pipeline running the stage. Runtime grants are what
the deployed identities receive, and are created only by Stage 4.

| Stage | Entry point | Creates or changes | Operator permission | Verified by read-back |
| --- | --- | --- | --- | --- |
| 0 | driver only | Nothing (read-only) | Reader on the target subscription, RG and backend accounts; directory read of groups | Tenant, empty RG, providers, Flex region, backend deployments, operator |
| 1 | [`main.bicep`](../../infra/staged/main.bicep) | Workspace, Cosmos account, identities, four Flex apps with storage and Insights, optional new APIM | RG Contributor; subscription `resourceGroups/write` to create the RG | Apps with zero settings, keyless storage, no database, zero role assignments |
| 2 | [`stage2-network.bicep`](../../infra/staged/stage2-network.bicep) + VNet integration | VNet, subnets, private DNS zones and links, private endpoints, site VNet integration | Network Contributor on the VNet, private DNS zone write and link, site write | Endpoints Approved with DNS records; every app integrated |
| 3 | [`stage3-schema.bicep`](../../infra/staged/stage3-schema.bicep) | Cosmos database and containers | Cosmos database/container write (Contributor on the account) | Containers and partition keys; no data roles yet |
| 4 | [`stage4-grants.bicep`](../../infra/staged/stage4-grants.bicep) | Azure RBAC, Cosmos SQL role definitions and assignments, APIM grant on Foundry | Role Based Access Control Administrator (or Owner) at each scope, including the Foundry account; Cosmos `sqlRoleDefinitions/write` and `sqlRoleAssignments/write` | Every assignment by principal and scope; none for other principals |
| 5 | driver (Microsoft Graph) | App registrations (new or merged), scopes, roles, preauthorized clients, groups and members | Application owner or Application Administrator; group owner or Groups Administrator | Identifier URI, v2 tokens, `access_as_user` scope |
| 6 | [`stage6-config.bicep`](../../infra/staged/stage6-config.bicep) | App settings, resolver authentication, APIM API/backends/policy, API telemetry, workbook | Site config write, APIM service contributor, workbook write | Setting names per app, resolver `Return401`, API path, policy hash; timers off |
| 7 | driver | Code packages, registry seed, delegated membership snapshot, client file | Function publishing (site write); settings write on the sync app; Graph read of the groups (delegated) | Functions listed, seed outcomes, sync run counts, client validator |
| 8 | driver | Model calls only | A gateway caller identity; Log Analytics read | 401/200/403 matrix, admin endpoints, LLM logs in the workspace |

Stages 2 and 5 do not depend on each other. Publishing (Stage 7) needs Stage 2 when storage is
private: a Flex app writes its package to its own deployment storage through its VNet.

## Configuration file

One JSON file drives every stage:
[`infra/staged/staged.config.example.json`](../../infra/staged/staged.config.example.json).
The driver refuses it until the placeholders are replaced. Sections:

| Section | Read by | Notes |
| --- | --- | --- |
| `tenantId`, `subscriptionId`, `resourceGroup`, `location`, `tags` | all | GUIDs are validated |
| `stage1` | 1 | Exactly the `main.bicep` parameters. Defaults: every public network access `Disabled`, APIM deferred, `StandardV2` |
| `network` | 2 | `mode: create` (VNet, subnets, zones) or `existing` (subnet and zone IDs) |
| `cosmos` | 3, 4 | Database name, capacity mode, custom role names |
| `apim` | 4, 6 | `existing` APIM, or the Stage 1 one; API id, path and display name |
| `backends` | 0, 4, 6 | Foundry accounts, deployment names and inference geography |
| `entra` | 5 | Display names to create, or `existing` app IDs to merge into; `allowAzureCliClient` |
| `groups` | 5, 7 | Project, classification, `groupId` or `groupDisplayName`, members, family policy and budgets |
| `client` | 7 | Project, classification and model aliases for `config.json` |
| `resolver`, `sync`, `reconciler`, `budgetState`, `gateway`, `syncTimerEnabled` | 6 | Same meaning as in the quickstart |
| `rateCard`, `workbook` | 6, 7 | Repository-relative rate card; a new workbook GUID |
| `admin` | 6 | `v3Enabled`; `extraAllowedClientIds` (empty; test clients only) |
| `acceptance` | 8 | Allowed and denied project/model pairs with the expected status |

## Stage notes

### Stage 0: read-only checks
Fails on a provider that is not registered, a region without Flex Consumption, or a backend that
lacks a configured deployment. Registering providers needs subscription Contributor and is not
done by the driver.

### Stage 1: resources only
No settings, schema, grants, network attachment or code. With
`approveNewPublicApimBootstrap: true` a new APIM is created through
[`apim-service.bicep`](../../infra/staged/apim-service.bicep), with public ingress (APIM cannot be
created with public access disabled before a private endpoint exists). `BasicV2` has no VNet
integration; use `StandardV2` when any backend is private. Application Insights adds one
"Failure Anomalies" smart-detector rule per component a few minutes after creation
([Microsoft Learn](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/proactive-failure-diagnostics)).

### Stage 2: network
`mode: create` reuses [`infra/prereqs/network.bicep`](../../infra/prereqs/network.bicep), whose
subnet list is authoritative: run it once per VNet. The driver then attaches each Function App
to the Functions subnet one at a time (parallel joins failed with `ServiceAssociationLinkLease`).
The lab run took 11 minutes, mostly private endpoint creation.

### Stage 3: schema
The container list equals the quickstart's; `adminConfig` is added when the admin app is included.
`tests/Test-StagedStages.ps1` compares the two lists.

### Stage 4: runtime grants
| Principal | Grants |
| --- | --- |
| Each app | Storage Blob Data Owner on its own storage; Monitoring Metrics Publisher on its own Insights |
| Reconciler, admin | Log Analytics Reader on the workspace |
| Resolver | Cosmos Built-in Data Reader on the database |
| Sync | Entitlement writer on `entitlement` and `syncLease`; reader and create-only writer on `projects`; create-only writer on `backends` |
| Reconciler | Reader on `projects` and `entitlement`; state writer on `budgetState`, `aggregateBudgetState`, `reconcilerLease` |
| Admin | Project editor (read, query, create, replace; no delete or upsert) on `projects` and `adminConfig` |
| APIM identity | Cognitive Services User on each Foundry account |

Removing a principal from the configuration does not delete an assignment made earlier.

### Stage 5: Entra
Creates or reuses three registrations: gateway API plus developer sign-in (one app,
`access_as_user`, v2 tokens, public client), resolver API, and admin (`Projects.Manage`,
`CCOF.Projects.Read`/`Write`, SPA redirects for `/api/console` and `/api/console-v3`, assignment
required). For `existing` apps every list is merged: redirect URIs, identifier URIs,
preauthorized clients, scopes and roles keep their current entries. The Microsoft Graph
application permission for unattended sync is not part of this stage; `sync.mode:
delegated-snapshot` needs none ([PERMISSIONS.md](../PERMISSIONS.md), rows 2-3).

`entra.allowAzureCliClient` preauthorizes Azure CLI on the gateway app and adds its client ID to
the gateway policy's delegated clients. Developers can then use `az account get-access-token`
([client modes](../CLIENTS.md)); Stage 8 uses it for its test calls.

### Stage 6: configuration
Application settings are written as a complete set per app; this stage is the only settings
writer, so rerun it rather than editing settings by hand. The resolver accepts only the APIM
identity. Stage 1 owns the resource-log diagnostic settings; Stage 6 adds only the API-level
logger and diagnostic. Timers stay off until `syncTimerEnabled` or `reconciler.timerEnabled` is
set and Stage 6 is rerun.

### Stage 7: code and initial data
Publishes with `az functionapp deployment source config-zip` (the Flex publishing path), seeds
`projects` and `backends` through the sync app's `registrySeed` function (create only), loads group
membership from a delegated snapshot through `snapshotApply`, and writes `config.json` for the
selected project, checked by `client/bin/validate-config.mjs`.

### Stage 8: acceptance
Requires the `acceptance` matrix. Checks: anonymous 401 at the gateway and at the resolver;
each allowed pair 200; each denied pair the expected status; admin root 302 to V3, console 200,
API 401 without a token; LLM logs in the workspace within 15 minutes.

## Recovery

- A failed apply records nothing. Read the deployment operations, fix the cause and rerun the
  same stage; deterministic names make the rerun converge.
- A partially created Stage 1 is resumed only when `stage1-services` succeeded; otherwise empty
  or replace the RG under a separate approval.
- Stage 5 never deletes Entra objects. Stage 4 never removes earlier assignments.
- No recovery step enables public Cosmos/storage access, account keys or anonymous APIs.

## Manual Portal walkthrough

### Evidence and scope

The five Portal images below are existing, middle-masked captures from the earlier manual
guide. They show navigation and forms, not the outcome of a new deployment. Their source
captions and image hashes are in the
[Portal image manifest](images/portal/screenshots.json).
The screenshots in the [staged live report](../STAGED-LIVE-RUN-2026-10-20.md) are separately
labelled command-output captures or Admin console captures; neither is a Portal blade.

On 2026-10-20, Playwright opened the real Azure Portal for both FDPO and Contoso using
the dedicated capture profile. Both redirected to **Sign in to Microsoft Azure**.
No authentication was intercepted, no token was injected and no tenant configuration
was changed. Fresh Portal captures and the Standard v2 runs remain pending sign-in.

| Requested environment | Separate run record | Fresh Portal screenshots |
| --- | --- | --- |
| SASET MSFT FDPO | Pending target confirmation; separate from personal FDPO | Pending FDPO Portal sign-in |
| Personal FDPO | Earlier Basic v2 result exists; Standard v2 not tested | Pending FDPO Portal sign-in |
| Contoso | Standard v2 and directory permission run not tested | Pending Contoso Portal sign-in |

Each run has its own subscription, resource group, configuration directory and state
directory. The current driver does not bind its state file to a subscription or tenant;
sharing `.staged-state` between configurations can return outputs from another run.

### 0. Confirm the directory, subscription and permissions

1. Open [Azure Portal](https://portal.azure.com). The account menu's **Switch directory**
   selects the intended directory. **Subscriptions** shows the subscription name and ID.
   SASET and personal FDPO are different subscriptions in the same tenant.
2. Open the selected subscription's **Access control (IAM) > Check access > View my access**.
   Record the effective Azure role and scope for the operator.
3. Open **Microsoft Entra ID > Roles and administrators**. Record the directory role used
   for registrations, groups and consent; activate eligible access through PIM where required.
   A tenant administrator is not automatically an Azure subscription Owner.
4. Open **Subscriptions > Resource providers**. Check the providers required by Stage 0.
   A denied read is not evidence that a provider or resource is absent.

**Evidence:** directory, subscription, effective Azure role/scope and effective Entra role
are recorded separately. Resource provisioning and consent are not started from the
wrong directory.

### 1. Create and inspect the resources

1. Open **Resource groups > Create**, select the approved subscription, group name and region,
   then **Review + create**. The historical image below shows this form.
2. For the Bicep path, Stage 1 in this guide creates the service resources. For a hand-created
   resource path, the separate
   [Azure Portal-first workbook](AZURE-PORTAL-DEPLOYMENT.md) describes the individual forms.
   These are alternative paths; they do not run over each other's resource names.
3. For the requested new API Management instance, the selected SKU is **Standard v2**,
   not Basic v2 or classic Standard. Record its system-assigned identity from
   **API Management > Identity > System assigned**.
4. Open **Resource group > Deployments > stage1-services** for a Bicep deployment.
   **Deployment details** shows the individual resource operations; **Outputs** contains the
   IDs and principal IDs needed later. A green parent deployment alone is not runtime proof.

![Historical Portal resource-group creation form; not a new deployment result](images/portal/02-2-middle-masked.png)

### Foundry prerequisite: account, deployment and endpoint

The staged templates currently reference an existing Foundry account and deployments.
They do not create a Foundry account, purchase a Marketplace offer, deploy a Claude model,
or create its private endpoint.

1. In the intended subscription, open or create the approved Foundry resource using the
   Microsoft Foundry service. Record the account resource ID and location.
2. Open its Foundry portal and model catalog. Select the approved Claude model.
   The offer's availability, subscription eligibility, Marketplace terms, region and
   model quota must be resolved before a deployment can complete. A directory role alone
   does not prove these prerequisites.
3. Record the exact deployment name, version and inference geography shown by Foundry.
   `backends[].deploymentInferenceGeo` and the project's model allow-list use deployment
   names that actually exist; examples are not evidence of provisioned capacity.
4. Copy the account's actual Anthropic endpoint from its endpoint information. This is not
   a Foundry project URL. The backend URL includes the expected `/anthropic` base path;
   the gateway operation adds `/v1/messages`.
5. For private Foundry, open the account's **Networking > Private endpoint connections**.
   Record its approved private endpoint and DNS configuration. Public access is disabled
   only after the approved private path is verified.

**Evidence still needed:** Foundry resource, Claude deployment details, offer acceptance
where required, endpoint, private endpoint connection, and DNS from the APIM network.

### 2. Connect the caller networks

1. Open the VNet's **Subnets**. Functions and APIM use separate integration subnets.
   Flex Functions use `Microsoft.App/environments`; Standard v2 APIM uses its documented
   integration delegation (`Microsoft.Web/serverFarms`) and an associated NSG.
   The historical Functions form below is a navigation reference.
2. Open each Function App's **Networking > VNet integration** and select the approved
   Functions subnet. Verify each app independently.
3. Open **API Management > Network > Outbound traffic > VNet integration**. Select the
   dedicated APIM subnet. The VNet and Standard v2 APIM must be in the same subscription
   and region; the subnet cannot be shared with another resource.
   [Microsoft's outbound integration guide](https://learn.microsoft.com/en-us/azure/api-management/integrate-vnet-outbound)
   describes the requirements.
4. Open each private endpoint and verify its connection is **Approved**. In
   **Private DNS zones > Virtual network links**, verify the links to the caller VNet.
   The Foundry zone is a separate dependency from the blob and Cosmos zones.
5. Test resolution and connectivity from the real caller network. A Portal DNS record
   or an approved connection alone does not prove this.

**Current implementation gap:** Stage 2 attaches the Function Apps, but does not attach
APIM or create the Foundry endpoint/DNS path. Selecting Standard v2 alone does not
complete these steps. Outbound APIM integration also does not make its ingress private.

![Historical Functions subnet edit form](images/portal/03-4-middle-masked.png)

![Historical private DNS VNet-link form; not a DNS resolution test](images/portal/03-7-middle-masked.png)

### 3. Verify the Cosmos structure

Open **Cosmos DB account > Data Explorer**, where network access and the operator's
data-plane permissions allow it. Compare the database, container IDs and partition keys
with Stage 3 outputs. When Data Explorer cannot reach a private account, the ARM
read-back used by the driver verifies schema without opening public access.
Neither check creates seed documents or grants item access.

### 4. Verify each runtime permission

1. For Azure roles, open the exact target resource's **Access control (IAM) > Role
   assignments**. Filter by the managed identity, check the role name, and check
   **Scope** rather than assuming a subscription-wide assignment is required.
2. On the Foundry account, confirm **Cognitive Services User** for the new APIM
   system-assigned identity. The historical image below shows this view.
3. Compare every app's storage, telemetry and workspace permissions with the
   Stage 4 matrix above. Cosmos item access is a separate permission system.
4. Cosmos SQL role definitions and assignments remain the explicit Bicep/CLI
   operation in Stage 4; the general **IAM** blade is not a replacement for them.

![Historical Foundry IAM view showing Cognitive Services User for APIM](images/portal/07-6-middle-masked.png)

### 5. Verify registrations, membership and consent

1. Open **Microsoft Entra ID > App registrations > gateway application**. Check
   **Expose an API**, its `api://...` URI, `access_as_user`, v2 token configuration,
   and the public-client redirect configuration.
2. Check the separate resolver registration. On the admin registration, check the
   `Projects.Manage` scope, reader/editor app roles and both SPA redirects:
   `https://<admin-host>/api/console` and `https://<admin-host>/api/console-v3`.
3. Open **Enterprise applications > admin application > Users and groups** and verify
   the intended editor/reader assignments. Assignment-required is a separate check.
4. Open each classification group under **Groups > Members** and check the intended
   user's object ID. Membership still needs synchronization to reach the gateway.
5. For unattended sync, the approved Graph application grants are a separate
   privileged operation using `Grant-SyncGraphPermissions.ps1`. Tenant-admin consent
   is not implied by an Azure role. The earlier run used delegated snapshots instead;
   it does not prove unattended consent or timer execution.

![Historical Entra group Members view; not synchronization evidence](images/portal/06-7-middle-masked.png)

### 6-8. Configuration, publishing and acceptance

1. Open each Function App's **Settings > Environment variables** and inspect only the
   reviewed settings. Setting values containing credentials are not part of screenshots.
   The resolver's **Authentication** page must require authentication and restrict its caller.
2. Open **API Management > APIs > Claude API**. Verify the messages operation, backend,
   rendered policy and diagnostic configuration. This check does not edit an existing
   production API.
3. Build/publish, native Cosmos data access, delegated snapshots and client-file validation
   remain the explicit commands in Stages 4 and 7. A Portal-only ZIP upload is not equivalent
   to the documented Flex publishing command.
4. Run the Stage 8 positive and negative cases. Confirm fresh request IDs reach Log Analytics;
   old workspace rows are not evidence of the current test run.
5. Open the real Admin V3 URL, complete Microsoft sign-in, and inspect overview,
   project detail, chargeback and onboarding downloads. A demo-mode browser interception
   does not verify sign-in. Capture the final UI without one.

**Acceptance still needed for each target:** Standard v2 networking, Foundry setup,
actual Azure and Graph permissions, an allowed request, expected denied requests,
fresh correlated telemetry, and genuine signed-in Portal/Admin screenshots.

### Review findings and current verification

| Finding | Source | Status |
| --- | --- | --- |
| Standard v2 selection does not configure APIM outbound VNet integration | `Staged.Resources.ps1`, `Invoke-Stage2` attaches only Function Apps | Unresolved; the APIM Portal step above is a separate operation |
| Foundry provisioning is outside the staged templates | `Invoke-Stage0` reads existing accounts/deployments; Stage 4 grants access | Unresolved; account, model deployment and private connectivity remain prerequisites |
| State is not bound to the deployment target | `Staged.Common.ps1`, `Read-StgState`/`Get-StgStage` use only the state path | Reproduced offline: outputs saved for one synthetic tenant/subscription/RG were returned for another; use separate directories |
| Telemetry acceptance is not tied to this run | `Staged.Application.ps1`, `Invoke-Stage8` counts workspace rows from the previous two hours and finally accepts one request | Unresolved; current request IDs must be correlated before claiming a new-run telemetry pass |

The existing offline Bicep and stage-contract tests pass, including 254 staged checks and
the Stage 1 recursive boundary check. These tests do not establish Portal usability,
Standard v2 networking, tenant permissions, or fresh-run telemetry correlation.

The revised guide was rendered locally and checked in Edge through Playwright: all five
historical Portal images loaded, the manual-walkthrough anchor existed and no page errors
occurred. A broken-image negative control was detected; restoring the image returned all
five to a loaded state. This is documentation validation, not Portal deployment evidence.

## References

- [Live run report, 2026-10-20](../STAGED-LIVE-RUN-2026-10-20.md) and the
  [Stage 1 report](../STAGE1-LIVE-VERIFICATION.md).
- [Bicep deployment permissions](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-cli);
  [role assignments in templates](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-template);
  [Cosmos DB data-plane RBAC](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-setup-rbac);
  [Flex Consumption deployment](https://learn.microsoft.com/azure/azure-functions/deployment-zip-push#deploy-by-using-azure-cli);
  [APIM private endpoints](https://learn.microsoft.com/en-us/azure/api-management/private-endpoint).
- Tests: `tests/Test-StagedStages.ps1` (stage boundaries, negative control, Cosmos contract, driver,
  configuration) and `tests/Test-StagedCustomerDeployment.ps1` (Stage 1).
