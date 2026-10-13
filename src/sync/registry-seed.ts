// The quick-start's registry seed (ADR-0024, the quick-start's Proposed answer to D-7;
// docs/QUICKSTART.md, step 5). A customer whose Azure Policy denies marketplace VM images has no
// runner VM inside the VNet, and Cosmos public access is off, so the sync app writes the registry
// documents itself: Deploy-Quickstart.ps1 puts them, base64 of { seedId, projects, backends } as
// New-QsSeedDocuments builds them, in the app setting CCOF_SEED_DOCUMENTS and enables this timer.
//
// Create only, with the sync identity's onbProjectWriter role (readMetadata, items/read,
// items/create; no upsert, no replace): a document that exists (409) is read back and its seeded
// fields compared, so a rerun reports present-equal and a different document present-differs, and
// nothing existing is ever changed. Every document is checked before the first write with the
// identifier and model patterns of the sync's projects reader (projects.ts) and the resolver's
// backend registry check (src/resolver/backend.ts); one invalid document refuses the whole seed.
// One ccof.seed.result.v1 line per run (telemetry.ts). Framework-free: function-app.ts registers the
// timer and azure.ts supplies the Cosmos containers.

import { checkBackendRecord } from "../resolver/backend.ts";
import { isIdentifier } from "../resolver/freshness.ts";
import { readHostSettings, readSyncConfig } from "./config.ts";
import type { SyncConfig } from "./config.ts";
import { readProjectDocument } from "./projects.ts";
import { SEED_RESULT_SCHEMA, formatSeedResult } from "./telemetry.ts";
import type { SeedCounts, SeedDocumentResult, SeedOutcome, SeedResult } from "./telemetry.ts";
import { GUID } from "./types.ts";

// No hyphen: a function whose name has one cannot be disabled on Linux (Learn, "How to disable
// functions in Azure Functions").
export const SEED_FUNCTION_NAME = "registrySeed";
export const SEED_SETTING = "CCOF_SEED_DOCUMENTS";
export const SEED_SCHEDULE = "0 */1 * * * *";
// The resolver reads the same container (src/resolver/registry-reads.ts), partition key /backendId.
export const BACKENDS_CONTAINER = "backends";
// Linux limits one environment string to 128 KiB (MAX_ARG_STRLEN), and app settings reach the host as
// environment variables; the wrapper's own limit is lower.
export const MAX_SEED_SETTING_LENGTH = 96 * 1024;
export const MAX_SEED_DOCUMENTS = 500;

export type SeedContainer = "projects" | "backends";

export interface SeedStore {
  // "created" (201) or "conflict" (409); any other failure throws, with the HTTP status as code or
  // statusCode when there is one.
  create(container: SeedContainer, doc: Record<string, unknown>): Promise<"created" | "conflict">;
  // The stored document, or null when there is none (404).
  read(container: SeedContainer, id: string, partitionKey: string): Promise<Record<string, unknown> | null>;
}

export interface SeedDependencies {
  openStore(config: SyncConfig, managedIdentityClientId: string): SeedStore;
  log(line: string): void;
  now(): Date;
}

type Settings = Readonly<Record<string, string | undefined>>;

interface SeedEntry {
  container: SeedContainer;
  id: string;
  partitionKey: string;
  doc: Record<string, unknown>;
}

const SEED_ID = /^[0-9a-f]{32}$/;
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;
const PAYLOAD_KEYS = ["backends", "projects", "seedId"];
// The exact shape of New-QsSeedDocuments (infra/quickstart/Deploy-Quickstart.ps1), which onboarding
// Stage 3's project schema also fixes (scripts/Onboarding.Schemas.psm1).
const PROJECT_KEYS = ["id", "projectId", "displayName", "status", "backendId", "designatedSubscriptionId", "supersedes", "retiredAt", "classifications"];
const CLASSIFICATION_KEYS = ["groupId", "modelAllowList", "personBudget", "aggregateBudget", "aggregateMode", "onboardingMode", "tokenLimits"];
const BUDGET_KEYS = ["amount", "currency", "period"];
const BACKEND_KEYS = ["id", "backendId", "status", "apiFormat", "auth"];
// The fields each authentication mode of src/resolver/backend.ts uses, and no other.
const AUTH_KEYS: Record<string, string[]> = {
  "managed-identity": ["mode", "resource"],
  "credential-manager": ["mode", "providerId", "connectionId"],
  "backend-entity": ["mode"],
};

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOnlyKeys(value: Record<string, unknown>, allowed: readonly string[]): boolean {
  return Object.keys(value).every((key) => allowed.includes(key));
}

function isBudget(value: unknown): boolean {
  return (
    isObject(value) &&
    hasOnlyKeys(value, BUDGET_KEYS) &&
    typeof value.amount === "number" &&
    Number.isFinite(value.amount) &&
    value.amount >= 0 &&
    (value.currency === "CCU" || value.currency === "USD") &&
    value.period === "monthly"
  );
}

