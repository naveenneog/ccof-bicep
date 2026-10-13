"""Generate the editable draw.io overview and its portable SVG from one geometry."""
from pathlib import Path
import html
import xml.etree.ElementTree as E

HERE = Path(__file__).resolve().parent
W, H = 2500, 2400
cells, boxes, edges = [], [], []
BLUE, GREEN, PURPLE, ORANGE, GRAY = "#0078d4", "#107c10", "#8764b8", "#ca5010", "#687787"


def box(id, x, y, w, h, title, lines=(), fill="#ffffff", stroke=BLUE, parent="1", dashed=False, boundary=False):
    boxes.append(dict(id=id, x=x, y=y, w=w, h=h, title=title, lines=list(lines),
                      fill=fill, stroke=stroke, parent=parent, dashed=dashed, boundary=boundary))


def edge(id, source, target, points, label="", color=BLUE, dashed=False, arrow=True, lx=None, ly=None):
    edges.append(dict(id=id, source=source, target=target, points=points, label=label,
                      color=color, dashed=dashed, arrow=arrow, lx=lx, ly=ly))


box("title", 35, 25, 2425, 98, "Claude Code on Foundry | identity, routing & private-network architecture",
    ["Integrated baseline and optional wiring • Customer-neutral design • Design / wiring requirements, not live acceptance"], "#ffffff", "#ffffff")
box("tenant", 450, 145, 2005, 1495, "CUSTOMER ENTRA TENANT • identity / token trust boundary",
    fill="#ffffff", stroke=BLUE, dashed=True, boundary=True)
box("directory", 475, 200, 1450, 250, "DIRECTORY CONTROL PLANE • separate from Azure resource RBAC",
    fill="#f3f8fc", stroke=BLUE, parent="tenant", dashed=True, boundary=True)
box("combined", 500, 255, 440, 165, "Combined developer + Gateway API",
    ["Single-tenant public client • token v2", "Delegated access_as_user • no secret", "WAM / browser PKCE; device code optional", "Consent + Conditional Access apply"], "#e7f2fc", BLUE, "directory")
box("groups", 970, 255, 445, 165, "Flat Entra security groups → Graph",
    ["Direct membership → project / STD / PRM / CYB", "Stable group IDs authorize; names are snapshots", "Sync UAMI: GroupMember.Read.All", "+ User.Read.All + Application.Read.All"], "#eaf5ea", GREEN, "directory")
box("resolver-app", 1445, 255, 455, 165, "Separate internal Resolver API",
    ["No public-client redirects / developer scopes", "EasyAuth pins APIM MI app ID AND object ID", "APIM-only audience; no developer access", "Azure Owner ≠ Entra administrator"], "#e7f2fc", BLUE, "directory")
box("workstation", 35, 230, 360, 480, "DEVELOPER WORKSTATION",
    ["Claude Code CLI", "VS Code Claude Code panel", "Claude Desktop", "", "Approved ccof-token helper", "MSAL • secure broker / encrypted cache", "Gateway API audience only", "", "onboarding.json: strict schemaVersion 1", "Config only • no grants / usage metering", "No direct Foundry / resolver permission"], "#f3f8fc", BLUE)
box("ingress", 35, 770, 360, 195, "OPTIONAL CUSTOMER INGRESS",
    ["Internal-only ingress / WAF / SIPA controls", "Customer-approved access topology", "Not universally created by quickstart", "Dashed = optional, not proof of deployment"], "#fff8ed", ORANGE, dashed=True)
box("admin", 35, 1045, 360, 420, "ADMINISTRATOR CONTROL PLANE",
    ["Cloud Shell • ARM / Graph / OneDeploy", "Resource-specific Bicep modules", "", "Network → resources → directory objects", "→ remaining wiring → grants / config / code", "→ registrySeed → client artifacts / tests", "", "Entra and Azure roles held separately", "Grant Graph before first timer token", "Cached MI tokens can delay new roles", "", "Ordinary Cloud Shell: no private data plane", "No jumpbox / VM assumption"], "#fff8ed", ORANGE)
