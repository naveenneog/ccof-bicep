# Runbooks

Step-by-step guides. Read them in this order for a new deployment:

| Order | Runbook | Who uses it | What it covers |
|---|---|---|---|
| 1 | [DEPLOY-STEP-BY-STEP.md](DEPLOY-STEP-BY-STEP.md) | Anyone deploying CCOF for the first time | Steps 0-8, each with a script, Azure CLI and Portal option, how to check it, and screenshots |
| 1a | [DEPLOYMENT-RUNBOOK.md](DEPLOYMENT-RUNBOOK.md) | Platform, identity and network teams | Handoff details: Entra apps and groups, managed identities, network design, permission-separated execution |
| 2 | [ADMIN-OPERATIONS.md](ADMIN-OPERATIONS.md) | CCOF administrators | Projects, people, models, limits, budgets, retirement, audit, another Foundry backend |
| 3 | [USER-ONBOARDING.md](USER-ONBOARDING.md) | Service desk, developers, Intune packaging | Client files, sign-in and Claude Code / Desktop setup |

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
