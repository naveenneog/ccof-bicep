# Environment folder template

Copy this folder to `deploy/<environment>/` (lowercase letters, digits and `-`; for example `deploy/infprod/`),
replace every `REPLACE-` value, and open a pull request. The pipeline refuses the name `example`.

| File | Driver | Notes |
|---|---|---|
| `staged.config.json` | [`Invoke-StagedDeployment.ps1`](../../infra/staged/Invoke-StagedDeployment.ps1) Stages 0-7 | Field reference: [`staged.config.example.json`](../../infra/staged/staged.config.example.json). `entra.manualVerification`, `entra.existing` and every `groups[].groupId` are required: the pipeline never creates or changes Entra objects |
| `dr-standby.config.json` | [`Invoke-DrPrerequisites.ps1`](../../infra/dr/Invoke-DrPrerequisites.ps1), [`Invoke-DrStandby.ps1`](../../infra/dr/Invoke-DrStandby.ps1), [`Invoke-DrFrontDoor.ps1`](../../infra/dr/Invoke-DrFrontDoor.ps1) | Field reference: [`dr.config.example.json`](../../infra/dr/dr.config.example.json). Keep `standby.stagedConfigPath` = `staged.config.json`, `stagedStateDirectory` = `.staged-state`, `stateDirectory` = `.dr-state` (relative to this folder). No `entra` section: Entra stays manual. Leave `failover.ledgerCoverageStartAt` empty until the coverage start is verified (DR runbook section 5.2); a `REPLACE-` value makes every failover phase, including the final Status, refuse |
| `health-a.json` | [`Invoke-HealthAlerts.ps1`](../../infra/monitoring/Invoke-HealthAlerts.ps1) | Region A resource group. Field reference: [`health.config.example.json`](../../infra/monitoring/health.config.example.json). Set `apim.id` when Stage 1 uses an existing APIM, and `workspaceId` when the workspace is not `<stem>-law` |
| `health-b.json` | same | Region B (DR standby): DR `secondary.resourceGroup`, stem `<stem>-<standby.nameSuffix>`, `workspaceId` and `cosmosId` of the primary workspace and Cosmos account; shared Cosmos and Front Door rules and the idle-standby rules off; `foundryAccountIds` lists only region-B-only accounts (a shared account stays in `health-a.json`), with `foundryServerErrors` on ([HEALTH-ALERTS.md](../../docs/runbooks/HEALTH-ALERTS.md) section 6). Required with `dr-standby.config.json`; to run without region B alerts, replace it with `health-b.optout.json` (`reason`, `approvedBy`, `approvedOn`), shown as NO REGION B HEALTH MONITORING on every run |

Scope `all` needs `staged.config.json`, `dr-standby.config.json`, `health-a.json` and `health-b.json` (or `health-b.optout.json`). Without DR, omit `dr-standby.config.json` and run scope `primary`. Scope
`health` needs `staged.config.json` and `health-a.json`, plus `health-b.json` or `health-b.optout.json` with a DR configuration. The `resolve` job reports a missing file before anything
runs. No file holds a secret. Driver state (`.staged-state`, `.dr-state`, `.dr-evidence`,
`.health-alerts-a`, `.health-alerts-b`) is not committed here: the pipeline keeps it on the branch
`cicd-state/<environment>`.

Runbook: [CICD-ENVIRONMENT-DEPLOYMENT.md](../../docs/runbooks/CICD-ENVIRONMENT-DEPLOYMENT.md).
Checklist for the network and Entra teams: [CICD-NETWORK-ENTRA-CHECKLIST.md](../../docs/runbooks/CICD-NETWORK-ENTRA-CHECKLIST.md).
