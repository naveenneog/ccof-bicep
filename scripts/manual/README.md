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
| `Test-FoundryPrivatePath.ps1` | Small, read-only APIM → Foundry private-path configuration check; no credentials, keys or traffic probes |
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

## APIM → Foundry private-path check (Cloud Shell PowerShell)

From the already-pulled `~/ccof-bicep` checkout on `feat/project-admin-api`, replace
the placeholders below with full account/service IDs (not a Foundry project ID).
Only Azure CLI and PowerShell 7 are required; no npm/install/login step is run.

```powershell
Set-Location "$HOME\ccof-bicep"
$apimId = '/subscriptions/<APIM-SUBSCRIPTION>/resourceGroups/<APIM-RG>/providers/Microsoft.ApiManagement/service/<APIM-NAME>'
$foundryId = '/subscriptions/<FOUNDRY-SUBSCRIPTION>/resourceGroups/<FOUNDRY-RG>/providers/Microsoft.CognitiveServices/accounts/<ACCOUNT-NAME>'
& .\scripts\manual\Test-FoundryPrivatePath.ps1 -ApimResourceId $apimId -FoundryResourceId $foundryId
```

The checker discovers the hostname from backend **URLs only**, and the endpoint
from Foundry's connection references. It stops on ambiguity. For literal policy
URLs, multiple endpoints, or customer-managed/hub DNS, supply the relevant
overrides (omit parameters you do not need):

```powershell
$options = @{
    BackendHost = '<ACCOUNT-NAME>.services.ai.azure.com' # actual APIM backend host
    PrivateEndpointId = '/subscriptions/<PE-SUB>/resourceGroups/<PE-RG>/providers/Microsoft.Network/privateEndpoints/<PE-NAME>'
    PrivateDnsZoneIds = @(
        '/subscriptions/<CENTRAL-DNS-SUB>/resourceGroups/<CENTRAL-DNS-RG>/providers/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com'
        '/subscriptions/<CENTRAL-DNS-SUB>/resourceGroups/<CENTRAL-DNS-RG>/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com'
        '/subscriptions/<CENTRAL-DNS-SUB>/resourceGroups/<CENTRAL-DNS-RG>/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com'
    )
    DnsVnetResourceId = '/subscriptions/<DNS-SUB>/resourceGroups/<DNS-RG>/providers/Microsoft.Network/virtualNetworks/<DNS-HUB>'
}
& .\scripts\manual\Test-FoundryPrivatePath.ps1 -ApimResourceId $apimId -FoundryResourceId $foundryId @options
```

**Simplest for central DNS:** pass just the DNS subscription **name** (or GUID),
optionally its resource group. The checker finds the `privatelink.*` zone matching
the backend hostname there; no zone IDs needed:

```powershell
& .\scripts\manual\Test-FoundryPrivatePath.ps1 -ApimResourceId $apimId -FoundryResourceId $foundryId `
    -BackendHost '<ACCOUNT-NAME>.services.ai.azure.com' `
    -DnsSubscription '<Central DNS subscription name>' -DnsResourceGroup '<central-dns-rg>'  # RG optional
```

The name must be visible in `az account list --all`; if two subscriptions share
the name, pass the GUID. `-PrivateDnsZoneIds`, when given, takes precedence.

### Optional VDI/client DNS check

To check whether the central App Service private DNS zone is statically visible
to a VDI VNet, pass the VNet resource ID and the admin app's normal hostname.
This checks the `privatelink.azurewebsites.net` A record and link. Pass the
admin app private endpoint ID as well to compare the record to its actual NIC
IP. The DNS zone can be in a separate subscription/resource group; reuse
`-DnsSubscription` and `-DnsResourceGroup`, or give the full zone ID directly:

```powershell
& .\scripts\manual\Test-FoundryPrivatePath.ps1 -ApimResourceId $apimId -FoundryResourceId $foundryId `
    -BackendHost '<ACCOUNT-NAME>.services.ai.azure.com' `
    -DnsSubscription '<CENTRAL-DNS-SUBSCRIPTION-NAME>' -DnsResourceGroup '<CENTRAL-DNS-RG>' `
    -ClientVnetResourceId '/subscriptions/<VDI-SUB>/resourceGroups/<VDI-RG>/providers/Microsoft.Network/virtualNetworks/<VDI-VNET>' `
    -ClientHost '<ADMIN-APP>.azurewebsites.net' `
    -ClientPrivateEndpointId '/subscriptions/<APP-SUB>/resourceGroups/<APP-RG>/providers/Microsoft.Network/privateEndpoints/<ADMIN-APP-PE>'
