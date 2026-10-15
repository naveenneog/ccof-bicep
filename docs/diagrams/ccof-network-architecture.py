"""Generate the editable draw.io overview and its portable SVG from one geometry."""
from pathlib import Path
import html
import xml.etree.ElementTree as E
import base64
import argparse
import asyncio
import hashlib
import json
from urllib.parse import quote

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--png", action="store_true", help="Render PNG previews with approved local Playwright/Edge and write their source/hash manifest.")
arguments = parser.parse_args()

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
    ["Claude Code CLI / VS Code panel", "Approved client / tenant policies apply", "", "Route A: Azure CLI browser sign-in", "Admin-approved delegated client trust", "Route B: helper + secure MSAL cache", "Gateway API audience only", "", "Config is not an entitlement grant", "Never persist a bearer token in settings", "No direct Foundry / resolver permission"], "#f3f8fc", BLUE)
box("ingress", 35, 770, 360, 195, "OPTIONAL CUSTOMER INGRESS",
    ["Internal-only ingress / WAF / SIPA controls", "Customer-approved access topology", "Not universally created by quickstart", "Dashed = optional, not proof of deployment"], "#fff8ed", ORANGE, dashed=True)
box("admin", 35, 1045, 360, 420, "ADMIN CONTROL PLANE",
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
edge("groups-read", "sync", "groups", [(500, 950), (465, 950), (465, 465), (1190, 465), (1190, 420)], "⑤ Graph read", GREEN, True, lx=720, ly=455)
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

network_boxes, network_edges = boxes, edges
boxes, edges = [], []
box("title", 25, 20, 1630, 85, "Claude on Foundry | identity, inference and network boundaries",
    ["Customer-neutral design; Azure icons are Microsoft's originals. Not live deployment evidence."], "#ffffff", "#ffffff")
box("tenant", 320, 125, 1325, 1290, "CUSTOMER ENTRA TENANT", fill="#ffffff", stroke=BLUE, dashed=True, boundary=True)
box("directory", 345, 165, 1275, 220, "DIRECTORY TRUST - separate from Azure resource/data roles",
    fill="#f3f8fc", stroke=BLUE, parent="tenant", dashed=True, boundary=True)
box("combined", 365, 215, 355, 145, "Gateway + user sign-in app",
    ["Combined registration by default", "access_as_user; v2 gateway audience", "Azure CLI needs explicit client trust"], "#e7f2fc", BLUE, "directory")
box("groups", 740, 215, 355, 145, "Groups and Microsoft Graph",
    ["Direct project/classification members", "Sync UAMI reads; no directory writes", "STD / PRM / CYB admissions"], "#eaf5ea", GREEN, "directory")
box("resolver-app", 1115, 215, 485, 145, "Separate resolver API registration",
    ["Backend audience; no user redirect URIs", "Allowed caller: APIM MI client AND object IDs", "Developers never call the resolver directly"], "#e7f2fc", BLUE, "directory")
box("workstation", 25, 180, 260, 275, "DEVELOPER DEVICE",
    ["Claude Code / VS Code", "Azure CLI interactive session", "or approved secure helper", "Customer CA / MFA applies", "No static keys in settings", "Project selector is checked"], "#f3f8fc", BLUE)
box("admin", 25, 610, 260, 235, "ADMINISTRATOR",
    ["Portal + Cloud Shell", "Scoped ARM / Graph grants", "Explicit client trust approval", "Publishing path must reach", "private deployment storage"], "#fff8ed", ORANGE)
box("core", 345, 420, 960, 970, "CORE SUBSCRIPTION / PLATFORM RESOURCE GROUP",
    fill="#ffffff", stroke=GRAY, parent="tenant", dashed=True, boundary=True)
box("apim", 370, 475, 360, 150, "API Management",
    ["JWT: tenant/audience/client/scope", "Entitlement + exact model routing", "Person/group + family token limits"], "#e7f2fc", BLUE, "core")
box("resolver", 865, 475, 410, 150, "Resolver Function App",
    ["APIM-only EasyAuth; system MI", "Project + person -> classification", "Read registry through Cosmos SQL PE"], "#e7f2fc", BLUE, "core")
box("sync", 370, 685, 360, 150, "Sync Function App",
    ["UAMI -> Graph direct membership", "Writes entitlement projection", "Create-only seed; cleanup mandatory"], "#eaf5ea", GREEN, "core")
box("cosmos", 865, 685, 410, 150, "Cosmos DB registry",
    ["Projects / backends / entitlements", "Scoped native data-plane RBAC", "Private target; PaaS outside VNet"], "#e7f2fc", BLUE, "core")
box("storage", 370, 895, 360, 165, "Per-app deployment storage",
    ["Separate blob storage per app", "Managed identity; no account keys", "Blob PE + reachable publishing host"], "#e7f2fc", BLUE, "core")
box("telemetry", 865, 895, 410, 165, "Azure Monitor + workbook",
    ["App Insights / LAW / diagnostics", "Fixed-price reporting, not an invoice", "Optional reconciler outside request path"], "#f3eefb", PURPLE, "core")
box("vnet", 370, 1120, 905, 255, "CUSTOMER VNET - OUTBOUND INTEGRATION AND PE NICs",
    ["Private DNS links/forwarding; approved NSG/UDR egress. PaaS services remain outside."],
    fill="#f5f9fc", stroke=BLUE, parent="core", dashed=True, boundary=True)
box("apim-subnet", 385, 1220, 265, 115, "APIM outbound subnet",
    ["Standard v2 integration", "Microsoft.Web/serverFarms"], "#ffffff", BLUE, "vnet", dashed=True)
box("functions-subnet", 680, 1220, 265, 115, "Functions outbound",
    ["Flex integration subnet", "Microsoft.App/environments"], "#ffffff", BLUE, "vnet", dashed=True)
box("pe-subnet", 975, 1220, 285, 115, "Private-endpoint subnet",
    ["Cosmos SQL / blob PE NICs", "Optional resolver/Foundry PE"], "#ffffff", BLUE, "vnet", dashed=True)
box("backends", 1335, 420, 285, 360, "BACKEND SUBSCRIPTION A", fill="#ffffff", stroke=GRAY, parent="tenant", dashed=True, boundary=True)
box("foundry", 1360, 485, 235, 260, "Microsoft Foundry",
    ["Account + deployments", "Resolved backendId only", "APIM MI cognitive token", "Per-account RBAC grant", "/anthropic/v1/messages", "Exposure per owner"], "#e7f2fc", BLUE, "backends")
box("backend-sub-b", 1335, 825, 285, 250, "OPTIONAL SUBSCRIPTION B", fill="#ffffff", stroke=ORANGE, parent="tenant", dashed=True, boundary=True)
box("foundry-next", 1360, 880, 235, 170, "Additional Foundry",
    ["Same-tenant MI route", "Separate account grant", "No implicit default route"], "#fff8ed", ORANGE, "backend-sub-b", dashed=True)
box("legend", 25, 1450, 1595, 150, "READING THE BOUNDARIES",
    ["Blue: authenticated request dependencies; green dashed: background Graph/read/write; purple: telemetry; gray: network association.",
     "Private endpoints are NICs, not the PaaS service. Outbound VNet integration does not create private inbound ingress.",
     "Optional components are dashed amber. Token-only limits are not dollar-spend guarantees; private-network acceptance is separate."],
    "#ffffff", GRAY)
edge("signin", "workstation", "combined", [(285, 270), (365, 270)], "SSO", BLUE, lx=325, ly=255)
edge("request", "workstation", "apim", [(285, 400), (320, 400), (320, 550), (370, 550)], "", BLUE)
edge("resolve", "apim", "resolver", [(730, 550), (865, 550)], "MI", BLUE, lx=795, ly=533)
edge("routing", "apim", "foundry", [(600, 475), (600, 460), (1480, 460), (1480, 485)], "Authorized backend / MI", BLUE, lx=1075, ly=451)
edge("groups-read", "sync", "groups", [(370, 760), (335, 760), (335, 400), (920, 400), (920, 360)], "Graph read", GREEN, True, lx=750, ly=405)
edge("projection", "sync", "cosmos", [(730, 760), (865, 760)], "Write", GREEN, True, lx=795, ly=744)
edge("registry-read", "resolver", "cosmos", [(1070, 625), (1070, 685)], "SQL / PE", BLUE, lx=1140, ly=657)
edge("logs", "apim", "telemetry", [(730, 600), (790, 600), (790, 980), (865, 980)], "Logs", PURPLE, True, lx=820, ly=959)
edge("apim-attach", "apim", "apim-subnet", [(550, 625), (350, 625), (350, 1190), (515, 1190), (515, 1220)], "", GRAY, True, False)
edge("functions-attach", "resolver", "functions-subnet", [(1275, 600), (1290, 600), (1290, 1200), (815, 1200), (815, 1220)], "", GRAY, True, False)
edge("cosmos-pe", "cosmos", "pe-subnet", [(1275, 800), (1298, 800), (1298, 1210), (1110, 1210), (1110, 1220)], "", GRAY, True, False)
edge("blob-pe", "storage", "pe-subnet", [(550, 1060), (550, 1080), (1294, 1080), (1294, 1190), (1200, 1190), (1200, 1220)], "", GRAY, True, False)
edge("admin-control", "admin", "core", [(285, 730), (310, 730), (310, 1030), (345, 1030)], "", ORANGE, True)
edge("second-backend", "apim", "foundry-next", [(700, 475), (700, 465), (1318, 465), (1318, 965), (1360, 965)], "", ORANGE, True)

icons = {
    "tenant": "tenant", "combined": "app-registration", "resolver-app": "app-registration",
    "groups": "groups", "workstation": "users", "admin": "cloud-shell",
    "apim": "api-management", "resolver": "functions", "sync": "functions",
    "reconciler": "functions", "cosmos": "cosmos-db", "storage": "storage",
    "telemetry": "monitor", "foundry": "foundry", "foundry-next": "foundry",
    "vnet": "vnet", "apim-subnet": "nsg", "functions-subnet": "vnet",
    "pe-subnet": "private-endpoints", "dns": "dns",
}
icon_data = {name: (HERE / "icons" / "azure" / f"{name}.svg").read_bytes() for name in set(icons.values())}


def render(diagram, name, page_boxes, page_edges, width, height, svg_name):
    by_id = {b["id"]: b for b in page_boxes}
    assert len(by_id) == len(page_boxes)
    model = E.SubElement(diagram, "mxGraphModel", grid="1", gridSize="10", guides="1",
                         connect="1", arrows="1", fold="1", page="1", pageScale="1",
                         pageWidth=str(width), pageHeight=str(height), math="0", shadow="0")
    root = E.SubElement(model, "root")
    E.SubElement(root, "mxCell", id="0")
    E.SubElement(root, "mxCell", id="1", parent="0")
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="svg-title svg-description">',
           f'<title id="svg-title">{html.escape(name)}</title>',
           '<desc id="svg-description">Editable Azure architecture, original Microsoft Azure SVG icons, tenant/subscription/VNet/subnet boundaries, PaaS outside private-endpoint subnets; design not live evidence.</desc>', '<defs>']
    for color in (BLUE, GREEN, PURPLE, ORANGE):
        svg.append(f'<marker id="arrow{color[1:]}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="{color}"/></marker>')
    svg += ['</defs>', f'<rect width="{width}" height="{height}" fill="white"/>']
    for b in page_boxes:
        parent = by_id.get(b["parent"])
        if parent:
            assert b["x"] >= parent["x"] and b["y"] >= parent["y"]
            assert b["x"] + b["w"] <= parent["x"] + parent["w"] and b["y"] + b["h"] <= parent["y"] + parent["h"], b["id"]
        icon = icon_data.get(icons.get(b["id"]))
        heading_width = b["w"] - (82 if icon else 32)
        size = fit(b["title"], 30 if b["id"] == "title" else 18 if b["boundary"] else 21, heading_width, bold=True)
        style = (f"rounded=1;whiteSpace=wrap;html=1;fillColor={b['fill']};strokeColor={b['stroke']};"
                 f"dashed={int(b['dashed'])};dashPattern=8 5;fontFamily=Arial;fontSize=19;fontColor=#101820;"
                 "align=left;verticalAlign=top;spacingTop=14;spacingLeft=16;spacingRight=12;")
        if b["boundary"]:
            style += "container=1;collapsible=0;recursiveResize=0;pointerEvents=0;"
        value = f'<div style="font-size:{size}px;font-weight:bold;line-height:32px">{html.escape(b["title"])}</div>'
        for text in b["lines"]:
            font_size = fit(text, 19, b["w"] - 32)
            value += f'<div style="font-size:{font_size}px;line-height:27px">{html.escape(text) if text else "&nbsp;"}</div>'
        cell = E.SubElement(root, "mxCell", id=b["id"], value=value, style=style, vertex="1", parent=b["parent"])
        E.SubElement(cell, "mxGeometry", x=str(b["x"] - (parent["x"] if parent else 0)),
                     y=str(b["y"] - (parent["y"] if parent else 0)), width=str(b["w"]), height=str(b["h"]), attrib={"as": "geometry"})
        svg.append(f'<g id="{b["id"]}"><rect x="{b["x"]}" y="{b["y"]}" width="{b["w"]}" height="{b["h"]}" rx="10" fill="{b["fill"]}" stroke="{b["stroke"]}" stroke-width="2"'
                   + (' stroke-dasharray="8 5"' if b["dashed"] else '') + '/>')
        if icon:
            uri = "data:image/svg+xml," + quote(icon.decode("utf-8"), safe="")
            child = E.SubElement(root, "mxCell", id=b["id"] + "-azure-icon", value="",
                                 style=f"shape=image;imageAspect=1;aspect=fixed;image={uri};", vertex="1", parent=b["id"])
            E.SubElement(child, "mxGeometry", x=str(b["w"] - 48), y="10", width="32", height="32", attrib={"as": "geometry"})
            svg.append(f'<image x="{b["x"]+b["w"]-48}" y="{b["y"]+10}" width="32" height="32" href="data:image/svg+xml;base64,{base64.b64encode(icon).decode()}"/>')
        svg.append(f'<text x="{b["x"]+16}" y="{b["y"]+32}" fill="#101820" font-family="Arial,Segoe UI,sans-serif" font-size="{size}" font-weight="700">{html.escape(b["title"])}</text>')
        for i, text in enumerate(b["lines"]):
            assert b["y"] + 63 + i * 27 < b["y"] + b["h"] - 6, b["id"]
            size = fit(text, 19, b["w"] - 32)
            svg.append(f'<text x="{b["x"]+16}" y="{b["y"]+63+i*27}" fill="#101820" font-family="Arial,Segoe UI,sans-serif" font-size="{size}">{html.escape(text)}</text>')
        svg.append('</g>')
    for e in page_edges:
        source, target = by_id[e["source"]], by_id[e["target"]]
        p, q = e["points"][0], e["points"][-1]
        style = (f"html=1;rounded=0;strokeColor={e['color']};strokeWidth=2;dashed={int(e['dashed'])};"
                 f"endArrow={'block' if e['arrow'] else 'none'};endFill=1;fontFamily=Arial;fontSize=17;fontColor={e['color']};"
                 f"exitX={(p[0]-source['x'])/source['w']};exitY={(p[1]-source['y'])/source['h']};"
                 f"entryX={(q[0]-target['x'])/target['w']};entryY={(q[1]-target['y'])/target['h']};")
        cell = E.SubElement(root, "mxCell", id=e["id"], value="", style=style, edge="1", parent="1", source=e["source"], target=e["target"])
        geometry = E.SubElement(cell, "mxGeometry", relative="1", attrib={"as": "geometry"})
        points = E.SubElement(geometry, "Array", attrib={"as": "points"})
        for x, y in e["points"][1:-1]:
            E.SubElement(points, "mxPoint", x=str(x), y=str(y))
        svg.append(f'<polyline id="{e["id"]}" points="{" ".join(f"{x},{y}" for x,y in e["points"])}" fill="none" stroke="{e["color"]}" stroke-width="2.5"'
                   + (' stroke-dasharray="3 5"' if e["color"] in (GRAY, PURPLE) else ' stroke-dasharray="8 5"' if e["dashed"] else '')
                   + (f' marker-end="url(#arrow{e["color"][1:]})"' if e["arrow"] else '') + '/>')
        if e["label"]:
            label_width = len(e["label"]) * 9.2 + 16
            label = E.SubElement(root, "mxCell", id=e["id"] + "-label", value=e["label"],
                                 style=f"text;html=1;fillColor=#ffffff;strokeColor=none;align=center;fontFamily=Arial;fontSize=17;fontColor={e['color']};", vertex="1", parent="1")
            E.SubElement(label, "mxGeometry", x=str(e["lx"]-label_width/2), y=str(e["ly"]-17), width=str(label_width), height="23", attrib={"as":"geometry"})
            svg.append(f'<rect x="{e["lx"]-label_width/2}" y="{e["ly"]-18}" width="{label_width}" height="24" fill="white"/>')
            svg.append(f'<text x="{e["lx"]}" y="{e["ly"]}" text-anchor="middle" fill="{e["color"]}" font-family="Arial,Segoe UI,sans-serif" font-size="17">{html.escape(e["label"])}</text>')
    svg.append('</svg>')
    (HERE / svg_name).write_text("\n".join(svg), encoding="utf-8")


