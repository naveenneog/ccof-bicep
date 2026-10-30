# Health and outage e-mail alerts (add-on)

This add-on sends e-mail when a CCOF service stops answering or reports failures. It is applied on
top of a finished deployment (Steps 0 to 8 of [DEPLOY-STEP-BY-STEP.md](DEPLOY-STEP-BY-STEP.md), with
or without Azure Front Door from [DR-FRONT-DOOR.md](DR-FRONT-DOOR.md)). It covers the signals the
admin console shows on its Health page
([admin/ui-v3/pages/health.tsx:26-61](../../admin/ui-v3/pages/health.tsx)).

It does not change any resource, setting or policy of the deployment. It does not use Microsoft
Graph or Microsoft Entra. It runs from Azure Cloud Shell (PowerShell) and calls Azure Resource
Manager only. It is not one of the staged Steps: Step 1 to 8 state, hashes and templates are not read
or written.

| File | Content |
| --- | --- |
| [infra/monitoring/Invoke-HealthAlerts.ps1](../../infra/monitoring/Invoke-HealthAlerts.ps1) | Driver: preview, apply, test notification, remove |
| [infra/monitoring/HealthAlerts.psm1](../../infra/monitoring/HealthAlerts.psm1) | Configuration checks, probe choice, alert definitions, what-if guard, removal selection |
| [infra/monitoring/health-alerts.bicep](../../infra/monitoring/health-alerts.bicep) | Template; resource group scope, Incremental mode |
| [infra/monitoring/health.config.example.json](../../infra/monitoring/health.config.example.json) | Configuration sample |
| [analytics/alerts/](../../analytics/alerts/) | KQL of the log alerts |
| [tests/Test-HealthAlerts.ps1](../../tests/Test-HealthAlerts.ps1) | Offline tests (no Azure) |

## 1. What it creates

All resources are in the deployment's resource group, are named `<stem>-health-*` and carry the tag
`ccof-component=health-alerts`. `<stem>` is the Stage 1 name stem `<prefix>-<suffix>`, the part
before `-law` in the Log Analytics workspace name.

| Resource | Name | Count |
| --- | --- | --- |
| Action group (e-mail receivers, common alert schema) | `<stem>-health-ag` | 1 |
| Application Insights component that holds the availability tests; sends results to `<stem>-law`; local authentication disabled | `<stem>-health-ai` | 1 when at least one test is added |
| Standard availability tests (every 5 minutes, 5 locations, 30 s timeout, TLS check, no redirects) | `<stem>-health-wt-<key>` | 0 to 5 |
| Metric alert rules | `<stem>-health-<name>`, `<stem>-health-avail-<key>` | up to 9 plus one per test and one per Foundry account |
| Log search alert rules (on the Log Analytics workspace, no managed identity) | `<stem>-health-<name>` | up to 6 |

A full deployment with Front Door and one Foundry account gives about 23 resources. Live run in a
lab (2026-10-30, Front Door, public network access disabled on APIM and the admin app): what-if
`Create=23`, no `Modify` or `Delete` of other resources; APIM diagnostic settings and admin app
setting names were identical before and after. `-Remove -Apply` then deleted the 24 owned resources
(23 plus the Failure Anomalies rule); after the unused Smart Detection action group was deleted, the
resource group's resource list matched the list taken before the first apply (132 resources).

Azure adds two resources on its own a few minutes after it creates the component (Application
Insights smart detection), observed in the same lab run:

| Resource | Created by | Removal |
| --- | --- | --- |
| Smart detector rule `Failure Anomalies - <stem>-health-ai` | Azure, for the owned component | Deleted by `-Remove -Apply` (exact name) |
| Action group `Application Insights Smart Detection` | Azure, in the component's resource group when it has none; other components' Failure Anomalies rules can use it | Left in place by `-Remove`; the driver prints the delete command |

### Availability tests

