# CI/CD: deploy and manage a complete environment

This runbook covers one GitHub Actions workflow, [`deploy-environment.yml`](../../.github/workflows/deploy-environment.yml).
It deploys a new CCOF environment (for example Infosys Prod) from the folder `deploy/<environment>/`:

- Stages 0-7 in region A (East US 2);
- Front Door;
- the DR standby in region B (Central US);
- health alerts for both regions.

After the first run, the same workflow manages the environment. A rerun previews every step, which should show
NoChange, and applies only what changed. Manual network and Entra work is done at approval gates. The pipeline
only checks the results and never changes Entra.

Related files:

| File | Purpose |
|---|---|
| [`ccof-step.yml`](../../.github/workflows/ccof-step.yml) | Reusable job: sign-in, state restore, prerequisite checks, one driver step, evidence upload, state save, sign-out |
| [`drift-check.yml`](../../.github/workflows/drift-check.yml) | Scheduled read-only previews; opens an issue when Azure differs from the configuration |
| [`scripts/cicd/`](../../scripts/cicd/) | Prerequisite checks (`Test-CicdPrerequisites.ps1`), driver commands (`Invoke-CicdDriver.ps1`), drift (`Get-CicdDrift.ps1`), state (`Sync-CicdState.ps1`) |
| [`deploy/example/`](../../deploy/example/README.md) | Template for `deploy/<environment>/` |
| [CICD-NETWORK-ENTRA-CHECKLIST.md](CICD-NETWORK-ENTRA-CHECKLIST.md) | Printable checklist for the network and Entra teams |

## 1. How it works

- **Drivers.** Each job runs one existing driver command, without changes:
  - [`Invoke-StagedDeployment.ps1`](../../infra/staged/Invoke-StagedDeployment.ps1);
  - [`Invoke-DrPrerequisites.ps1`](../../infra/dr/Invoke-DrPrerequisites.ps1);
  - [`Invoke-DrStandby.ps1`](../../infra/dr/Invoke-DrStandby.ps1);
  - [`Invoke-DrFrontDoor.ps1`](../../infra/dr/Invoke-DrFrontDoor.ps1);
  - [`Invoke-HealthAlerts.ps1`](../../infra/monitoring/Invoke-HealthAlerts.ps1);
  - [`Invoke-DrFailover.ps1`](../../infra/dr/Invoke-DrFailover.ps1) (`Status` only).
- **Command builder.** `Get-CicdDriverCommand` in [`CicdDriver.psm1`](../../scripts/cicd/CicdDriver.psm1) builds each command. It refuses:
  - a Stage 4 that would write to Entra;
  - an approval that does not belong to the step;
  - an apply on the preview runner;
  - Front Door with the standby before the standby is ready;
  - failover changes.
- **Preview, then apply.** Every step runs as a preview first: what-if for Bicep steps, the printed plan for script steps. The apply job runs only when `apply` is true and the environment's reviewers approve it.
- **Sign-in.** The runner host's managed identity signs in through `.github/actions/azure-login-mi` (`az login --identity`). There is no Azure secret, no federated credential and no `azure/login`. Runner setup is described in `docs/runbooks/CICD-SETUP.md`.
- **Evidence.** Each job writes evidence to `evidence/<environment>/<step>-<mode>.log`, uploads it as an artifact, and adds the last 25 lines to the job summary.

Manual steps that the pipeline never runs:

| Step | Runbook |
|---|---|
| Entra registrations, groups and members | [DEPLOYMENT-RUNBOOK.md](DEPLOYMENT-RUNBOOK.md) |
| Stage 8 acceptance with a user token | [STAGED-DEPLOYMENT-V2.md](STAGED-DEPLOYMENT-V2.md) |
| Region B sites private endpoints and DNS (DR 7.4) | [DR-STANDBY-CLOUD-SHELL.md](DR-STANDBY-CLOUD-SHELL.md) |
| Front Door `Lockdown`, `DrainPrimary`, `RestorePrimary` | [DR-FRONT-DOOR.md](DR-FRONT-DOOR.md) |
| Failover `Fence`, `Promote`, `Failback` | [DR-STANDBY-CLOUD-SHELL.md](DR-STANDBY-CLOUD-SHELL.md) section 11 |

