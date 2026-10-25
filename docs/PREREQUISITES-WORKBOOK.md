# D1 prerequisite resources workbook

> **Historical.** This describes the earlier D1-D3 deployment flow. The current prerequisites are in the [deployment runbook](runbooks/DEPLOYMENT-RUNBOOK.md#1-entra-administrator-handoff).

Stage D1 of the deployment (`docs/PILOT.md` C-9, `docs/DEPLOYMENT-STAGES.md`). The customer's
infrastructure teams create the resources below, in the Azure portal or with the optional Bicep of
`infra/prereqs`. Then `scripts/Record-Prerequisites.ps1` reads each resource, checks it against the
decisions, and records its id. The later stages use only recorded ids.

No step here grants a role or sets an application setting: stage D3 grants every role from data,
and stage D2 deploys every setting. Each step's screenshot is captured from a live environment by
WP-SHOTS, annotated, with ids and names of people redacted.

## Before you start

| Item | Where it comes from |
|---|---|
| The D0 decisions (tier, units, zones, capacity mode, retention, Flex sizing, storage redundancy) | WP-HADEC's Stage 0 export, `kind: ccof.stage0.availability`, named in the answers as `availabilityFile` or inline as `availability` |
| Names, network, publisher and app registration ids | The answers file, validated against `config/core.answers.schema.json` (sections listed in `x-ccof-stages.D1`) |
| Policy in the target subscription | Read before you start: where policy forces private access (as in the Contoso proof of concept, `docs/DEPLOYMENT-GUIDE.md`, Troubleshooting), create the network of steps D1-03 to D1-05 |

Check the answers before creating anything. This makes no Azure call:

```powershell
pwsh ./scripts/Record-Prerequisites.ps1 -Action Plan -AnswersPath <answers.json> -CheckpointPath <checkpoint.json>
```

It lists every missing decision, or writes `d1.parameters.json` in the answers' output directory and
prints the optional Bicep commands, the role preflight first (Role preflight, after D1-19).

## Who does what

| Steps | Performed by | Role and scope (`docs/DEPLOYMENT-GUIDE.md`, People and roles) |
|---|---|---|
| D1-01, D1-02 | Platform deployer | Contributor on the subscription (resource providers, resource group) |
| D1-03 to D1-15 | Infrastructure team | Contributor on the resource group; Network Contributor on the VNet in network mode `existing` |
| D1-16 to D1-18 | Entra application administrator | Cloud Application Administrator or Application Administrator, or none while "Users can register applications" is Yes |
| D1-19 | Platform deployer | Reader on the resource group and the network; Microsoft Graph read of applications |

## Steps

Each step lists its inputs (answer paths), the portal path, the optional Bicep, and how it is
verified. `Record-Prerequisites.ps1 -Action Record` repeats every verification.

### D1-01 Resource providers

- **Inputs:** `target.subscriptionId`, `target.resourceProviders`.
- **Portal:** Subscriptions → the subscription → Settings → Resource providers. Register
  Microsoft.ApiManagement, Microsoft.Web, Microsoft.App, Microsoft.DocumentDB, Microsoft.Network,
  Microsoft.OperationalInsights, Microsoft.Insights, Microsoft.Storage and Microsoft.ManagedIdentity.
  Microsoft.App is needed by Flex Consumption's VNet integration, and Microsoft.Web by APIM v2's
  (`docs/DEPLOYMENT-GUIDE.md`, Step 1 and Troubleshooting).
- **Command:** `az provider register --namespace <namespace> --subscription <id>`.
- **Verify:** `az provider show --namespace <namespace> --subscription <id> --query registrationState` reads `Registered`.

> Screenshot D1-01: pending capture (WP-SHOTS).

### D1-02 Resource group

- **Inputs:** `target.resourceGroup.name`, `target.location`, `target.tags`. Skip in mode `existing`.
- **Portal:** Resource groups → Create.
- **Bicep:** `az deployment sub create --subscription <id> --location <region> --template-file infra/prereqs/resource-group.bicep --parameters name=<rg> location=<region> tags=@<tags.json>`.
- **Verify:** the group exists in `target.location`.

> Screenshot D1-02: pending capture (WP-SHOTS).

### D1-03 Network security group for the APIM subnet

- **Inputs:** `network.create.apimNsgName`. Network mode `create` only.
- **Portal:** Network security groups → Create, then Settings → Inbound and Outbound security
  rules: the nine rules of `infra/prereqs/network.bicep` (Microsoft's documented minimum for APIM
  VNet integration, as in `infra/poc/main.bicep`). APIM creation fails without an NSG on its subnet
  (`NetworkSecurityGroupNotFound`, 2026-10-09).
- **Bicep:** part of `infra/prereqs/network.bicep`.
- **Verify:** the NSG is attached to the APIM subnet.

> Screenshot D1-03: pending capture (WP-SHOTS).

### D1-04 Virtual network and subnets

- **Inputs:** `network.create.vnetName`, `.addressSpace`, `.subnets.apim`, `.privateEndpoints`,
  `.functions`, `.runner` (null for none). In mode `existing`, the ids in `network.existing`.
- **Portal:** Virtual networks → Create → IP addresses, then Settings → Subnets:
  - APIM subnet: NSG of D1-03, delegation `Microsoft.Web/serverFarms` (APIM v2 outbound integration);
  - private endpoint subnet: no delegation;
  - Functions subnet: delegation `Microsoft.App/environments`, not `Microsoft.Web/serverFarms`
    (live ARM error, 2026-10-09). The three Flex apps share it;
  - optional runner subnet, for a temporary private runner (onboarding Stage 3, the sync's snapshot apply).
- **Bicep:** `infra/prereqs/network.bicep`. Its subnet list is authoritative: do not re-run it after
  day-2 networking (D5) has added subnets.
- **Verify:** delegations as above.

> Screenshot D1-04: pending capture (WP-SHOTS).

### D1-05 Private DNS zones

- **Inputs:** none beyond the VNet. In mode `existing`, `network.existing.privateDnsZoneIds`.
- **Portal:** Private DNS zones → Create `privatelink.documents.azure.com` and
  `privatelink.blob.core.windows.net`; for each, Virtual network links → Add the VNet, auto-registration off.
- **Bicep:** part of `infra/prereqs/network.bicep`.
- **Verify:** both zones are linked to the VNet.

> Screenshot D1-05: pending capture (WP-SHOTS).

### D1-06 Log Analytics workspace

- **Inputs:** `names.logAnalyticsWorkspace`, `availability.telemetry.workspaceRegion`, `.retentionDays`.
- **Portal:** Log Analytics workspaces → Create; then Usage and estimated costs → Data retention.
- **Bicep:** `infra/prereqs/log-analytics.bicep` (local authentication off, as WP-TEL's
  `phase4-telemetry.bicep`). WP-TEL also publishes `infra/poc/phase4-telemetry-workspace.bicep`.
- **Verify:** region and retention equal the decisions.

> Screenshot D1-06: pending capture (WP-SHOTS).

### D1-07 User-assigned identities

- **Inputs:** `names.identities.sync`, `names.identities.reconciler`.
- **Portal:** Managed Identities → Create, once for each. Note the Object (principal) ID and the
  Client ID on Overview; D1-19 records them. The sync's identity exists before its app, so a Graph
  application permission can be granted before the app's first token request
  (`docs/DEPLOYMENT-GUIDE.md`, Step 7).
- **Bicep:** `infra/prereqs/identities.bicep`.
- **Verify:** both exist in the resource group.

> Screenshot D1-07: pending capture (WP-SHOTS).

### D1-08 Cosmos DB account

- **Inputs:** `names.cosmosAccount`, `names.cosmosPrivateEndpoint`, `availability.registry.capacityMode`,
  `.zoneRedundant`, `.regions` (one region in this release).
- **Portal:** Azure Cosmos DB → Create → Azure Cosmos DB for NoSQL:
  - Basics: capacity mode as decided (provisioned throughput or serverless). Serverless runs in one
    region, and converting serverless to provisioned is one-way (`docs/AVAILABILITY.md`, [C1] [C3]);
  - Global distribution: availability zones as decided. Some subscriptions cannot use zones in a
    region (Microsoft.DocumentDB/locations `isSubscriptionRegionAccessAllowedForAz`, read by WP-HADEC);
  - Networking: private endpoint in the private endpoint subnet, integrated with the
    `privatelink.documents.azure.com` zone; public network access Disabled;
  - Security: key-based authentication disabled (`disableLocalAuth`).

  The database, its throughput and the containers are D2's.
- **Bicep:** `infra/prereqs/cosmos-account.bicep`.
- **Verify:** capacity mode, zone redundancy, public access Disabled, local authentication disabled,
  private endpoint connection Approved.

> Screenshot D1-08: pending capture (WP-SHOTS).

### D1-09 to D1-13 Function Apps: storage, Application Insights, plans and apps

One set per app: resolver, sync, reconciler.

- **Inputs:** `names.apps.<app>.*` (function app, plan, storage account, deployment container,
  storage private endpoint, Application Insights or null), `availability.storage.sku`,
  `availability.functions.<app>.*` (always-ready count, zone redundancy, maximum instances, memory).
- **D1-09 Storage account:** Storage accounts → Create: redundancy as decided; Advanced: "Allow
  storage account key access" Disabled, anonymous blob access Disabled; Networking: public access
  Disabled, private endpoint for `blob` in the `privatelink.blob.core.windows.net` zone; then Data
  storage → Containers → the deployment container. A blob endpoint alone is enough for these apps
  (WP-SYNC, live since 2026-10-11T12:53Z).
- **D1-10 Application Insights** (resolver and sync; the reconciler logs through a diagnostic setting
  instead, WP-REC): workspace-based, on the D1-06 workspace, local authentication disabled.
- **D1-11 to D1-13 Function App:** Function App → Create → Flex Consumption: Node.js 22; storage of
  D1-09 with managed-identity authentication; Networking: VNet integration into the Functions subnet;
  identity: system-assigned for the resolver (ADR-0009), the D1-07 user-assigned identity for the sync
  and the reconciler; scale: always-ready, maximum instances and memory as decided; zone redundancy
  of the plan as decided (it needs at least two always-ready instances, Learn flex-consumption-plan).

  Some portal flows add Storage Blob Data Owner for the app's identity on its storage. D3 then finds
  that grant and records it; nothing else changes.
- **Bicep:** `infra/prereqs/function-app.bicep`, once per app (all three are composed in
  `infra/prereqs/all.bicep`). It sets no application setting: after any re-run on an existing app,
  run D2 again.
- **Verify:** runtime Node 22 on Flex Consumption, VNet subnet, identity, sizing, plan zone
  redundancy, storage redundancy and access, Application Insights on the workspace.

> Screenshots D1-09 to D1-13: pending capture (WP-SHOTS).

### D1-14 API Management instance

- **Inputs:** `names.apim`, `availability.apim.sku`, `.units`, `.zones`, `apim.publisherEmail`,
  `apim.publisherName`.
- **Portal:** API Management services → Create: tier (Standard v2 or Premium v2) and units as
  decided; availability zones where offered, as decided (zones are set at creation only, Learn
  reliability-api-management); Virtual network: outbound integration into the APIM subnet; then
  Security → Managed identities: system assigned On. The resolver trusts only this identity
  (ADR-0009). Never run `az apim update` on it: without `--enable-managed-identity true` it removes
  the identity.
- **Bicep:** `infra/prereqs/apim.bicep`.
- **Verify:** tier, units, zones, identity, subnet, provisioning Succeeded. Provisioning can take
  30 minutes or more.

> Screenshot D1-14: pending capture (WP-SHOTS).

### D1-15 Workbook shell

- **Inputs:** `workbook.resourceName` (a GUID), `workbook.displayName`.
- **Bicep:** WP-WB's `infra/workbook/resource.bicep` (parameters workbookResourceName,
  workbookDisplayName, location, workspaceResourceId). It creates an empty shared workbook; D2 fills
  it. Never re-run it after D2: it resets the content.
- **Verify:** the workbook exists.

> Screenshot D1-15: pending capture (WP-SHOTS).

### D1-16 to D1-18 App registrations (Microsoft Entra)

In the deployment's tenant. They are created once per gateway, not per project. The Entra
application administrator runs the registrations preflight first (Role preflight, below).

- **Default (ADR-0026): two mandatory registrations.** D1-16 and D1-17 configure **one**
  combined developer/gateway application. Set `identity.gatewayApi.appId` and
  `identity.developerSignIn.appId` to the same application ID. D1-18 stays a separate Resolver API.
  A backend application is optional, only for a cross-tenant client-credentials backend.
  Existing installations with separate D1-16/D1-17 apps remain supported.
- **D1-16 Gateway API settings:** App registrations → New registration, single tenant; Expose an API: an
  Application ID URI and the scope of `identity.gatewayApi.scope` (enabled); Manifest: set
  `requestedAccessTokenVersion` explicitly to `identity.gatewayApi.accessTokenVersion`, whatever a
  new registration shows (2 in the combined example; legacy answers may use 1 or 2). Resources
  set it explicitly, and an empty value means 1 ([app manifest reference](https://learn.microsoft.com/entra/identity-platform/reference-microsoft-graph-app-manifest),
  retrieved 2026-10-13). D1-19 reads it and refuses any other value (`token_version_mismatch`,
  `scripts/Core.Prereqs.psm1:155-161`). Its
  Application ID URI and app id are the audiences the gateway accepts. Only when
  `identity.allowAppOnlyTestTokens` is true (test identities, WP-NET finding S1): an app role whose
  value is `identity.testClientAppRole`, `allowedMemberTypes` `Application`, enabled, and assigned to
  the service principal of each application in `identity.testClientAppIds`. The PoC's role and
  assignment are G17 and G18 in `docs/status/WP-GW.md`.
- **D1-17 Developer sign-in settings, on that same application by default:** a public client;
  Authentication: the redirect URIs of
  `identity.developerSignIn.redirectUris`; API permissions: delegated access to the Gateway API's
  scope for a legacy separate client. Include `http://localhost`, the native-client callback,
  and the Windows broker callback `ms-appx-web://Microsoft.AAD.BrokerPlugin/<appId>`.
  Enable public-client flows for optional device-code login; browser/WAM use the redirects.
  WP-CLIENT's `scripts/client/Set-DeveloperSignInRedirects.ps1` adds redirects without changing API
  settings. Consent follows the tenant's settings; do not assume token-to-self bypasses them.
  The helper requests `<appId>/<scope>` for itself (AADSTS90009; ADR-0026).
- **D1-18 Resolver API** (ADR-0009, WP-RES): single tenant; Application ID URI `api://<appId>`;
  Manifest `requestedAccessTokenVersion` 2; no secret, no redirect URI, no scope; its enterprise
  application exists. Its app ID must differ from **both** D1-16/D1-17 role IDs; only APIM's
  managed identity passes its application/principal restrictions. WP-RES's
  `Initialize-ResolverApiRegistration` (`infra/poc/resolver-auth.ps1`)
  can create it.
- **Answers:** put each app id in `identity.*.appId`. The test-identity decision is
  `identity.allowAppOnlyTestTokens`, `identity.testClientAppIds` and `identity.testClientAppRole`:
  false, an empty list and null in production.
- **Verify:** as listed; D1-19 reads them through Microsoft Graph. It does not read the app role: a
  missing or unassigned role shows as 403 for the test client's token (`docs/status/WP-CORE-RUN.md`,
  U-new-CORE-RUN-9).

> Screenshots D1-16 to D1-18: pending capture (WP-SHOTS).

### D1-19 Record the ids

```powershell
pwsh ./scripts/Record-Prerequisites.ps1 -Action Record -AnswersPath <answers.json> -CheckpointPath <checkpoint.json>
```

It reads every resource and registration above with the signed-in Azure CLI identity of the target
tenant, read-only, and refuses with each difference and its reason if anything differs from the
decisions. When all match, it writes `stage-D1` with the ids of `docs/DEPLOYMENT-STAGES.md`, "D1
record keys", the role preflights passed (`rolePreflight`: who, when and through which role, or null
for a part not run), and audit lines next to the checkpoint record. Run it again after any fix.

