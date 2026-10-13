// Arguments and input files of the sync CLI (cli.ts). Pure, so the parsing is
// tested without loading an Azure SDK.

import { GUID } from "./types.ts";
import type { RunOutcome } from "./telemetry.ts";

export const USAGE = [
  "Usage:",
  "  node dist/sync/cli.js --once --credential azure-cli|managed-identity [--client-id <guid>] --settings <file.json>",
  "  node dist/sync/cli.js snapshot --credential azure-cli --groups <groups.json> --settings <file.json> --out <snapshot.json>",
  "  node dist/sync/cli.js apply-snapshot --snapshot <snapshot.json> --credential managed-identity|azure-cli [--client-id <guid>] --settings <file.json>",
  "",
  "  --once                 one sync run reading Graph, then exit",
  "  snapshot               read the listed groups with the signed-in person's Azure CLI login (delegated Graph read)",
  "                         and write a snapshot; any failed group writes nothing",
  "  apply-snapshot         check a snapshot and apply it with the same plan, lease and removal limits as the timer",
  "  --credential           azure-cli: the signed-in person's Azure CLI login; managed-identity: this machine's identity",
  "  --client-id            a user-assigned identity's client id (managed-identity only)",
  "  --settings             JSON object of settings, string values only (docs/SYNC.md)",
  "  --groups               JSON object {\"groupIds\": [\"<group object id>\", ...]}",
  "",
  "Exit codes: 0 succeeded, 1 failed, 2 refused input, 3 partial, 4 skipped (another run holds the lease).",
].join("\n");

type Credential = "azure-cli" | "managed-identity";

export type CliArgs =
  | { ok: true; command: "help" }
  | { ok: true; command: "run"; credential: Credential; clientId: string | null; settingsPath: string }
  | { ok: true; command: "snapshot"; credential: "azure-cli"; groupsPath: string; settingsPath: string; outPath: string }
  | { ok: true; command: "apply-snapshot"; credential: Credential; clientId: string | null; snapshotPath: string; settingsPath: string }
  | { ok: false; error: string };

type Failure = { ok: false; error: string };

const VALUE_FLAGS: Record<string, readonly string[]> = {
  run: ["--credential", "--client-id", "--settings"],
  snapshot: ["--credential", "--groups", "--settings", "--out"],
  "apply-snapshot": ["--snapshot", "--credential", "--client-id", "--settings"],
};

function readFlags(command: string, argv: readonly string[]): { values: Map<string, string>; once: boolean } | Failure {
  const seen = new Set<string>();
  const values = new Map<string, string>();
  let once = false;
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (seen.has(flag)) return { ok: false, error: `${flag} is given more than once` };
    seen.add(flag);
    if (flag === "--once" && command === "run") {
      once = true;
      continue;
    }
    if (VALUE_FLAGS[command].includes(flag)) {
      const value = argv[i + 1];
      if (value === undefined || value.startsWith("--")) return { ok: false, error: `${flag} needs a value` };
      values.set(flag, value);
      i += 1;
      continue;
    }
    return { ok: false, error: `unknown argument ${flag} for ${command}; see --help` };
  }
  return { values, once };
}

function readCredential(values: Map<string, string>): { credential: Credential; clientId: string | null } | Failure {
  const credential = values.get("--credential");
  if (credential !== "azure-cli" && credential !== "managed-identity") return { ok: false, error: "--credential must be azure-cli or managed-identity" };
  const clientId = values.get("--client-id") ?? null;
  if (clientId !== null && credential !== "managed-identity") return { ok: false, error: "--client-id applies only to --credential managed-identity" };
  if (clientId !== null && !GUID.test(clientId)) return { ok: false, error: "--client-id must be a GUID" };
  return { credential, clientId: clientId?.toLowerCase() ?? null };
}

function required(values: Map<string, string>, flag: string, what: string): string | Failure {
  return values.get(flag) ?? { ok: false, error: `${flag} <${what}> is required` };
}

export function parseCliArgs(argv: readonly string[]): CliArgs {
  if (argv.length === 1 && argv[0] === "--help") return { ok: true, command: "help" };
  const command = argv[0] === "snapshot" || argv[0] === "apply-snapshot" ? argv[0] : "run";
  const flags = readFlags(command, command === "run" ? argv : argv.slice(1));
  if ("ok" in flags) return flags;
  const { values } = flags;
  if (command === "run" && !flags.once) return { ok: false, error: "--once is required: the CLI makes exactly one run" };
  const cred = readCredential(values);
  if ("ok" in cred) return cred;
  const settingsPath = required(values, "--settings", "file.json");
  if (typeof settingsPath !== "string") return settingsPath;

  if (command === "snapshot") {
    if (cred.credential !== "azure-cli") return { ok: false, error: "snapshot reads Graph with --credential azure-cli (a person's delegated sign-in)" };
    const groupsPath = required(values, "--groups", "groups.json");
    if (typeof groupsPath !== "string") return groupsPath;
    const outPath = required(values, "--out", "snapshot.json");
    if (typeof outPath !== "string") return outPath;
    return { ok: true, command, credential: "azure-cli", groupsPath, settingsPath, outPath };
  }
  if (command === "apply-snapshot") {
    const snapshotPath = required(values, "--snapshot", "snapshot.json");
    if (typeof snapshotPath !== "string") return snapshotPath;
    return { ok: true, command, ...cred, snapshotPath, settingsPath };
  }
  return { ok: true, command: "run", ...cred, settingsPath };
}

export type SettingsFile = { ok: true; settings: Record<string, string> } | { ok: false; error: string };

export function parseSettingsFile(text: string): SettingsFile {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { ok: false, error: "the settings file is not JSON" };
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return { ok: false, error: "the settings file must be a JSON object" };
  const settings: Record<string, string> = {};
  for (const [name, value] of Object.entries(parsed)) {
    if (typeof value !== "string") return { ok: false, error: `setting ${name} must be a string, as an app setting is` };
    settings[name] = value;
  }
  return { ok: true, settings };
}

export function parseGroupsFile(text: string): { ok: true; groupIds: string[] } | { ok: false; error: string } {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { ok: false, error: "the groups file is not JSON" };
  }
  const groupIds = (parsed as { groupIds?: unknown } | null)?.groupIds;
  if (!Array.isArray(groupIds) || groupIds.length === 0 || !groupIds.every((g) => typeof g === "string")) {
    return { ok: false, error: 'the groups file must be {"groupIds": ["<group object id>", ...]} with at least one id' };
  }
  return { ok: true, groupIds: groupIds as string[] };
}

export function exitCodeFor(outcome: RunOutcome): number {
  return { succeeded: 0, failed: 1, partial: 3, skipped: 4 }[outcome];
}