## 2. Prerequisites

`Test-CicdPrerequisites.ps1` checks the items below. It is read-only, runs at the start of every run, and writes
`prereqs.json` and `prereqs.md`. Each check reports pass, fail or manual, with an evidence line and a source
reference. The run stops on any fail. Items marked manual are confirmed at a gate.

| Area | What is checked | Owner if it fails |
|---|---|---|
| Configuration | Files present, no `REPLACE-` placeholders, staged and DR configs on one tenant and subscription, DR state paths match the folder layout | Deployment lead |
| Access | Workload and network resource groups exist; the pipeline identity holds the actions each scope needs (role assignments read with `assignedTo`) | Subscription owner |
| Subscription | Resource providers registered; Flex Consumption, API Management and Cosmos DB offered in both regions (API Management capacity: manual) | Subscription owner |
| Names | Front Door endpoint name (global) available, or owned by this environment per saved state. Other names derive from `stage1.prefix`; the Stage 1 what-if shows a clash | Deployment lead |
| Network | Region A and B VNets; subnets with the right delegation and size (API Management `Microsoft.Web/serverFarms` /27 or larger, Functions `Microsoft.App/environments` /27 or larger, private endpoints without delegation /28 or larger); APIM NSG; private DNS zones present and linked to both VNets; peering connected | Network team |
| Foundry | Accounts exist; Claude deployments present; Marketplace terms state where readable | Foundry owner |
| Front Door | Front Door name (`frontDoor.stem`) and WAF mode inputs | Platform owner |
| Entra | App and group IDs are GUIDs; read with Graph GET only when the identity may, else manual; `entra.manualVerification` present | Entra team |

Run it on a workstation from a PowerShell 7 prompt at the repository root (read-only, Azure CLI signed in). Call it in-process as shown: through `pwsh -File`, the `-Scope` list arrives as one string.

```powershell
./scripts/cicd/Test-CicdPrerequisites.ps1 -DeployDirectory deploy/<environment> -OutputDirectory out/prereqs -Mode apply -Scope primary,frontdoor,standby,health
```

Use `-Offline` to check only the files.

Before the first run:

1. The subscription owner creates the workload resource groups for region A and region B. The pipeline creates no resource group.
2. The network team builds the network in both regions. Work from [the checklist](CICD-NETWORK-ENTRA-CHECKLIST.md), part A.
3. The Entra team creates the registrations and groups. Work from the checklist, part B.
4. The Foundry owner deploys the Claude models and accepts the Marketplace offer.
5. A runner administrator sets up the two runners and identities (`docs/runbooks/CICD-SETUP.md`).
6. A repository administrator creates the GitHub environments (section 5).

## 3. Environment folder

The template is in [`deploy/example/`](../../deploy/example/README.md). The workflow reads these files:

| File | Used by | Required for scope |
|---|---|---|
| `staged.config.json` | Stages 0-7; read by DR and Front Door | every scope |
| `dr-standby.config.json` | DR prerequisites, standby, Front Door, failover status | `all`, `frontdoor-primary`, `standby`, `frontdoor-full` |
| `health-a.json` | Health alerts, region A | `all`, `health` |
| `health-b.json` | Health alerts, region B (DR standby: standby stem and group, `workspaceId` and `cosmosId` of the primary, shared and idle-standby rules off; [HEALTH-ALERTS.md](HEALTH-ALERTS.md) section 6) | `all`, `health` when `dr-standby.config.json` exists |
| `health-b.optout.json` | Explicit opt-out from region B alerts: `reason`, `approvedBy`, `approvedOn` (`yyyy-MM-dd`). Replaces `health-b.json`; the `resolve` job warns and the run summary shows NO REGION B HEALTH MONITORING | instead of `health-b.json` |

Rules:

