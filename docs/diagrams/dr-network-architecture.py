"""Render the proposed DR network design with original Microsoft Azure icons."""

import argparse
import base64
import hashlib
import html
import json
from pathlib import Path
import textwrap
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
ICONS = ROOT / "docs" / "diagrams" / "icons" / "azure"
OUT = ROOT / "docs" / "images" / "dr"
W, H = 3600, 2320
BLUE, GREEN, PURPLE, GRAY, ORANGE = (
    "#0078d4", "#107c10", "#7650a3", "#607080", "#ba5100"
)
parts, nodes, links, used_icons = [], {}, [], set()


def text(x, y, lines, size=21, bold=False, color="#172334"):
    if isinstance(lines, str):
        lines = [lines]
    spans = "".join(
        f'<tspan x="{x}" dy="{0 if i == 0 else size * 1.4}">'
        f"{html.escape(line)}</tspan>"
        for i, line in enumerate(lines)
    )
    parts.append(
        f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}"'
        f' font-weight="{600 if bold else 400}">{spans}</text>'
    )


def icon(name, x, y, size=48):
    used_icons.add(name)
    raw = (ICONS / f"{name}.svg").read_bytes()
    uri = base64.b64encode(raw).decode()
    parts.append(
        f'<image x="{x}" y="{y}" width="{size}" height="{size}"'
        f' preserveAspectRatio="xMidYMid meet"'
        f' href="data:image/svg+xml;base64,{uri}"/>'
    )


def panel(key, x, y, w, h, title, *, color=BLUE, fill="none",
          dashed=False, symbol=None, subtitle=None):
    nodes[key] = dict(x=x, y=y, width=w, height=h, boundary=True)
    dash = ' stroke-dasharray="10 7"' if dashed else ""
    parts.append(
        f'<g id="{key}"><rect x="{x}" y="{y}" width="{w}" height="{h}"'
        f' rx="14" fill="{fill}" stroke="{color}" stroke-width="2"{dash}/></g>'
    )
    if symbol:
        icon(symbol, x + 18, y + 15, 38)
    text(x + (70 if symbol else 22), y + 42, title, 23, True)
    if subtitle:
        text(x + 22, y + 74, subtitle, 18, color=GRAY)


def card(key, x, y, w, h, title, lines=(), *, symbol=None, color=BLUE,
         fill="#ffffff", standby=False):
    nodes[key] = dict(x=x, y=y, width=w, height=h, boundary=False)
    dash = ' stroke-dasharray="7 5"' if standby else ""
    parts.append(
        f'<g id="{key}"><rect x="{x}" y="{y}" width="{w}" height="{h}"'
        f' rx="9" fill="{fill}" stroke="{color}" stroke-width="1.7"{dash}/></g>'
    )
    if h <= 60:
        if symbol:
            icon(symbol, x + 10, y + 10, 30)
        text(x + (50 if symbol else 15), y + 32, title, 17, True)
        return
    offset = 80 if symbol else 20
    if symbol:
        icon(symbol, x + 18, y + 17, 46)
    title_lines = textwrap.wrap(title, max(16, int((w - offset - 18) / 12)))
    text(x + offset, y + 33, title_lines, 22, True)
    start = y + 52 + len(title_lines) * 29
    wrapped = []
    for line in lines:
        wrapped.extend(textwrap.wrap(line, max(18, int((w - 40) / 10.6))))
    last_baseline = start + 4 + max(0, len(wrapped) - 1) * 19 * 1.4
    assert last_baseline + 5 <= y + h, (key, wrapped)
    text(x + 20, start + 4, wrapped, 19)


def wire(key, source, target, points, label="", *, color=BLUE,
         dashed=False, at=None, arrow=True):
    links.append(dict(id=key, source=source, target=target))
    coords = " ".join(f"{x},{y}" for x, y in points)
    dash = ' stroke-dasharray="9 6"' if dashed else ""
    marker = f' marker-end="url(#arrow-{color[1:]})"' if arrow else ""
    # White under-stroke keeps a crossing distinguishable from a junction.
    parts.append(
        f'<polyline points="{coords}" fill="none" stroke="white"'
        f' stroke-width="7"/>'
        f'<polyline id="{key}" points="{coords}" fill="none" stroke="{color}"'
        f' stroke-width="2.5" stroke-linejoin="round"{dash}{marker}/>'
    )
    if label:
        x, y = at
        width = max(len(s) for s in label.split("\n")) * 9.4 + 14
        count = len(label.split("\n"))
        parts.append(
            f'<rect x="{x - 5}" y="{y - 18}" width="{width}"'
            f' height="{count * 24 + 5}" rx="3" fill="white" fill-opacity=".96"/>'
        )
        text(x, y, label.split("\n"), 18, color=color)


