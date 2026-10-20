# Change log

## 2026-10-20 — Standard v2 and private Foundry, SASET MSFT FDPO and Contoso

- Stage 1 can create a keyless private Foundry account with Claude deployments
  (`foundry-account.bicep`; `modelProviderData` required, API `2025-10-01-preview`).
- Stage 2 integrates a Standard v2 APIM with the VNet (outbound) and creates the Foundry private
  endpoint with its three DNS zones.
- `sharedResourceGroup` and the guarded Stage 1 rerun: what-if must not change resources outside
  the deployment's prefix. State is bound to tenant/subscription/RG. Stage 8 correlates telemetry by
  this run's request IDs.
- Live: SASET MSFT FDPO (shared RG) stages 0-8 with 200 responses; Contoso stages 0-8 with new
  Entra objects, Claude blocked by the sandbox subscription, Graph consent refused without an active
  admin role ([report](STAGED-STDV2-RUNS-2026-10-20.md)).

## 2026-10-20 — Manual Portal walkthrough and verification gaps

- Added click paths for the staged guide, Foundry setup prerequisites, Standard v2 outbound
  networking, IAM and Entra checks, and the operations that still need Bicep or CLI.
- Embedded five existing masked Portal screenshots beside the relevant steps. They are
  labelled historical navigation references, not new FDPO/Contoso deployment evidence.
- Real Playwright Portal probes for FDPO and Contoso reached the Microsoft sign-in page.
  Fresh blade captures and the requested Standard v2 runs remain blocked on sign-in and
  confirmation of the separate SASET/personal FDPO targets.
- Documented unresolved APIM integration, Foundry provisioning, cross-target state reuse
  (reproduced offline) and uncorrelated telemetry acceptance. Bicep compilation and existing
  stage tests pass but do not prove those missing behaviours.
- Playwright verified the rendered guide's five images and internal anchor. A broken-image
  negative control failed as intended, and restoring the image passed.

## 2026-10-20 — Stages 2-8 implemented and run live

- New entry points in `infra/staged`: `stage2-network.bicep`, `stage3-schema.bicep`,
  `stage4-grants.bicep`, `stage6-config.bicep` (+ `stage6-api-telemetry.bicep`), and the driver
  `Invoke-StagedDeployment.ps1` (stages 0-8: preview by default, apply, read-back, state).
  Configuration: `staged.config.example.json`.
- Stage 1: optional APIM moved into `apim-service.bicep` (what-if failed on the conditional scope);
  `BasicV2` allowed; outputs `names` and `apimName` for later stages.
- Live run in a new lab RG after deleting the Stage 1 RG: all nine stages verified, gateway
  401/200/403 matrix, Admin V3 with live chargeback data
  ([report](STAGED-LIVE-RUN-2026-10-20.md), 20 screenshots in `docs/images/staged`).
- Tests: `tests/Test-StagedStages.ps1` (stage boundaries with a negative control, Cosmos
  contract against the quickstart, driver and configuration checks).
- Runbook rewritten: [configurable staged deployment](runbooks/STAGED-DEPLOYMENT-V2.md).

## 2026-10-20 — Stage 1 resources-only proof

- Completed live provider verification of the existing staged templates in an
  isolated new lab RG: 20 template resources at read-back (Application Insights
  later auto-added four Failure Anomalies alert rules, recorded in the report);
  all four private/keyless service checks pass, and no schema, application settings or runtime grants were created.
  Existing inference/admin deployments were not write targets. APIM is deferred.
- Added a scoped work ledger and local Ironclad charter/gate without installing
  hooks or changing CI. The stage contract remains the existing resources-only
  template and recursive offline test.
- Added the Stage 1 [live report](STAGE1-LIVE-VERIFICATION.md) and
  [permission/configuration/runbook](runbooks/STAGED-DEPLOYMENT-V2.md).
- Full packet gate, root regression/type-check/build and 95 admin tests pass.
  Later-stage entry points, Admin V3 Azure acceptance and scale/accessibility
  verification remain pending.
