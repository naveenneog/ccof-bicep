# Existing-resource manual completion helpers

Use these from the reviewed repository checkout with
[the public-access completion workbook](../../docs/runbooks/PUBLIC-ACCESS-WORKBOOK.md).
They do not redeploy the core infrastructure or require Bicep.

```powershell
$repo = (Get-Location).Path
$bundle = Join-Path $repo 'scripts/manual'
$out = Join-Path $HOME 'ccof-private'
New-Item -ItemType Directory -Path $out -Force | Out-Null
. (Join-Path $bundle 'Session-Helpers.ps1')
```

Administrator helpers require PowerShell 7; `Run-Bundles.ps1` requires 7.2.
The separately documented developer CMD/Azure CLI routes support Windows PowerShell 5.1.
Keep inputs, generated settings, backups, seed payloads and reports outside the
repository with approved local access restrictions.

| File | Behavior |
|---|---|
| `Session-Helpers.ps1` | Dot-source only; Discovery reads existing values and canonicalizes provider regions; role/settings functions plan unless explicitly applied |
| `Run-Bundles.ps1` | Optional, separately approved bundle dispatch; plan by default; `-Apply` writes the selected scoped changes |
| `Build-LocalArtifacts.ps1` | Offline policy, create-only seed and report generation; no Azure write, no silent overwrite of changed seed documents |
| `Validate-Registry.mjs` | Uses the actual runtime validator with an in-memory store; creates no real Cosmos items |
| `*.example.json` | Templates only; replace placeholders with approved actual values |

Do not copy just this directory into isolation: helpers reuse the checked shared
modules under `scripts/`, including provider JSON/query handling and safe REST.
The client workstation does not need these administrator scripts or a repo clone;
Module 13 prints complete hand-configurable alternatives.

Important behavior:

- ARM identifiers compare case-insensitively; Cosmos database/container ID paths
  remain case-sensitive. Trailing separators do not create duplicate ARM identities.
- Cosmos custom-role verification accepts CLI enum and ARM resource-type response
  shapes but still refuses changed actions/scopes. Assignment read-back is bounded;
  deterministic IDs avoid creating another assignment on a retry.
- An incomplete `customer-values.json` is refused before role writes. The raw
  `customer-inputs.json` is not a substitute for successful discovery.
- Query results accept ARM `Tables/Columns/Rows` and data-plane
  `tables/columns/rows`, including ordered dictionaries and a single row.
- A seed passes only for the exact intended seed and every expected document.
  Cleanup remains mandatory after a failed or successful attempt.
- Role grants or source availability do not establish live acceptance or override
  customer permissions, Conditional Access, private reachability or financial approval.