Each candidate endpoint is requested once from the shell that runs the driver before a test is
added ([HealthAlerts.psm1 `Resolve-HaProbes`](../../infra/monitoring/HealthAlerts.psm1)).

| Key | Request | Healthy answer | Source of the expectation |
| --- | --- | --- | --- |
| `gateway-fd` | `https://<frontDoor.host>/status-0123456789abcdef` | 200 | [infra/dr/frontdoor.bicep:70](../../infra/dr/frontdoor.bicep), [Invoke-DrFrontDoor.ps1:220](../../infra/dr/Invoke-DrFrontDoor.ps1) |
| `admin-fd` | `https://<frontDoor.host>/api/console` | 200 | [infra/dr/frontdoor.bicep:108](../../infra/dr/frontdoor.bicep), [Invoke-DrFrontDoor.ps1:221](../../infra/dr/Invoke-DrFrontDoor.ps1) |
| `gateway-direct` | `https://<apim>.azure-api.net/status-0123456789abcdef` | 200 | APIM gateway status endpoint |
| `admin-direct` | `https://<stem>-admin.azurewebsites.net/api/console` | 200 | [admin/src/function-app.ts:120](../../admin/src/function-app.ts) |
| `resolver-direct` | `https://<stem>-resolver.azurewebsites.net/api/health` | 401 | Without a token the resolver answers 401 ([src/resolver/http-handler.ts:298](../../src/resolver/http-handler.ts)); 503 means its configuration is incomplete |

`probes.<name>` in the configuration selects each test:

- `auto` (default): the test is added when Azure Resource Manager does not report public network
  access `Disabled` for the target and the request returns the healthy answer. When APIM and the
  admin app are locked down behind Front Door, only the Front Door tests (and the resolver, if public)
  are added.
- `on`: the test is added; a different answer is printed as a warning.
- `off`: the test is not added and the endpoint is not requested.

`auto` checks reachability from where the driver runs. Cloud Shell reaches the same public endpoints
as the Azure test agents. On a workstation with private DNS for the Function Apps or APIM, a direct
probe can succeed there and fail from Azure; `off` avoids that test.

### Alert rules

Defaults are in [HealthAlerts.psm1:17-34](../../infra/monitoring/HealthAlerts.psm1). Each can be
changed or disabled under `rules` in the configuration. Severity 0 is critical, 4 is verbose. The
e-mail of each rule names its section below.

| Rule (`rules.<name>`) | Signal | Fires when (default) | Severity | Admin Health page |
| --- | --- | --- | --- | --- |
| `availability` | Availability test | failed from 2 or more locations in 5 min | 1 | Endpoint probes |
| `apimGateway5xx` | APIM metric `Requests`, `GatewayResponseCodeCategory=5XX` | 10 or more in 15 min | 1 | Telemetry freshness (gateway) |
| `apimBackend5xx` | APIM metric `Requests`, `BackendResponseCodeCategory=5XX` | 10 or more in 15 min | 2 | Foundry backend |
| `apimCapacity` | APIM metric `Capacity` (or `CpuPercent_Gateway` when `Capacity` is absent) | average above 80 over 15 min | 2 | - |
| `resolverUnavailable` | `ApiManagementGatewayLogs`, `TraceRecords` source `ccof.resolver.v1`, `resolverOutcome` `unavailable` (gateway 503 `entitlement_unavailable`) | 500 basis points (5 %) or more of at least 20 requests in 15 min | 1 | Telemetry freshness |
| `gatewayTelemetrySilent` | `ApiManagementGatewayLogs` for the Claude API | no row for 1440 min | 3 | Telemetry freshness |
| `functionServerErrors` | `AppRequests` with result code 500 or more, plus `AppExceptions`, of the four Function Apps; one alert per app | 5 or more in 15 min | 2 | Admin app, Integrations |
| `syncRunFailures` | `ccof.sync.run.v1` with `outcome` `failed` or `partial` | 1 or more runs in 60 min | 2 | Integrations |
| `reconcilerRunFailures` | `ccof.reconciler.run.v1` with `outcome` `failed`, `settings_invalid` or `refused`; one alert per `reason` | 3 or more runs in 30 min | 2 | Reconciler freshness |
| `reconcilerStale` | `ccof.reconciler.run.v1` with `outcome` `written` | none for 30 min (window 60 min) | 1 | Reconciler freshness |
| `cosmosThrottled` | Cosmos DB metric `TotalRequests`, `StatusCode=429` | 50 or more in 15 min | 3 | Project registry (Cosmos DB) |
| `cosmosServerErrors` | Cosmos DB metric `TotalRequests`, `StatusCode` 500 or 503 | 5 or more in 15 min | 2 | Project registry (Cosmos DB) |
| `cosmosAvailability` | Cosmos DB metric `ServiceAvailability` (hourly) | below 99.9 % | 1 | Project registry (Cosmos DB) |
| `foundryServerErrors` | Foundry metric `ModelRequests` with `StatusCode` 500, 502, 503 or 504 (or `ServerErrors`) | 5 or more in 15 min | 2 | - |
| `frontDoorOriginHealth` | Front Door metric `OriginHealthPercentage` per origin group | below 90 % over 15 min | 1 | - |
| `frontDoor5xx` | Front Door metric `Percentage5XX` | above 5 % over 15 min | 2 | - |