box("core", 475, 480, 1290, 1135, "CORE AZURE SUBSCRIPTION • core resource group / approved region",
    fill="#ffffff", stroke=GRAY, parent="tenant", dashed=True, boundary=True)
box("apim", 500, 560, 565, 225, "AZURE API MANAGEMENT • cloud-managed service",
    ["Existing APIM usually • system-assigned MI enabled", "① Validate tenant / audience / client / scope / person", "x-ccof-project is intent, checked against entitlement", "Admission cap + cached v3 / d3 resolver decision", "Exact model admission; aggregate + family ceilings", "Per-person AND group limits • never substitute backend"], "#e7f2fc", BLUE, "core")
box("resolver", 1170, 560, 565, 225, "RESOLVER FUNCTION • Flex / system-assigned MI",
    ["② APIM-only EasyAuth • internal API audience", "Resolve person + project → classification / backendId", "Validated familyPolicy: haiku / sonnet / opus", "Fable / Mythos: exact registration AND CYB only", "Token-limits-only baseline; optional monetary mode", "③ Least-privilege Cosmos reads over private SQL PE"], "#e7f2fc", BLUE, "core")
box("sync", 500, 855, 565, 230, "SYNC FUNCTION • Flex / user-assigned MI",
    ["⑤ Microsoft Graph reads → entitlement projection", "Successful run applies membership additions/removals", "Freeze affected projects on failed reads; syncLease", "Conflict: retain incumbent classification, otherwise none", "registrySeed timer: create-only projects + backends", "Verify readback; disable timer / clean payload after use"], "#eaf5ea", GREEN, "core")
box("cosmos", 1170, 855, 565, 230, "COSMOS DB • private SQL registry, outside VNet",
    ["Public access disabled + local auth off at creation", "entitlement / projects / backends / subscriptionIndex", "budgetState / aggregateBudgetState", "syncLease / reconcilerLease", "Resolver: reads; sync: scoped writes / seed creates", "Reconciler: scoped budget writes • never broad keys"], "#e7f2fc", BLUE, "core")
box("vnet", 500, 1140, 1235, 300, "CUSTOMER VNET • core subscription + region • network boundary",
    fill="#f5f9fc", stroke=BLUE, parent="core", dashed=True, boundary=True)
box("apim-subnet", 525, 1210, 330, 185, "APIM outbound subnet",
    ["Microsoft.Web/serverFarms delegation", "Required NSG • approved routes / UDR", "APIM compute is NOT in this subnet", "Existing APIM is not auto-attached", "Actual caller VNet must resolve / route"], "#ffffff", BLUE, "vnet", dashed=True)
box("functions-subnet", 880, 1210, 330, 185, "Functions outbound subnet",
    ["Microsoft.App/environments delegation", "Resolver + sync + optional reconciler", "Flex compute is NOT in this subnet", "Outbound integration ≠ inbound PE", "Separate from APIM subnet"], "#ffffff", BLUE, "vnet", dashed=True)
box("pe-subnet", 1235, 1210, 475, 185, "PRIVATE-ENDPOINT SUBNET • NICs only",
    ["Baseline: Cosmos SQL + each app's blob PE", "Optional: resolver sites PE (inbound only)", "Optional: Foundry account PE(s), any subscription", "PE approval and DNS / route must be verified", "Target PaaS services remain outside this VNet"], "#ffffff", BLUE, "vnet", dashed=True)
box("reconciler", 500, 1480, 540, 125, "OPTIONAL RECONCILER • Flex / UAMI",
    ["LAW usage → budgetState / aggregateBudgetState", "Monetary mode only; baseline has no reconciler timer", "FunctionAppLogs diagnostics • reconcilerLease"], "#fff8ed", ORANGE, "core", dashed=True)
box("storage", 1090, 1480, 645, 125, "PER-APP BLOB DEPLOYMENT STORAGE • outside VNet",
    ["Resolver / sync / optional reconciler • identity-based access", "Public access disabled; shared-key auth off at creation", "Separate blob private endpoint per app • OneDeploy packages"], "#e7f2fc", BLUE, "core")
