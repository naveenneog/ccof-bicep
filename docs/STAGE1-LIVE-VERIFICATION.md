# Stage 1 live verification — 2026-10-20

Result: **PASS for resource-only provisioning and the checks below.**
This is not a runtime, customer-policy, networking or Admin V3 acceptance result.

## Run identity and configuration

| Field | Evidence |
| --- | --- |
| Source | `b116f63`; the deployed staged Bicep files were unchanged from that commit |
| Target | Fresh lab RG `ccof-stage1-20261020-rg`, eastus2; no existing CCOF RG was a deployment target |
| Deployment | `stage1-proof`, Incremental mode |
| Started / completed | 09:04:19 / 09:06:32 UTC, about 133 seconds |
| Read-back completed | 09:10:32 UTC |
| Prefix | `s1proof`; generated stem `s1proof-shq7x43u5xq6w` |
| Options | Admin included, Cosmos serverless, four Flex apps at Node 22 / 2048 MB / maximum scale 40 |
| Exposure | Cosmos, storage and Function public network access all Disabled |
| APIM | Not deployed; no public bootstrap approved |

## Evidence and result

| Check | Observed result |
| --- | --- |
| Target preflight | RG did not exist; resource inventory was empty after RG creation and immediately before deployment |
| Offline build | Main Bicep and Bicep parameter example compiled; JSON parameter example matched template parameters |
| Boundary test | 14 recursive template resource declarations checked; existing runbook's 27 PowerShell blocks parsed |
| Negative control | A valid Bicep fixture with an injected Azure role assignment compiled, then failed the intended recursive resource-type assertion; no mutated template was deployed |
| Azure provider validation | Succeeded |
| What-if | 32 Create changes, no Modify/Delete changes; includes storage child resources and per-app diagnostics |
| Actual deployment | Parent deployment Succeeded |
| Top-level inventory | Exactly 20: 1 workspace, 1 Cosmos account, 2 user-assigned identities, 4 storage accounts, 4 Flex plans, 4 Function Apps, 4 Insights components |
| Cosmos | Provisioning Succeeded; PNA Disabled, local authentication disabled; zero SQL databases and zero native data-role assignments |
| All four apps | PNA Disabled, no VNet subnet attachment, Node 22; zero application settings |
| App identities | Resolver/admin SystemAssigned; sync/reconciler UserAssigned; real principal IDs exported |
| All four storage accounts | Provisioning Succeeded; PNA Disabled, shared keys and public blobs disabled; firewall Deny / bypass None |
| Deployment containers | `app-package` exists in all four storage accounts with publicAccess None |
| Application Insights | Local authentication disabled on all four components |
| Diagnostics | Every Function App has `ccof-function-logs` targeting the new workspace |
| Azure grants | Zero role assignments scoped at or below the new RG; inherited operator access excluded |
| APIM outputs | ID and principal empty; status `deferred-no-public-bootstrap-approved` |

### Tooling findings

- What-if required `--no-pretty-print` for JSON parsing; `-o json` alone emitted
  display text. The runbook records the working command.
- An initial read-back used an unsupported `--scope` plus `--all` role-list
  combination. The completed verification used the ARM role-assignment list
  endpoint, checked pagination, and filtered actual assignment scopes.
- Diagnostic-settings CLI returned an array, not a `value` wrapper. The verifier
  was corrected before a PASS result was recorded.

These were verification-script issues; they did not require changing or weakening
the deployed resources.

## Regression and documentation checks

- Full packet gate: exit 0; `npm test`, `npx --no-install tsc --noEmit` and
  `npm run build` passed. The root regression ran in about 245 seconds.
- Admin: build succeeded, 95 tests passed, zero failures or skips.
- The new runbook's three PowerShell blocks parse and its local links resolve.
- Tests ran with live integration disabled and isolated logged-out Azure profiles;
  the live deployment/read-back used a separate lab profile.
- Existing file-size warnings remain in `admin/ui/app.js`, `admin/ui/v2.jsx` and
  `infra/quickstart/Deploy-Quickstart.ps1`. No baseline budget was relaxed.
- Documentation/source-boundary review: the templates are reused unchanged;
  the new plan labels unimplemented stages and does not grant permission through
  a documentation command or count resource provisioning as runtime acceptance.

## Retained artifacts

Raw evidence is private session material under `files/stage1-live`, not committed:
parameter set, RG and before/after inventories, provider validation, what-if,
deployment response/timestamps, `verify.ps1`, `verify.log`, `verified.json` and the
isolated negative-control fixture/log. No tokens or app-setting values are part
of this report.

The new lab resources are retained, with private ingress and no running
application configuration. They can incur charges. They were not deleted or
promoted to production.

## Limits and pending work

- No restricted Contributor-only test identity was created. The permission matrix
  is based on resource operations and documentation, not a live least-privilege
  certification.
- No APIM deployment/private cutover, Foundry deployment, Graph consent, runtime
  grants, Cosmos schema/seed, application publishing or network attachment ran.
- No Admin V3 live sign-in, root redirect, cost data or client onboarding test ran.
- Neither customer policy/quotas nor 10,000-project performance was established.
- The separate stages 2-8 remain design/documentation, not implemented entry points.

Commands and operator permissions:
[configurable staged deployment](runbooks/STAGED-DEPLOYMENT-V2.md).
