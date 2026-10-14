// The delegated snapshot apply without a runner VM (docs/SYNC.md, "Without the Graph application
// permission"). The sync Function App is already inside the VNet with the sync identity's Cosmos
// roles, so it applies the snapshot the workstation sets as an app setting (base64, with the SHA-256
// the snapshot command printed) through the same plan, lease and removal limits as the timer and the
// runner's apply-snapshot. Registered by function-app.ts only while CCOF_SYNC_SNAPSHOT is set.
// A second run of the same snapshot is refused by the lease (snapshot_older_than_applied).

import { readSnapshotLimits, readSyncConfig } from "./config.ts";
import type { SyncConfig } from "./config.ts";
import { configFailure, refusedBeforeRun, runSync } from "./run.ts";
import type { RunDependencies } from "./run.ts";
import { snapshotReader, validateSnapshot } from "./snapshot.ts";

// No hyphen: a function whose name has one cannot be disabled on Linux.
export const SNAPSHOT_FUNCTION_NAME = "snapshotApply";
export const SNAPSHOT_SETTING = "CCOF_SYNC_SNAPSHOT";
export const SNAPSHOT_SHA_SETTING = "CCOF_SYNC_SNAPSHOT_SHA256";
export const SNAPSHOT_OPERATION_SETTING = "CCOF_SYNC_SNAPSHOT_OPERATION_ID";
export const SNAPSHOT_SCHEDULE = "0 */1 * * * *";

export function snapshotOperationLog(env: Readonly<Record<string, string | undefined>>, log: (line: string) => void) {
  const operationId = env[SNAPSHOT_OPERATION_SETTING]?.trim();
  return (line: string) => {
    if (!operationId) { log(line); return; }
    let event;
    try { event = JSON.parse(line); } catch { log(line); return; }
    if (event && typeof event === "object" && event.schema === "ccof.sync.run.v1") {
      event.snapshotOperationId = operationId;
      log(JSON.stringify(event));
    } else {
      log(line);
    }
  };
}

export interface SnapshotFunctionDependencies {
  // Called only after every input is valid, so a refused apply makes no Azure call.
  createDependencies(config: SyncConfig): RunDependencies;
  log(line: string): void;
  now(): Date;
  newRunId(): string;
}

export async function runSnapshotFunction(env: Readonly<Record<string, string | undefined>>, deps: SnapshotFunctionDependencies) {
  const context = { trigger: "timer" as const, now: deps.now, newRunId: deps.newRunId, log: snapshotOperationLog(env, deps.log) };
  const config = readSyncConfig(env);
  const limits = readSnapshotLimits(env);
  if (!config.ok || !limits.ok) {
    return configFailure([...(config.ok ? [] : config.problems), ...(limits.ok ? [] : limits.problems)], context);
  }
  const expected = (env[SNAPSHOT_SHA_SETTING] ?? "").trim().toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(expected)) return refusedBeforeRun("snapshot_hash_missing", [`${SNAPSHOT_SHA_SETTING}:invalid`], context);
  const text = Buffer.from((env[SNAPSHOT_SETTING] ?? "").trim(), "base64").toString("utf8");
  const snapshot = validateSnapshot(text, { tenantId: config.config.tenantId, now: deps.now(), limits: limits.limits });
  if (!snapshot.ok) return refusedBeforeRun("snapshot_invalid", snapshot.problems, context);
  if (snapshot.sha256 !== expected) return refusedBeforeRun("snapshot_hash_mismatch", [`${SNAPSHOT_SHA_SETTING}:differs`], context);
  const reader = snapshotReader(snapshot);
  return runSync(
    config.config,
    { ...deps.createDependencies(config.config), readGroup: reader.readGroup, checkGroups: reader.checkGroups },
    { ...context, source: { kind: "snapshot", sha256: snapshot.sha256, readAt: snapshot.readAt } },
  );
}