```

`-ClientVnetResourceId` and `-ClientHost` must be provided together. The admin
app private endpoint ID is optional; without it, the checker reports the A
record but cannot verify its IP target. A completed zone link is a static
configuration check only: custom VDI DNS forwarding, VPN/on-premises resolver
behavior, and live VDI DNS are not proven. Run `Resolve-DnsName
<ADMIN-APP>.azurewebsites.net` on the VDI and compare the answer with the
private endpoint NIC IP.

Use `cognitiveservices.azure.com` or `openai.azure.com` and its corresponding
`privatelink.*` zone **instead** when that is the actual backend suffix. The check
requires only that hostname's zone, not all three. Cross-subscription/RG IDs are
followed directly, with **explicit `--subscription` on every GET**, without
changing the CLI's active subscription. Zone-group references are authoritative
cross-subscription zone IDs, never restricted to the workload subscription/RG.
`-PrivateDnsZoneIds` overrides discovery for centrally managed/manual records or
when zone groups cannot be read. Only zones matching the backend suffix are checked.
Reader access
is needed for every queried resource (including NICs, peerings and DNS links).
Central DNS/zone-group permission denials report **UNVERIFIED** with the exact
query scope and access code/action, not “zone missing” or success. Other CLI
failures remain explicit FAILs; raw diagnostics are withheld to avoid accidental
credential disclosure.

- Reports APIM SKU/outbound subnet/delegation, NSGs and UDRs, exact Foundry PE
  target/account group, provisioning/approval, NIC IPs/FQDNs, zone groups,
  hostname-specific A records, DNS links, custom DNS, and both direct peerings
  when VNets differ. Inbound APIM Private Link does **not** provide outbound access.
- Exit **1**: failed/incomplete static check; **2**: DNS permission gaps prevent
  full static verification (known static failures take precedence). Exit **0**: no detected static
  failure; **not** a working-path verdict. WARN/UNVERIFIED still require review.
  Routed hub/NVA topologies without direct peering are outside this small checker.
- DNS links do not propagate through peering. A hub link/custom DNS configuration
  cannot prove customer forwarding, Private Resolver rulesets or APIM cached DNS.
  NSG rule/route existence cannot prove effective firewall/NSG/return-path access.
- Public access enabled can mask a broken private path. A backend 403 appearing
  only with Foundry public access disabled strongly suggests network denial;
  a policy-wrapped 502 credential message alone does not prove an identity failure.

For an **additional host-network probe**, run this on an existing approved
VNet-connected host using the relevant DNS path (Cloud Shell only if appropriately
VNet-connected). Replace the hostname with the **exact** APIM backend hostname:

```powershell
$backendHost = '<ACCOUNT-NAME>.services.ai.azure.com'
[System.Net.Dns]::GetHostAddresses($backendHost) | Select-Object IPAddressToString
$tcp = [System.Net.Sockets.TcpClient]::new()
try {
    $tcp.ConnectAsync($backendHost, 443).WaitAsync([TimeSpan]::FromSeconds(10)).GetAwaiter().GetResult()
    'Host-network TCP 443 connected'
} finally { $tcp.Dispose() }
```

Compare resolved IPs to the checker’s **hostname-specific PE NIC IP**, not merely
whether they start with `10.` (private networks can use other address ranges).
This probe proves only that host's DNS/TCP, not APIM's DNS, TLS, managed identity
or model access. Final acceptance needs an actual APIM request/private-path
diagnostic, with credentials kept out of reports. Nothing here changes Azure.

Offline regression test: `pwsh -NoProfile -File .\tests\Test-FoundryPrivatePath.ps1`.
This focused companion deliberately leaves `Test-NetworkConfiguration.ps1`
unchanged: the older full-estate checker requires unrelated Functions/storage/
Cosmos inputs and its optional admin health check reads a function key.
