import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { UI_HEADERS, serveUi, serveUiV3, v3Enabled } from "../src/ui.ts";

const srcV3 = fileURLToPath(new URL("../ui-v3/", import.meta.url));
const srcV2 = fileURLToPath(new URL("../ui/", import.meta.url));

test("V3 console is served only when ADMIN_V3_ENABLED=true", async () => {
  assert.equal(v3Enabled({}), false);
  assert.equal(v3Enabled({ ADMIN_V3_ENABLED: "1" }), false);
  assert.equal(v3Enabled({ ADMIN_V3_ENABLED: "true" }), true);
  assert.equal((await serveUiV3("", false, srcV3)).status, 404);
  assert.equal((await serveUiV3("app.css", false, srcV3)).status, 404);
  const page = await serveUiV3("", true, srcV3);
  assert.equal(page.status, 200);
  assert.equal(page.headers["content-type"], "text/html; charset=utf-8");
});

test("V3 serves an explicit allow-list with the same strict CSP as V2", async () => {
  for (const asset of ["", "app.css", "icon.svg"]) {
    const r = await serveUiV3(asset, true, srcV3);
    assert.equal(r.status, 200, asset);
    assert.equal(r.headers["content-security-policy"], UI_HEADERS["content-security-policy"]);
    assert.equal(r.headers["x-content-type-options"], "nosniff");
  }
  for (const asset of ["../package.json", "..%2Fpackage.json", "main.tsx", "rate-card.json", "constructor", "__proto__", "toString", "app.js.map", "index.html"]) {
    assert.equal((await serveUiV3(asset, true, srcV3)).status, 404, asset);
  }
  assert.equal((await serveUi("constructor", srcV2)).status, 404, "V2 allow-list ignores prototype keys too");
  const csp = UI_HEADERS["content-security-policy"];
  assert.match(csp, /default-src 'none'/);
  assert.match(csp, /script-src 'self'(;|$)/);
  assert.match(csp, /style-src 'self'(;|$)/);
  assert.doesNotMatch(csp, /unsafe-inline|unsafe-eval|https:\/\/cdn|\*/);
});

test("V3 HTML loads only same-origin assets, with no inline script or style", async () => {
  const html = await readFile(new URL("../ui-v3/index.html", import.meta.url), "utf8");
  const refs = [...html.matchAll(/(?:src|href)="([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(refs.sort(), ["/api/console-v3/app.css", "/api/console-v3/app.js", "/api/console-v3/icon.svg"]);
  assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>/);
  assert.doesNotMatch(html, /<style|style="/);
  assert.doesNotMatch(html, /\son[a-z]+="/);
});

test("V3 sources never use inline style attributes or eval", async () => {
  const { readdir } = await import("node:fs/promises");
  const files: string[] = [];
  const walk = async (dir: URL) => {
    for (const e of await readdir(dir, { withFileTypes: true })) {
      if (e.isDirectory()) await walk(new URL(`${e.name}/`, dir));
      else if (/\.(tsx?|css)$/.test(e.name)) files.push(fileURLToPath(new URL(e.name, dir)));
    }
  };
  await walk(new URL("../ui-v3/", import.meta.url));
  assert.ok(files.length > 10);
  for (const f of files) {
    const text = await readFile(f, "utf8");
    assert.doesNotMatch(text, /\bstyle=\{|dangerouslySetInnerHTML|\beval\(|new Function\(/, f);
    assert.doesNotMatch(text, /https?:\/\/(?!login\.microsoftonline\.com)[a-z0-9.-]+\.(com|net|io)\/[^"]*\.(js|css)/i, f);
  }
});

// WCAG 2 contrast of the theme tokens, computed from their OKLCH values.
function toRgb([L, C, H]: number[]): number[] {
  const a = C * Math.cos(H * Math.PI / 180), b = C * Math.sin(H * Math.PI / 180);
  const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3, m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3, s = (L - 0.0894841775 * a - 1.291485548 * b) ** 3;
  const lin = [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s, -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s, -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s];
  return lin.map((x) => Math.min(1, Math.max(0, x)));
}
const luminance = (c: number[]) => { const [r, g, b] = toRgb(c); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
const contrast = (x: number[], y: number[]) => { const a = luminance(x), b = luminance(y); return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05); };

test("Light and Dark themes keep text at 4.5:1 or better on every surface they use", async () => {
  const css = await readFile(new URL("../ui-v3/app.css", import.meta.url), "utf8");
  const block = (sel: string) => { const i = css.indexOf(sel); assert.ok(i >= 0, sel); return css.slice(i, css.indexOf("}", i)); };
  const tokens = (b: string) => Object.fromEntries([...b.matchAll(/--([\w-]+):\s*oklch\(([^)]+)\)/g)].map(([, k, v]) => [k, v.split("/")[0].trim().split(/\s+/).map(Number)]));
  const pairs = [["ink", "bg"], ["ink", "chrome"], ["ink-2", "surface"], ["ink-2", "chrome-2"], ["muted", "bg"], ["muted", "surface"], ["muted", "chrome"], ["muted", "chrome-2"],
    ["link", "surface"], ["on-primary", "primary"], ["ink", "primary-tint"], ["warn-ink", "warn-tint"], ["danger-ink", "danger-tint"], ["ok-ink", "ok-tint"], ["ink", "info-tint"], ["bg", "ink"]];
  for (const sel of [':root, [data-theme="light"]', '[data-theme="dark"]']) {
    const t = tokens(block(sel));
    for (const [fg, bg] of pairs) assert.ok(contrast(t[fg], t[bg]) >= 4.5, `${sel} ${fg} on ${bg}: ${contrast(t[fg], t[bg]).toFixed(2)}`);
  }
});