def regional_lane(letter, x, location, standby):
    # Title and subtitle end left of the diagnostic-log wires (x ~ 1490).
    status = "PASSIVE" if standby else "ACTIVE"
    panel(
        f"region-{letter}", x, 1360 if standby else 430, 1600, 800,
        f"REGION {letter} - {location} - {status}",
        color=GRAY, subtitle=("Warm standby; " if standby else "Serving; ") + "services sit outside the VNet."
    )
    y = 1360 if standby else 430
    card(
        f"apim-{letter}", x + 40, y + 100, 430, 155, "APIM Standard v2",
        ["Private gateway; not VNet-injected",
         "Outbound VNet integration",
         "Messages + personal /usage APIs"],
        symbol="api-management", standby=standby
    )
    card(
        f"resolver-{letter}", x + 520, y + 100, 450, 155, f"Resolver {letter}",
        ["Entitlement + personal /usage reads", "Private ingress; APIM-only identity"],
        symbol="functions", standby=standby
    )
    card(
        f"admin-{letter}", x + 1020, y + 100, 540, 155, f"Admin console {letter}",
        ["Read-only until fenced promotion" if standby else "Active writer + permanent change record",
         "Separate Front Door private origin"],
        symbol="functions", standby=standby
    )
    card(
        f"pool-{letter}", x + 40, y + 300, 430, 155, f"Model-specific pool {letter}",
        ["Local members: priority 1", "Remote members: priority 2",
         "Circuit breaker on each member"],
        color=ORANGE, fill="#fff8ec"
    )
    card(
        f"jobs-{letter}", x + 520, y + 300, 1040, 155, f"Membership sync + reconciler {letter}",
        ["Timers OFF until fenced promotion + ledger continuity gate" if standby
         else "Timers ON; one active writer set; Cosmos leases",
         "Graph group reads; budgetState writes; authoritative ledger queries"],
        symbol="functions", color=GREEN, standby=standby
    )
    panel(
        f"vnet-{letter}", x + 40, y + 500, 1520, 270,
        f"CUSTOMER VNET {letter} - {location}",
        dashed=True, symbol="vnet",
        subtitle="Only delegated integration subnets and private endpoint NICs are inside."
    )
    panel(
        f"apim-subnet-{letter}", x + 60, y + 595, 350, 145,
        "APIM integration", dashed=True, symbol="subnet"
    )
    text(x + 80, y + 675, ["Microsoft.Web/serverFarms", "NSG + approved routes"], 18)
    panel(
        f"functions-subnet-{letter}", x + 440, y + 595, 390, 145,
        "Functions integration", dashed=True, symbol="subnet"
    )
    text(x + 460, y + 675, ["Microsoft.App/environments", "Separate outbound integration"], 18)
    panel(
        f"pe-subnet-{letter}", x + 860, y + 590, 680, 155,
        "Private endpoint subnet", dashed=True, symbol="private-endpoints",
        subtitle="Undelegated; endpoint NICs only, not service instances."
    )
    for idx, (n, title) in enumerate([
        ("monitor-pe", f"M-{letter}: AMPLS"),
        ("cosmos-pe", f"C-{letter}: Cosmos"),
        ("foundry-pe", f"F-{letter}: Foundry"),
    ]):
        card(f"{n}-{letter}", x + 875 + idx * 215, y + 675, 205, 49,
             title, symbol="private-endpoints")
    text(x + 880, y + 744, "+ Function sites and per-app blob private endpoints", 16)
    wire(
        f"resolve-{letter}", f"apim-{letter}", f"resolver-{letter}",
        [(x + 470, y + 150), (x + 520, y + 150)], dashed=standby
    )
    wire(
        f"select-{letter}", f"apim-{letter}", f"pool-{letter}",
        [(x + 255, y + 255), (x + 255, y + 300)], dashed=standby
    )
    wire(
        f"integrate-apim-{letter}", f"apim-{letter}", f"apim-subnet-{letter}",
        [(x + 40, y + 185), (x + 18, y + 185), (x + 18, y + 655),
         (x + 60, y + 655)],
        color=GRAY, dashed=True
    )
    wire(
        f"integrate-fn-{letter}", f"resolver-{letter}", f"functions-subnet-{letter}",
        [(x + 745, y + 255), (x + 745, y + 270),
         (x + 495, y + 270), (x + 495, y + 480),
         (x + 635, y + 480), (x + 635, y + 595)], color=GRAY, dashed=True
    )
    wire(
        f"private-model-{letter}", f"pool-{letter}", f"foundry-pe-{letter}",
        [(x + 255, y + 455), (x + 255, y + 487), (x + 1420, y + 487),
         (x + 1420, y + 675)],
        color=ORANGE, dashed=standby
    )


