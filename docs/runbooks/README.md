# Runbooks

Copy-paste runbooks. Each step is a block you paste as-is; values come from one variables block at
the top.

| Runbook | Use it for |
|---|---|
| [AZURE-PORTAL-DEPLOYMENT.md](AZURE-PORTAL-DEPLOYMENT.md) | Creating and connecting every resource in the Azure Portal; Cloud Shell only for artifact generation, per-app access grants and code publish |
| [CLOUD-SHELL-QUICKSTART.md](CLOUD-SHELL-QUICKSTART.md) | Deploying the core from Azure Cloud Shell into an existing VNet: discovery, form, validation, preview, deployment, member sync, checks, diagnostics |

Diagnostic scripts live in [`scripts/diagnostics/`](../../scripts/diagnostics/):

| Script | Purpose |
|---|---|
| `Find-SeedError.ps1` | Names the exact form field behind `seed_document_invalid` (read-only) |
| `windows-az-utf8/az.ps1` | Windows only: Azure CLI in UTF-8 mode for `'charmap' codec` errors |
# Existing resources and manual completion

Use [PUBLIC-ACCESS-WORKBOOK.md](PUBLIC-ACCESS-WORKBOOK.md) when the platform resources
already exist. It is the no-Bicep configuration/seed/client/report path, not a full
quickstart infrastructure redeployment. Modules 13–16 include full plain client source,
approved Azure CLI trust, reporting readers, optional monetary activation and customer-owned
private cutover. Its module numbers differ from the resource-creation guide below.

Real screenshots and their limits are listed in the [screenshot inventory](images/portal/README.md).