box("backends", 1810, 480, 615, 450, "DESIGNATED BACKEND SUBSCRIPTION A • same tenant",
    fill="#ffffff", stroke=GRAY, parent="tenant", dashed=True, boundary=True)
box("foundry", 1840, 590, 555, 260, "PROJECT-SPECIFIC FOUNDRY ACCOUNT",
    ["④ set-backend-service → resolved backendId only", "APIM system MI → cognitive resource token", "Cognitive Services User grant on each target account", "Accounts can live in different Azure subscriptions", "Anthropic account base: /anthropic", "Messages: /v1/messages • NOT /api/projects", "Public/private exposure is backend-owner policy", "Optional PEs are in caller's VNet, not here"], "#e7f2fc", BLUE, "backends")
box("backend-sub-b", 1810, 970, 615, 235, "DESIGNATED BACKEND SUBSCRIPTION B … N • same tenant",
    fill="#ffffff", stroke=GRAY, parent="tenant", dashed=True, boundary=True)
box("foundry-next", 1840, 1030, 555, 145, "FOUNDRY ACCOUNT • additional project backend",
    ["Independent per-account MI grant / model deployments", "Project backendId maps here, not to account A", "Public/private per owner • optional caller-VNet PE"], "#e7f2fc", BLUE, "backend-sub-b")
box("other-tenant", 1810, 1680, 615, 255, "OPTIONAL DIFFERENT ENTRA TENANT",
    ["Foundry account + backend-tenant application credentials", "Staged credential path; manual MI helper refuses cross-tenant", "APIM-only credential custody / rotation • never client-distributed", "Cross-tenant PE approval is independent of authentication", "Not the Resolver API app; not the managed-identity baseline"], "#fff8ed", ORANGE, dashed=True)
box("telemetry", 1810, 1260, 615, 355, "AZURE MONITOR • core subscription / managed resources",
    ["⑥ APIM GatewayLogs + GatewayLlmLogs", "+ sanitized trusted usage / resolver traces", "Resolver + sync App Insights; Function logs", "→ Log Analytics → full chargeback workbook + fixed rate card", "", "Request-time person / group / project / model / family / backend", "Disjoint input / output / cache read / write 5m / write 1h", "Stream cache categories unknown, never guessed", "No prompts / responses / credentials logged", "Selectors are NOT authorization; list price ≠ invoice"], "#f3eefb", PURPLE, "tenant")
box("dns", 35, 1680, 1730, 195, "PRIVATE DNS + CUSTOMER NETWORK RESPONSIBILITIES",
    ["Baseline: privatelink.documents.azure.com • privatelink.blob.core.windows.net",
     "Optional inbound resolver: privatelink.azurewebsites.net",
     "Optional Foundry: privatelink.cognitiveservices.azure.com / openai.azure.com / services.ai.azure.com",
     "Link / forward from the ACTUAL APIM and Functions caller networks; hub peering does not share DNS",
     "Customer owns approved custom DNS, firewall, UDR, hub / peering and ingress controls"], "#f5f9fc", BLUE)
box("revocation", 35, 1905, 1730, 195, "REVOCATION / RECLASSIFICATION • bounded, not instantaneous",
    ["⑦ Group removal → successful sync → resolver / cache refresh → subsequent requests denied",
     "Baseline allow TTL 120s; refusal 30s; extra last-known-good grace 3600s on resolver failure",
     "Urgent: verify registry revoke, then deploy policy keyVersion • no eager generation eviction",
     "Move A → B: remove A / prove deny / add B; dual classifications never silently upgrade",
     "New spend stamps B; historical spend remains with A, never rewritten from today's directory"], "#eaf5ea", GREEN)
