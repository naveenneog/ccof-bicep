# Front Door Premium in front of both regions (Azure Cloud Shell)

**For:** an operator who has built region A ([Deploy CCOF step by step](DEPLOY-STEP-BY-STEP.md)) and
region B ([DR standby region](DR-STANDBY-CLOUD-SHELL.md), sections 1-10, all phases including `Code`).
**Result:** one Front Door Premium endpoint with a WAF policy, private-link origins to both APIM
gateways and both admin Function Apps, region A preferred and region B used when A's health probe
fails, and public network access disabled on all four origins. Before region B exists, Front Door can
front region A alone: [section 5](#5-primary-region-first).
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
| 6 | `... -Phase Lockdown -ConfigPath $cfg` then with `-Apply` | Sets `publicNetworkAccess` to `Disabled` on both APIMs and both admin apps, one at a time, and reads it back. Publish the admin code in both regions first (section 3) | `publicNetworkAccess Disabled verified` for each; waits up to 45 minutes per resource |

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
2026-10-26). [ADR 0037](../adr/0037-admin-publishing-after-front-door-lockdown.md) (accepted
2026-10-27): the admin code is published before `Lockdown` (deployment Step 7 and the DR `Code`
phase). After `Lockdown`, Step 7 and the `Code` phase skip the admin package with the warning
`admin_public_access_disabled`, and updates and fix patches are published from a VM inside the VNet:
[admin updates from a VM](ADMIN-UPDATE-FROM-VM.md).

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

## 5. Primary region first

Front Door can be deployed in front of region A only, before region B exists, so that users are given
the permanent Front Door host from the start. Region B's origins are added later to the same profile,
endpoint and origin groups; the host name does not change.

**Switch:** `-PrimaryOnly` on [`Invoke-DrFrontDoor.ps1`](../../infra/dr/Invoke-DrFrontDoor.ps1)
(line 23). It is never assumed: without the switch the driver still requires region B.

**What is deployed:** one APIM origin (`primary-gateway`) and one admin origin (`primary-admin`), both
priority 1 ([`DrStandby.psm1`](../../infra/dr/DrStandby.psm1) `New-DrFrontDoorParameters`, line 212).
The template accepts one or two origins per group
([`frontdoor.bicep`](../../infra/dr/frontdoor.bicep) lines 18-25). The profile `<stem>-fd`, endpoint
`<stem>`, origin groups `apim` and `admin`, routes `gateway` and `admin`, WAF policy and security
policy are named from `frontDoor.stem` only (`frontdoor.bicep` lines 46 and 55), so they are the same
in both modes.

**Configuration read in this mode** (`Get-DrFrontDoorPrimaryOnlyProblems`, `DrStandby.psm1` line 69):

| Field | Required | Meaning |
| --- | --- | --- |
| `standby.stagedConfigPath` | yes | Region A's `staged.config.json` (subscription, resource group) |
| `standby.stagedStateDirectory` | yes | Region A's `.staged-state`; Stage 1 outputs give the APIM ID, gateway host and admin app name |
| `standby.stateDirectory` | yes | Where `frontdoor-state.json` is written; created if missing. Use the same directory region B will use later |
| `primary.location` | yes | Region A, for example `eastus2` |
| `frontDoor.stem` | yes | As in section 1 |
| `frontDoor.wafMode`, `frontDoor.probeIntervalSeconds` | no | As in section 1; defaults `Detection` and `30` |
| `tags` | no | Tags on the profile and WAF policy |

`tenantId`, `secondary`, `standby.apim`, `standby.nameSuffix` and the other region B fields are not read.
Region A must have an admin Function App.

**Phases** (preview without `-Apply`, change with `-Apply`):

```powershell
pwsh -File $repo/infra/dr/Invoke-DrFrontDoor.ps1 -Phase Deploy  -ConfigPath $cfg -PrimaryOnly
pwsh -File $repo/infra/dr/Invoke-DrFrontDoor.ps1 -Phase Deploy  -ConfigPath $cfg -PrimaryOnly -Apply
pwsh -File $repo/infra/dr/Invoke-DrFrontDoor.ps1 -Phase Approve -ConfigPath $cfg -PrimaryOnly
pwsh -File $repo/infra/dr/Invoke-DrFrontDoor.ps1 -Phase Approve -ConfigPath $cfg -PrimaryOnly -Apply
pwsh -File $repo/infra/dr/Invoke-DrFrontDoor.ps1 -Phase Verify  -ConfigPath $cfg -PrimaryOnly
```

- `Deploy` preview lists a profile, endpoint, two origin groups, two origins, two routes, WAF policy
  and security policy.
- `Approve -Apply` approves two connections (one APIM, one admin app) and stops with
  `frontdoor_connections_missing` if fewer than two are approved (`Invoke-DrFrontDoor.ps1` line 187).
- `Lockdown`, `DrainPrimary` and `RestorePrimary` refuse to run with `-PrimaryOnly`
  (`frontdoor_primary_only_phase_refused`, `DrStandby.psm1` line 97). Region A's APIM and admin app
  keep public network access until region B exists and `Lockdown` runs in full mode.
- `frontdoor-state.json` records `"mode": "primaryOnly"`.

**Client gateway URL:** `https://<endpoint host>/<apim.apiPath>`, for example
`https://<stem>-<hash>.z01.azurefd.net/anthropic`, with no trailing `/v1`. The endpoint host is printed
by `Deploy -Apply` and stored as `endpointHostName` in `frontdoor-state.json`. The `gateway` route
forwards the path unchanged to APIM.

**Adding region B later:** build region B ([DR standby region](DR-STANDBY-CLOUD-SHELL.md)), complete
the full `dr.config.json`, then run `Deploy`, `Approve` and `Verify` from section 2 without
`-PrimaryOnly`. The deployment is incremental and adds `standby-gateway` and `standby-admin` to the
existing origin groups. Changing the mode clears the recorded approvals and verification
(`Set-DrFrontDoorStateMode`, `DrStandby.psm1` line 116), so `Approve` (four connections) and `Verify`
must pass again before `Lockdown`. Region A's two connections are already approved and are counted.
Once the state records a full deployment, `-PrimaryOnly` is refused (`frontdoor_mode_mismatch`).