// Problems are field paths with codes; a classification code appears only when it is an identifier.
function checkProject(doc: unknown): string[] {
  if (!isObject(doc)) return ["document:not_an_object"];
  const problems: string[] = [];
  if (!hasOnlyKeys(doc, PROJECT_KEYS)) problems.push("document:unexpected_key");
  const read = readProjectDocument(doc);
  if (!read.ok) problems.push(...read.problems);
  if (typeof doc.displayName !== "string" || doc.displayName.length < 1 || doc.displayName.length > 200) problems.push("displayName:invalid");
  if (typeof doc.designatedSubscriptionId !== "string" || !GUID.test(doc.designatedSubscriptionId)) problems.push("designatedSubscriptionId:invalid");
  // A seed creates new active projects only.
  if (doc.supersedes !== null) problems.push("supersedes:invalid");
  if (doc.retiredAt !== null) problems.push("retiredAt:invalid");
  if (isObject(doc.classifications)) {
    for (const [code, value] of Object.entries(doc.classifications)) {
      if (!isIdentifier(code) || !isObject(value)) continue;
      const path = `classifications.${code}`;
      if (!hasOnlyKeys(value, CLASSIFICATION_KEYS)) problems.push(`${path}:unexpected_key`);
      if (!isBudget(value.personBudget)) problems.push(`${path}.personBudget:invalid`);
      if (value.aggregateBudget !== null && !isBudget(value.aggregateBudget)) problems.push(`${path}.aggregateBudget:invalid`);
      if (value.onboardingMode !== "block" && value.onboardingMode !== "warn") problems.push(`${path}.onboardingMode:invalid`);
    }
  }
  return problems;
}

function checkBackend(doc: unknown): string[] {
  if (!isObject(doc)) return ["document:not_an_object"];
  const problems: string[] = [];
  if (!hasOnlyKeys(doc, BACKEND_KEYS)) problems.push("document:unexpected_key");
  if (!isIdentifier(doc.backendId)) {
    problems.push("backendId:invalid");
    return problems;
  }
  const verdict = checkBackendRecord(doc, doc.backendId);
  if (verdict.kind === "invalid") problems.push(verdict.detail);
  else if (verdict.kind === "not_active") problems.push("status:not_active");
  const auth = doc.auth;
  if (isObject(auth) && typeof auth.mode === "string" && AUTH_KEYS[auth.mode] && !hasOnlyKeys(auth, AUTH_KEYS[auth.mode])) problems.push("auth:unexpected_key");
  return problems;
}

type Decoded =
  | { ok: true; seedId: string; projects: unknown[]; backends: unknown[] }
  | { ok: false; seedId: string | null; reason: "seed_documents_malformed" | "seed_documents_too_large" };

function decodeSeed(encoded: string): Decoded {
  if (encoded.length > MAX_SEED_SETTING_LENGTH) return { ok: false, seedId: null, reason: "seed_documents_too_large" };
  const malformed = (seedId: string | null = null): Decoded => ({ ok: false, seedId, reason: "seed_documents_malformed" });
  if (encoded.length % 4 !== 0 || !BASE64.test(encoded)) return malformed();
  let payload: unknown;
  try {
    payload = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(Buffer.from(encoded, "base64")));
  } catch {
    return malformed();
  }
  if (!isObject(payload)) return malformed();
  const seedId = typeof payload.seedId === "string" && SEED_ID.test(payload.seedId) ? payload.seedId : null;
  if (!seedId) return malformed();
  const keys = Object.keys(payload).sort();
  if (keys.join(",") !== PAYLOAD_KEYS.join(",")) return malformed(seedId);
  const { projects, backends } = payload;
  if (!Array.isArray(projects) || !Array.isArray(backends)) return malformed(seedId);
  const count = projects.length + backends.length;
  if (count === 0 || count > MAX_SEED_DOCUMENTS) return malformed(seedId);
  return { ok: true, seedId, projects, backends };
}

// Backends first: a project names its backend, so the backend document exists before the project.
function toEntries(decoded: { projects: unknown[]; backends: unknown[] }): { entries: SeedEntry[]; refused: SeedDocumentResult[]; invalid: boolean } {
  const entries: SeedEntry[] = [];
  const refused: SeedDocumentResult[] = [];
  const seen = new Set<string>();
  let invalid = false;
  const add = (container: SeedContainer, doc: unknown, problems: string[], key: "projectId" | "backendId") => {
    const raw = isObject(doc) ? doc[key] : undefined;
    const id = isIdentifier(raw) ? raw : null;
    if (id !== null && problems.length === 0) {
      if (seen.has(`${container}/${id}`)) problems = ["id:duplicate"];
      seen.add(`${container}/${id}`);
    }
    if (problems.length > 0) {
      invalid = true;
      refused.push({ container, id, outcome: "failed", code: "invalid_document", problems });
      return;
    }
    entries.push({ container, id: id as string, partitionKey: id as string, doc: doc as Record<string, unknown> });
    refused.push({ container, id, outcome: "failed", code: "batch_refused" });
  };
  for (const doc of decoded.backends) add("backends", doc, checkBackend(doc), "backendId");
  for (const doc of decoded.projects) add("projects", doc, checkProject(doc), "projectId");
  return { entries, refused, invalid };
}

