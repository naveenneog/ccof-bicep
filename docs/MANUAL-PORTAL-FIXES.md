# Manual deployment fixes and acceptance boundaries

This is a customer-neutral record of reproducible defects and operational lessons.
It contains no customer inputs, tenant IDs, access tokens or private issue logs.
The existing-resource workflow is [the completion workbook](runbooks/PUBLIC-ACCESS-WORKBOOK.md);
resource creation remains in [the Portal guide](runbooks/AZURE-PORTAL-DEPLOYMENT.md).

| Area | Change / disposition |
|---|---|
| Attached managed identities | Compare resource-ID keys ignoring ARM casing/trailing separators, read principal/client IDs from the attachment map, use an ARM read only when needed, refuse missing/ambiguous attachments |
| Incomplete discovery values | Refuse raw/incomplete inputs before a role write instead of submitting a null Cosmos scope |
| Existing Cosmos custom roles | Accept both CLI `CustomRole` and ARM role-definition resource type; retain exact action, exclusion and approved scope verification |
| Cosmos assignment verification | Compare ARM account portions ignoring case but retain exact database/container IDs; bounded read-back and deterministic retry IDs avoid false failures/duplicate IDs |
| Hidden table IDs | Name identifier columns `objectId`, `backendId` or similar rather than `id`, which the Azure CLI table formatter suppresses |
| Combined vs split app screenshots | Default is one combined gateway/developer registration plus a separate resolver API; redirects and API exposure are on the combined app. Lab/reference images are labelled, not a requirement to split it |
| Reconciler package assets | Absolute paths are no longer joined onto the repo twice; relative paths resolve against their stated base, and empty source paths fail explicitly |
| Reporting region | Discovery resolves display names through provider location metadata. Offline artifact build refuses old noncanonical values early; reporting errors identify safe field/reason codes without echoing private values |
| Query response casing/shape | Shared parser supports ordered dictionaries and objects, ARM/data-plane casing, message column order, one row and empty results; provider errors are not treated as no data |
| Seed check false positives | Complete script blocks and an exact seed/document assertion prevent later pasted lines from printing a false success after an earlier failure |
| Conditional seed registration | Document payload/startup/trigger-sync checks and mandatory cleanup; an enabled flag is not a completed seed |
| Project correlation | Compare the approved project and actual seed ID; a prior success for another project is not acceptance. Do not reseed or overwrite data solely to fix a query |
| Operator Cosmos read denial | Native data access belongs to the operator separately from Function App identities. Use an approved data reader; do not substitute Azure Contributor, write access or keys |
| Function App check queries | Azure CLI 2.91 nests site fields under `properties`; Steps 10.1/10.4 queries and the Step 13.6 evidence host-name read accept both shapes, and evidence refuses an empty resolver host name instead of rendering a null resolver URL |
| Private endpoint status queries | Checks read `manualPrivateLinkServiceConnections` or `privateLinkServiceConnections`, so manual-approval and auto-approved endpoints both report their real status instead of a blank |
| Telemetry deployment arguments | Step 20.2 wraps member access in `$(...)`; unquoted `name=$obj.prop` arguments sent `System.Collections.Hashtable...` to ARM |
| Manual client delivery | Full plain CMD/MJS source and approved Azure CLI options are documented. A one-file launcher is not standalone authentication and no native gateway protocol is implied |

## What these fixes do not do

They do not activate PIM, approve tenant consent, grant directory-wide rights,
create a customer's network, prove private routing, or validate production spending.
Data Explorer permissions, real sync outcomes, report reader access, usage completeness,
Conditional Access and the approved client route remain deployment prerequisites.
The optional reconciler's successful run outcome is `written`, not `succeeded`;
financial-mode activation requires real fresh state and approved delayed/freshness behavior.

Screenshots are historical forms or UI/navigation references with middle-only
identifier masks. Pending advanced-editor, consent, active financial-state and
private-cutover captures are explicit in the screenshot inventory. A masked image
is not current deployment proof.

## Regression coverage

- `Test-AzureResponse.ps1`: response shapes, region mapping, Cosmos path case,
  deterministic IDs and BOM-prefixed provider JSON.
- `Test-PublicManualHelpers.ps1`: mixed-case UAMI discovery/fallback, null-scope
  refusal, existing ARM-type roles, delayed read-back, no-write reruns and exact seed gates.
- `Test-PortalPackagePaths.ps1`: absolute/relative paths, alternate working directory,
  spaces, packaged extras and ZIP roots.
- `chargeback-report.test.ts`: actionable non-sensitive input diagnostics.
- Existing core, quickstart, Portal, resolver and client suites remain acceptance
  checks for preserved behavior; local mocks are not live Azure acceptance.
