// Azure Functions v4 registration of the timer-triggered sync, and of the quick-start's registry seed
// (registry-seed.ts) while its documents are set. Thin by design: the run is src/sync/run.ts, the
// seed src/sync/registry-seed.ts, both tested with fakes.
//
// The resolver app's package also contains dist/sync, because package.json
// "main" is the glob dist/**/*.js. The timer is therefore registered only in
// the app whose CCOF_APP_ROLE setting is "sync".
//
// Graph token sequencing (ADR-0016): the managed identity's Graph token is
// requested only inside a run, and the deploy script keeps this function
// disabled (AzureWebJobs.syncEntitlement.Disabled) until the Graph application
// permission is granted. Managed identity tokens are cached by the platform
// "per resource URI for around 24 hours" (Learn, "Best practice
// recommendations for managed system identities", retrieved 2026-10-11).

import { randomUUID } from "node:crypto";
import { app } from "@azure/functions";
import type { InvocationContext, Timer } from "@azure/functions";
import { ManagedIdentityCredential } from "@azure/identity";
import { createAzureDependencies, createSeedStore } from "./azure.ts";
import { readHostSettings, readSyncConfig } from "./config.ts";
import { SEED_FUNCTION_NAME, SEED_SCHEDULE, SEED_SETTING, runRegistrySeed } from "./registry-seed.ts";
import { configFailure, runSync } from "./run.ts";
import { SNAPSHOT_FUNCTION_NAME, SNAPSHOT_SCHEDULE, SNAPSHOT_SETTING, runSnapshotFunction, snapshotOperationLog } from "./snapshot-function.ts";

// No hyphen: a function whose name has one cannot be disabled on Linux (Learn,
// "How to disable functions in Azure Functions").
export const FUNCTION_NAME = "syncEntitlement";

async function syncTimer(_timer: Timer, context: InvocationContext): Promise<void> {
  const runContext = {
    trigger: "timer" as const,
    now: () => new Date(),
    newRunId: () => randomUUID(),
    log: (line: string) => context.log(line),
  };
  const host = readHostSettings(process.env);
  const sync = readSyncConfig(process.env);
  if (!host.ok || !sync.ok) {
    configFailure([...(host.ok ? [] : host.problems), ...(sync.ok ? [] : sync.problems)], runContext);
    return;
  }
  const credential = new ManagedIdentityCredential({ clientId: host.managedIdentityClientId });
  await runSync(sync.config, createAzureDependencies(sync.config, credential), runContext);
}

// The quick-start's registry seed (registry-seed.ts; docs/QUICKSTART.md, step 5).
async function registrySeedTimer(_timer: Timer, context: InvocationContext): Promise<void> {
  await runRegistrySeed(process.env, {
    openStore: (config, clientId) => createSeedStore(config, new ManagedIdentityCredential({ clientId })),
    log: (line: string) => context.log(line),
    now: () => new Date(),
  });
}

// The delegated snapshot apply without a runner VM (snapshot-function.ts; docs/SYNC.md).
async function snapshotApplyTimer(_timer: Timer, context: InvocationContext): Promise<void> {
  const log = snapshotOperationLog(process.env, (line: string) => context.log(line));
  const host = readHostSettings(process.env);
  if (!host.ok) {
    configFailure(host.problems, { trigger: "timer", now: () => new Date(), newRunId: () => randomUUID(), log });
    return;
  }
  const credential = new ManagedIdentityCredential({ clientId: host.managedIdentityClientId });
  await runSnapshotFunction(process.env, {
    createDependencies: (config) => createAzureDependencies(config, credential),
    log,
    now: () => new Date(),
    newRunId: () => randomUUID(),
  });
}

if (process.env.CCOF_APP_ROLE === "sync") {
  app.timer(FUNCTION_NAME, { schedule: "%SYNC_SCHEDULE%", runOnStartup: false, handler: syncTimer });
  // Only while step 5 has set the seed documents, so the staged path (which never sets them) gets no
  // new function; the host runs it only while AzureWebJobs.registrySeed.Disabled is false, which the
  // quick-start's settings keep true outside step 5.
  if (process.env[SEED_SETTING]?.trim()) {
    app.timer(SEED_FUNCTION_NAME, { schedule: SEED_SCHEDULE, runOnStartup: false, handler: registrySeedTimer });
  }
  // Only while Invoke-SnapshotApplyThroughFunction.ps1 has set a snapshot; it also keeps
  // AzureWebJobs.snapshotApply.Disabled true outside its run.
  if (process.env[SNAPSHOT_SETTING]?.trim()) {
    app.timer(SNAPSHOT_FUNCTION_NAME, { schedule: SNAPSHOT_SCHEDULE, runOnStartup: false, handler: snapshotApplyTimer });
  }
}
