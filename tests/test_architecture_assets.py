from pathlib import Path
import base64
import hashlib
import json
import struct
import urllib.parse
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
diagrams = root / "docs" / "diagrams"
rendered = json.loads((diagrams / "render-manifest.json").read_text())
for filename, digest in rendered["files"].items():
    assert hashlib.sha256((diagrams / filename).read_bytes()).hexdigest() == digest, f"Diagram export drift: {filename}"
manifest = json.loads((diagrams / "icons" / "azure" / "manifest.json").read_text())
hashes = set()
for icon in manifest["icons"]:
    data = (diagrams / "icons" / "azure" / icon["file"]).read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    assert digest == icon["sha256"], icon["file"]
    hashes.add(digest)

mx = ET.parse(diagrams / "ccof-network-architecture.drawio").getroot()
pages = mx.findall("diagram")
assert len(pages) == 2
for page, stem in zip(pages, ("ccof-architecture-overview", "ccof-network-architecture")):
    model = page.find("mxGraphModel")
    cells = {c.attrib["id"]: c for c in model.find("root").findall("mxCell")}
    assert len(cells) == len(model.find("root").findall("mxCell"))
    for cell in cells.values():
        if cell.get("edge") == "1":
            assert cell.get("source") in cells and cell.get("target") in cells
    assert cells["groups-read"].get("source") == "sync"
    assert cells["groups-read"].get("target") == "groups"
    for service in ("apim", "resolver", "sync", "cosmos", "storage", "foundry"):
        current = cells[service]
        while current.get("parent") in cells:
            current = cells[current.get("parent")]
            assert current.get("id") not in ("vnet", "apim-subnet", "functions-subnet", "pe-subnet"), service
    icons = 0
    for cell in cells.values():
        style = cell.get("style", "")
        if "shape=image;" not in style:
            continue
        image = next(p.removeprefix("image=") for p in style.split(";") if p.startswith("image="))
        assert image.startswith("data:image/svg+xml,")
        data = urllib.parse.unquote_to_bytes(image.removeprefix("data:image/svg+xml,"))
        assert hashlib.sha256(data).hexdigest() in hashes
        icons += 1
    assert icons >= 10
    svg = ET.parse(diagrams / (stem + ".svg")).getroot()
    assert svg.get("width") == model.get("pageWidth")
    assert svg.get("height") == model.get("pageHeight")
    for image in svg.findall(".//{http://www.w3.org/2000/svg}image"):
        uri = image.get("href")
        assert uri.startswith("data:image/svg+xml;base64,")
        assert hashlib.sha256(base64.b64decode(uri.split(",", 1)[1])).hexdigest() in hashes
    png = (diagrams / (stem + ".png")).read_bytes()
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    width, height = struct.unpack(">II", png[16:24])
    assert (width, height) == (int(model.get("pageWidth")), int(model.get("pageHeight")))
print("Editable two-page architecture, actual Microsoft icon hashes, endpoint edges, PaaS/VNet boundaries and preview sizes: PASS")

dr = root / "docs" / "images" / "dr"
dr_manifest = json.loads((dr / "dr-render-manifest.json").read_text())
for path, digest in [
    (root / dr_manifest["source"], dr_manifest["sourceSha256"]),
    (dr / "dr-active-passive.svg", dr_manifest["svgSha256"]),
    (dr / "dr-active-passive.png", dr_manifest["pngSha256"]),
    (dr / "dr-active-passive.excalidraw", dr_manifest["excalidrawSha256"]),
]:
    assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, f"DR export drift: {path.name}"
dr_svg = ET.parse(dr / "dr-active-passive.svg").getroot()
dr_images = dr_svg.findall(".//{http://www.w3.org/2000/svg}image")
assert len(dr_images) >= 15, "DR diagram has no original Azure service icons"
for image in dr_images:
    uri = image.get("href")
    assert uri.startswith("data:image/svg+xml;base64,"), "DR icon needs an external request"
    assert hashlib.sha256(base64.b64decode(uri.split(",", 1)[1])).hexdigest() in hashes

def dr_bounds(name):
    group = dr_svg.find(f".//{{http://www.w3.org/2000/svg}}g[@id='{name}']")
    rect = group.find("{http://www.w3.org/2000/svg}rect")
    return [float(rect.get(k)) for k in ("x", "y", "width", "height")]

def overlaps(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by

for letter in ("A", "B"):
    vnet = dr_bounds(f"vnet-{letter}")
    for service in (f"apim-{letter}", f"resolver-{letter}", f"foundry-{letter}",
                    "cosmos-a", "cosmos-b", "logs-a", "logs-b", "ampls"):
        assert not overlaps(vnet, dr_bounds(service)), f"{service} is drawn inside VNet {letter}"
    for subnet in (f"apim-subnet-{letter}", f"functions-subnet-{letter}", f"pe-subnet-{letter}"):
        x, y, width, height = dr_bounds(subnet)
        vx, vy, vw, vh = vnet
        assert vx <= x and vy <= y and x + width <= vx + vw and y + height <= vy + vh, subnet
png = (dr / "dr-active-passive.png").read_bytes()
assert png[:8] == b"\x89PNG\r\n\x1a\n"
assert struct.unpack(">II", png[16:24]) == tuple(dr_manifest["dimensions"])
scene = json.loads((dr / "dr-active-passive.excalidraw").read_text())
assert scene["type"] == "excalidraw"
for element in scene["elements"]:
    if element["type"] == "text":
        assert element["width"] > 0 and element["height"] > 0
        assert element["strokeColor"] == "#000000"
for image in scene["files"].values():
    assert hashlib.sha256(base64.b64decode(image["dataURL"].split(",", 1)[1])).hexdigest() in hashes
print("DR Azure icons, export hashes, private subnets and managed-service boundaries: PASS")
