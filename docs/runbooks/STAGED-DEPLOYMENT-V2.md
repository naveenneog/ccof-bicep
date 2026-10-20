# Configurable staged deployment

Stage 1 was deployed and read back in Azure on 2026-10-20. The remaining stages
below describe the agreed separation; this document does not claim that separate
entry points for stages 2-8 have been implemented.

The existing [four-stage runbook](STAGED-CUSTOMER-DEPLOYMENT.md) remains available.
Its stage numbers differ. The resource-only Stage 1 entry point is the same.
The [live report](../STAGE1-LIVE-VERIFICATION.md) records the tested configuration.

## Stages and permission boundaries

Operator permissions and permissions granted to runtime identities are distinct.
Azure Contributor does not grant Azure RBAC assignment rights or Cosmos data access.

| Stage | Work | Operator permission boundary | Exit evidence |
| --- | --- | --- | --- |
| 0 | Read approved inputs, existing resources, subscriptions, regions and policies | Azure Reader on referenced scopes; separately authorized directory reads | Explicit inventory; inaccessible is not absent |
| 1 | New service resources and identities only | Resource-group Contributor, or equivalent resource/deployment actions listed below | Successful provisioning, exact resource and principal inventory, boundary read-back |
| 2 | Network integration, private endpoints, approvals and DNS | Network Contributor on approved networks; DNS-zone write/link and VNet join rights; endpoint approval rights on targets | Connectivity from real caller networks |
| 3 | Cosmos database/container structure | Cosmos database/container management actions on the account | Partition keys, indexing and capacity match approved inputs |
| 4 | Runtime Azure and Cosmos-native access grants | Azure role-assignment rights at each scope; separate Cosmos SQL role-definition/assignment actions | Principal, role, scope and effective access verified |
| 5 | Entra registrations, scopes, app roles, assignments and optional Graph consent | Authorized application owner/administrator and group permissions; appropriate privileged administrator for Graph application consent | Registration and consent handoff, verified token claims |
| 6 | Application settings, APIM configuration, diagnostics and workbook content | Site configuration, APIM and monitoring write rights at selected scopes | Settings/policy read-back; schedules stay disabled |
| 7 | Pinned code packages and approved initial data | Function publishing rights; scoped Cosmos data-write rights from a reachable host | Package hashes, handler registration and seed verification |
| 8 | E2E, negative tests, bounded load and activation | Test identities, telemetry read access and explicit activation rights | Acceptance evidence and rollback handoff |

Stage 1 includes per-service diagnostic settings. Stage 6 covers subsequent
application/APIM telemetry configuration, not a second creation of those settings.
Stages 2 and 5 can progress independently when their dependencies exist.
Private storage/network reachability gates publishing regardless of stage number.

## Stage 1: resources only

Entry point: `infra/staged/main.bicep`. It creates:

- One Log Analytics workspace and one Cosmos account.
- Sync and reconciler user-assigned managed identities.
- Resolver, sync and reconciler Flex Function services, plus admin when enabled.
  Each service has its own plan, storage account, private-access blob container,
  Application Insights component and Function log diagnostic setting.
- An optional new APIM shell, only with explicit public-bootstrap approval.

It does not create application settings, code packages, Cosmos databases, runtime
role assignments, Entra objects, API/backend policies or network attachments.
The shell's required Node runtime and identity-backed deployment storage reference
are platform properties, not a published application.

### Operator permissions