> Screenshot D1-19: pending capture (WP-SHOTS), terminal output, ids only.

## Role preflight

Before the first write of a part, the person who performs it checks that they hold D1's minimum role
for it (`config/stage-roles.json`, stage D1), with the checkpoint record the stages share:

```powershell
pwsh ./scripts/Record-Prerequisites.ps1 -Action Preflight -Part resources -AnswersPath <answers.json> -CheckpointPath <checkpoint.json>
pwsh ./scripts/Record-Prerequisites.ps1 -Action Preflight -Part registrations -AnswersPath <answers.json> -CheckpointPath <checkpoint.json>
```

| Part | Before | Who runs it | Passes with |
|---|---|---|---|
| `resources` | The Bicep of `infra/prereqs`, or the portal steps D1-02 to D1-15 | Infrastructure team | Contributor or Owner on the resource group, assigned there or above it (before D1-02 in mode `create`, on the subscription) |
| `registrations` | D1-16 to D1-18 | Entra application administrator | Application Administrator or Cloud Application Administrator, active; or "Users can register applications" set to Yes |

It reads only, and refuses before any write with a reason code: `caller_rights_missing` (it names the
roles, the scope, who usually holds them and what you hold), `caller_roles_unreadable` (a role that
cannot be read is never taken as held), `identity_unreadable` (the Azure CLI gives no identity for
`target.subscriptionId`: sign in with an account that sees that subscription, with any role on it,
for example Reader on the resource group; this applies to the registrations part too),
`stage_data_invalid`, `part_missing`, `answers_incomplete` or `wrong_tenant`. A pass is recorded as
`stage-D1-preflight:<part>` with your object id; D1-19 copies it into `stage-D1` as recorded in the
shared file, without checking it again, and says whether it ran with the same answers
(`sameAnswers`). It does not check Contributor on the subscription for `target.resourceProviders`
`register` (D1-01) or Network Contributor on the VNet in network mode `existing`: the stage data does
not declare them (`docs/status/WP-CORE-RUN.md`, U-new-CORE-RUN-14). A service principal cannot pass
the registrations part, because its directory roles cannot be read (U-new-CORE-RUN-13).

## Rollback

Each resource is deleted in the portal or with `az resource delete --ids <id>` (a resource group:
`az group delete --name <rg> --subscription <id>`), after D3's grants and D2's deployments that use it
are removed. Keep the checkpoint record: it shows what was created, by whom and when.