box("legend", 35, 2140, 2390, 220, "READING THIS OVERVIEW",
    ["BLUE solid arrows ①–④: synchronous auth / request dependency; response returns on the same request path",
     "GREEN dashed arrows ⑤ / ⑦: asynchronous membership projection / revocation   •   PURPLE dotted ⑥: telemetry / reporting",
     "ORANGE dashed: administrator control plane or optional credential / monetary path   •   GRAY dotted, no arrow: network association",
     "Solid blue/green service boxes: integrated implementation baseline (not live acceptance); amber dashed: optional production wiring / monetary or cross-tenant path",
     "Boundaries: dashed labeled tenant / subscription / VNet / subnet containers; cloud-managed PaaS runs OUTSIDE VNet",
     "Source baseline: ADR-0026 / ADR-0028; manual + quickstart modules, gateway policy, CLIENTS / SYNC / CHARGEBACK (see ARCHITECTURE.md)"], "#ffffff", GRAY)

edge("signin", "workstation", "combined", [(395, 315), (500, 315)], "① SSO", BLUE, lx=446, ly=296)
edge("request", "workstation", "apim", [(395, 655), (500, 655)], "① HTTPS", BLUE, lx=446, ly=638)
edge("ingress-option", "ingress", "apim", [(395, 855), (445, 855), (445, 750), (500, 750)], "", ORANGE, True)
edge("resolve", "apim", "resolver", [(1065, 655), (1170, 655)], "② MI", BLUE, lx=1117, ly=638)
edge("registry-read", "resolver", "cosmos", [(1452, 785), (1452, 855)], "③ SQL / PE", BLUE, lx=1555, ly=824)
edge("routing", "apim", "foundry", [(1015, 560), (1015, 540), (2085, 540), (2085, 590)], "④ Authorized backend route • MI", BLUE, lx=1540, ly=530)
edge("route-sub-b", "apim", "foundry-next", [(1015, 560), (1015, 540), (1800, 540), (1800, 1110), (1840, 1110)], "", BLUE)
edge("groups-read", "groups", "sync", [(1190, 420), (1190, 465), (465, 465), (465, 950), (500, 950)], "⑤ Graph read", GREEN, True, lx=720, ly=455)
edge("projection", "sync", "cosmos", [(1065, 965), (1170, 965)], "⑤ Write", GREEN, True, lx=1118, ly=948)
edge("apim-attach", "apim", "apim-subnet", [(780, 785), (780, 825), (485, 825), (485, 1110), (690, 1110), (690, 1210)], "", GRAY, True, False)
edge("functions-attach", "sync", "functions-subnet", [(980, 1085), (980, 1130), (1045, 1130), (1045, 1210)], "", GRAY, True, False)
edge("cosmos-pe", "cosmos", "pe-subnet", [(1450, 1085), (1450, 1210)], "SQL PE", GRAY, True, False, lx=1510, ly=1150)
edge("blob-pe", "storage", "pe-subnet", [(1510, 1480), (1510, 1395)], "Blob PE", GRAY, True, False, lx=1580, ly=1462)
edge("cross-tenant-route", "apim", "other-tenant", [(1065, 775), (1095, 775), (1095, 1125), (1795, 1125), (1795, 1760), (1810, 1760)], "④ Optional backend-tenant credentials", ORANGE, True, lx=2080, ly=1669)
edge("telemetry-path", "apim", "telemetry", [(1065, 745), (1115, 745), (1115, 1110), (1785, 1110), (1785, 1310), (1810, 1310)], "⑥ Sanitized traces + logs", PURPLE, True, lx=1410, ly=1100)
edge("function-logs", "resolver", "telemetry", [(1735, 745), (1775, 745), (1775, 1440), (1810, 1440)], "", PURPLE, True)
edge("optional-budget-read", "telemetry", "reconciler", [(1810, 1570), (1775, 1570), (1775, 1630), (760, 1630), (760, 1590)], "Optional monetary usage read", ORANGE, True, lx=1280, ly=1652)
edge("admin-arm", "admin", "core", [(395, 1130), (440, 1130), (440, 1540), (475, 1540)], "ARM", ORANGE, True, lx=414, ly=1510)
edge("admin-graph", "admin", "directory", [(220, 1045), (220, 1020), (420, 1020), (420, 435), (475, 435)], "", ORANGE, True)
edge("budget-write", "reconciler", "cosmos", [(750, 1480), (750, 1455), (1750, 1455), (1750, 1070), (1735, 1070)], "Optional scoped budget writes", ORANGE, True, lx=1290, ly=1472)
edge("optional-ingress-request", "workstation", "ingress", [(210, 710), (210, 770)], "", ORANGE, True)

