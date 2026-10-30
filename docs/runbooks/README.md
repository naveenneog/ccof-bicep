# Runbooks

Step-by-step guides. Read them in this order for a new deployment:

| Order | Runbook | Who uses it | What it covers |
|---|---|---|---|
| 1 | [DEPLOY-STEP-BY-STEP.md](DEPLOY-STEP-BY-STEP.md) | Anyone deploying CCOF for the first time | Steps 0-8, each with a script, Azure CLI and Portal option, how to check it, and screenshots |
| 1a | [DEPLOYMENT-RUNBOOK.md](DEPLOYMENT-RUNBOOK.md) | Platform, identity and network teams | Handoff details: Entra apps and groups, managed identities, network design, permission-separated execution |
| 2 | [ADMIN-OPERATIONS.md](ADMIN-OPERATIONS.md) | CCOF administrators | Projects, people, models, limits, budgets, retirement, audit, another Foundry backend |
| 3 | [USER-ONBOARDING.md](USER-ONBOARDING.md) | Service desk, developers, Intune packaging | Client files, sign-in and Claude Code / Desktop setup |
| 4 | [DR-CLOUD-SHELL.md](DR-CLOUD-SHELL.md) | Operators adding disaster recovery after a single-region deployment | The DR parts deployable today, in Azure Cloud Shell: standby network and identities (P0-P2), workspace replication, per-project backend failover; and the parts not deployable yet |
| 5 | [DR-STANDBY-CLOUD-SHELL.md](DR-STANDBY-CLOUD-SHELL.md) | Operators building the DR standby region (region B) after P0-P2 | Cloud Shell setup with durable state, `dr.config.json` field reference with a full example, the seven region B driver phases (preview then apply), resuming after the 20-minute timeout; section 11: the lab failover drill, region B promotion, workspace switchover and failback to region A |
| 6 | [DR-FRONT-DOOR.md](DR-FRONT-DOOR.md) | Operators putting Front Door in front of both regions after region B is built | Front Door Premium phases (deploy, approve private links, verify, lock down public access), admin code publishing after lockdown, drain and restore of the primary origins with the measured propagation times |
| 7 | [ADMIN-UPDATE-FROM-VM.md](ADMIN-UPDATE-FROM-VM.md) | Operators publishing admin console updates and fix patches after Front Door lockdown | One-time VM setup (private endpoint, DNS, VM with managed identity, role), then each update: preview, publish through Run Command, verify, roll back |
| 8 | [HEALTH-ALERTS.md](HEALTH-ALERTS.md) | Operators adding e-mail alerts after Step 8 (with or without Front Door) | Action group, availability tests and alert rules for the admin Health page's signals; preview, apply, test notification and removal from Cloud Shell; creates only its own tagged resources |

Command reference for the deployment driver: [STAGED-DEPLOYMENT-V2.md](STAGED-DEPLOYMENT-V2.md).

Other ways to deploy, for specific situations:

| Runbook | Use it when |
|---|---|
| [CLOUD-SHELL-QUICKSTART.md](CLOUD-SHELL-QUICKSTART.md) | One administrator holds every role and deploys into an existing VNet from Azure Cloud Shell |
| [AZURE-PORTAL-DEPLOYMENT.md](AZURE-PORTAL-DEPLOYMENT.md) | Resources must be created by hand in the Azure Portal; Cloud Shell is used only for artifacts, access grants and code publishing |
| [PUBLIC-ACCESS-WORKBOOK.md](PUBLIC-ACCESS-WORKBOOK.md) | The resources already exist and need configuration, seeding, client files and reports, without Bicep |
| [STAGED-CUSTOMER-DEPLOYMENT.md](STAGED-CUSTOMER-DEPLOYMENT.md) | **Historical** four-stage plan and private VDI v1-to-v2 admin update; kept for reference |

The Portal deployment workbook starts with a linked module list; the public access workbook starts with
a progress sheet. Each module can be followed on its own.

Diagnostic scripts live in [`scripts/diagnostics/`](../../scripts/diagnostics/):

| Script | Purpose |
|---|---|
| `Find-SeedError.ps1` | Names the exact form field behind `seed_document_invalid` (read-only) |
| `windows-az-utf8/az.ps1` | Windows only: Azure CLI in UTF-8 mode for `'charmap' codec` errors |
Screenshots used in the Portal guides and their limits are listed in the [screenshot inventory](images/portal/README.md).
