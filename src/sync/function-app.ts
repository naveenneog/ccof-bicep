// Azure Functions v4 registration of the timer-triggered sync. Thin by design:
// the run is src/sync/run.ts, tested with fakes.
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
import { createAzureDependencies } from "./azure.ts";
import { readHostSettings, readSyncConfig } from "./config.ts";
import { configFailure, runSync } from "./run.ts";

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

if (process.env.CCOF_APP_ROLE === "sync") {
  app.timer(FUNCTION_NAME, { schedule: "%SYNC_SCHEDULE%", runOnStartup: false, handler: syncTimer });
}
