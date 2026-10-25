# 1. Deployment runbook

Applies to the single-region staged deployment and Admin **3.2.0** on branch `feat/admin-console-v2`.
This guide covers a same-tenant gateway with private Foundry backends, four Function Apps,
Cosmos, the admin console and the chargeback workbook.
[Admin operations](ADMIN-OPERATIONS.md) and [user onboarding](USER-ONBOARDING.md) follow deployment.

**Release availability:** the Admin 3.2.0 fixes were verified locally and deployed to the Contoso lab on
22 October 2026. They are on branch `feat/admin-console-v2`; `main` holds the later Admin 3.3 and
disaster recovery design.
The source commit, package hashes, configuration and stage state identify a deployment.

## Readiness and the one-hour target

The target is a one-hour execution window once identity approvals, model capacity, networking,
tooling and operator access are ready. It is not a measured greenfield deployment guarantee.
APIM provisioning, Marketplace eligibility, PIM activation, consent, DNS propagation and private
endpoint approvals can exceed that window.

The 22 October Contoso **code-only Stage 7 rerun took 1,364 seconds (22.7 minutes)**, including
four packages, seed verification and a membership snapshot. Its Stage 8 took 21 seconds, but had
no successful model-inference test because the sandbox cannot purchase Claude. The earlier
[Fabrikam run](../STAGED-STDV2-RUNS-2026-10-20.md) includes admitted-model 200 responses and correlated
telemetry. These are different acceptance results, not interchangeable proof.

| Before the execution window | Ready when |
| --- | --- |
| Approved source and tools | PowerShell 7, Node 22+, npm, git, Azure CLI/Bicep; locked dependencies restored; approved commit recorded |
| Entra apps and groups | The tables below are completed with actual IDs; app owners can run the Stage 4 merge/read-back |
| Resource identities | Stage 1 inventory exists if identities and their grants must be ready before the clock starts |
| Azure permissions | Stage owners have active access at every target scope, including network and Foundry subscriptions |
| Foundry | Approved Claude offer, regional availability, quota and exact deployments already verified |
| Network | Address ranges reserved, routes/egress approved, endpoint approvers available, VDI DNS path working |
| Change controls | Reviewed configuration, rollback packages, approved APIM ingress choice and retained stage state |

A practical 60-minute reservation is 10 minutes for preflight/handoffs, 15 for schema/grants/
configuration/network read-back, 25 for publication/initialization and 10 for functional
acceptance. This assumes resource provisioning and network construction have already completed.
Fresh resources remain part of the full procedure below, but outside that readiness assumption.

## 1. Entra administrator handoff

Names below are naming recommendations, not lookups by display name. The handoff records the
tenant ID, application/client IDs, application **object** IDs, enterprise-application/service-
principal object IDs, scope IDs, role IDs and group object IDs separately.

### App registrations

| Suggested name | Why / where used | Configuration in Entra admin center |
| --- | --- | --- |
| `CCOF Gateway <environment>` | Developer sign-in **and** APIM JWT audience; the same application serves both roles | Single tenant. Identifier URI `api://<gateway-client-id>`. Enabled delegated scope `access_as_user`. Manifest `api.requestedAccessTokenVersion: 2`. **Authentication > Mobile and desktop applications:** `http://localhost` and `ms-appx-web://Microsoft.AAD.BrokerPlugin/<gateway-client-id>`. `https://login.microsoftonline.com/common/oauth2/nativeclient` is also used by the existing prerequisite guide. Public client flows enabled for an approved device-code fallback; no secret and no implicit grants. **Expose an API > Authorized client applications:** the gateway app itself for `access_as_user`, and Microsoft Azure CLI for the acceptance path below. |
| `CCOF Resolver API <environment>` | Internal resolver API; only APIM's managed identity calls it | Separate single-tenant app. URI `api://<resolver-client-id>`. Manifest token version 2. Enterprise application exists. No public-client redirects, SPA redirect, secret or developer delegated scope. Stage 5 pins its audience and the APIM application ID **and** principal ID in Function authentication. |
| `CCOF Admin <environment>` | Admin SPA and admin API | Single tenant. URI `api://<admin-client-id>`. Enabled **Admin-consent** delegated scope `Projects.Manage`. Token version 2. App roles `CCOF.Projects.Read` and `CCOF.Projects.Write`, enabled, allowed member type `Users/Groups` (`allowedMemberTypes: ["User"]` in the manifest). SPA redirects `https://<actual-admin-host>/api/console` and `https://<actual-admin-host>/api/console-v3`. Preauthorize this app for `Projects.Manage`, and Azure CLI when used for acceptance. Enterprise app **Properties > Assignment required = Yes**; intended readers/editors assigned the corresponding app role. No client secret. |