function statusOf(err: unknown): number | undefined {
  if (typeof err !== "object" || err === null) return undefined;
  const e = err as { code?: unknown; statusCode?: unknown };
  const value = typeof e.code === "number" ? e.code : e.statusCode;
  return typeof value === "number" ? value : undefined;
}

function failureCode(step: "create" | "read", err: unknown): string {
  const status = statusOf(err);
  return status === undefined ? `${step}_error` : `${step}_http_${status}`;
}

// JSON with object keys sorted: key order is not a difference, array order is.
function canonical(value: unknown): string {
  if (value === undefined) return "undefined";
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (isObject(value)) return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
  return JSON.stringify(value);
}

// The seeded fields only: a field the seed does not write (an operator's note, Cosmos system
// properties) is not a difference.
function differingFields(stored: Record<string, unknown>, wanted: Record<string, unknown>): string[] {
  return Object.keys(wanted)
    .filter((key) => canonical(stored[key]) !== canonical(wanted[key]))
    .sort();
}

async function seedOne(store: SeedStore, entry: SeedEntry): Promise<SeedDocumentResult> {
  const base = { container: entry.container, id: entry.id };
  let created: "created" | "conflict";
  try {
    created = await store.create(entry.container, entry.doc);
  } catch (err) {
    return { ...base, outcome: "failed", code: failureCode("create", err) };
  }
  if (created === "created") return { ...base, outcome: "created" };
  let stored: Record<string, unknown> | null;
  try {
    stored = await store.read(entry.container, entry.id, entry.partitionKey);
  } catch (err) {
    return { ...base, outcome: "failed", code: failureCode("read", err) };
  }
  if (!stored) return { ...base, outcome: "failed", code: "read_not_found" };
  const fields = differingFields(stored, entry.doc);
  return fields.length > 0 ? { ...base, outcome: "present-differs", fields } : { ...base, outcome: "present-equal" };
}

function countOf(documents: SeedDocumentResult[]): SeedCounts {
  const count = (outcome: SeedDocumentResult["outcome"]) => documents.filter((d) => d.outcome === outcome).length;
  return { created: count("created"), presentEqual: count("present-equal"), presentDiffers: count("present-differs"), failed: count("failed") };
}

function outcomeOf(documents: SeedDocumentResult[]): SeedOutcome {
  if (documents.some((d) => d.outcome === "failed")) return "failed";
  if (documents.some((d) => d.outcome === "present-differs")) return "differs";
  return "succeeded";
}

// Returns null, with no Cosmos call and no log line, while the setting is absent or empty.
export async function runRegistrySeed(settings: Settings, deps: SeedDependencies): Promise<SeedResult | null> {
  const encoded = settings[SEED_SETTING]?.trim();
  if (!encoded) return null;
  const started = deps.now();
  const finish = (seedId: string | null, documents: SeedDocumentResult[], refusal?: { reason: string; problems?: string[] }): SeedResult => {
    const result: SeedResult = {
      schema: SEED_RESULT_SCHEMA,
      seedId,
      outcome: refusal ? "refused" : outcomeOf(documents),
      reason: refusal?.reason,
      problems: refusal?.problems,
      counts: countOf(documents),
      documents,
      startedAt: started.toISOString(),
      durationMs: deps.now().getTime() - started.getTime(),
    };
    deps.log(formatSeedResult(result));
    return result;
  };

  const decoded = decodeSeed(encoded);
  if (!decoded.ok) return finish(decoded.seedId, [], { reason: decoded.reason });
  const { entries, refused, invalid } = toEntries(decoded);
  if (invalid) return finish(decoded.seedId, refused, { reason: "seed_documents_invalid" });

  // The sync's own Cosmos settings and managed identity, as a sync run reads them (config.ts).
  const host = readHostSettings(settings);
  const sync = readSyncConfig(settings);
  if (!host.ok || !sync.ok) {
    const problems = [...(host.ok ? [] : host.problems), ...(sync.ok ? [] : sync.problems)].map((p) => `${p.setting}:${p.problem}`);
    return finish(decoded.seedId, refused, { reason: "seed_config_invalid", problems });
  }
  let store: SeedStore;
  try {
    store = deps.openStore(sync.config, host.managedIdentityClientId);
  } catch {
    return finish(decoded.seedId, entries.map((e) => ({ container: e.container, id: e.id, outcome: "failed", code: "store_unavailable" })));
  }
  const documents: SeedDocumentResult[] = [];
  for (const entry of entries) documents.push(await seedOne(store, entry));
  return finish(decoded.seedId, documents);
}
