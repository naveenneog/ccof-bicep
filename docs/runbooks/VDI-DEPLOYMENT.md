# CCOF deployment, DR and email alerts from a Windows VDI

This guide separates platform deployment from developer onboarding. The commands
below are for the authorized operator, not for every developer. The detailed
[staged deployment guide](DEPLOY-STEP-BY-STEP.md) is the field and permission reference.

## 1. Prerequisites

- An approved repository copy, PowerShell 7.2 or later, Node.js 22 or later with npm,
  Azure CLI and Bicep. Stage 7 publishes built application packages.
- A private staged configuration, deployment-state folder and approved Azure CLI
  profile. The configuration starts from
  [`staged.config.example.json`](../../infra/staged/staged.config.example.json);
  identifiers, models, networking and permission decisions come from the platform teams.
- The appropriate Azure, network and Entra roles for each stage. The identity team
  handles app and group changes within the organization's approved permissions.
- Connectivity to the endpoints needed by each step. A VDI browser can open Azure
  Cloud Shell for management operations, but Cloud Shell does not automatically
  have access to private endpoints. Stage 7 publishing and stage 8 acceptance can
  require an approved private-network VDI or VM. Public ingress is not a prerequisite.

On the VDI, the following commands show installed tool versions:

```powershell
pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
node --version
npm --version
az.cmd version
az.cmd bicep version
```

Configuration and state contain internal resource IDs. They remain outside the
repository and in approved private storage. The driver records completed stages in
the state directory; later stages depend on that record.

## 2. Set the session and Azure account

Replace the placeholders with approved, absolute Windows paths and deployment values.
The CLI profile below is separate from other Azure CLI work. Its sign-in follows
the organization's Conditional Access policy.

```powershell
$repo = 'REPLACE-LOCAL-REPOSITORY-PATH'
$cfg = 'REPLACE-PRIVATE-STAGED-CONFIG-PATH'
$state = 'REPLACE-PRIVATE-STAGED-STATE-FOLDER'
$tenant = 'REPLACE-TENANT-ID'
$subscription = 'REPLACE-SUBSCRIPTION-ID'
$env:AZURE_CONFIG_DIR = 'REPLACE-PRIVATE-AZURE-CLI-PROFILE-FOLDER'
foreach ($value in @($repo, $cfg, $state, $tenant, $subscription, $env:AZURE_CONFIG_DIR)) {
    if ($value -match 'REPLACE-' -or [string]::IsNullOrWhiteSpace($value)) {
        throw 'Replace each placeholder with the approved value.'
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $repo 'infra\staged\Invoke-StagedDeployment.ps1') -PathType Leaf)) {
    throw 'The staged deployment script was not found in the repository copy.'
}
if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) {
    throw 'The private staged configuration was not found.'
}
Set-Location -LiteralPath $repo
```

The repository build uses the organization's approved package source or cache:

```powershell
npm.cmd ci --ignore-scripts --no-audit --no-fund
if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
npm.cmd run build
if ($LASTEXITCODE -ne 0) { throw 'Application build failed.' }
```

```powershell
az.cmd login --tenant $tenant --output none
if ($LASTEXITCODE -ne 0) { throw 'Azure CLI sign-in failed.' }
az.cmd account set --subscription $subscription
if ($LASTEXITCODE -ne 0) { throw 'Azure CLI subscription selection failed.' }
az.cmd account show --query "{tenant:tenantId, subscription:id}" --output table
if ($LASTEXITCODE -ne 0) { throw 'Azure CLI account check failed.' }
```

