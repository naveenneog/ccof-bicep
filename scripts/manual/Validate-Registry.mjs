import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [repo, registryPath, settingsPath] = process.argv.slice(2);
if (!repo || !registryPath || !settingsPath || process.argv.length !== 5) {
  throw new Error("Usage: node Validate-Registry.mjs REPO REGISTRY_JSON SYNC_SETTINGS_OBJECT_JSON");
}
const load = (file) => {
  const text = readFileSync(file, "utf8");
  if (text.includes("REPLACE-")) throw new Error(`Unfilled placeholders: ${path.basename(file)}`);
  return JSON.parse(text);
};
const documents = load(registryPath);
assert.deepEqual(Object.keys(documents).sort(), ["backends", "projects"]);
assert.ok(Array.isArray(documents.projects) && documents.projects.length > 0, "At least one project is required");
assert.ok(Array.isArray(documents.backends) && documents.backends.length > 0, "At least one backend is required");
const backendIds = new Set(documents.backends.map((b) => b.backendId));
assert.equal(backendIds.size, documents.backends.length, "Duplicate backend");
for (const p of documents.projects) assert.ok(backendIds.has(p.backendId), "Project references an unknown backend");
const settings = load(settingsPath);
const { runRegistrySeed } = await import(pathToFileURL(path.join(repo, "src", "sync", "registry-seed.ts")).href);
const encoded = Buffer.from(JSON.stringify({ seedId: "0123456789abcdef0123456789abcdef", ...documents })).toString("base64");
const records = new Map();
const store = {
  create: async (container, doc) => {
    const key = `${container}/${doc.id}`;
    if (records.has(key)) return "conflict";
    records.set(key, structuredClone(doc));
    return "created";
  },
  read: async (container, id) => records.get(`${container}/${id}`) ?? null,
};
const deps = { openStore: () => store, now: () => new Date(), log: () => {} };
const result = await runRegistrySeed({ ...settings, CCOF_SEED_DOCUMENTS: encoded }, deps);
assert.equal(result?.outcome, "succeeded", `Registry refused: ${JSON.stringify(result)}`);
assert.equal(result.documents.length, documents.projects.length + documents.backends.length);
assert.ok(result.documents.every((d) => d.outcome === "created"));
const again = await runRegistrySeed({ ...settings, CCOF_SEED_DOCUMENTS: encoded }, deps);
assert.equal(again?.outcome, "succeeded");
assert.ok(again.documents.every((d) => d.outcome === "present-equal"));
console.log(`Offline validation passed for ${result.documents.length} documents. No Azure calls, credentials or real items were used.`);