- `entra.manualVerification` (`confirmedBy`, `confirmedOn` as yyyy-MM-dd) is required.
- `entra.existing` app IDs and every `groups[].groupId` are required.
- `groups[].members` is empty: group owners add members.
- In `dr-standby.config.json`, `standby.stagedConfigPath` is `staged.config.json`, `stagedStateDirectory` is `.staged-state` and `stateDirectory` is `.dr-state`. These paths are relative to the folder.
- `dr-standby.config.json` has no `entra` section. With one, DR Discover reads the applications through Graph and stops when the identity may not read them ([DR-STANDBY-CLOUD-SHELL.md](DR-STANDBY-CLOUD-SHELL.md) section 7.3).
- The folder holds no secret.
- Leave `failover.ledgerCoverageStartAt` empty until the coverage start is verified (DR runbook section 5.2). A `REPLACE-` value makes every failover phase refuse, including the final `Status`.
- Driver state is not committed with the configuration. It lives on the branch `cicd-state/<environment>` (section 8).

## 4. Identities and roles

There are two runners, each with its own user-assigned managed identity. Both runners are inside the
environment's VNet. Prod runners and identities are in the Prod subscription; no identity is shared between
environments.

| Runner (labels) | Identity roles | Runs |
|---|---|---|
| `ccof-preview` (`self-hosted, ccof-vnet, ccof-preview`) | Reader on the workload, network and Foundry scopes; Cosmos DB Built-in Data Reader | Pull request checks, `resolve`, gate checks, Stage 0, Stage 4 preview |
| `ccof-apply` (`self-hosted, ccof-vnet, ccof-apply`) | Contributor on the workload RGs; Network Contributor on the network RGs; Role Based Access Control Administrator, conditioned to the Stage 3 and Foundry roles | Every what-if preview, every verify and status step, every apply. Only inside a GitHub environment, never for a pull request |

