# Portal-first helpers

Use [the Azure Portal deployment workbook](../../docs/runbooks/AZURE-PORTAL-DEPLOYMENT.md).
Resources are created manually in the UI. These are not an all-resources deployment script.

| Entry point | Default effect | Explicit write action |
|---|---|---|
| `Export-PortalArtifacts.ps1` | Compile private form; validate UI evidence; generate settings, policy, seed and full chargeback content locally | None |
| `Build-PortalPackage.ps1` | Build one app ZIP with its own entry point, host.json and production dependencies | None; publish with the separate `az config-zip` command |
| `Grant-PortalAppAccess.ps1` | Show one existing app's least-privilege access plan; check live attached identity | `-Apply` grants and verifies runtime access; no admin privileges, Graph consent, resource/code/settings deployment |
| `evidence.example.json` | Placeholder record populated from Portal Properties/Identity views | None |

Copy inputs to git-ignored `.env` paths; never commit customer evidence, generated
artifacts or receipts. Restore these files after Cloud Shell disconnects and run only
the unfinished module/app. No script relies on Quickstart's state file.

The access helper reuses `Core.Permissions.psm1`, `Core.PermissionsApply.psm1` and
the existing assignment source files. It refuses custom-role rewrites, reuses
existing grants and writes per-app receipts. Graph permissions are a separate
privileged administrator approval using the existing narrow Graph helper.

The artifact exporter uses existing configuration/schema composers loaded with
`-DotSourceOnly`, not the Quickstart dispatcher. The package builder reuses staged
D2's per-app reachable-file packaging. Private settings are generated, never
automatically applied; the customer merges them in the Portal.
