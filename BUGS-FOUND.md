# Bugs found: full-setup bug hunt

Scope: offline validation of the whole repository (build, typecheck, Node and PowerShell suites,
client tests, Bicep build of every template, PowerShell parse of every script, JSON and schema
checks), plus a review of the end-to-end setup flow (`docs/runbooks/AZURE-PORTAL-DEPLOYMENT.md`,
`docs/runbooks/CLOUD-SHELL-QUICKSTART.md`, scripts, infra, app settings, function names, timer
settings) and of the sync delegated-snapshot path. Live-lab findings from an Azure deployment were
folded in.

## Catalogue

| ID | Severity | Area | File:line | Symptom | Root cause | Fix status |
|---|---|---|---|---|---|---|
| B-01 | High | Infra / network | `infra/prereqs/network.bicep:31,75,92` | On a VNet created after 31 March 2026, the APIM and Functions integration subnets have no internet egress; Graph sync, Log Analytics queries and Application Insights ingestion fail. | New VNets default every subnet to private (`defaultOutboundAccess=false`); the template never set the property. | Fixed: `defaultOutboundAccess` parameter (default `true`) set on the APIM and Functions subnets; `false` only with customer NAT/firewall egress. Test: `tests/Test-Quickstart.ps1`. |
| B-02 | High | Docs / Portal guide | `docs/runbooks/AZURE-PORTAL-DEPLOYMENT.md:459-476,513` (Steps 03.3, 03.4) | Following the guide (Portal or CLI) creates private subnets without egress, even when the "Enable private subnet" box looked unchecked. | Guide did not mention the setting; CLI omitted `--default-outbound-access`. | Fixed: field-table row and note; CLI passes `--default-outbound-access true`. Test: `tests/Test-PortalGuide.ps1`. |
| B-03 | Medium | Docs / Portal guide | `docs/runbooks/AZURE-PORTAL-DEPLOYMENT.md:488,522,555` (Steps 03.3-03.5 checks) | Subnet checks print `prefix: null` on current API versions. | ARM now returns `addressPrefixes` (array) instead of `addressPrefix`. | Fixed: `addressPrefix \|\| addressPrefixes[0]`. Test: `tests/Test-PortalGuide.ps1`. |
| B-04 | Medium | Docs / egress checks | `docs/runbooks/AZURE-PORTAL-DEPLOYMENT.md:660-668` (Step 03.8); `docs/runbooks/CLOUD-SHELL-QUICKSTART.md:134-141` (1.2) | Egress checks cannot show a private subnet without NAT/firewall; Step 03.8 skipped the APIM subnet. | Queries omitted `defaultOutboundAccess` (and 03.8 `natGateway`). | Fixed: queries include both; 03.8 also reads the APIM subnet when known; guidance added. |
| B-05 | Medium | Docs / sync | `docs/SYNC.md:197-200` | Says reading group members "needs a role such as Global Reader" for the delegated snapshot: pushes operators towards a privileged role the path does not need. | Over-stated permission. Default user permissions let a member read groups and members; `snapshot` reads only `/groups/{id}/members?$select=id,accountEnabled` and the service-principal cast. | Fixed: no privileged role needed; ownership or a reader role only under restricted default permissions or hidden membership. |
| B-06 | Medium | Scripts / quick-start | `infra/quickstart/Deploy-Quickstart.ps1:684`; `infra/quickstart/Grant-SyncGraphPermissions.ps1:18-21` | Tells the operator to "use sync.mode delegated-snapshot", which step 1 of the same script refuses without the runner VM (`runner_required_for_delegated_snapshot`, line 119). | Message predates the no-VM apply through the sync Function App. | Fixed: points to the no-VM path (keep the timer disabled; CLOUD-SHELL-QUICKSTART section 5; SYNC.md). |
| B-07 | Low | Docs / Portal guide | `docs/runbooks/AZURE-PORTAL-DEPLOYMENT.md:2785-2791` (module 16) | The Portal path gives no route when no one can grant the Graph application permission; the exporter and manual path refuse a non-`application-permission` mode. | Missing cross-reference to the delegated snapshot applied through the Function App. | Fixed: "Without the grant" note (skip module 16, keep `AzureWebJobs.syncEntitlement.Disabled=true`, apply snapshots through the function). |
| B-08 | Low | Docs / Portal guide | `docs/runbooks/AZURE-PORTAL-DEPLOYMENT.md:1613,1621-1623` (Step 09.1) | The guide sends the operator to the Advanced tab for key access, anonymous access and TLS. | The Portal storage create form moved these to the Security tab. | Fixed: "Where" path and field table say Security. Test: `tests/Test-PortalGuide.ps1`. |
| B-09 | Info | Docs / Portal guide | `docs/runbooks/AZURE-PORTAL-DEPLOYMENT.md:563-565` (Step 03.6) | Extra round trip: zone, then link in a second form. | The Private DNS zone create form has a Virtual Network Links tab. | Fixed: note that Step 03.7 can be done in the same form. |
| N-01 | Info | Infra / poc | `infra/poc/phase3-cosmos-function.bicep:178` | Bicep linter warning `no-hardcoded-env-urls` (`core.windows.net`). | Proof-of-concept template, not on the supported path. | Not fixed: outside the deployment path; warning only. |
| N-02 | Info | Docs / ADR | `docs/adr/0024-single-administrator-quick-start.md:35` | Same "delegated-snapshot needs no application permission" wording as B-06. | Historical decision record. | Not fixed: ADRs record the decision as taken. |

## Checked, not bugs

- NSG rule protocol casing: ARM returns `TCP`; no script or doc in this tree compares protocol
  case-sensitively (Bicep only writes `Tcp`, which ARM accepts).
- Function names and timer settings: `syncEntitlement`, `registrySeed`, `snapshotApply`,
  `reconcileBudgets`, `resolve`, `health` match `AzureWebJobs.<fn>.Disabled` and the always-ready
  names in the guide.
- Delegated snapshot: `AzureCliCredential` with the Graph `.default` scope and the operator's tenant;
  the printed SHA-256 equals the snapshot file's; the apply helper verifies the same hash.
- App Insights `DisableLocalAuth` / `WorkspaceResourceId` (PascalCase in ARM), flattened `az apim
  show` output, `az ad group member check` output, ISO `P30D`, and the dns-zone-group `--zone-name`
  were reported by a review pass and are correct.
- `client/config.example.json` fails `validate-config.mjs` by design (placeholders); a filled copy
  validates. `config/core.answers.example.json` reports format problems only on placeholder values.

## Step-number mapping for the restructured guide

The guide being restructured on another branch renumbers modules. Carry these fixes across:
main Steps 03.3-03.5 (subnets) = new 21.2-21.4; 03.6/03.7 (DNS zone and link) = 21.6/21.7;
03.8 (egress) = the network egress check; 09.1 (storage) = 06.1; module 16 (Graph grant) = the
Graph-permission module.
