// The sync CLI (docs/SYNC.md). Three commands, each printing JSON lines:
//   --once           one run reading Graph (same code and lease as the timer)
//   snapshot         read the listed groups with a person's delegated Azure CLI
//                    login and write a snapshot; any failed group writes nothing
//   apply-snapshot   check a snapshot and apply it inside the VNet
//
// The module does nothing when imported: the Functions host loads every file
// under dist/ in the resolver app, so a command starts only when this file is
// the process entry point.

import { createHash, randomUUID } from "node:crypto";
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { exitCodeFor, parseCliArgs, parseGroupsFile, parseSettingsFile, USAGE } from "./cli-args.ts";
import type { CliArgs } from "./cli-args.ts";
import { readGraphSettings, readSnapshotLimits, readSyncConfig } from "./config.ts";
import type { ConfigProblem } from "./config.ts";
import { configFailure, refusedBeforeRun, runSync } from "./run.ts";
import { GRAPH_SCOPE } from "./graph.ts";
import { snapshotGroupReader, takeSnapshot, validateSnapshot, snapshotReader } from "./snapshot.ts";

type RunArgs = Extract<CliArgs, { ok: true; command: "run" | "apply-snapshot" }>;
type SnapshotArgs = Extract<CliArgs, { ok: true; command: "snapshot" }>;

const context = () => ({ trigger: "cli" as const, now: () => new Date(), newRunId: () => randomUUID(), log: (line: string) => console.log(line) });

function readSettings(path: string): Record<string, string> | null {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    console.error(`cannot read the settings file ${path}`);
    return null;
  }
  const file = parseSettingsFile(text);
  if (!file.ok) {
    console.error(file.error);
    return null;
  }
  return file.settings;
}

async function credentialFor(args: RunArgs, tenantId: string) {
  const { AzureCliCredential, ManagedIdentityCredential } = await import("@azure/identity");
  if (args.credential === "azure-cli") return new AzureCliCredential({ tenantId });
  return args.clientId ? new ManagedIdentityCredential({ clientId: args.clientId }) : new ManagedIdentityCredential();
}

async function runCommand(args: RunArgs): Promise<number> {
  const settings = readSettings(args.settingsPath);
  if (!settings) return 2;
  const ctx = context();
  const config = readSyncConfig(settings);
  const limits = args.command === "apply-snapshot" ? readSnapshotLimits(settings) : null;
  const problems: ConfigProblem[] = [...(config.ok ? [] : config.problems), ...(limits && !limits.ok ? limits.problems : [])];
  if (!config.ok || problems.length > 0) {
    configFailure(problems, ctx);
    return 2;
  }
  const snapshotLimits = limits && limits.ok ? limits.limits : null;
  // Loaded only now, after every input is valid: an invalid run makes no Azure call.
  const { createAzureDependencies } = await import("./azure.ts");
  const deps = createAzureDependencies(config.config, await credentialFor(args, config.config.tenantId));
  if (args.command === "run") return exitCodeFor((await runSync(config.config, deps, ctx)).outcome);

  let text: string;
  try {
    text = readFileSync(args.snapshotPath, "utf8");
  } catch {
    console.error(`cannot read the snapshot ${args.snapshotPath}`);
    return 2;
  }
  const snapshot = validateSnapshot(text, { tenantId: config.config.tenantId, now: ctx.now(), limits: snapshotLimits as NonNullable<typeof snapshotLimits> });
  if (!snapshot.ok) {
    refusedBeforeRun("snapshot_invalid", snapshot.problems, ctx);
    return 2;
  }
  const reader = snapshotReader(snapshot);
  const summary = await runSync(config.config, { ...deps, readGroup: reader.readGroup, checkGroups: reader.checkGroups }, { ...ctx, source: { kind: "snapshot", sha256: snapshot.sha256, readAt: snapshot.readAt } });
  return exitCodeFor(summary.outcome);
}

async function snapshotCommand(args: SnapshotArgs): Promise<number> {
  const settings = readSettings(args.settingsPath);
  if (!settings) return 2;
  const graph = readGraphSettings(settings);
  if (!graph.ok) {
    console.error(`settings refused: ${graph.problems.map((p) => `${p.setting}:${p.problem}`).join(", ")}`);
    return 2;
  }
  let groups: ReturnType<typeof parseGroupsFile>;
  try {
    groups = parseGroupsFile(readFileSync(args.groupsPath, "utf8"));
  } catch {
    console.error(`cannot read the groups file ${args.groupsPath}`);
    return 2;
  }
  if (!groups.ok) {
    console.error(groups.error);
    return 2;
  }
  if (existsSync(args.outPath)) {
    console.error(`${args.outPath} exists; a snapshot never overwrites a file`);
    return 2;
  }
  const { AzureCliCredential } = await import("@azure/identity");
  const credential = new AzureCliCredential({ tenantId: graph.settings.tenantId });
  const getToken = async () => {
    const token = await credential.getToken(GRAPH_SCOPE);
    if (!token) throw new Error("no Graph token");
    return token.token;
  };
  const read = snapshotGroupReader(graph.settings, {
    fetch: (url, init) => fetch(url, init),
    getToken,
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  });
  const result = await takeSnapshot(groups.groupIds, graph.settings.tenantId, read, () => new Date());
  if (!result.ok) {
    console.log(JSON.stringify({ schema: "ccof.sync.snapshot.result.v1", outcome: "failed", reason: result.reason, groupId: result.groupId }));
    return 1;
  }
  const text = `${JSON.stringify(result.snapshot, null, 2)}\n`;
  // Written whole, then renamed: a reader never sees a partial file.
  writeFileSync(`${args.outPath}.partial`, text, { encoding: "utf8", flag: "wx" });
  renameSync(`${args.outPath}.partial`, args.outPath);
  const members = result.snapshot.groups.reduce((n, g) => n + g.members.length, 0);
  console.log(JSON.stringify({ schema: "ccof.sync.snapshot.result.v1", outcome: "succeeded", tenantId: result.snapshot.tenantId, readAt: result.snapshot.readAt, groups: result.snapshot.groups.length, members, bytes: Buffer.byteLength(text), sha256: createHash("sha256").update(text, "utf8").digest("hex") }));
  return 0;
}

export async function main(argv: readonly string[]): Promise<number> {
  const args = parseCliArgs(argv);
  if (!args.ok) {
    console.error(`${args.error}\n\n${USAGE}`);
    return 2;
  }
  if (args.command === "help") {
    console.log(USAGE);
    return 0;
  }
  return args.command === "snapshot" ? snapshotCommand(args) : runCommand(args);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).then(
    (code) => {
      process.exitCode = code;
    },
    () => {
      console.error("the sync command stopped with an unexpected error");
      process.exitCode = 1;
    },
  );
}