Microsoft Azure CLI application ID: **`04b07795-8ddb-461a-bbee-02f9e1bf7b46`**.
For the command-line acceptance route it needs both scope preauthorization and the runtime
allowed-client entry. In the staged JSON these are `entra.allowAzureCliClient: true` for the
gateway and `admin.extraAllowedClientIds: ["04b07795-8ddb-461a-bbee-02f9e1bf7b46"]` for admin.
The Admin 3.2.0 fix preauthorizes the latter during Stage 4. This does not assign the operator
an admin role or bypass Conditional Access.

Portal path: **Microsoft Entra ID > App registrations > application > Expose an API**.
The following real lab capture shows the scope and authorized clients, with GUID middles masked.
Names in screenshots are navigation examples, not customer values.

![Gateway scope and authorized clients, Portal capture 21 October 2026](images/staged-portal/04-gateway-expose-api.png)

**App registration > Authentication** shows public-client redirects. This historical
reference includes an additional Desktop browser callback from that lab; only the callbacks
used by the approved client flow are part of a customer's configuration.

![Historical public-client Authentication view; not the admin SPA redirect configuration](images/portal/06-4-middle-masked.png)

Portal path: **App registrations > CCOF Admin > App roles**.

![Admin read and write app roles](images/staged-portal/04-admin-roles.png)

The two admin SPA hostnames can be finalized only after the actual Function hostname is known.
Precreating an app is not the same as completing its redirects.
Source: [`Staged.Entra.ps1`](../../infra/staged/Staged.Entra.ps1) and
[Entra prerequisite details](../QUICKSTART-PREREQUISITES.md).

### Security groups

| Object | Configuration / ownership | Used by |
| --- | --- | --- |
| `CCOF-<project>-STD`, `CCOF-<project>-PRM`, other approved classifications | Security groups with accountable owners; record each object ID and direct user members. One distinct group per classification in a project. No nested-group expansion. | Sync maps direct membership to project/classification entitlements. |
| Admin readers | People or an approved role-assigned group; assigned `CCOF.Projects.Read` on the **admin enterprise app** | Admin read access, not model access |
| Admin editors | People or an approved role-assigned group; assigned `CCOF.Projects.Write` | Project/budget/limit/retirement changes |

The staged `entra.adminEditors` / `adminReaders` lists are principal object IDs; `@me` is a lab
convenience. A role-assigned admin group is distinct from a model-entitlement group.

### Managed identities and required Graph grants

Managed identities are Azure resources/service principals, not extra app registrations to
create under **App registrations**.

| Identity | Creation / record | Required access |
| --- | --- | --- |
| APIM | System assigned, **APIM > Managed identities > System assigned > On**; record principal ID and its service-principal application ID | Cognitive Services User on each same-tenant Foundry account; sole caller allowed by resolver authentication |
| Resolver Function | System assigned, created with the Function App | Own storage/telemetry, Cosmos database read |
| Sync Function | User-assigned identity created by Stage 1, attached to sync; record resource ID, client ID and principal ID | Cosmos entitlement/lease writer, project read/create, backend create, and `adminConfig` reader; own storage/telemetry |
| Reconciler Function | User-assigned identity created by Stage 1, attached to reconciler | Cosmos state writes, project/entitlement reads, Log Analytics read, own storage/telemetry |
| Admin Function | System assigned, created with the Function App | Project and `adminConfig` read/query/create/replace; Log Analytics read; ARM Reader on configured inventory scopes; Graph permissions below |

**Current-template boundary:** `main.bicep` creates the two user-assigned identities; it has no
parameter for importing arbitrary precreated identities. Resolver/admin/APIM system identities
exist only after their parent resources exist. For a requirement that *all identities and their
consent exist beforehand*, Stage 1 and the consent handoff occur in the readiness phase.
Reusing differently named identities needs a separately reviewed template change, not fabricated state.