Log rules evaluate every `evaluationFrequencyMinutes` (default 5) and resolve automatically when the
condition clears. Their queries reuse the gateway and resolver queries of the existing telemetry
alerts ([analytics/alerts/gateway-base.kql](../../analytics/alerts/gateway-base.kql),
[resolver-base.kql:4](../../analytics/alerts/resolver-base.kql),
[resolver-failures.kql](../../analytics/alerts/resolver-failures.kql),
[missing-telemetry.kql](../../analytics/alerts/missing-telemetry.kql)) and read the same run lines as
the admin console ([admin/src/operations.ts:38-43](../../admin/src/operations.ts)): `FunctionAppLogs`
and `AppTraces` of the app's site and Application Insights IDs. A run line can appear in both tables;
the run rules count distinct `runId` values.

### availability

An availability test failed from two or more locations. The e-mail names the test. Front Door tests
fail when Front Door or its origin (APIM or the admin app) does not answer; the resolver test fails
when the resolver app does not answer 401. Portal: Application Insights `<stem>-health-ai` >
Availability shows each location's result and response.

### apimgateway5xx

APIM answered 5xx. The gateway answers 503 `entitlement_unavailable` when the resolver is
unreachable, and passes through backend 5xx. `resolverUnavailable` and `apimBackend5xx` separate the
two causes.

### apimbackend5xx