def build():
    text(40, 52, "CCOF | Active/passive DR with private Standard v2 gateways and multiple Foundry backends", 34, True)
    text(40, 90, "PROPOSED DESIGN - not deployed or failover-qualified. Original Microsoft Azure service icons; no customer-specific addresses.", 22)
    panel("users", 40, 420, 360, 530, "CUSTOMER USERS / VDI", symbol="users")
    card("developers", 65, 505, 310, 120, "Developers",
         ["Claude Code / VS Code", "Claude Desktop"], symbol="users")
    card("admins", 65, 655, 310, 120, "Administrators",
         ["Browser on corporate VDI"], symbol="users")
    card("readers", 65, 805, 310, 120, "Report readers",
         ["Chargeback / workbook"], symbol="users")
    card("workbook", 500, 150, 430, 140, "Chargeback workbook",
         ["Both APIM resource IDs", "Actual serving-backend attribution"], symbol="workbooks", color=GREEN)
    panel("entra", 2680, 130, 880, 270, "MICROSOFT ENTRA ID - CUSTOMER TENANT", color=PURPLE, symbol="tenant")
    for idx, (key, title, name) in enumerate([
        ("gateway-app", "Gateway app - access_as_user", "app-registration"),
        ("admin-app", "Admin app - Projects.Read / Projects.Write", "app-registration"),
        ("groups", "Entitlement groups - STD / PRM / CYB", "groups"),
    ]):
        card(key, 2710, 200 + idx * 61, 820, 53, title, symbol=name, color=PURPLE)
    card("dns", 1960, 130, 650, 180, "Central private DNS + regional routes",
         ["VNet links, hub peering and DNS forwarding",
          "Foundry / Cosmos / Functions / blob / Monitor",
          "DNS links alone do not provide connectivity"], symbol="dns", color=GREEN)
    card("front-door", 490, 1170, 440, 210, "Azure Front Door Premium",
         ["(WAF + built-in DDoS protection)",
          "APIM A priority 1 / B priority 2",
          "Private origins; caching OFF",
          "Separate private admin origin group"], symbol="front-door", color=ORANGE, fill="#fff8ec")
    icon("waf", 845, 1187, 45)
    text(490, 1425, ["Front Door is the public edge.", "Its private endpoints are Microsoft-managed;",
                      "they are not NICs in the customer VNet."], 20)
    regional_lane("A", 1000, "East US 2", False)
    regional_lane("B", 1000, "Central US", True)
    wire("signin", "developers", "gateway-app",
         [(375, 540), (425, 540), (425, 340), (2650, 340), (2650, 225), (2710, 225)],
         label="Delegated sign-in / gateway audience", at=(1240, 330), color=GRAY)
    wire("admin-signin", "admins", "admin-app",
         [(375, 690), (445, 690), (445, 360), (2630, 360), (2630, 286), (2710, 286)],
         label="Admin sign-in", at=(2200, 350), color=GRAY)
    wire("users-edge", "developers", "front-door",
         [(375, 595), (460, 595), (460, 1240), (490, 1240)],
         label="HTTPS + gateway token", at=(480, 1125))
    wire("admin-edge", "admins", "front-door",
         [(375, 745), (440, 745), (440, 1310), (490, 1310)], color=GRAY)
    wire("report-workbook", "readers", "workbook",
         [(375, 840), (405, 840), (405, 220), (500, 220)], color=GREEN)
    wire("edge-a", "front-door", "apim-A",
         [(930, 1215), (955, 1215), (955, 610), (1040, 610)],
         label="Managed Private Link / primary", at=(520, 980))
    wire("edge-b", "front-door", "apim-B",
         [(930, 1300), (975, 1300), (975, 1540), (1040, 1540)],
         label="Managed Private Link / DR", at=(520, 1540), dashed=True)
    wire("edge-admin-a", "front-door", "admin-A",
         [(930, 1250), (940, 1250), (940, 410), (2290, 410), (2290, 530)],
         color=GRAY)
    wire("edge-admin-b", "front-door", "admin-B",
         [(930, 1340), (940, 1340), (940, 1340), (2290, 1340), (2290, 1460)],
         color=GRAY, dashed=True)

    panel("foundry-service", 2680, 450, 880, 390,
          "MULTIPLE FOUNDRY BACKENDS - OUTSIDE VNets", color=GREEN, symbol="foundry")
    card("foundry-A", 2720, 535, 800, 125, "Foundry A1 + A2 | East US 2",
         ["Equivalent approved model / deployment / geography",
          "Private endpoints F-A; local priority 1 in pool A"], symbol="foundry", color=GREEN)
    card("foundry-B", 2720, 690, 800, 125, "Foundry B1 + B2 | Central US",
         ["Equivalent approved model / deployment / geography",
          "Private endpoints F-B; local priority 1 in pool B"], symbol="foundry", color=GREEN)
    text(2685, 880, "Each pool: member breaker opens -> skip; cooldown -> permit again.", 19)
    wire("foundry-local-a", "foundry-pe-A", "foundry-A",
         [(2407, 1154), (2407, 1210), (2610, 1210), (2610, 590), (2720, 590)],
         label="Local priority 1", at=(2695, 510), color=ORANGE)
    wire("foundry-local-b", "foundry-pe-B", "foundry-B",
         [(2407, 2084), (2407, 2140), (2630, 2140), (2630, 750), (2720, 750)],
         color=ORANGE, dashed=True)
    wire("foundry-remote-a", "pool-A", "foundry-B",
         [(1470, 800), (1500, 800), (1500, 905), (2650, 905), (2650, 780), (2720, 780)],
         label="Priority 2 / approved cross-region private paths", at=(1860, 900), color=ORANGE, dashed=True)
    wire("foundry-remote-b", "pool-B", "foundry-A",
         [(1470, 1790), (1500, 1790), (1500, 1830), (2670, 1830), (2670, 620), (2720, 620)],
         color=ORANGE, dashed=True)
    panel("monitor-service", 2680, 960, 880, 490,
          "LOG ANALYTICS - MANAGED SERVICE BOUNDARY", color=PURPLE, symbol="log-analytics",
          subtitle="One workspace ID; not inside a customer VNet.")
    card("ampls", 2720, 1055, 800, 105, "Azure Monitor Private Link Scope (AMPLS)",
         ["Scope for both regional Monitor PEs; private log queries"], symbol="monitor", color=PURPLE)
    text(2720, 1178, "Azure-managed replication; typically ~2 minutes, not guaranteed", 19)
    card("logs-a", 2720, 1215, 350, 195, "East US 2 | primary",
         ["APIM gateway + LLM logs", "Private queries via AMPLS",
          "Both APIM resource IDs"], symbol="log-analytics", color=PURPLE)
    card("logs-b", 3170, 1215, 350, 195, "Central US | shadow",
         ["Passive replica",
          "Manual switchover",
          "No historical backfill"], symbol="log-analytics", color=PURPLE)
    wire("log-replication", "logs-a", "logs-b", [(3070, 1320), (3170, 1320)], color=PURPLE, dashed=True)
    wire("scope-workspace", "ampls", "logs-a",
         [(2900, 1140), (2900, 1215)], color=PURPLE)
    for letter, y in [("A", 430), ("B", 1360)]:
        turn = 1270 if letter == "A" else 2180
        wire(f"monitor-link-{letter}", f"monitor-pe-{letter}", "ampls",
             [(1977, y + 724), (1977, turn),
              (2640 if letter == "A" else 2660, turn),
              (2640 if letter == "A" else 2660, 1095), (2720, 1095)], color=PURPLE, dashed=True)
    wire("diagnostics", "apim-A", "logs-a",
         [(1470, 570), (1490, 570), (1490, 390), (3580, 390),
          (3580, 1195), (3100, 1195), (3100, 1260), (3070, 1260)],
         label="Both APIMs: diagnostic ingestion uses a managed Microsoft channel (not the Monitor PE)", at=(1950, 385), color=PURPLE)
    wire("diagnostics-b", "apim-B", "logs-a",
         [(1470, 1500), (1500, 1500), (1500, 1290), (2720, 1290)],
         color=PURPLE, dashed=True)
    wire("workbook-query", "workbook", "ampls",
         [(930, 220), (950, 220), (950, 110), (3590, 110), (3590, 1040), (3120, 1040), (3120, 1055)],
         label="KQL queries need the AMPLS-connected corporate/VDI path", at=(1100, 120), color=PURPLE)

    panel("cosmos-service", 2680, 1530, 880, 600,
          "COSMOS DB - ONE ACCOUNT / TWO REGIONS", color=GREEN, symbol="cosmos-db",
          subtitle="Managed data-plane boundary, not a customer VNet.")
    card("cosmos-a", 2720, 1640, 800, 150, "East US 2 | write region",
         ["Provisioned throughput; Session consistency",
          "projects / entitlement / budgets / adminConfig / leases",
          "Private SQL access through C-A"], symbol="cosmos-db", color=GREEN)
    card("cosmos-b", 2720, 1920, 800, 150, "Central US | read region",
         ["Replica promoted on configured service-managed failover",
          "Standby writers remain fenced until promotion",
          "Private SQL access through C-B"], symbol="cosmos-db", color=GREEN)
    wire("cosmos-replication", "cosmos-a", "cosmos-b", [(3100, 1790), (3100, 1920)],
         label="Azure-managed replication\nSession RPO: under 15 minutes",
         at=(3140, 1840), color=GREEN, dashed=True)
    wire("cosmos-link-a", "cosmos-pe-A", "cosmos-a",
         [(2192, 1154), (2192, 1250), (2620, 1250), (2620, 1710), (2720, 1710)],
         color=GREEN)
    wire("cosmos-link-b", "cosmos-pe-B", "cosmos-b",
         [(2192, 2084), (2192, 2168), (2650, 2168), (2650, 1990), (2720, 1990)],
         color=GREEN, dashed=True)

    panel("notes", 40, 2200, 3520, 100, "BOUNDARY AND FAILOVER NOTES", color=GRAY)
    text(65, 2270, [
        "Dashed blue: customer VNet / subnet. Solid service boxes: PaaS outside VNet. Only PE NICs sit inside PE subnets. Azure replication is not VNet peering.",
    ], 19)


