// Azure Functions v4 registration of the timer-triggered reconciler. Thin by
// design: the run is src/reconciler/run.ts, tested with fakes.
//
// The package's entry point is this file (package.json "main" is set to
// dist/reconciler/function-app.js when the package is built), and the timer
// is registered only where CCOF_APP_ROLE is "reconciler", as the sync does.

import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { app } from "@azure/functions";
import type { InvocationContext, Timer } from "@azure/functions";
import { ManagedIdentityCredential } from "@azure/identity";
import { loadRunAssets } from "./assets.ts";
import { createReconcilerDependencies } from "./azure.ts";
import { runReconciler, settingsFailure } from "./run.ts";
import type { RunDependencies } from "./run.ts";
import { readReconcilerSettings } from "./settings.ts";

// No hyphen: a function whose name has one cannot be disabled on Linux (Learn,
// "How to disable functions in Azure Functions").
export const FUNCTION_NAME = "reconcileBudgets";

// The package root is two levels above dist/reconciler/.
const packageRoot = new URL("../../", import.meta.url);

// Read once per host instance; a new package or settings change restarts it.
const assets = loadRunAssets((path) => readFile(new URL(path, packageRoot), "utf8")).catch(
  () => ({ ok: false, problem: { setting: "package", problem: "unreadable" } }) as const,
);
let dependencies: RunDependencies | undefined;

async function reconcileTimer(_timer: Timer, context: InvocationContext): Promise<void> {
  const runContext = { now: () => new Date(), newRunId: () => randomUUID(), log: (line: string) => context.log(line) };
  const read = readReconcilerSettings(process.env);
  if (!read.ok) {
    settingsFailure(read.problems, runContext);
    return;
  }
  const loaded = await assets;
  if (!loaded.ok) {
    settingsFailure([loaded.problem], runContext);
    return;
  }
  dependencies ??= createReconcilerDependencies(read.settings, new ManagedIdentityCredential({ clientId: read.settings.managedIdentityClientId }));
  await runReconciler(read.settings, loaded.assets, dependencies, runContext);
}

if (process.env.CCOF_APP_ROLE === "reconciler") {
  app.timer(FUNCTION_NAME, { schedule: "%RECONCILER_SCHEDULE%", runOnStartup: false, handler: reconcileTimer });
}
