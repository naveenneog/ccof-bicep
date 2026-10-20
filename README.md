# Claude on Foundry — Azure API Management gateway

Deploy an identity-aware Claude gateway on Microsoft Foundry, with project routing,
per-family quotas, directory synchronization and fixed-price usage reporting.
This repository contains sanitized source and synthetic examples—not a running service.

## Architecture

[![Azure architecture: Entra trust, APIM, Functions, private registry, Foundry and network boundaries](docs/diagrams/ccof-architecture-overview.svg)](docs/diagrams/ccof-architecture-overview.svg)

[Editable draw.io — overview and detailed network pages](docs/diagrams/ccof-network-architecture.drawio) ·
[Detailed network SVG](docs/diagrams/ccof-network-architecture.svg) ·
[Architecture and evidence limits](docs/ARCHITECTURE.md) ·
[Microsoft Azure icon attribution](docs/diagrams/icons/azure/ATTRIBUTION.md)

Cloud-managed PaaS services are outside the subnet containing their private-endpoint
NICs. Outbound integration, private ingress, DNS/routing and identity authorization are
separate controls. Optional reconciliation is not an inference-path dependency.

## What v0.2.0 contains

- Strict family-policy contracts shared by the resolver, sync and reconciler.
  The gateway consumes decision version 3 and uses the `d3` cache namespace.
- Exact registered model IDs, aggregate and family ceilings, and classification
  restrictions. Fable/Mythos access requires authoritative classification `CYB`.
- Explicit project-to-backend mapping, including multiple designated subscriptions.
  A backend descriptor alone is not evidence that a second live route works.
- A combined developer-client/gateway registration by default. The internal resolver
  remains a separate API registration; its managed-identity authorization is unchanged.
- Project/classification-specific client exports and cached read/write token accounting.
- A complete chargeback workbook with fixed list-price reporting and historical
  attribution. `-Only 3` refuses missing, empty or tampered workbook artifacts.
- Modular manual deployment alongside the quickstart, including actual CLI regression
  coverage for manual dispatch.
- Fresh-create Application Insights dependency ordering and trigger resynchronization
  during the registry-seed wait. Both sync and reconciler host files are included.
- An editable [architecture overview](docs/ARCHITECTURE.md), with
  [draw.io source](docs/diagrams/ccof-network-architecture.drawio).

## Start here

1. Read [prerequisites](docs/QUICKSTART-PREREQUISITES.md) and
   [permissions](docs/PERMISSIONS.md).
2. Choose [quickstart](docs/QUICKSTART.md),
   [manual deployment](docs/MANUAL-DEPLOYMENT.md), or the
   [Azure Portal-first workbook](docs/runbooks/AZURE-PORTAL-DEPLOYMENT.md)
   for UI resource creation with only necessary, individually scoped CLI steps.
   If resources already exist, use the [no-Bicep public-access completion workbook](docs/runbooks/PUBLIC-ACCESS-WORKBOOK.md):
   manual client sign-in with full plain source (13), complete chargeback/report access (14),
   separately approved budget-state activation (15), and customer-owned private cutover (16).
3. Copy `infra\quickstart\customer-form.bicepparam` and replace every placeholder
   with your own approved tenant, subscriptions, identities, groups and backend deployments.
   Never deploy the synthetic examples unchanged.
4. Follow the selected guide. Review generated inputs before deployment.
5. Read [client configuration](docs/CLIENTS.md), [sync](docs/SYNC.md) and
   [chargeback](docs/CHARGEBACK.md) before accepting the result.

Deployment creates billable Azure resources and requires explicit directory/resource
permissions. No public test command deploys resources or sends paid Foundry traffic.
Conditional Access, consent, tenant policy and private-network reachability remain
operator prerequisites. Optional network features are distinguished from historical
mandatory-WAF/private-network diagrams in the architecture page.

[Manual deployment fixes](docs/MANUAL-PORTAL-FIXES.md) explain the region/path,
identity/role and seed-query fixes and distinguish code defects from permission or
acceptance prerequisites. The [Portal screenshot inventory](docs/runbooks/images/portal/README.md)
labels historical forms, navigation references and pending captures. Identifier
middles are masked; screenshots are not deployment values or live acceptance.

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
documents Stage 1 inputs, operator permissions and commands. Its
[Azure live proof](docs/STAGE1-LIVE-VERIFICATION.md) verifies resource-only
provisioning; the later-stage entry points and application acceptance remain separate.

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
