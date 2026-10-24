import { build } from "esbuild";
import { copyFile, mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const root = new URL("./", import.meta.url);
await mkdir(new URL("ui-dist/", root), { recursive: true });
for (const file of ["index.html", "app.css", "icon.svg"]) {
  await copyFile(new URL(`ui/${file}`, root), new URL(`ui-dist/${file}`, root));
}
await copyFile(new URL("../config/rate-card.json", root), new URL("ui-dist/rate-card.json", root));
await build({
  entryPoints: [fileURLToPath(new URL("ui/app.js", root))],
  outfile: fileURLToPath(new URL("ui-dist/app.js", root)),
  bundle: true,
  minify: true,
  format: "esm",
  target: ["es2022"],
  legalComments: "eof",
});

// V3 console (admin/ui-v3 -> ui-dist-v3). Same-origin bundle; no CDN, no runtime code fetch.
await mkdir(new URL("ui-dist-v3/", root), { recursive: true });
for (const file of ["index.html", "app.css", "icon.svg"]) {
  await copyFile(new URL(`ui-v3/${file}`, root), new URL(`ui-dist-v3/${file}`, root));
}
await build({
  entryPoints: [fileURLToPath(new URL("ui-v3/main.tsx", root))],
  outfile: fileURLToPath(new URL("ui-dist-v3/app.js", root)),
  bundle: true,
  minify: true,
  format: "esm",
  target: ["es2022"],
  jsx: "automatic",
  define: { "process.env.NODE_ENV": '"production"' },
  legalComments: "eof",
});

// The workbook's own KQL sources, packaged for the V3 server-side chargeback and reconciler views.
await mkdir(new URL("kql/", root), { recursive: true });
for (const [from, to] of [["../analytics/ledger.kql", "ledger.kql"], ["../analytics/workbooks/pricing.kql", "pricing.kql"], ["../analytics/workbooks/budgets.kql", "budgets.kql"]]) {
  await copyFile(new URL(from, root), new URL(`kql/${to}`, root));
}