| Scope / operation | Required access |
| --- | --- |
| Existing target RG | `Microsoft.Resources/deployments/*` and read/write actions for the resource types below; RG Contributor is the standard built-in role |
| Resource types | `Microsoft.OperationalInsights/workspaces`, `Microsoft.DocumentDB/databaseAccounts`, `Microsoft.ManagedIdentity/userAssignedIdentities`, `Microsoft.Storage/storageAccounts` and blob service/container children, `Microsoft.Web/serverfarms`, `Microsoft.Web/sites`, `Microsoft.Insights/components`, `Microsoft.Insights/diagnosticSettings` |
| Attaching a user-assigned identity | `Microsoft.ManagedIdentity/userAssignedIdentities/assign/action` on the selected identity; identities in this stage are newly created in the target RG |
| Optional APIM | `Microsoft.ApiManagement/service` read/write and diagnostic-setting write at its scope |
| New RG, if required | Subscription-scope `Microsoft.Resources/subscriptions/resourceGroups/write`; RG creation is separate from the template |
| Unregistered provider, if required | Provider registration permission at subscription scope; no automatic registration in Stage 1 |
| Verification | Read permissions on deployed resources, Cosmos database/SQL-role inventories, app-settings list and role-assignment inventories; some read-back operations use POST/list actions |

No `Microsoft.Authorization/roleAssignments/write` or directory consent is needed
by the Stage 1 template. The lab proof used the existing authorized operator; it
did not establish least privilege by deploying under a newly restricted principal.
Azure Policy and deny assignments can still prevent resource creation.

### Configuration

Both `main.bicepparam` and `main.parameters.example.json` are supported. The
operator uses one private, reviewed parameter set for preview and deployment.

| Parameter | Default / contract |
| --- | --- |
| `prefix` | Required, approved lowercase alphanumeric string, 3-8 characters; suffix derives from RG ID and prefix |
| `location`, `tags` | RG location; empty tags |
| `includeAdmin` | `true`; `false` omits only the new admin service |
| `cosmosCapacityMode` | `serverless`; alternatively `provisioned`; SQL database throughput belongs to schema stage |
| `retentionInDays` | 30, range 30-730 |
| `storageSku` | `Standard_LRS`; alternatively `Standard_ZRS`, subject to region/policy availability |
| `cosmosPublicNetworkAccess`, `storagePublicNetworkAccess`, `functionsPublicNetworkAccess` | `Disabled`; the proof retained all three defaults |
| `maximumInstanceCount`, `instanceMemoryMB` | 40 maximum instances per app, 2048 MB; these are scaling limits, not a reservation of 40 running instances |
| `approveNewPublicApimBootstrap` | `false`; APIM is deferred, not silently created with public ingress |
| `apimPublisherEmail`, `apimPublisherName` | Required approved values only when APIM bootstrap is authorized |
| `apimSku`, `apimUnits` | `StandardV2`, 1; APIM was not deployed in this proof |

### Build, preview and deploy

The target must be a newly approved empty RG. ARM is upsert-based, not an atomic
create-only API. This path is not an update or resume command for a partially
populated RG. Existing environment discovery belongs to Stage 0.

The commands use PowerShell 7.2+. Subscription selection is explicit, and no
`az account set` is required. An isolated `AZURE_CONFIG_DIR` avoids changing a
shared operator profile. Authentication occurs in that profile before live use.

```powershell
$ErrorActionPreference = 'Stop'
$sub = 'REPLACE-approved-subscription-guid'
$rg = 'REPLACE-approved-empty-resource-group'
$parameters = 'REPLACE-private-absolute-path-to-parameters.json'
if ($sub -notmatch '^[0-9a-fA-F-]{36}$' -or
    $rg -notmatch '^[A-Za-z0-9_-]{1,90}$' -or
    -not (Test-Path -LiteralPath $parameters)) { throw 'Approved inputs required.' }
if ($parameters -match '[&|<>^()]') { throw 'Unsupported native argument characters in parameter path.' }
$values = (Get-Content -LiteralPath $parameters -Raw | ConvertFrom-Json).parameters
if ($values.prefix.value -cnotmatch '^[a-z0-9]{3,8}$') { throw 'Invalid prefix.' }
if ($values.approveNewPublicApimBootstrap.value -and
    (-not $values.apimPublisherEmail.value -or -not $values.apimPublisherName.value)) {
    throw 'Approved APIM publisher details required.'
}
az account show --subscription $sub --query '{subscription:id,tenant:tenantId}' -o json
if ($LASTEXITCODE) { throw 'Subscription verification failed.' }
```