byid = {b["id"]: b for b in boxes}
try:
    from PIL import ImageFont
    if not Path(r"C:\Windows\Fonts\arial.ttf").is_file():
        raise ImportError("Use the portable approximate metrics without local Arial.")
    def fit(text, size, width, bold=False):
        font = r"C:\Windows\Fonts\arialbd.ttf" if bold else r"C:\Windows\Fonts\arial.ttf"
        while size > 16 and ImageFont.truetype(font, size).getlength(text) > width:
            size -= 1
        assert ImageFont.truetype(font, size).getlength(text) <= width, text
        return size
except ImportError:
    def fit(text, size, width, bold=False):
        return min(size, max(16, int(width / max(1, len(text) * .53))))

mxfile = E.Element("mxfile", host="local", version="24.7.17")
diagram = E.SubElement(mxfile, "diagram", id="ccof-network-architecture", name="Network and trust overview")
model = E.SubElement(diagram, "mxGraphModel", dx="2500", dy="2160", grid="1", gridSize="10",
                     guides="1", tooltips="1", connect="1", arrows="1", fold="1", page="1",
                     pageScale="1", pageWidth=str(W), pageHeight=str(H), math="0", shadow="0")
root = E.SubElement(model, "root")
E.SubElement(root, "mxCell", id="0")
E.SubElement(root, "mxCell", id="1", parent="0")
for b in boxes:
    parent = byid.get(b["parent"])
    style = (f"rounded=1;whiteSpace=wrap;html=1;fillColor={b['fill']};strokeColor={b['stroke']};"
             f"dashed={int(b['dashed'])};dashPattern=8 5;fontFamily=Arial;fontSize=19;fontColor=#101820;"
             "align=left;verticalAlign=top;spacingTop=14;spacingLeft=16;spacingRight=12;")
    if b["boundary"]:
        style += "container=1;collapsible=0;recursiveResize=0;pointerEvents=0;"
    size = fit(b["title"], 30 if b["id"] == "title" else 18 if b["boundary"] else 21, b["w"]-32, bold=True)
    value = f'<div style="font-size:{size}px;font-weight:bold;line-height:32px">{html.escape(b["title"])}</div>'
    for text in b["lines"]:
        size = fit(text, 19, b["w"]-32)
        value += f'<div style="font-size:{size}px;line-height:27px">{html.escape(text) if text else "&nbsp;"}</div>'
    c = E.SubElement(root, "mxCell", id=b["id"], value=value, style=style, vertex="1", parent=b["parent"])
    E.SubElement(c, "mxGeometry", x=str(b["x"] - (parent["x"] if parent else 0)),
                 y=str(b["y"] - (parent["y"] if parent else 0)), width=str(b["w"]), height=str(b["h"]), attrib={"as": "geometry"})
for e in edges:
    s, t = byid[e["source"]], byid[e["target"]]
    p, q = e["points"][0], e["points"][-1]
    style = (f"html=1;rounded=0;strokeColor={e['color']};strokeWidth=2;dashed={int(e['dashed'])};"
             f"endArrow={'block' if e['arrow'] else 'none'};endFill=1;fontFamily=Arial;fontSize=17;"
             f"fontColor={e['color']};labelBackgroundColor=#ffffff;"
             f"exitX={(p[0]-s['x'])/s['w']};exitY={(p[1]-s['y'])/s['h']};"
             f"entryX={(q[0]-t['x'])/t['w']};entryY={(q[1]-t['y'])/t['h']};")
    c = E.SubElement(root, "mxCell", id=e["id"], value="", style=style, edge="1", parent="1", source=e["source"], target=e["target"])
    g = E.SubElement(c, "mxGeometry", relative="1", attrib={"as": "geometry"})
    arr = E.SubElement(g, "Array", attrib={"as": "points"})
    for x, y in e["points"][1:-1]:
        E.SubElement(arr, "mxPoint", x=str(x), y=str(y))
    if e["label"]:
        width = len(e["label"])*9.2+16
        c = E.SubElement(root, "mxCell", id=e["id"]+"-label", value=html.escape(e["label"]),
                         style=f"text;html=1;strokeColor=none;fillColor=#ffffff;align=center;verticalAlign=middle;fontFamily=Arial;fontSize=17;fontColor={e['color']};",
                         vertex="1", parent="1")
        E.SubElement(c, "mxGeometry", x=str(e["lx"]-width/2), y=str(e["ly"]-17), width=str(width), height="23", attrib={"as":"geometry"})
