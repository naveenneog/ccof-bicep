# Configurable staged deployment

CCOF deploys in nine stages, run one at a time by
[`infra/staged/Invoke-StagedDeployment.ps1`](../../infra/staged/Invoke-StagedDeployment.ps1).
Each stage has its own operator permission boundary, a preview, an apply, and a read-back
verification. All nine stages ran end to end in a new lab resource group on 2026-10-20;
the evidence and screenshots are in the [live run report](../STAGED-LIVE-RUN-2026-10-20.md).

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
