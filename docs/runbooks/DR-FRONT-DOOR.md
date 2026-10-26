# Front Door Premium in front of both regions (Azure Cloud Shell)

**For:** an operator who has built region A ([Deploy CCOF step by step](DEPLOY-STEP-BY-STEP.md)) and
region B ([DR standby region](DR-STANDBY-CLOUD-SHELL.md), sections 1-10, all phases including `Code`).
**Result:** one Front Door Premium endpoint with a WAF policy, private-link origins to both APIM
gateways and both admin Function Apps, region A preferred and region B used when A's health probe
fails, and public network access disabled on all four origins.
**Driver:** [`infra/dr/Invoke-DrFrontDoor.ps1`](../../infra/dr/Invoke-DrFrontDoor.ps1) with template
[`infra/dr/frontdoor.bicep`](../../infra/dr/frontdoor.bicep). Decision: [ADR 0033](../adr/0033-dr-active-passive.md).

Each phase is a preview without `-Apply` and an Azure change with `-Apply`. The driver records its
results in `frontdoor-state.json` in `standby.stateDirectory`, and later phases refuse to run before
the phases they depend on are recorded.

## 1. Configuration

The `frontDoor` section of the same `dr.config.json` that region B uses
([`dr.config.example.json`](../../infra/dr/dr.config.example.json)):

| Field | Example | Accepted values | Meaning |
| --- | --- | --- | --- |
| `frontDoor.stem` | `ccofprdfd` | 3-40 lowercase letters, digits and `-`, starting with a letter | Profile `<stem>-fd`, endpoint `<stem>`, WAF policy `<stem>waf`. The endpoint name is global, so the stem must be unique |
| `frontDoor.wafMode` | `Detection` | `Detection`, `Prevention` | `Detection` logs WAF matches without blocking. Model prompts and code can match managed rules, so exclusions are tuned in `Detection` before `Prevention` (template comment) |
| `frontDoor.probeIntervalSeconds` | `30` | 5-255 | Seconds between health probes from each Front Door point of presence |

Both regions must have an admin Function App; the driver refuses otherwise.

## 2. Phases, in order

The session block from [DR standby region, section 4](DR-STANDBY-CLOUD-SHELL.md#4-set-up-cloud-shell)
defines `$repo` and `$cfg`.

| # | Command | Changes | Expect |
| --- | --- | --- | --- |
| 1 | `pwsh -File $repo/infra/dr/Invoke-DrFrontDoor.ps1 -Phase Deploy -ConfigPath $cfg` | Nothing (what-if) | A `Create` list: profile, endpoint, two origin groups, four origins, two routes, WAF policy, security policy |
| 2 | Same with `-Apply` | Deploys the template | `Front Door deployed: https://<endpoint host>` and the note that the private links still need approval |
| 3 | `... -Phase Approve -ConfigPath $cfg` | Nothing | One `Pending CCOF origin` line per origin; the driver only acts on connections whose request message starts with `CCOF Front Door origin` or `CCOF Front Door admin origin` |
| 4 | Same with `-Apply` | Approves those four connections on the two APIMs and two admin apps | `Approved 4 Front Door private links.` Fewer than four stops with `frontdoor_connections_missing` |
| 5 | `... -Phase Verify -ConfigPath $cfg` | Nothing | `GET /status-0123456789abcdef` returns 200 and `GET /api/console` 200 or 302 through the Front Door host; up to 30 attempts 30 s apart |
| 6 | `... -Phase Lockdown -ConfigPath $cfg` then with `-Apply` | Sets `publicNetworkAccess` to `Disabled` on both APIMs and both admin apps, one at a time, and reads it back | `publicNetworkAccess Disabled verified` for each; waits up to 45 minutes per resource |

Lab observations (2026-10-25):

- After the first deployment both routes returned the generic Front Door 404 on the first two tries
  and 200 on the third. `Verify` retries for that reason.
- The origin group's `deploymentStatus` stayed `NotStarted` while routing worked; the live 200
  responses and the approved connections were the evidence used.
- `Lockdown` of an APIM took about 45 minutes to read back `Disabled`.
- A rejected private endpoint connection cannot be approved again (`PrivateLinkStatusChangeNotAllowed`);
  the endpoint has to be deleted and recreated. `Approve` never rejects.

## 3. After Lockdown: code publishing to the admin apps

`Lockdown` disables public network access on both admin apps. Publishing a package to an admin app
from Cloud Shell or a workstation outside the VNet then returns HTTP 403 (region B `Code` phase,
2026-10-26). The admin code is therefore published before `Lockdown`, or from a host that reaches
the apps privately. Options for later updates are compared in
[ADR 0037](../adr/0037-admin-publishing-after-front-door-lockdown.md).

## 4. Drill phases

| Phase | Effect | Reverse |
| --- | --- | --- |
| `DrainPrimary` | Sets an invalid origin host header (`dr-drill.invalid`) on region A's two origins; their health probes fail and traffic moves to region B. Requires a recorded `Verify` | `RestorePrimary` |
| `RestorePrimary` | Restores region A's origin host headers | — |

After `RestorePrimary` the lab saw region A's origin health at 0 % for about 25 minutes and 100 %
about 45 minutes after the deployment; the drain took about 15 minutes. An unchanged re-PUT of the
primary gateway origin was made about 30 minutes after `RestorePrimary`, and health rose after it;
whether the re-PUT was needed was not established. Health is read with:

```powershell
az monitor metrics list --resource REPLACE-front-door-profile-resource-id --metric OriginHealthPercentage `
  --interval PT5M --offset 30m --aggregation Average --filter "Origin eq '*'" -o table
```

Promotion of region B's writers and failback are separate steps
([DR standby region, section 11](DR-STANDBY-CLOUD-SHELL.md#11-live-drill-record-2026-10-2526)).