E.indent(mxfile)
E.ElementTree(mxfile).write(HERE / "ccof-network-architecture.drawio", encoding="utf-8", xml_declaration=True)

svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-labelledby="svg-title svg-description">',
       '<title id="svg-title">Claude Code on Foundry network and trust architecture</title>',
       '<desc id="svg-description">Customer-neutral source-verified overview of developer identity, gateway authorization, private registry, membership sync, project-specific Foundry backends, optional tenant and ingress wiring, and chargeback telemetry.</desc>',
       '<defs>']
for color in (BLUE, GREEN, PURPLE, ORANGE):
    svg.append(f'<marker id="arrow{color[1:]}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="{color}"/></marker>')
svg += ['</defs>', f'<rect width="{W}" height="{H}" fill="white"/>']
for b in boxes:
    svg.append(f'<g id="{b["id"]}"><rect x="{b["x"]}" y="{b["y"]}" width="{b["w"]}" height="{b["h"]}" rx="10" fill="{b["fill"]}" stroke="{b["stroke"]}" stroke-width="2"'
               + (' stroke-dasharray="8 5"' if b["dashed"] else '') + '/>')
    fontsize = 30 if b["id"] == "title" else (18 if b["boundary"] else 21)
    fontsize = fit(b["title"], fontsize, b["w"]-32, bold=True)
    svg.append(f'<text x="{b["x"]+16}" y="{b["y"]+32}" fill="#101820" font-family="Arial,Segoe UI,sans-serif" font-size="{fontsize}" font-weight="700">{html.escape(b["title"])}</text>')
    for i, line in enumerate(b["lines"]):
        assert b["y"]+63+i*27 < b["y"]+b["h"]-6, b["id"]
        size = fit(line, 19, b["w"]-32)
        svg.append(f'<text x="{b["x"]+16}" y="{b["y"]+63+i*27}" fill="#101820" font-family="Arial,Segoe UI,sans-serif" font-size="{size}">{html.escape(line)}</text>')
    svg.append('</g>')
for e in edges:
    points = " ".join(f"{x},{y}" for x, y in e["points"])
    svg.append(f'<polyline id="{e["id"]}" points="{points}" fill="none" stroke="{e["color"]}" stroke-width="2.5"'
               + (' stroke-dasharray="3 5"' if e["color"] in (GRAY, PURPLE) else ' stroke-dasharray="8 5"' if e["dashed"] else '')
               + (f' marker-end="url(#arrow{e["color"][1:]})"' if e["arrow"] else '') + '/>')
    if e["label"]:
        width = len(e["label"])*9.2+16
        svg.append(f'<rect x="{e["lx"]-width/2}" y="{e["ly"]-18}" width="{width}" height="24" fill="white"/>')
        svg.append(f'<text x="{e["lx"]}" y="{e["ly"]}" text-anchor="middle" fill="{e["color"]}" font-family="Arial,Segoe UI,sans-serif" font-size="17">{html.escape(e["label"])}</text>')
svg.append('</svg>')
(HERE / "ccof-network-architecture.svg").write_text("\n".join(svg), encoding="utf-8")
print(f"Generated {len(boxes)} grouped vertices and {len(edges)} semantic connections.")