def editable_scene(svg):
    elements, files = [], {}
    namespace = "{http://www.w3.org/2000/svg}"
    for element in ET.fromstring(svg).iter():
        kind = element.tag.removeprefix(namespace)
        item = {
            "id": f"dr-{len(elements)}", "angle": 0, "strokeColor": "#000000",
            "backgroundColor": "transparent", "fillStyle": "solid", "strokeWidth": 1,
            "strokeStyle": "solid", "roughness": 0, "opacity": 100,
            "groupIds": [], "seed": 1, "version": 1, "versionNonce": 0,
            "isDeleted": False, "boundElements": [], "updated": 0,
            "link": None, "locked": False,
        }
        if kind == "rect" and element.get("stroke"):
            item.update(
                type="rectangle", x=float(element.get("x")), y=float(element.get("y")),
                width=float(element.get("width")), height=float(element.get("height")),
                strokeColor=element.get("stroke"),
                backgroundColor=element.get("fill", "none").replace("none", "transparent"),
                strokeStyle="dashed" if element.get("stroke-dasharray") else "solid",
                roundness={"type": 3},
            )
        elif kind == "image":
            uri = element.get("href")
            file_id = hashlib.sha256(base64.b64decode(uri.split(",", 1)[1])).hexdigest()
            files[file_id] = dict(id=file_id, dataURL=uri, mimeType="image/svg+xml", created=0)
            item.update(
                type="image", x=float(element.get("x")), y=float(element.get("y")),
                width=float(element.get("width")), height=float(element.get("height")),
                fileId=file_id, status="saved", scale=[1, 1],
            )
        elif kind == "text":
            lines = [span.text or "" for span in element.findall(namespace + "tspan")]
            size = float(element.get("font-size"))
            item.update(
                type="text", x=float(element.get("x")), y=float(element.get("y")) - size,
                width=max(1, max(map(len, lines), default=0) * size * 0.65),
                height=size * 2.5 * max(1, len(lines)),
                text="\n".join(lines), originalText="\n".join(lines), fontSize=size,
                fontFamily=2, textAlign="left", verticalAlign="top",
                containerId=None, lineHeight=1.4, autoResize=True,
            )
        elif kind == "polyline" and element.get("stroke") != "white":
            points = [list(map(float, pair.split(","))) for pair in element.get("points").split()]
            x, y = points[0]
            item.update(
                type="arrow" if element.get("marker-end") else "line", x=x, y=y,
                width=max(p[0] for p in points) - min(p[0] for p in points),
                height=max(p[1] for p in points) - min(p[1] for p in points),
                points=[[px - x, py - y] for px, py in points],
                strokeColor=element.get("stroke"), strokeWidth=2,
                strokeStyle="dashed" if element.get("stroke-dasharray") else "solid",
                startArrowhead=None, endArrowhead="arrow" if element.get("marker-end") else None,
                startBinding=None, endBinding=None,
            )
        else:
            continue
        elements.append(item)
    return dict(type="excalidraw", version=2, source="CCOF",
                elements=elements, files=files,
                appState={"viewBackgroundColor": "#ffffff"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--png", action="store_true",
                        help="Export PNG using installed Playwright and Edge.")
    args = parser.parse_args()
    build()
    assert all(e["source"] in nodes and e["target"] in nodes for e in links)
    # Cloud-managed services must stay outside every customer VNet.
    for letter in ("A", "B"):
        vnet = nodes[f"vnet-{letter}"]
        for name in (f"cosmos-{letter.lower()}", "logs-a", "logs-b", "ampls"):
            node = nodes[name]
            overlap = (node["x"] < vnet["x"] + vnet["width"]
                       and node["x"] + node["width"] > vnet["x"]
                       and node["y"] < vnet["y"] + vnet["height"]
                       and node["y"] + node["height"] > vnet["y"])
            assert not overlap, name
    defs = "".join(
        f'<marker id="arrow-{c[1:]}" markerWidth="9" markerHeight="9"'
        f' refX="8" refY="4" orient="auto" markerUnits="strokeWidth">'
        f'<path d="M0,0 L8,4 L0,8 z" fill="{c}"/></marker>'
        for c in (BLUE, GREEN, PURPLE, GRAY, ORANGE)
    )
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}"'
        f' width="{W}" height="{H}" role="img" aria-labelledby="title desc">'
        '<title id="title">CCOF DR: original Azure icons and private network boundaries</title>'
        '<desc id="desc">Proposed two-region Standard v2 gateways behind Front Door Premium;'
        ' Cosmos and Log Analytics are outside customer VNets, with private endpoint connections.</desc>'
        f'<defs>{defs}</defs><rect width="{W}" height="{H}" fill="white"/>'
        '<g font-family="Segoe UI, Arial, sans-serif">'
        + "".join(parts) + "</g></svg>"
    )
    ET.fromstring(svg)
    OUT.mkdir(parents=True, exist_ok=True)
    target = OUT / "dr-active-passive.svg"
    target.write_text(svg, encoding="utf-8")
    editable = OUT / "dr-active-passive.excalidraw"
    editable.write_text(json.dumps(editable_scene(svg), indent=2) + "\n", encoding="utf-8")
    manifest = {
        "source": str(Path(__file__).relative_to(ROOT)).replace("\\", "/"),
        "sourceSha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "svgSha256": hashlib.sha256(target.read_bytes()).hexdigest(),
        "excalidrawSha256": hashlib.sha256(editable.read_bytes()).hexdigest(),
        "dimensions": [W, H],
        "icons": {name: hashlib.sha256((ICONS / f"{name}.svg").read_bytes()).hexdigest()
                  for name in sorted(used_icons)},
    }
    if args.png:
        from playwright.sync_api import sync_playwright
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(channel="msedge")
            page = browser.new_page(viewport={"width": W, "height": H},
                                    device_scale_factor=1)
            page.goto(target.as_uri(), wait_until="load")
            page.evaluate("document.fonts.ready")
            bounds = page.evaluate("""() => [...document.querySelectorAll('text')].map(t => {
                const b = t.getBBox();
                return {text:t.textContent, x:b.x, y:b.y, right:b.x+b.width, bottom:b.y+b.height};
            }).filter(b => b.x < 0 || b.y < 0 || b.right > 3600 || b.bottom > 2320)""")
            assert not bounds, bounds
            png = OUT / "dr-active-passive.png"
            cdp = page.context.new_cdp_session(page)
            capture = cdp.send("Page.captureScreenshot",
                               {"format": "png", "captureBeyondViewport": False})
            png.write_bytes(base64.b64decode(capture["data"]))
            browser.close()
        manifest["pngSha256"] = hashlib.sha256(png.read_bytes()).hexdigest()
    (OUT / "dr-render-manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Rendered {target.name}: {len(nodes)} nodes, {len(links)} links, "
          f"{len(used_icons)} original Microsoft icons.")


if __name__ == "__main__":
    main()