A Foundry backend answered APIM with 5xx. The Foundry account's metrics and service health show
whether the model deployment is degraded. Per-project backend failover is described in
[ADMIN-OPERATIONS.md section 7 D](ADMIN-OPERATIONS.md#d-optional-per-project-backend-failover-admin-33).

### apimcapacity

APIM gateway capacity (or gateway CPU) is high. Sustained values above 80 % precede latency and
failures; APIM units are set by `stage1.apimUnits`.

### resolverunavailable

The gateway could not get an entitlement from the resolver for at least 5 % of requests. Causes seen
in deployments: resolver app stopped or unreachable from APIM over the network, missing resolver
service principal (APIM token for the resolver fails), Cosmos DB unreachable from the resolver.
The resolver's own requests appear under `functionServerErrors`.

### gatewaytelemetrysilent

No gateway log row for the Claude API in the last 24 hours. Either no traffic reached the gateway, or
APIM resource logs no longer reach the workspace (diagnostic setting removed or pointed elsewhere).
Chargeback and reconciler inputs stop in both cases. An idle deployment (for example a weekend
without use) also fires this rule; `rules.gatewayTelemetrySilent.enabled: false` disables it.

### functionserverrors

A Function App returned 5xx or logged exceptions. The `app` dimension names the Application Insights
component (`<stem>-<app>-ai`). Portal: that component > Failures.

### syncrunfailures

A sync run ended `failed` or `partial` ([src/sync/telemetry.ts:9-12](../../src/sync/telemetry.ts)).
Run lines: `pwsh infra/sync/Get-SyncRunLines.ps1` ([infra/sync/Get-SyncRunLines.ps1](../../infra/sync/Get-SyncRunLines.ps1)).
Reasons and refusals are listed in [SYNC.md](../SYNC.md).

### reconcilerrunfailures

Reconciler runs ended `failed`, `settings_invalid` or `refused`
([src/reconciler/telemetry.ts:15](../../src/reconciler/telemetry.ts)). The `reason` dimension
carries the reason code, for example `ledger_continuity_gap`
([src/reconciler/run.ts:199](../../src/reconciler/run.ts)). The admin console's Reconciler page
lists the same runs.

### reconcilerstale

No `written` reconciler run for 30 minutes; budget state is getting stale (admin Health:
Reconciler freshness). The rule also fires while the reconciler timer is disabled on purpose
(`reconciler.timerEnabled: false`, or the region is the passive one after a DR switchover);
`rules.reconcilerStale.enabled: false` disables it there.

### cosmosthrottled

Cosmos DB throttled requests with 429. Serverless accounts throttle above their burst limit;
provisioned accounts above their throughput.

### cosmosservererrors

Cosmos DB returned 500 or 503.

### cosmosavailability

Cosmos DB hourly service availability is below 99.9 %. Azure Service Health shows regional incidents.

### foundryservererrors

A Foundry account returned server errors. One rule per account in `foundryAccountIds`.

### frontdoororiginhealth

Front Door health probes fail for an origin group (`apim` or `admin`). With two regions, a value of
50 % means one region's origin is down and traffic uses the other.

### frontdoor5xx

Front Door answered 5xx for more than 5 % of requests.

## 2. Prerequisites and permissions

| Item | Detail |
| --- | --- |
| Deployment | Stage 1 resources exist: `<stem>-law`, `<stem>-cosmos`, the resolver, sync and reconciler Function Apps and their `<stem>-<app>-ai` components; the admin app is optional. APIM is `<stem>-apim` or the `apim.id` of the configuration. |
| Role on the resource group | **Monitoring Contributor**. It includes `Microsoft.Insights/actiongroups/*`, `components/*`, `webtests/*`, `metricalerts/*`, `scheduledqueryrules/*`, `Microsoft.AlertsManagement/smartDetectorAlertRules/*`, `Microsoft.Resources/deployments/*`, `Microsoft.OperationalInsights/workspaces/search/action` and `*/read`. Application Insights Component Contributor is not needed in addition. |
| Other scopes | Read (Monitoring Reader or Reader) on an APIM, Front Door profile or workspace in another resource group, and on each Foundry account. |
| Log alert queries | No managed identity. Azure runs each log alert query with the permissions of the last user who created or edited the rule ([Microsoft Learn](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-create-log-alert-rule)). When that user loses read access to the workspace, the rules stop evaluating; a new `-Apply` by another operator with access re-establishes them. |
| Not required | Microsoft Graph, Entra roles, Owner, User Access Administrator, Function App settings write, APIM write. |
| Shell | Azure Cloud Shell (PowerShell) with `az` signed in to the tenant; or a workstation with PowerShell 7 and `AZURE_CONFIG_DIR` set to a signed-in profile. |

Foundry accounts in another subscription: the driver skips them unless
`allowCrossSubscriptionFoundry` is `true`. When it is `true` and their metric definitions cannot be
read, they are skipped with a message and the rest of the deployment continues. A metric alert rule
is created in this resource group with the account as its scope; if Azure refuses that scope, the
same configuration without the account (or a separate run in the Foundry subscription) is the
alternative.

## 3. Configuration

`health.config.json` (sample values; every `REPLACE` value is refused):

```json
{
  "schemaVersion": 1,
  "subscriptionId": "00000000-0000-4000-8000-000000000002",
  "resourceGroup": "rg-ccof-prod",
  "stem": "ccofprod-abc123def456g",
  "emailReceivers": ["ccof-ops@contoso.com", "oncall@contoso.com"],
  "frontDoor": {
    "host": "ccofprod-abcdefgh.z01.azurefd.net",
    "profileId": "/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg-ccof-prod/providers/Microsoft.Cdn/profiles/ccofprod-fd"
  },
  "foundryAccountIds": [
    "/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg-foundry/providers/Microsoft.CognitiveServices/accounts/contoso-foundry"
  ],
  "rules": {
    "gatewayTelemetrySilent": { "threshold": 720 },
    "apimGateway5xx": { "threshold": 20 }
  }
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `schemaVersion` | yes | `1` |
| `subscriptionId`, `resourceGroup` | yes | Deployment subscription and resource group (staged config) |
| `stem` | yes | Stage 1 name stem; `<stem>-law` is the workspace name |
| `emailReceivers` | yes | 1 to 20 plain addresses, no duplicates |
| `tags` | no | Extra tags; `ccof-component` is always `health-alerts` |
| `workspaceId` | no | Workspace resource ID when it is not `<stem>-law` (for example a standby region that logs to the primary workspace) |
| `apim.id`, `apim.apiId`, `apim.logWorkspaceId` | no | Existing APIM (staged `apim.existing`), API name (default `claude-messages`, staged `apim.apiId`), workspace of its resource logs |
| `frontDoor.host`, `frontDoor.profileId` | no | Front Door endpoint host name (`frontdoor-state.json` `endpointHostName`) and profile ID for its metric alerts |
| `foundryAccountIds` | no | Foundry account resource IDs (staged `backends[]`) |
| `allowCrossSubscriptionFoundry` | no | `true` includes accounts in other subscriptions |
| `probes` | no | `frontDoorGateway`, `frontDoorAdmin`, `apimDirect`, `adminDirect`, `resolverDirect`: `auto`, `on` or `off` |
| `webTestLocations` | no | Availability test location IDs; default East US, South Central US, North Central US, West US, West Europe |
| `evaluationFrequencyMinutes` | no | 1, 5 (default), 15, 30 or 60 |
| `rules.<name>` | no | `enabled`, `severity` (0-4), `threshold`, `windowMinutes` (metric rules: 5, 15, 30, 60, 360, 720 or 1440; log rules 5-2880), `minimumSamples` (`resolverUnavailable`) |

Values from an existing deployment:

```powershell
# stem: the workspace name without -law
az resource list --resource-group rg-ccof-prod --resource-type Microsoft.OperationalInsights/workspaces --query [].name --output tsv
# Front Door host
az afd endpoint list --resource-group rg-ccof-prod --profile-name ccofprod-fd --query [].hostName --output tsv
# Foundry account IDs from the staged configuration
(Get-Content ./staged.config.json | ConvertFrom-Json).backends | ForEach-Object { "/subscriptions/$($_.subscriptionId)/resourceGroups/$($_.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($_.accountName)" }
```

## 4. Cloud Shell, step by step

Azure Cloud Shell, PowerShell. The configuration file is kept in `$HOME`, which persists between
sessions; the repository clone does not need to persist.

**Step 1, code and configuration.**

```powershell
git clone https://github.com/naveenneog/ccof-bicep.git
cd ccof-bicep
Copy-Item infra/monitoring/health.config.example.json ~/health.config.json
code ~/health.config.json
```

**Step 2, preview.** Reads the deployment, requests the candidate endpoints once, runs
`az deployment group what-if` and prints every alert with its threshold and every change. Nothing is
created.

```powershell
./infra/monitoring/Invoke-HealthAlerts.ps1 -ConfigPath ~/health.config.json
```

Expected: `Create=<n>` for the `<stem>-health-*` resources and `Ignore` for the rest of the resource
group; the last line is `Preview only. No changes were made.` Any `Delete`, or any `Create` or
`Modify` of a resource that is not `<stem>-health-*` with the tag `ccof-component=health-alerts`,
stops the run with `whatif_refused` and exit code 3
([HealthAlerts.psm1 `Get-HaWhatIfProblems`](../../infra/monitoring/HealthAlerts.psm1)).

**Step 3, apply.** The same what-if check, then an Incremental deployment named
`ccof-health-alerts`, then a list of the owned resources.

```powershell
./infra/monitoring/Invoke-HealthAlerts.ps1 -ConfigPath ~/health.config.json -Apply
```

Running it again is safe: unchanged resources show `NoChange`; Azure can report `Modify` for the
owned component and rules because it normalizes some values.

**Step 4, test notification.** Azure Monitor sends a test e-mail to every receiver through
`<stem>-health-ag` ([REST: Create Notifications At Action Group Resource Level](https://learn.microsoft.com/rest/api/monitor/action-groups/create-notifications-at-action-group-resource-level)).

```powershell
./infra/monitoring/Invoke-HealthAlerts.ps1 -ConfigPath ~/health.config.json -TestNotification
```

Portal alternative: Monitor > Alerts > Action groups > `<stem>-health-ag` > Test action group.
The e-mail comes from `azure-noreply@microsoft.com`.

**Step 5, undo.** Lists, then deletes, only resources tagged `ccof-component=health-alerts` and named
`<stem>-health-*`, plus the `Failure Anomalies - <stem>-health-ai` rule Azure created for the owned
component. Other resources are not changed. The shared `Application Insights Smart Detection`
action group stays; the output names the command that deletes it when no rule uses it.

```powershell
./infra/monitoring/Invoke-HealthAlerts.ps1 -ConfigPath ~/health.config.json -Remove
./infra/monitoring/Invoke-HealthAlerts.ps1 -ConfigPath ~/health.config.json -Remove -Apply
```

Exit codes: 0 done, 2 configuration refused (nothing read from Azure), 3 refused or failed.

## 5. Where alerts appear in the Portal

| What | Portal path |
| --- | --- |
| Fired and resolved alerts | Monitor > Alerts, filter resource group |
| Rules, thresholds, enable or disable | Monitor > Alerts > Alert rules, filter name `<stem>-health` |
| Receivers | Monitor > Alerts > Action groups > `<stem>-health-ag` |
| Availability test results per location | Application Insights `<stem>-health-ai` > Availability |
| Owned resources | Resource group > Filter by tag `ccof-component` = `health-alerts` |

A rule disabled in the Portal is enabled again by the next `-Apply`; `rules.<name>.enabled: false`
in the configuration keeps it absent.

## 6. Not covered

- A second (standby) region: a separate configuration with the standby stem
  (`<stem>-b`), its APIM in `apim.id` and the shared workspace in `workspaceId`; resource names do not
  collide because they start with the stem.
- Endpoints reachable only from a private network: availability tests run from Azure's public test
  agents. The log and metric rules still cover those services.
- The admin console's Integrations rows for Microsoft Graph, cost data and retail prices.
- Model output correctness and billing accuracy; an HTTP answer is reachability evidence only.
- Cost: availability tests and log alert rules are billed by Azure Monitor
  ([pricing](https://azure.microsoft.com/pricing/details/monitor/)).

## References

- Action groups and common alert schema: <https://learn.microsoft.com/azure/azure-monitor/alerts/action-groups>,
  <https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-common-schema>
- Standard availability tests: <https://learn.microsoft.com/azure/azure-monitor/app/availability>
- Metric alerts: <https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-create-metric-alert-rule>
- Log search alerts: <https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-create-log-alert-rule>
- Monitoring Contributor role: <https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/monitor#monitoring-contributor>
- What-if: <https://learn.microsoft.com/azure/azure-resource-manager/templates/deploy-what-if>
