# Claude on Foundry — Azure API Management gateway

CCOF lets an organisation give its developers Claude (in Claude Code, VS Code or Claude Desktop)
through its own Azure subscription. Developers sign in with their Microsoft Entra ID account. An
Azure API Management (APIM) gateway checks which project they belong to, which Claude models that
project allows and how much of its budget is left, then forwards the request to the project's
Microsoft Foundry deployment. Usage is recorded per person and project for reporting and budgets.

This repository contains the source, templates and guides. It is not a running service; deploying
it creates billable Azure resources. Unfamiliar terms are explained in the [glossary](docs/GLOSSARY.md).

## How it works

[![Azure architecture: Entra trust, APIM, Functions, private registry, Foundry and network boundaries](docs/diagrams/ccof-architecture-overview.svg)](docs/diagrams/ccof-architecture-overview.svg)

1. A developer's tool sends a request with an Entra ID token and a project name.
2. APIM checks the token, asks the **resolver** app what the person may use, applies token limits,
   and forwards the request to the project's Foundry backend.
3. The **sync** app keeps project membership in step with Entra groups.
4. The **reconciler** app totals spend from the gateway logs and updates each budget.
5. The **admin console** manages projects, limits and budgets, and shows chargeback reports.

Details: [architecture](docs/ARCHITECTURE.md) ·
[editable draw.io](docs/diagrams/ccof-network-architecture.drawio) ·
[network](docs/NETWORK.md) ·
[icon attribution](docs/diagrams/icons/azure/ATTRIBUTION.md)

## Which guide to read

| You want to | Read |
| --- | --- |
| Understand the parts and the words used | [Glossary](docs/GLOSSARY.md), then [architecture](docs/ARCHITECTURE.md) |
| Deploy CCOF for an organisation, with separate identity, network and application teams (recommended) | [1. Deployment runbook](docs/runbooks/DEPLOYMENT-RUNBOOK.md), using the [staged deployment](docs/runbooks/STAGED-DEPLOYMENT-V2.md) |
| Deploy everything as one administrator into an existing network | [Cloud Shell quickstart](docs/runbooks/CLOUD-SHELL-QUICKSTART.md) |
| Create the resources by hand in the Azure Portal | [Azure Portal deployment](docs/runbooks/AZURE-PORTAL-DEPLOYMENT.md) |
| Configure resources that already exist, without Bicep | [Public access workbook](docs/runbooks/PUBLIC-ACCESS-WORKBOOK.md) |
| Add projects, people, models, limits and budgets | [2. Admin console operations](docs/runbooks/ADMIN-OPERATIONS.md) |
| Set up developers' machines | [3. User onboarding](docs/runbooks/USER-ONBOARDING.md) |
| Understand the 80% budget warning and why spend can pass 100% | [Budgets and spend pacing](docs/BUDGETS.md) |
| Let developers check their own spend | [Developer self-service usage](docs/USAGE-SELF-SERVICE.md) |
| Plan disaster recovery across two regions (design, not yet deployable) | [DR design](docs/DR-ACTIVE-PASSIVE.md) and [DR implementation](docs/design/DR-IMPLEMENTATION.md) |

Other documents describe earlier designs and are marked **Historical** at the top.

## Current release

| Part | Version | Source |
| --- | --- | --- |
| Gateway, resolver, sync, reconciler, templates | 0.2.0 plus the changes in [CHANGELOG](docs/CHANGELOG.md) | Branch `feat/budget-soft-limit` (not yet merged to `main`) |
| Admin console | 3.3.0 (`admin/package.json`) | Same branch |
| Developer client (`ccof-token`, `ccof-usage`) | 0.1.0 (`client/package.json`) | Same branch |

The last tagged release is [`v0.2.0`](docs/RELEASE-v0.2.0.md). Work in progress and open questions:
[STATUS](docs/STATUS.md) and [UNKNOWNS](docs/UNKNOWNS.md).

## What it looks like

Screenshots come from two lab deployments, called **Fabrikam lab** and **Contoso** in these documents.
Names, IDs, subscriptions and hosts in screenshots and reports are pseudonyms with the same shape as
the real values; the names are fictitious.

| | |
| --- | --- |
| ![Admin console overview with month-to-date cost](docs/images/staged/console-light-overview.png) | ![Staged deployment, stage 7 output](docs/images/staged/07-stage7-code-data.png) |
| Admin console: month-to-date cost by project, user and model | Staged deployment: one stage's output ([full run](docs/STAGED-LIVE-RUN-2026-10-20.md)) |
| ![ccof-usage output during the budget test](docs/images/budget/budget-run3-usage.png) | ![Admin console reconciler page](docs/images/staged/console-light-reconciler.png) |
| A developer's `/usage` at 71%, at the 80% warning and when exhausted ([budgets](docs/BUDGETS.md)) | Reconciler: each person's spend against their budget |

## Before you deploy

- Prerequisites and permissions: [Entra apps, groups and tools](docs/QUICKSTART-PREREQUISITES.md),
  [Azure and directory permissions](docs/PERMISSIONS.md).
- Replace every placeholder in the example forms (`infra\quickstart\customer-form.bicepparam`,
  `infra\staged\staged.config.example.json`) with your own tenant, subscriptions, groups and Foundry
  deployments. The examples are synthetic.
- Conditional Access, admin consent, tenant policy and private-network routing are owned by the
  customer's identity and network teams; the guides list what each team provides.
- Reference: [clients](docs/CLIENTS.md), [sync](docs/SYNC.md), [chargeback](docs/CHARGEBACK.md),
  [manual deployment](docs/MANUAL-DEPLOYMENT.md), [known manual-deployment fixes](docs/MANUAL-PORTAL-FIXES.md).

## Local verification

Requires Node.js, PowerShell 7, Python, Azure CLI with Bicep and, for the Kusto
semantic checks, a .NET SDK. Install the pinned dependencies after reviewing them:

```powershell
npm ci --ignore-scripts --no-audit --no-fund
npm test
npm run build
npx tsc -p tsconfig.typecheck.json
```

`npm test` runs every exported root Node and PowerShell suite, including the client
suite through its root test. It forces live integration off and uses repository-local
scratch. Private delivery-governance and portal-capture tooling are not part of this
public distribution; no private test assertion was weakened for export.

For a bounded local-mock driver, see [load testing](docs/LOAD-TESTING.md).
Mock metrics validate the driver, not APIM, Cosmos, real inference or billing capacity.
Do not aim a mock-only load command at an existing real Foundry route.

## Evidence and limits

The [configurable staged deployment](docs/runbooks/STAGED-DEPLOYMENT-V2.md)
runs CCOF in nine stages (`infra/staged/Invoke-StagedDeployment.ps1`), each with its own operator
permissions, preview, apply and read-back. The [live run report](docs/STAGED-LIVE-RUN-2026-10-20.md)
records all nine stages in a lab RG, from resources to authenticated model calls, with screenshots.

Offline tests are not live acceptance. Earlier quickstart seed resynchronization was
reported live-verified, but that does not prove the integrated v3 route, combined
client sign-in, second-subscription routing, workbook portal rendering or production load.
See [release verification](docs/RELEASE-v0.2.0.md) for the exact candidate results.

Fixed-price reporting is not Azure-settled billing or a proven dollar-enforcement
guarantee. Streamed cache usage can remain partial; unknown prices are explicitly
unpriced, never treated as zero. Customer compliance, retention, geography, negotiated
prices, Graph grants and production capacity must be decided and verified separately.

## License

License selection is still pending. No license file or grant of reuse rights is added
by this source publication; the package remains marked `UNLICENSED`.
