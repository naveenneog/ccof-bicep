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