```powershell
az bicep build --file infra\staged\main.bicep --stdout | Out-Null
if ($LASTEXITCODE) { throw 'Stage 1 compilation failed.' }
pwsh -NoProfile -File tests\Test-StagedCustomerDeployment.ps1
if ($LASTEXITCODE) { throw 'Stage 1 boundary checks failed.' }
$inventory = az resource list --subscription $sub -g $rg -o json
if ($LASTEXITCODE) { throw 'Target inventory could not be read.' }
if (@(($inventory -join "`n" | ConvertFrom-Json)).Count) { throw 'Target RG is not empty.' }
az deployment group what-if --subscription $sub -g $rg -n stage1-services `
    --template-file infra\staged\main.bicep --parameters "@$parameters" `
    --no-pretty-print --output json
if ($LASTEXITCODE) { throw 'Preview failed.' }
```

The preview must contain only approved new resources, no changes to existing
resources, and no network/grant/schema resources. Review the entire preview.
`--no-pretty-print` is necessary for machine-readable what-if JSON; `-o json`
alone did not produce JSON in the tested Azure CLI.

```powershell
# After reviewing the preview, recheck immediately before applying.
$inventory = az resource list --subscription $sub -g $rg -o json
if ($LASTEXITCODE) { throw 'Target inventory failed.' }
if (@(($inventory -join "`n" | ConvertFrom-Json)).Count) { throw 'Target changed; stop.' }
az deployment group create --subscription $sub -g $rg -n stage1-services `
    --mode Incremental --template-file infra\staged\main.bicep `
    --parameters "@$parameters" --output json
if ($LASTEXITCODE) { throw 'Inspect deployment operations; do not blindly retry.' }
```

### Outputs, verification and recovery

Outputs include workspace ARM/customer IDs, Cosmos ARM ID/endpoint, each service's
app/plan/storage/Insights IDs, hostnames and principal IDs, and APIM's explicit
deferred/deployed state. These are an inventory, not an application-ready flag.

Read-back checks cover all deployed services, not one representative app:
public ingress Disabled, no VNet attachment, Node 22 Flex runtime, real principal
IDs, zero application settings, private/keyless storage with firewall Deny and no
bypass, private deployment containers and diagnostic targets. Cosmos has local
auth disabled, no SQL databases and no data-role assignments. Azure grants within
the new RG are absent; inherited operator permissions are not counted as stage
outputs. See the [live evidence](../STAGE1-LIVE-VERIFICATION.md).

Expected inventory with admin included: 20 template resources, plus one
`Failure Anomalies - <app>-ai` smart-detector alert rule per Application Insights
component, created minutes later by the Azure Smart Alerts platform identity
([Microsoft Learn](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/proactive-failure-diagnostics)).
Count only those as expected extras. Run `az` queries without parentheses in
`--query` on Windows (for example count in PowerShell), because `az.cmd` passes
arguments through cmd.exe.

If deployment fails, read parent and nested operations and retain the inventory.
A nonempty RG blocks the create-new procedure. A recovery plan must explicitly
target the partially created resources and preserve the same names/parameters;
changing the prefix creates a different stack. Automatic deletion, public access,
storage keys and hidden grants are not recovery actions.

After successful deployment the service shells remain nonfunctional until their
later-stage dependencies are configured. Retained lab resources can incur charges.
Cleanup or promotion is a separately approved operation.

## References

- [Bicep deployment permissions](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-cli).
- [Azure role-assignment permissions](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-template).
- [APIM private endpoints and public-access constraints](https://learn.microsoft.com/en-us/azure/api-management/private-endpoint).
- Source: `infra/staged/main.bicep`, `function-service.bicep`, and
  `tests/Test-StagedCustomerDeployment.ps1`.
