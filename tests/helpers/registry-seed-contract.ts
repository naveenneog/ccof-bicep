// The contract between Deploy-Quickstart.ps1 step 5 and the sync app's registrySeed function: runs
// src/sync/registry-seed.ts twice on the CCOF_SEED_DOCUMENTS of this process's environment, against an
// in-memory store, and prints the two result lines. tests/Test-QuickstartSeed.ps1 passes the value
// New-QsSeedPayload builds from the quick-start parameters, so the documents the wrapper sends are the
// documents the function accepts. No Azure SDK is loaded.

import { SEED_SETTING, runRegistrySeed } from "../../src/sync/registry-seed.ts";
import type { SeedContainer, SeedStore } from "../../src/sync/registry-seed.ts";

const docs = new Map<string, Record<string, unknown>>();
const store: SeedStore = {
  async create(container: SeedContainer, doc: Record<string, unknown>) {
    const key = `${container}/${String(doc.id)}`;
    if (docs.has(key)) return "conflict";
    docs.set(key, structuredClone(doc));
    return "created";
  },
  async read(container: SeedContainer, id: string) {
    return docs.get(`${container}/${id}`) ?? null;
  },
};

// The sync app's settings as infra/quickstart/modules/app-settings.bicep writes them (placeholders).
const settings: Record<string, string | undefined> = {
  SYNC_TENANT_ID: "00000000-0000-0000-0000-0000000000aa",
  COSMOS_ENDPOINT: "https://example-sampleqs-cosmos.documents.azure.com:443/",
  COSMOS_DATABASE: "ccof",
  SYNC_PROJECTS_CONTAINER: "projects",
  SYNC_ENTITLEMENT_CONTAINER: "entitlement",
  SYNC_LEASE_CONTAINER: "syncLease",
  SYNC_LEASE_SECONDS: "300",
  SYNC_MEMBER_TYPES: "user",
  SYNC_MAX_REMOVALS_PER_RUN: "5",
  SYNC_MAX_REMOVAL_FRACTION: "0.1",
  SYNC_GRAPH_MAX_RETRIES: "3",
  SYNC_GRAPH_MAX_RETRY_AFTER_SECONDS: "30",
  SYNC_GRAPH_TIMEOUT_SECONDS: "30",
  SYNC_WRITE_MODE: "apply",
  SYNC_MANAGED_IDENTITY_CLIENT_ID: "00000000-0000-0000-0000-0000000000bb",
  SYNC_SCHEDULE: "0 */1 * * * *",
  [SEED_SETTING]: process.env[SEED_SETTING],
};

for (let run = 0; run < 2; run++) {
  await runRegistrySeed(settings, { openStore: () => store, log: (line) => console.log(line), now: () => new Date() });
}
