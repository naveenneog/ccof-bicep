import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const root = fileURLToPath(new URL("..", import.meta.url));
const guide = readFileSync(path.join(root, "docs/runbooks/PUBLIC-ACCESS-WORKBOOK.md"), "utf8").replaceAll("\r\n", "\n");
const folder = path.join(root, "docs/runbooks/images/portal");
const manifest = JSON.parse(readFileSync(path.join(folder, "screenshots.json"), "utf8")) as {
  images: { file: string; sha256: string; kind: string; caption: string; maskedRegions: number }[];
  pending: string[];
};

test("manual guide includes every complete helper module with no source drift", () => {
  for (const relative of [
    "bin/ccof-token.mjs", "bin/validate-config.mjs", "src/cli.mjs", "src/config.mjs",
    "src/desktop-schema.mjs", "src/errors.mjs", "src/msal-runtime.mjs",
    "src/scopes.mjs", "src/token-service.mjs",
  ]) {
    const heading = "#### File `C:\\ccof-client\\client\\" + relative.replaceAll("/", "\\") + "`";
    const start = guide.indexOf(heading);
    assert.ok(start >= 0, `Missing hand-copy file ${relative}`);
    const block = /```javascript\n([\s\S]*?)```/.exec(guide.slice(start));
    assert.ok(block, `Missing full source block ${relative}`);
    const source = readFileSync(path.join(root, "client", relative), "utf8").replaceAll("\r\n", "\n").trimEnd() + "\n";
    assert.equal(block[1], source, `Refresh the complete hand-copy source for ${relative}`);
  }
});

test("manual client route does not require a downloaded setup script and retains explicit trust boundaries", () => {
  const client = guide.slice(guide.indexOf("## 13."), guide.indexOf("## 14."));
  assert.match(client, /04b07795-8ddb-461a-bbee-02f9e1bf7b46/);
  assert.match(client, /Authorized client applications/);
  assert.match(client, /delegatedClients/);
  assert.match(client, /do not substitute Azure CLI/i);
  assert.match(client, /No repository clone/);
  assert.match(client, /native.*Cloud gateway|Cloud gateway.*native/is);
  assert.doesNotMatch(client, /-ExecutionPolicy\s+Bypass/);
  for (const block of client.matchAll(/```powershell\n([\s\S]*?)```/g)) {
    assert.doesNotMatch(block[1], /pwsh[^\n]*-File|FromBase64String|Invoke-Expression/);
  }
  assert.match(client, /Microsoft packages/);
});

test("real screenshot inventory has intact PNGs, declared masking and explicit missing evidence", () => {
  assert.ok(manifest.images.length >= 30);
  const seen = new Set<string>();
  for (const item of manifest.images) {
    assert.ok(!seen.has(item.file), item.file);
    seen.add(item.file);
    assert.match(item.file, /^[0-9]{2}-[A-Za-z0-9-]+-middle-masked\.png$/);
    const data = readFileSync(path.join(folder, item.file));
    assert.equal(data.subarray(0, 8).toString("hex"), "89504e470d0a1a0a", item.file);
    assert.equal(createHash("sha256").update(data).digest("hex"), item.sha256, item.file);
    assert.ok(data.readUInt32BE(16) >= 400 && data.readUInt32BE(20) >= 100, item.file);
    assert.ok(item.kind && item.caption && item.maskedRegions >= 0, item.file);
  }
  assert.ok(manifest.pending.some(p => /Advanced Editor/.test(p)));
});

test("expanded final modules retain reporting, optional enforcement and network ownership gates", () => {
  assert.match(guide, /## 14\. Publish and verify the complete chargeback workbook/);
  assert.match(guide, /## 15\. Optional budget-state enforcement/);
  assert.match(guide, /## 16\. Customer-owned private networking/);
  assert.match(guide, /successful run outcome is \*\*`written`\*\*/);
  assert.match(guide, /Do not assume Flex has a Kudu\/SCM shell/);
  assert.match(guide, /A settings read-back is not those tests/);
  assert.match(guide, /not an Azure\/Marketplace settled invoice/);
  assert.doesNotMatch(guide, /(?<!not )guarantees? a dollar ceiling/i);
  const publish = guide.slice(guide.indexOf("### Step 14.4"), guide.indexOf("### Step 14.5"));
  assert.match(publish, /\$parameters\.workbookContent\.value = \$content/);
  assert.match(publish, /--verify \$publishCheck/);
  assert.ok(publish.indexOf("--verify $publishCheck") < publish.indexOf("Invoke-RestMethod -Method Put"));
  const figures = [...guide.matchAll(/^!\[[^\]]*\]\((\.\/images\/portal\/[^)]+)\)/gm)].map(m => m[1]);
  assert.equal(new Set(figures).size, figures.length, "Repeated composition must not duplicate the reference gallery");
});

test("public manuals contain only neutral examples and have resolvable local links", () => {
  for (const relative of [
    "docs/runbooks/PUBLIC-ACCESS-WORKBOOK.md", "docs/runbooks/AZURE-PORTAL-DEPLOYMENT.md",
    "docs/MANUAL-PORTAL-FIXES.md", "scripts/manual/README.md",
  ]) {
    const file = path.join(root, relative);
    const text = readFileSync(file, "utf8");
    assert.doesNotMatch(text, /\b[A-Za-z0-9._%+-]+@(?:microsoft\.com|[A-Za-z0-9.-]+\.onmicrosoft\.com)\b/, relative);
    assert.doesNotMatch(text, /[A-Z]:\\Users\\(?!REPLACE-|<)[^\\\s]+\\/, relative);
    const prose = text.replace(/```[\s\S]*?```/g, "");
    for (const link of prose.matchAll(/!?\[[^\]]*\]\(([^)]+)\)/g)) {
      const target = link[1];
      if (/^(?:https?:|#)/.test(target)) continue;
      assert.ok(existsSync(path.resolve(path.dirname(file), target.split("#")[0])), `${relative}: ${target}`);
    }
  }
});