| Recipient | Microsoft Graph **application** permissions for this operating baseline | Grant owner / setting |
| --- | --- | --- |
| Sync user-assigned identity | `GroupMember.Read.All`, `User.Read.All`, `Application.Read.All` (the supplied grant helper's baseline, including service-principal member support) | Privileged Role Administrator or Global Administrator grants app roles to the exact managed-identity service principal. `sync.mode: application-permission`; timer enabled only after a successful group read. |
| Admin system-assigned identity | `GroupMember.Read.All` for group search; `User.Read.All` for current user names | Tenant admin consent on this identity. `ADMIN_GRAPH_ENABLED=true` and `ADMIN_USER_NAMES_ENABLED=true`. These permissions do not belong on the SPA registration. |

These Graph grants are required for the full unattended/group-search/user-name setup described here,
not an optional follow-up. Stage 4 does not grant them. Azure subscription Owner is not directory
consent authority. The existing grant procedure and read-back are in
[VDI upgrade section 2](../ADMIN-V3-VDI-UPGRADE.md#2-grant-the-graph-permission-manually) and
[`Grant-SyncGraphPermissions.ps1`](../../infra/quickstart/Grant-SyncGraphPermissions.ps1).

`delegated-snapshot` is the explicitly different mode used by the lab: a signed-in operator reads
groups and applies a snapshot. Its timer remains off. It is not automatic ongoing membership
synchronization and does not prove the Graph application grants work.

## 2. Network handoff

Production default is `network.mode: verify`: the customer builds the network and Stage 6
only checks it. `existing` allows the driver to create endpoints/integrations in approved
subnets; `create` also creates a VNet and is for a new lab only.

| Component | Suggested reservation | Required configuration |
| --- | --- | --- |
| VNet | Approved non-overlapping CIDR, for example `10.64.0.0/16` | APIM and integration VNet in the same subscription/region. The current verifier expects the configured subnets in one VNet. |
| APIM integration subnet | Dedicated `/24` suggested; documented minimum `/27` | `Microsoft.Web/serverFarms` delegation, NSG attached; only this Standard v2 APIM uses the subnet. Basic v2 cannot provide this private-backend integration. |
| Flex Functions integration subnet | `/24` planning example; minimum `/27`, capacity review for scaling | `Microsoft.App/environments` delegation, not `Microsoft.Web/serverFarms`. Separate from APIM and private endpoints. |
| Private-endpoint subnet | Undelegated `/24` planning example | Endpoint capacity for four blob stores, Cosmos, Foundry and any approved private ingress endpoints; policy and routing reviewed by network team |
| VDI / private Cloud Shell host | Existing reachable subnet/path | DNS and HTTPS reachability to admin, APIM and publishing endpoints. A normal public Cloud Shell session is not automatically in this VNet. |

| Private endpoint target | Subresource | Private DNS / validation |
| --- | --- | --- |
| Cosmos account | `Sql` | `privatelink.documents.azure.com`; hostname resolves to actual endpoint IP(s), including regional records |
| Each Function's storage account | `blob` | `privatelink.blob.core.windows.net`; own deployment/host blob access |
| Each private Foundry account | `account` | Zone group includes `privatelink.cognitiveservices.azure.com`, `privatelink.openai.azure.com`, `privatelink.services.ai.azure.com` |
| Private Function ingress, when required | `sites` | `privatelink.azurewebsites.net`, including site and SCM records as applicable to the actual publishing path |
| Private APIM ingress, when required | Approved APIM inbound endpoint | `privatelink.azure-api.net`; separate from outbound VNet integration |

All connections show **Approved**. Private DNS zones link to the caller VNet, or resolve through
the approved hub resolver/forwarder. On-premises/VDI DNS needs forwarding; an A record visible in
the Portal is not a successful client resolution test. `NxDomainRedirect` is a reviewed choice
for shared Foundry zones, not a replacement for missing records.

Outbound integration does **not** make APIM or a Function private inbound.
The current `existing`/`create` network module configures backend/storage private paths, not
every ingress endpoint in this table. Private ingress is customer-owned work in `verify` mode.
The screenshots below show public inbound lab settings and must not be copied as production policy.

![APIM outbound integration with public inbound access in the lab](images/staged-portal/06-apim-network.png)

![Function networking in the public-ingress lab; production requires the approved inbound design](images/staged-portal/06-function-networking.png)

![Private DNS VNet link](images/staged-portal/06-dns-links.png)

| Traffic | Required path |
| --- | --- |
| Clients to gateway, VDI to admin/SCM | HTTPS 443 through approved public/private ingress and IP controls |
| APIM to resolver/Foundry | HTTPS 443; private DNS/routes when those targets are private |
| Functions to blob/Cosmos | HTTPS 443 and required Cosmos transport ports for the configured client; validate the real runtime path |
| Sync/admin to Microsoft Graph | Approved HTTPS egress to Graph and identity endpoints |
| Reconciler/admin to Log Analytics; all apps to telemetry | Approved HTTPS egress to their configured query/ingestion endpoints |
| DNS | UDP/TCP 53 to the approved resolver |

Explicit NAT/firewall egress is the production planning assumption for private subnets.
The sample lab network's permissive outbound defaults and classic APIM-style NSG entries are
not a Standard v2 production security specification. Inbound NSG rules on a v2 **outbound
integration** subnet do not filter public gateway clients; IP filtering belongs at the actual
gateway/edge policy. A customer's IP allow-list can be placed at APIM **All APIs** scope with
reviewed inheritance, rather than pasting the large generated Claude policy into a size-limited editor.

Sources: [APIM outbound requirements][apim-network], [Flex networking][flex-network],
[private DNS zone values][dns], and
[`Test-NetworkConfiguration.ps1`](../../scripts/manual/Test-NetworkConfiguration.ps1).
That script inspects ARM configuration; it does not prove in-VNet DNS, egress or model inference.

## 3. Private JSON handoff

There is one deployment form: [`staged.config.example.json`](../../infra/staged/staged.config.example.json).
A completed private copy travels with `.staged-state` between authorized stage owners.
Tokens, keys and secrets are not handoff fields.

This is an **excerpt to merge into the full form**, not a standalone deployment file:

```json
{
  "entra": {
    "existing": {
      "gatewayAppId": "REPLACE-GATEWAY-CLIENT-GUID",
      "resolverAppId": "REPLACE-RESOLVER-CLIENT-GUID",
      "adminAppId": "REPLACE-ADMIN-CLIENT-GUID"
    },
    "allowAzureCliClient": true,
    "adminEditors": ["REPLACE-EDITOR-OBJECT-GUID"],
    "adminReaders": ["REPLACE-READER-OBJECT-GUID"]
  },
  "admin": {
    "v3Enabled": true,
    "extraAllowedClientIds": ["04b07795-8ddb-461a-bbee-02f9e1bf7b46"]
  },
  "sync": { "mode": "application-permission" },
  "syncTimerEnabled": false
}
```

Each existing `groups[]` entry carries `groupId`, project/classification, backend ID, model
allow-list, limits and budgets. The resource handoff is the real Stage 1 inventory in
`.staged-state\state.json`: `names`, `principals`, `clientIds`, Cosmos endpoint and APIM IDs.
It is not an arbitrary `created-apps.json` import. Stage 4 **merges** app configuration even
with `entra.existing`; its operator still needs app ownership/write permission.

## 4. Permission-separated execution

The tested driver retains stages **0-8**. In particular, Stage 2 is schema and Stage 5 is
configuration; renumbering them would make existing state and recovery instructions incorrect.

| Stage | Owner permission | Changes and gate |
| --- | --- | --- |
| 0: checks | Resource/directory read | Tenant/subscription, providers, Flex region, actual backend deployments |
| 1: resources | RG Contributor; RG creation at subscription if needed | Cosmos/workspace, four Flex apps/storage/Insights, identities, approved new APIM/Foundry. No schema/settings/grants/network/code. New APIM public bootstrap requires explicit approval. |
| 2: schema | Cosmos ARM database/container write | Database and containers, partition-key read-back |
| 3: access | RBAC Administrator/Owner at target scopes; Cosmos SQL role definition/assignment write separately | Runtime grants listed below; exact principal/scope read-back |
| 4: Entra merge | App owner/administrator, group membership authority; app-role assignment authority where required | Existing apps/groups reconciled with approved configuration; scope/preauthorized-client read-back |
| 5: configuration | Site config/auth write, APIM service contributor, workbook write | Settings, resolver authentication, APIM API/backends/rendered policy/diagnostics, workbook |
| 6: network verification | Read on network/endpoint/DNS/app scopes | Customer-built paths checked; no network changes with `verify` |
| 7: publication/data | App publishing and sync settings write; delegated Graph group read; telemetry query access | Four packages, create-only seed, initial delegated membership snapshot, validated client file |
| 8: acceptance | Authorized gateway caller and telemetry read | Positive/negative calls, admin authentication and request-correlated logs |

The production sync can use application permissions while Stage 7 still uses a delegated
snapshot for its initial load. Its operator therefore needs group-read consent too.
PIM roles and profiles belong to each operator, not to a shared all-powerful deployment identity.

For each full-setup admin integration, the post-Stage-5 settings handoff also records:

| Setting | Value |
| --- | --- |
| `ADMIN_GRAPH_ENABLED` | `true`, after `GroupMember.Read.All` consent |
| `ADMIN_USER_NAMES_ENABLED` | `true`, after `User.Read.All` consent |
| `ADMIN_RESOURCE_IDS` | Comma-separated APIM/Foundry ARM IDs approved for inventory |
| `ADMIN_DISCOVERY_SCOPES` | Approved subscription/RG ARM scopes for inventory discovery, where used |
| `ADMIN_CONFIG_CONTAINER` | `adminConfig`; Stage 5 sets this |
| `ADMIN_CLIENT_ID`, `ADMIN_GATEWAY_URL`, `ADMIN_PROJECT_HEADER` | Actual developer app, gateway base and selector header for generated client files; Stage 5 derives these |
| `SYNC_LIMITS_CONTAINER` on sync | `adminConfig`; Stage 5 sets it when admin exists |

The inventory settings scope what the admin API queries; matching ARM Reader access is still
required. Feature switches and extra inventory settings are not all populated by the driver.

### Runtime grants applied by Stage 3

| Principal | Role / scope |
| --- | --- |
| Each app | Storage Blob Data Owner on its own storage; Monitoring Metrics Publisher on its own Insights |
| Resolver | Cosmos Built-in Data Reader at database scope |
| Sync | Custom entitlement writer on `entitlement` and `syncLease`; reader/create-only writer on `projects`; create-only writer on `backends`; Data Reader on `adminConfig` when admin exists |
| Reconciler | Cosmos read on `projects`/`entitlement`; custom state writer on `budgetState`, `aggregateBudgetState`, `reconcilerLease`; Log Analytics Reader |
| Admin | Cosmos project editor on `projects` and `adminConfig`, read/query/create/replace, no delete/upsert; Log Analytics Reader |
| APIM | Cognitive Services User on each same-tenant Foundry account |

Admin ARM inventory Reader and Microsoft Graph app-role grants are separate prerequisites.
Cosmos data-plane roles are not the generic Cosmos account IAM Contributor role.
Definition: [`stage3-grants.bicep`](../../infra/staged/stage3-grants.bicep).

![Foundry IAM filtered to the APIM managed identity](images/staged-portal/03-foundry-iam.png)

### PowerShell session and stage commands

Commands below use Windows PowerShell 7 paths. **Cloud Shell > PowerShell** runs the same
`pwsh -File` driver, with its own host-native checkout/input paths. Cloud Shell sessions do not
share this Windows filesystem. A private VDI or VNet-connected Cloud Shell is required when
publishing endpoints are private; ordinary Cloud Shell can still perform authorized ARM/Graph stages.

```powershell
$ErrorActionPreference = 'Stop'
Set-Location 'C:\approved\ccof-bicep'
$repo = (Get-Location).Path
$cfg = 'C:\private\ccof\staged.config.json'
$state = 'C:\private\ccof\.staged-state'
$c = Get-Content $cfg -Raw | ConvertFrom-Json
$env:AZURE_CONFIG_DIR = Join-Path $HOME '.azure-ccof-deployment'
az login --tenant $c.tenantId
if ($LASTEXITCODE -ne 0) { throw 'Sign-in failed.' }
$accountText = az account show --subscription $c.subscriptionId -o json
if ($LASTEXITCODE -ne 0) { throw 'Subscription read failed.' }
$account = $accountText | ConvertFrom-Json
if ($account.tenantId -ine $c.tenantId) { throw 'Wrong tenant.' }
git rev-parse HEAD
```

The driver supplies explicit subscriptions; it does not call `az account set`.
Windows `az.cmd` re-parses shell metacharacters. Filled argument values containing
`( ) | & < > ^` are refused; JSON request bodies use files or native REST helpers.

For each stage, the authorized owner runs preview, reviews it, then separately applies.
The following single stage-number variable is changed explicitly at each handoff:

```powershell
$stage = 0
$driver = Join-Path $repo 'infra\staged\Invoke-StagedDeployment.ps1'
pwsh -NoProfile -File $driver -Stage $stage -ConfigPath $cfg -StateDirectory $state
if ($LASTEXITCODE -ne 0) { throw 'Preview/check failed.' }
```

```powershell
pwsh -NoProfile -File $driver -Stage $stage -ConfigPath $cfg -StateDirectory $state -Apply
if ($LASTEXITCODE -ne 0) { throw 'Apply/read-back failed; retain state for recovery.' }
```

Order: `0`, `1`, `2`, `3`, `4`, `5`, `6`, `7`, `8`. Stages 2-5 need ARM/Graph rather than
Cosmos data-plane connectivity. The customer can prepare networking after resources exist,
while those stages run. One state folder belongs to one environment. Only one Stage 7 runs
per checkout; concurrent dependency restores/publishing are refused.

### Production activation and acceptance

1. The admin identity's Graph grants and inventory Reader access are read back.
   `ADMIN_GRAPH_ENABLED` and `ADMIN_USER_NAMES_ENABLED` are set on the admin app.
   Stage 5 writes a **complete settings set** and currently does not preserve these manually
   added feature switches; reapplication includes restoring the approved switches afterwards.
2. Application-permission sync is tested with its required Graph roles and actual group reads.
   `syncTimerEnabled` then becomes `true` in the private form and Stage 5 is reapplied.
   `reconciler.timerEnabled` is enabled only when its ledger/rate-card/budget prerequisites pass.
3. Stage 6 succeeds and DNS/TLS is checked from actual APIM/Functions/VDI caller paths.
   No firewall/PNA/key policy is weakened for publication.
4. Stage 7 publishes the code. The seed is create-only; an existing different project causes
   refusal rather than overwriting admin changes.
5. Stage 8's `acceptance.allowed` contains a real admitted project/model expected to return 200.
   A matrix containing only denied cases is insufficient model acceptance.
6. Evidence contains anonymous 401, admitted 200, denied model/project 403, request-correlated
   usage telemetry, current sync/reconciler success, reader/editor separation, an audited test
   edit and a complete client export.

Contoso passed the applicable structural/negative checks, including the 3.2 retirement and
removal-limit paths. Its Marketplace restriction remains an explicit **inference acceptance
block**, even though Stage 8 itself succeeds with no allowed calls.

## 5. Recovery and handover

| Failure | Recovery boundary |
| --- | --- |
| `stage_order`, `stage_config_changed`, `stage_dependency_changed` | Correct the real prerequisite/configuration and rerun affected stages; state is not manually fabricated |
| Partial Stage 1 | Review deployment operations and exact resource ownership before retry; no RG deletion/reset |
| Network verification failure | Resolve endpoint/DNS/integration/egress in the approved network; no public-access workaround |
| Consent/role denial | Correct the exact identity/scope with the responsible access owner; wait for propagation and retest |
| Package/host failure | Retained app-specific ZIP, hash, settings and function-registration evidence; rollback only the affected app |
| Seed differs from existing data | Reviewed admin edit or new project; no blind upsert |

Handover contains the approved commit, hashes, completed JSON, state/evidence, actual resource IDs,
network owner, Graph/RBAC approvals, timer schedules, successful positive/negative calls and
app-specific rollback packages. Handoff files remain in restricted storage, outside public git.

## References

- [Driver contract and detailed Portal walkthrough](STAGED-DEPLOYMENT-V2.md).
- [Live Standard v2 results and limits](../STAGED-STDV2-RUNS-2026-10-20.md).
- [3.2 fixes and live test summary](../CHANGELOG.md).
- [Admin identity Graph consent and app-specific publishing](../ADMIN-V3-VDI-UPGRADE.md).
- [Network architecture](../NETWORK.md); [client identity contract](../CLIENTS.md).
- Microsoft: [API exposure][expose], [managed-identity app roles][mi-roles],
  [private Cloud Shell][cloud-shell], [APIM outbound networking][apim-network],
  [Flex networking][flex-network], [private DNS][dns].

[expose]: https://learn.microsoft.com/entra/identity-platform/quickstart-configure-app-expose-web-apis
[mi-roles]: https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/assign-app-role-managed-identity-powershell
[cloud-shell]: https://learn.microsoft.com/azure/cloud-shell/vnet/overview
[apim-network]: https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound
[flex-network]: https://learn.microsoft.com/azure/azure-functions/functions-create-vnet
[dns]: https://learn.microsoft.com/azure/private-link/private-endpoint-dns
