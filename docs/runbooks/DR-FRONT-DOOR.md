# Front Door Premium in front of both regions (Azure Cloud Shell)

**For:** an operator who has built region A ([Deploy CCOF step by step](DEPLOY-STEP-BY-STEP.md)) and
prepared region B ([DR standby region](DR-STANDBY-CLOUD-SHELL.md), sections 1-10).
**Result after approval, verification and Lockdown:** Front Door Premium with a WAF policy and
Private Link origins to both APIM gateways and admin apps. Region A is preferred, but **priority-2 B
can receive traffic automatically when A is unhealthy**. A primary-only deployment remains available
before B is ready: [section 5](#5-primary-region-first).
**Driver:** [`infra/dr/Invoke-DrFrontDoor.ps1`](../../infra/dr/Invoke-DrFrontDoor.ps1) with template
[`infra/dr/frontdoor.bicep`](../../infra/dr/frontdoor.bicep). Decision: [ADR 0033](../adr/0033-dr-active-passive.md).

Changes require `-Apply`; `Verify` reads Azure and writes local state even without `-Apply`. The
driver records results in `frontdoor-state.json` in `standby.stateDirectory`.

> **Before full Deploy, Approve, DrainPrimary or Lockdown apply:** complete the one manual Entra batch, approved
> private paths, code publication and authenticated end-to-end region B checks in
> [DR standby sections 7.3-7.5](DR-STANDBY-CLOUD-SHELL.md#73-one-manual-entra-batch).
> `-ConfirmStandbyReady` is the operator's explicit confirmation, not an automated proof of those
> checks. The current existing-network path and guards have not been lab-tested end to end and do
> not establish customer connectivity. Older lab observations below are historical.

## 1. Configuration

The `frontDoor` section of the same `dr.config.json` that region B uses
([`dr.config.example.json`](../../infra/dr/dr.config.example.json)):

| Field | Example | Accepted values | Meaning |
| --- | --- | --- | --- |
| `frontDoor.stem` | `ccofprdfd` | 3-40 lowercase letters, digits and `-`, starting with a letter | Profile `<stem>-fd`, endpoint `<stem>`, WAF policy `<stem>waf` with hyphens removed. The endpoint name is global, so the stem must be unique |
| `frontDoor.wafMode` | `Detection` | `Detection`, `Prevention` | `Detection` logs WAF matches without blocking. Model prompts and code can match managed rules, so exclusions are tuned in `Detection` before `Prevention` (template comment) |
| `frontDoor.probeIntervalSeconds` | `30` | 5-255 | Seconds between health probes from each Front Door point of presence |

Full mode requires an admin Function App in both regions; primary-only mode requires one in A.
When using an existing profile, restore its state and confirm the configured stem, subscription,
resource group and saved profile ID against the actual profile before any deployment. The stem is
the prefix, **not** the full `<stem>-fd` profile name. The driver stops with
`frontdoor_target_mismatch` when a populated saved target field differs from the configured stem,
subscription, resource group, profile name or profile ID, and `frontdoor_target_unknown` when a
saved state has no complete target identity. It cannot identify an existing profile without saved
state or compare an absent field. Do not guess if state is lost: recover
and independently verify the target, run `Deploy` without `-Apply`, and review the what-if for
unexpected changes before proceeding ([target guard](../../infra/dr/DrStandby.psm1)).

## 2. Phases, in order

The session block from [DR standby region, section 4](DR-STANDBY-CLOUD-SHELL.md#4-set-up-cloud-shell)
defines `$repo` and `$cfg`. Before a full deployment, region B must have saved `Data`, `Shells`,
`Grants`, `Config`, `Network`, `Code` and `Verify` records with valid timezone-bearing completion
times. `Grants` must be at or after `Shells`; `Config` at or after `Grants`; `Network` at or after
`Shells`; `Code` at or after `Config` and `Network`; and `Verify` at or after `Data` and `Code`.
Rerunning an earlier phase can make later records stale. Rerun and verify affected dependent
phases rather than editing state ([`Get-DrFrontDoorReadinessProblem`](../../infra/dr/DrStandby.psm1)).

Complete and independently verify the Entra batch, approved Function App endpoints and DNS, private
publisher and region B application tests **before** full `Deploy -Apply` or `Approve -Apply`. An
approval can activate an already-deployed pending B origin; a full profile may already be routing to
B. Investigate and follow the approved incident procedure rather than assuming B is inactive.

| # | Command | Changes | Expect |
| --- | --- | --- | --- |
| 1 | `Deploy` without `-Apply` | Azure what-if; local parameter file | Review the profile, endpoint, origin groups, four origins, routes, WAF and security policy |
| 2 | `Deploy -Apply -ConfirmStandbyReady` | Deploys the full template | `Front Door deployed: https://<endpoint host>`; review and approve the private links |
| 3 | `... -Phase Approve -ConfigPath $cfg` | Nothing | For every origin target, prints each candidate's full target-side connection ID, private endpoint ID, request description and status for independent owner review |
| 4 | `Approve -Apply -ConfirmStandbyReady` with the reviewed new IDs | Approves only the independently reviewed pending connections on the two APIMs and two admin apps | Four exact IDs read back `Approved`; missing, duplicate, mismatched, unrelated or extra supplied IDs stop the apply |
| 5 | `Verify` | Azure read-only; invalidates old local verification before attempting the checks and records new verification only on success | Gateway status returns 200 and admin console 200 or 302 through the Front Door host; up to 30 attempts 30 s apart. This does not prove B served the requests |
| 6 | `Lockdown`, then `Lockdown -Apply -ConfirmStandbyReady` | Sets `publicNetworkAccess` to `Disabled` on both APIMs and both admin apps, one at a time, and reads it back | Already-private origins are skipped; others are polled for up to 45 minutes each |

After confirming the prerequisites and approving the changes:

```powershell
$fd = "$repo/infra/dr/Invoke-DrFrontDoor.ps1"
pwsh -NoProfile -File $fd -Phase Deploy -ConfigPath $cfg
pwsh -NoProfile -File $fd -Phase Deploy -ConfigPath $cfg -ConfirmStandbyReady -Apply
pwsh -NoProfile -File $fd -Phase Approve -ConfigPath $cfg
# STOP here until the target resource owners independently identify the exact new connections.
# Example only: after primary-only approval, replace BOTH placeholders with the reviewed B IDs.
$reviewedNew = 'REPLACE-full-B-gateway-connection-ID,REPLACE-full-B-admin-connection-ID'
pwsh -NoProfile -File $fd -Phase Approve -ConfigPath $cfg -ReviewedConnectionIds $reviewedNew -ConfirmStandbyReady -Apply
pwsh -NoProfile -File $fd -Phase Verify -ConfigPath $cfg
pwsh -NoProfile -File $fd -Phase Lockdown -ConfigPath $cfg
pwsh -NoProfile -File $fd -Phase Lockdown -ConfigPath $cfg -ConfirmStandbyReady -Apply
```

Run one command at a time and stop on failure. `-ConfirmStandbyReady` is required on full
`Deploy`, `Approve`, `DrainPrimary` and `Lockdown` applies, not on their previews. It also checks
current saved standby phase records before any Azure change. Neither check independently verifies
Entra approval, private publishing or live B traffic. Preserve the updated state and evidence
securely after each phase. Do not run standby or Front Door phases concurrently in different
sessions: the standby state files and readiness checks are not a distributed lock, and the owner must
stop if the underlying deployment or readiness changes during the review. On one machine, the Front
door driver and the standby driver read and write `frontdoor-state.json` under a short exclusive
`frontdoor-state.lock` file and write atomically. They write only if the file still has the content
they last read, so a long-running phase (for example `Verify` route polling) cannot overwrite a
concurrent change: it stops with `frontdoor_state_changed` and writes nothing. `Deploy`,
`DrainPrimary` and `RestorePrimary` compare against the state read before their configuration
change; if it changed meanwhile (for example a `Verify` recorded `verifiedAt` against the old or
half-applied configuration), they remove `verifiedAt`, record `verificationInvalidatedAt` and stop
with `frontdoor_state_changed`. Rerun that phase and then `Verify`. `frontdoor_state_locked` means
another run held the lock for about five seconds. In either case, inspect the state and rerun the
phase. This does not protect copies of the state directory on other machines.

### Independent connection-owner review is mandatory

The static `CCOF Front Door ...` request description is **not proof** that a request belongs to this
Front Door profile: another requester can use the same text. Preview lists all connections returned
on each target, including unrelated requests. Have the APIM and Function App resource owners
independently associate each full connection ID and private endpoint ID with the intended profile
using trustworthy evidence outside the description. **If the owner cannot establish that
association, STOP** and escalate; do not approve by text, target or proximity alone.

Pass `-ReviewedConnectionIds` as one comma-separated **string** through `pwsh -File`, with exactly
one independently reviewed full target-side connection ID for each origin without a previously
saved, revalidated approval. A fresh full deployment may need four IDs; the example above assumes
the two A IDs were saved by primary-only approval and only B's two are new. Do not include
previously saved IDs that have reviewed provenance, or additional candidates. Blank, repeated, wrong-target, wrong-request,
unrelated and extra IDs are refused before approval. The driver requires a nonempty endpoint ID,
the expected request description and an `Approved` or `Pending` status for a new ID, but those
checks do **not** independently establish profile ownership.

Previously saved IDs must still be found under their exact original target and read back `Approved`;
a missing or changed saved ID cannot be replaced by a description match, even if a replacement ID is
supplied. Stop and investigate rather than editing state. New approvals retain the original request
description. Immediately before each approval, the driver rechecks every selected exact ID, status,
endpoint and description; each approval and the complete plan must then read back `Approved` with the
same endpoint and description. A successful approval records the approved IDs as
`reviewedConnections`; only saved IDs with that provenance are reused without resupplying them.

State written by an older driver has saved IDs selected by request description and no
`reviewedConnections`. Those legacy IDs are **not** trusted: `Approve` stops with
`frontdoor_review_ids_required` until the owner independently reviews each legacy ID and supplies it
in `-ReviewedConnectionIds` (it must still be the exact saved ID and read back `Approved` with an
endpoint; a different ID for that origin is refused with `frontdoor_review_id_mismatch`). Until then,
`Verify`, `Lockdown` and `DrainPrimary` stop with `frontdoor_approval_unreviewed`.

An actual `Verify`, or an apply of `Deploy`, `Approve`, `DrainPrimary` or `RestorePrimary`,
invalidates earlier route verification before the relevant Azure operation; a later failure does not
reinstate it. `Verify` records `verifiedAt` only on success, so a failed rerun cannot authorize
`Lockdown`. Preserve the updated state and rerun `Verify` after a successful approval or change
([driver](../../infra/dr/Invoke-DrFrontDoor.ps1)).

Lab observations (2026-10-25):

- After the first deployment both routes returned the generic Front Door 404 on the first two tries
  and 200 on the third. `Verify` retries for that reason.
- The origin group's `deploymentStatus` stayed `NotStarted` while routing worked; the live 200
  responses and the approved connections were the evidence used.
- `Lockdown` of an APIM took about 45 minutes to read back `Disabled`.
- A rejected private endpoint connection cannot be approved again (`PrivateLinkStatusChangeNotAllowed`);
  the endpoint has to be deleted and recreated. `Approve` never rejects.

## 3. After Lockdown: code publishing to the admin apps

The BYO standby Function Apps remain private from Shells onward. `Code -Apply` requires
`-PrivatePublisher` on an approved in-network runner with app-specific approved `sites` private
endpoints and DNS for app and SCM names, as described in
[standby section 7.4](DR-STANDBY-CLOUD-SHELL.md#74-private-endpoints-and-code-publication).
It publishes all four packages and refuses to mark `Code` complete if admin publishing is skipped.
Cloud Shell is not assumed to have this private reachability.

The older [admin VM update runbook](ADMIN-UPDATE-FROM-VM.md) records an admin-only lab update; its
resource-creating setup needs separate approval and its older DR admin-skip description does not
describe the current driver. A standard primary Stage 7 without a private publisher may still skip a
private admin app. Do not change Function App public access to publish code.

## 4. Drill phases

| Phase | Effect | Reverse |
| --- | --- | --- |
| `DrainPrimary` | Sets an invalid host header (`dr-drill.invalid`) on A's two origins. Requires Front Door `Verify`; apply also requires current saved standby phases, completed manual/private/end-to-end checks and `-ConfirmStandbyReady` | `RestorePrimary` |
| `RestorePrimary` | Restores A's origin host headers and enables A's two origins only. Requires saved full-profile and primary state plus readable profile, A APIM, admin and origin metadata, but not B state/health, standby phase timestamps or `-ConfirmStandbyReady` | — |

For an approved drill, first complete [standby readiness](DR-STANDBY-CLOUD-SHELL.md#75-readiness-before-front-door):

```powershell
$fd = "$repo/infra/dr/Invoke-DrFrontDoor.ps1"
pwsh -NoProfile -File $fd -Phase DrainPrimary -ConfigPath $cfg
pwsh -NoProfile -File $fd -Phase DrainPrimary -ConfigPath $cfg -ConfirmStandbyReady -Apply
pwsh -NoProfile -File $fd -Phase RestorePrimary -ConfigPath $cfg
pwsh -NoProfile -File $fd -Phase RestorePrimary -ConfigPath $cfg -Apply
```

Do not delay recovery to prove B is healthy. If `frontdoor-state.json` is missing, restore the saved
**full-profile** state archive and A's staged configuration/state before `RestorePrimary`; a
primary-only state is insufficient. Restore does **not** redeploy the template or touch B origins:
it reads the exact profile, A targets and the two A origins, checks their IDs, hosts, Private Link
targets and priority, and previews their current and intended fields. It then PATCHes only
`properties.originHostHeader` and `properties.enabledState` on those A origins. Unexpected profile,
target, host, header, origin state or provisioning metadata is a **STOP**, not permission to guess.

The driver's API request follows Microsoft's
[AFD Origins Update (2025-04-15)](https://learn.microsoft.com/rest/api/frontdoorservice/azurefrontdoorstandardpremium/afd-origins/update)
and [AFD Origins Get](https://learn.microsoft.com/rest/api/frontdoorservice/azurefrontdoorstandardpremium/afd-origins/get):
PATCH can return `200` or asynchronous `202`. For `202` it tracks the returned
`Azure-AsyncOperation` or `Location` ARM URL, respects `Retry-After`, and requires successful
completion and exact origin readback. Polling is bounded; a missing/untrusted operation URL, failed,
canceled or timed-out operation, failed readback or unexpected unchanged field is a **STOP**. If
the first A origin succeeds and the second fails, A may be partially restored; inspect both before
retrying, and do not redeploy the full template as a shortcut. The operator needs permission to
track the operation at resource-group scope. The script obtains an ARM token through Azure CLI and
makes no Graph call.

`primaryRestoredAt` records verified **control-plane** fields, not edge propagation, origin health or
successful traffic. Check the actual A routes and metrics after recovery. The PATCH path has been
tested with offline fakes only, not against this customer's Azure profile; the owner must review the
preview and operation/readback evidence.

In the older lab run, which used a full-template restore rather than the current PATCH path, region
A's origin health was 0 % for about 25 minutes and 100 % about 45 minutes after deployment; the
drain took about 15 minutes. An unchanged re-PUT of the primary gateway origin was made about 30
minutes after that restore, and health rose after it; whether the re-PUT was needed was not
established. Do not treat those timings as validation of the current path. Health is read with:

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

**Switch:** `-PrimaryOnly` on [`Invoke-DrFrontDoor.ps1`](../../infra/dr/Invoke-DrFrontDoor.ps1).
It is never assumed: without the switch the driver still requires region B.

**What is deployed:** one APIM origin (`primary-gateway`) and one admin origin (`primary-admin`), both
priority 1 ([`DrStandby.psm1`](../../infra/dr/DrStandby.psm1) `New-DrFrontDoorParameters`).
The template accepts one or two origins per group
([`frontdoor.bicep`](../../infra/dr/frontdoor.bicep)). The profile `<stem>-fd`, endpoint
`<stem>`, origin groups `apim` and `admin`, routes `gateway` and `admin`, WAF policy and security
policy are named from `frontDoor.stem` only (`frontdoor.bicep` lines 46 and 55), so they are the same
in both modes.

**Configuration read in this mode** (`Get-DrFrontDoorPrimaryOnlyProblems`, `DrStandby.psm1`):

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
$fd = "$repo/infra/dr/Invoke-DrFrontDoor.ps1"
pwsh -NoProfile -File $fd -Phase Deploy  -ConfigPath $cfg -PrimaryOnly
pwsh -NoProfile -File $fd -Phase Deploy  -ConfigPath $cfg -PrimaryOnly -Apply
pwsh -NoProfile -File $fd -Phase Approve -ConfigPath $cfg -PrimaryOnly
# STOP until the resource owners independently identify the two exact A connection IDs.
$reviewedPrimary = 'REPLACE-full-A-gateway-connection-ID,REPLACE-full-A-admin-connection-ID'
pwsh -NoProfile -File $fd -Phase Approve -ConfigPath $cfg -PrimaryOnly -ReviewedConnectionIds $reviewedPrimary -Apply
pwsh -NoProfile -File $fd -Phase Verify  -ConfigPath $cfg -PrimaryOnly
```

- `Deploy` preview lists a profile, endpoint, two origin groups, two origins, two routes, WAF policy
  and security policy.
- `Approve -Apply` requires the independently reviewed ID for each new connection (one APIM, one
  admin app); saved IDs must still match and be `Approved`. It reads both exact IDs back.
- `Lockdown`, `DrainPrimary` and `RestorePrimary` refuse to run with `-PrimaryOnly`
  (`frontdoor_primary_only_phase_refused`). This mode does not change public access on the origins.
- `frontdoor-state.json` records `"mode": "primaryOnly"`.
- Primary-only `Deploy -Apply` does not require `-ConfirmStandbyReady`. Its saved endpoint host can
  be included in the one manual Entra batch before adding B.

**Client gateway URL:** `https://<endpoint host>/<apim.apiPath>`, for example
`https://<stem>-<hash>.z01.azurefd.net/anthropic`, with no trailing `/v1`. The endpoint host is printed
by `Deploy -Apply` and stored as `endpointHostName` in `frontdoor-state.json`. The `gateway` route
forwards the path unchanged to APIM. Staged Step 8 can test this address: set
`acceptance.gatewayUrl` to `https://<endpoint host>/<apim.apiPath>` in region A's `staged.config.json`
([Step 8](DEPLOY-STEP-BY-STEP.md#step-8-test-end-to-end)).

**Adding region B later:** build region B ([DR standby region](DR-STANDBY-CLOUD-SHELL.md)), complete
the one Entra batch and private/end-to-end readiness checks, and complete the full `dr.config.json`.
Then run `Deploy`, `Approve` and `Verify` from section 2 without `-PrimaryOnly`; full
`Deploy -Apply` and `Approve -Apply` require `-ConfirmStandbyReady` and current saved standby
evidence. The deployment is incremental and adds
`standby-gateway` and `standby-admin` to the
existing origin groups. Changing the mode clears the recorded approvals and verification but
retains prior connection IDs only for rechecking (`Set-DrFrontDoorStateMode`, `DrStandby.psm1`),
so `Approve` (four connections) and `Verify` must pass again before `Lockdown`.
Once the state records a full deployment, `-PrimaryOnly` is refused (`frontdoor_mode_mismatch`).
Region B may receive traffic as soon as its origin is usable; do not defer readiness until after
the full deployment.