The displayed tenant and subscription are checked against the approved deployment.
The deployment scripts use the signed-in account; they do not sign in for the operator.
For a Cloud Shell session, use its own already-signed-in account and the
[Cloud Shell instructions](DEPLOY-STEP-BY-STEP.md#a-separate-azure-cli-sign-in),
not Windows paths or the VDI's Azure CLI profile.

## 3. Run stages 0-8

Stage 0 checks the configuration and access and records local state:

```powershell
pwsh -NoProfile -File .\infra\staged\Invoke-StagedDeployment.ps1 -Stage 0 -ConfigPath $cfg -StateDirectory $state
```

| Stage | Work |
| --- | --- |
| 1 | Azure resources |
| 2 | Cosmos DB schema |
| 3 | Runtime role assignments |
| 4 | Entra applications and groups, or the approved manual-verification path |
| 5 | Application settings, APIM policy and workbook |
| 6 | Network verification or the explicitly selected network mode |
| 7 | Application publishing and initial data |
| 8 | End-to-end acceptance using an authorized caller |

For each stage from 1 through 8, set `$stage` to that number and run the preview:

```powershell
$stage = 1
pwsh -NoProfile -File .\infra\staged\Invoke-StagedDeployment.ps1 -Stage $stage -ConfigPath $cfg -StateDirectory $state
```

After review and authorization for that stage, the separate apply command is:

```powershell
pwsh -NoProfile -File .\infra\staged\Invoke-StagedDeployment.ps1 -Stage $stage -ConfigPath $cfg -StateDirectory $state -Apply
```

Continue only after the stage completes and its result is verified. Stage 8 sends an
inference request and can incur usage. A preview is not an applied stage. For private
network and publishing prerequisites, see
[staged deployment](DEPLOY-STEP-BY-STEP.md#step-7-publish-the-code-and-load-the-first-data)
and [stage notes](STAGED-DEPLOYMENT-V2.md#stage-notes).

Cloud Shell without mounted storage is ephemeral: configuration and state are lost
when the session ends unless exported securely. The
[state export and restore steps](DEPLOY-STEP-BY-STEP.md#cloud-shell-without-storage-ephemeral-session)
cover the primary deployment. The standby guide requires durable storage.

## 4. Standby and failover

Standby deployment needs the primary configuration and state, a private DR
configuration, approved standby network and DNS, and the required Azure and Entra
permissions. The standby scripts are on `main`; dated branch and environment
observations in older runbooks describe the time of those tests.

The [standby runbook](DR-STANDBY-CLOUD-SHELL.md) contains `Discover`, `Bootstrap`
and `Verify` prerequisites, followed by `Data`, `Shells`, `Grants`, `Config`,
`Network`, `Code` and `Verify` phases. Review each preview before a separate apply.
The lab exercised the DR cycle, but the runbook identifies open qualification
items; it does not establish that a particular customer's standby is deployed or
production-qualified.

The DR `Discover` and `Config` paths read application registrations through
Microsoft Graph. Primary-stage `manualVerification` does not bypass those reads.
If Conditional Access or permissions prevent the reads, resolve that prerequisite
with the identity team before applying DR configuration: `Config -Apply` can make
Azure changes before a later directory read fails. Failover, writer promotion,
failback and Front Door routing are separate approved operations.

## 5. Email health alerts

The [health-alert runbook](HEALTH-ALERTS.md) describes the configuration and Azure
Monitor permissions. It does not require an Entra administrator or Microsoft Graph.
The operator supplies private `health.config.json` values, including approved
recipients and, when Front Door alerts are wanted, the correct profile resource ID
and hostname. A workstation run requires `AZURE_CONFIG_DIR` to point to a signed-in
profile.

From the repository folder in the same VDI session:

```powershell
$health = 'REPLACE-PRIVATE-HEALTH-CONFIG-PATH'
if ($health -match 'REPLACE-' -or -not (Test-Path -LiteralPath $health -PathType Leaf)) {
    throw 'Provide the approved private health configuration file.'
}
pwsh -NoProfile -File .\infra\monitoring\Invoke-HealthAlerts.ps1 -ConfigPath $health
```

The command is a preview. After reviewing the planned resources and approvals:

```powershell
pwsh -NoProfile -File .\infra\monitoring\Invoke-HealthAlerts.ps1 -ConfigPath $health -Apply
```

A separate test requests an email from the deployed action group:

```powershell
pwsh -NoProfile -File .\infra\monitoring\Invoke-HealthAlerts.ps1 -ConfigPath $health -TestNotification
```

The recipient confirms delivery. An existing Health page or a prepared configuration
alone does not establish that alert resources or email delivery are active.