What-if needs the same permissions as the deployment ([Learn: what-if permissions](https://learn.microsoft.com/azure/azure-resource-manager/templates/deploy-what-if#required-permissions)).
That is why previews run on the apply runner, in the environment `<environment>-preview`, which accepts only the
`main` branch. Verify steps that list app settings also need more than Reader.

Each job checks the runner role twice:

- `azure-login-mi` with `expected-role`;
- `Invoke-CicdDriver.ps1`, which refuses an apply unless `CCOF_RUNNER_ROLE=apply` (`runner_role_mismatch`).

The full role list with role IDs is in `docs/runbooks/CICD-SETUP.md` section 5.

## 5. GitHub environments, gates and approvers

Create these environments before the first run. In each one, set the deployment branch policy to the
`main` branch only. Add required reviewers to all except `-preview`. The `resolve` job refuses to start if any
environment is missing, has no reviewers, or has no branch policy. Without this check, GitHub would create an
unknown environment without protection.

| Environment | Approver | Approves |
|---|---|---|
| `<env>-preview` | none | Previews and verification on the apply runner |
| `<env>-apply` | Deployment owner (platform team) | Stage 1, 2, 3, 5, 6, 7 apply; Front Door primary Deploy; standby Data, Grants, Config, Code; health apply and test e-mail |
| `<env>-gate-network` | Network team lead | Network ready before Stage 0 (checklist part A); DR Bootstrap (peering, DNS links); standby Network (`PrivateNetworkChanges`) |
| `<env>-gate-entra` | Entra team lead | Stage 4: Entra settings done as in checklist part B and `entra.manualVerification` committed. The job then re-reads what it can, read-only |
| `<env>-gate-privatelink` | Resource owners (API Management, Function Apps) and network | Front Door private link approval of the listed connection IDs (`fd_reviewed_ids`); DR 7.3/7.4 handoff before standby Code |
| `<env>-gate-security` | Security officer | Standby Shells: public API Management bootstrap (`PublicApimBootstrap`, optional `PublicFunctionAccess`) |
| `<env>-gate-frontdoor` | Platform owner and DR owner | Front Door with region B origins (`StandbyReady`, scope `frontdoor-full`) |

Each approval is recorded in the job summary: who approved, when, and the comment.

## 6. Run order and timings

Start a run with **Actions > deploy-environment > Run workflow**, from `main`. The inputs are:

| Input | Meaning |
|---|---|
| `environment` | Folder name under `deploy/` |
| `apply` | If false, the run only previews |
| `scope` | `all`, `primary`, `frontdoor-primary`, `standby`, `frontdoor-full` or `health` |
| `fd_reviewed_ids` | Front Door private endpoint connection IDs reviewed by the resource owners. If empty, the run stops after the Approve preview |
| `approvals` | Optional: `ExistingVnetUpdate`, `CosmosThroughputReduction`, `PublicFunctionAccess` |
| `health_test_notification` | Send the health alert test e-mail |

The jobs run in this order. Each step previews, then waits for its gate, then applies. The times are lab apply
times in seconds:

1. **Before the stages**
   - `resolve`;
   - prerequisite checks;
   - gate network.
2. **Region A stages**

   | Step | Lab apply time (s) |
   |---|---|
   | Stage 0 | 50 |
   | Stage 1 resources | 156-288 |
   | Stage 2 Cosmos | 196-198 |
   | Stage 3 grants | 322-393 |
   | Stage 4: gate entra | 48-83 (manual verify is faster) |
   | Stage 5 config | 75-78 |
   | Stage 6 network | 740-759 |
   | Stage 7 code | 1279-1424 |

3. **Front Door, primary only**

   | Step | Lab apply time (s) |
   |---|---|
   | Deploy | 230 |
   | Approve (gate privatelink) | - |
   | Verify | up to about 900 (propagation) |

4. **DR standby**
   - Discover
   - Bootstrap (gate network)
   - Verify
   - Data: 452 s
   - Shells (gate security)
   - Grants: 276 s
   - Config: 119 s
   - Network (gate network): 179 s
   - handoff gate privatelink (DR 7.3/7.4)
   - Code: about 1100 s
   - Verify: 358 s
5. **Front Door with the standby** (scope `frontdoor-full` only, gate frontdoor)
   - Deploy
   - Approve
   - Verify
6. **Health alerts**
   - Region A: preview, then apply
   - Region B: preview, then apply (`health-b.json`; skipped only with `health-b.optout.json`, reported on every run)
   - Test e-mail (optional)
7. **`final`**
   - Failover `Status` (scopes `all`, `standby`, `frontdoor-full`)
   - Prerequisite checks again, for the scopes of the run (`primary`; `primary,frontdoor`; `primary,health`; or all four)

Sources for the times: [STAGED-STDV2-RUNS-2026-10-20.md](../STAGED-STDV2-RUNS-2026-10-20.md),
[DR-STANDBY-CLOUD-SHELL.md](DR-STANDBY-CLOUD-SHELL.md) and [DR-FRONT-DOOR.md](DR-FRONT-DOOR.md).

A complete first run takes about 3.5-4 hours of machine time. Waiting for approvals adds to that.

A failed job stops every later job. Fix the cause and rerun the workflow with the same inputs. Steps that are
already applied preview NoChange and apply idempotently. Saved state lets later stages read earlier outputs.

After Front Door with the standby (saved mode `full`), the driver refuses `-PrimaryOnly`. The `resolve` job reads the saved mode and skips the primary-only Front Door jobs on later runs.

## 7. Manage the environment afterwards

- **Configuration change.** Open a pull request that edits `deploy/<environment>/`. The pull request runs
  Stage 0 and the prerequisite checks on the preview runner. Pull requests from forks get no job. After the
  merge, run the workflow with `apply` false to review the previews. Then run it with `apply` true.
- **Drift.** [`drift-check.yml`](../../.github/workflows/drift-check.yml) runs on weekdays at 03:17 UTC for the
  environments in the repository variable `CCOF_DRIFT_ENVIRONMENTS` (a JSON array, for example `["infprod"]`).
  It previews Stages 1, 2, 3, 5, 6 and the health alerts whose files exist. `Get-CicdDrift.ps1` reports every what-if Create,
  Delete or Modify as drift, and every missing log as drift. Deploy and Unsupported lines are listed for review.
  On drift it opens an issue `Drift: <environment>` with the label `ccof-drift`, or comments on the open one.
  It never applies and never saves state.

## 8. Driver state

The drivers write their state into `deploy/<environment>/`:

- `.staged-state`;
- `.dr-state`;
- `.dr-evidence`;
- `.health-alerts-a`, `.health-alerts-b`.

[`Sync-CicdState.ps1`](../../scripts/cicd/Sync-CicdState.ps1) keeps this state on the orphan branch
`cicd-state/<environment>`:

- every job restores the state before it runs;
- apply and verify jobs save it afterwards, even when the job fails;
- pull request runs never save.
- pull request and drift runs read the branch with the job token (`CCOF_STATE_TOKEN`, passed to git through environment configuration, never on the command line), because those checkouts keep no credentials.

The branch holds no secret. Protect it with a ruleset so that only GitHub Actions can push.

To deploy from Cloud Shell instead, check out the branch into the folder. The drivers read the same files.

Runs never overlap for one environment (`concurrency: ccof-env-<environment>`).

## 9. Rollback per step

The drivers apply forward and are idempotent. To roll back, revert the configuration commit and rerun the step,
or use the manual action below.

| Step | Rollback |
|---|---|
| Stage 1 resources | Revert the config and rerun. The Bicep deployments are incremental and do not delete: remove an unwanted new resource by hand |
| Stage 2 Cosmos schema | Containers are additive; remove a wrong container by hand only when it is empty |
| Stage 3 grants | Remove the role assignment in the Portal (Access control) and rerun Stage 3 with the fixed config |
| Stage 4 Entra | Entra team reverts the registration change; update `entra.manualVerification` |
| Stage 5 configuration | Revert the config and rerun Stage 5 (settings, API, policy are overwritten) |
| Stage 6 network | Network team reverts the private endpoint or integration; rerun Stage 6 |
| Stage 7 code and data | Rerun Stage 7 from the previous commit (the packages are rebuilt from that commit) |
| Front Door | `DrainPrimary`/`RestorePrimary` by hand ([DR-FRONT-DOOR.md](DR-FRONT-DOOR.md)); delete the profile to remove it |
| DR standby | Each phase is independent; region B resources can be deleted without touching region A ([DR-STANDBY-CLOUD-SHELL.md](DR-STANDBY-CLOUD-SHELL.md)) |
| Health alerts | `Invoke-HealthAlerts.ps1 -Remove` from Cloud Shell ([HEALTH-ALERTS.md](HEALTH-ALERTS.md)) |

## 10. Runner security limits

- **Runner scope.** Organisation runner groups can limit a runner to selected repositories and workflows. For
  a repository owned by a user account, a self-hosted runner is scoped to the repository, and any workflow in
  that repository can target its labels.
- **Mitigations:**
  - no pull request jobs from forks;
  - pull request jobs never run on `ccof-apply`;
  - every apply job sits behind an environment with required reviewers and a `main`-only branch policy;
  - branch protection on `main`;
  - CODEOWNERS for `.github/workflows/` and `deploy/**`;
  - the runner role check in each job.
- **Dependency on the runner branch.** `.github/actions/azure-login-mi` and `scripts/cicd/Test-RunnerHost.sh` come from the runner setup change (`docs/runbooks/CICD-SETUP.md`). Merge that change before this workflow.

  See [GitHub: security hardening for self-hosted runners](https://docs.github.com/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners).
- **Inputs.** Workflow inputs reach scripts only through environment variables, never inline in `run:`.

## 11. References

- [Learn: sign in with a managed identity (`az login --identity`)](https://learn.microsoft.com/cli/azure/authenticate-azure-cli-managed-identity)
- [GitHub: deployment environments](https://docs.github.com/actions/managing-workflow-runs-and-deployments/managing-deployments/managing-environments-for-deployment)
- [GitHub: reusable workflows](https://docs.github.com/actions/sharing-automations/reusing-workflows)
- [STAGED-DEPLOYMENT-V2.md](STAGED-DEPLOYMENT-V2.md), [DEPLOYMENT-RUNBOOK.md](DEPLOYMENT-RUNBOOK.md),
  [DR-STANDBY-CLOUD-SHELL.md](DR-STANDBY-CLOUD-SHELL.md), [DR-FRONT-DOOR.md](DR-FRONT-DOOR.md),
  [HEALTH-ALERTS.md](HEALTH-ALERTS.md), [../DR-ACTIVE-PASSIVE.md](../DR-ACTIVE-PASSIVE.md)