mxfile = E.Element("mxfile", host="local", version="24.7.17")
overview = E.SubElement(mxfile, "diagram", id="ccof-overview", name="Overview - Azure icons and boundaries")
render(overview, "Claude on Foundry architecture overview", boxes, edges, 1680, 1640, "ccof-architecture-overview.svg")
network = E.SubElement(mxfile, "diagram", id="ccof-network-architecture", name="Detailed network and trust")
render(network, "Claude on Foundry detailed network and trust", network_boxes, network_edges, W, H, "ccof-network-architecture.svg")
E.indent(mxfile)
E.ElementTree(mxfile).write(HERE / "ccof-network-architecture.drawio", encoding="utf-8", xml_declaration=True)
print(f"Generated two editable pages, {len(boxes)+len(network_boxes)} vertices, original Azure SVG icons and two SVG previews.")

if arguments.png:
    try:
        from playwright.async_api import async_playwright
    except ImportError as error:
        raise RuntimeError("PNG export requires approved local Playwright and Microsoft Edge; no placeholder PNG is generated.") from error

    async def render_pngs():
        async with async_playwright() as playwright:
            browser = await playwright.chromium.launch(channel="msedge", headless=True)
            try:
                for stem, width, height in (("ccof-architecture-overview", 1680, 1640), ("ccof-network-architecture", W, H)):
                    page = await browser.new_page(viewport={"width": width, "height": height}, device_scale_factor=1)
                    await page.set_content('<html><body style="margin:0;background:white">' + (HERE / f"{stem}.svg").read_text(encoding="utf-8") + "</body></html>")
                    await page.wait_for_timeout(1000)
                    cdp = await page.context.new_cdp_session(page)
                    screenshot = await asyncio.wait_for(cdp.send("Page.captureScreenshot", {"format": "png", "captureBeyondViewport": False}), timeout=30)
                    (HERE / f"{stem}.png").write_bytes(base64.b64decode(screenshot["data"]))
                    await page.close()
            finally:
                await browser.close()

    asyncio.run(render_pngs())
    names = ("ccof-network-architecture.drawio", "ccof-architecture-overview.svg", "ccof-architecture-overview.png",
             "ccof-network-architecture.svg", "ccof-network-architecture.png")
    manifest = {"files": {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest() for name in names},
                "rendering": "Same geometry; original Microsoft SVGs embedded; local Edge at 1x device scale. Design, not live acceptance."}
    (HERE / "render-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print("Rendered both PNGs and recorded vector/draw.io/preview hashes.")
