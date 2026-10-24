# Editable Azure architecture

`ccof-network-architecture.drawio` contains two editable pages:

1. **Overview:** identity, gateway/Functions/registry/Foundry, subscription and
   network boundaries, and separate reporting.
2. **Detailed network and trust:** private endpoints, DNS/egress ownership,
   optional ingress/monetary/cross-tenant paths and evidence limits.

The README uses `ccof-architecture-overview.svg`. Architecture documentation links
the larger network SVG and both PNG previews. All service icons are original
[Microsoft Azure SVGs](icons/azure/ATTRIBUTION.md), embedded in the editable file
and vector previews; no network icon lookup is required when opening them.

## Regeneration

From the repository root:

```text
python docs/diagrams/ccof-network-architecture.py --png
```

Vector/draw.io generation uses Python's standard library; Pillow/Arial metrics
are used when available. PNG export additionally needs approved local Playwright
and Microsoft Edge. The generator does not download a browser or pretend that a
failed render succeeded. Use a consistent approved render host and inspect both pages.

Without `--png`, only vectors/editable source are regenerated; the hash check will
flag stale checked-in PNGs until they are regenerated. `render-manifest.json`
ties the draw.io, SVG and PNG exports together. `Test-ArchitectureAssets.ps1`
validates icon source hashes, preview hashes/dimensions, edge targets and the
PaaS-outside-VNet boundary rule without requiring a browser in CI.

Real deployment Resource IDs, addresses and endpoint values do not belong in this
public design diagram. Optional lines are not claims that those paths were deployed.

## Disaster recovery view

`dr-network-architecture.py` generates the left-to-right DR design with original Azure icons,
regional VNet/subnet boundaries, and separate managed Cosmos and Log Analytics boundaries.
The overview remains in `dr-active-passive.mmd` as a logical Mermaid view.

```text
python docs/diagrams/dr-network-architecture.py --png
```

This writes `docs/images/dr/dr-active-passive.svg`, its PNG preview, an editable
`dr-active-passive.excalidraw` scene with embedded original icons, and
`docs/images/dr/dr-render-manifest.json`. The manifest records generator and export hashes and
the original icon hashes. Without `--png`, only the SVG is regenerated.
The SVG embeds its icons and works without external requests.
