// Sync removal limits edited from the admin console. Stored in adminConfig as one document that the
// sync reads before each run (src/sync/removal-limits.ts, same validation). Without an enabled,
// unexpired override, the sync's app settings SYNC_MAX_REMOVALS_PER_RUN / SYNC_MAX_REMOVAL_FRACTION apply.

import type { Container } from "@azure/cosmos";
import { REMOVAL_LIMITS_DOCUMENT_ID, removalLimitsProblems } from "../../src/sync/removal-limits.ts";
import { ValidationError, isObject } from "./validation.ts";
import type { Doc } from "./validation.ts";

export interface LimitsStore {
  read(): Promise<{ doc: Doc; etag: string } | null>;
  // The new ETag, or null when the stored ETag differs (or the document appeared meanwhile).
  save(doc: Doc, etag: string | null): Promise<string | null>;
}
const EDITABLE = ["enabled", "maxRemovalsPerRun", "maxRemovalFraction", "expiresAt", "reason"];
export const MAX_OVERRIDE_DAYS = 90;

// The stored document; schemaVersion, updatedAt and updatedBy are set by the server, never the browser.
export function limitsFromBody(body: unknown, actorOid: string, now: Date): Doc {
  if (!isObject(body) || Object.keys(body).some((k) => !EDITABLE.includes(k))) throw new ValidationError(["document:unexpected_key"]);
  const doc: Doc = {
    schemaVersion: 1, enabled: body.enabled, maxRemovalsPerRun: body.maxRemovalsPerRun, maxRemovalFraction: body.maxRemovalFraction,
    expiresAt: body.expiresAt ?? null, reason: typeof body.reason === "string" ? body.reason.trim() : body.reason,
  };
  const problems = removalLimitsProblems(doc);
  if (typeof doc.expiresAt === "string" && !problems.includes("expiresAt:invalid")) {
    const at = Date.parse(doc.expiresAt);
    // A past expiry is harmless on a disabled override, so switching an expired one off is always possible.
    if (at <= now.getTime() && doc.enabled === true) problems.push("expiresAt:not_in_future");
    else if (at > now.getTime() + MAX_OVERRIDE_DAYS * 86_400_000) problems.push("expiresAt:beyond_90_days");
  }
  if (problems.length) throw new ValidationError(problems);
  return { ...doc, updatedAt: now.toISOString(), updatedBy: actorOid };
}

export function overrideState(doc: Doc | null, now: Date): "none" | "disabled" | "expired" | "in_effect" | "invalid" {
  if (!doc) return "none";
  if (removalLimitsProblems(doc).length) return "invalid";
  if (!doc.enabled) return "disabled";
  return typeof doc.expiresAt === "string" && Date.parse(doc.expiresAt) <= now.getTime() ? "expired" : "in_effect";
}

const SYSTEM = ["schemaVersion", "updatedAt", "updatedBy", ...EDITABLE];
export const publicLimits = (doc: Doc | null) => doc ? Object.fromEntries(SYSTEM.map((k) => [k, doc[k] ?? null])) : null;

export function createLimitsStore(container: Container): LimitsStore {
  const id = REMOVAL_LIMITS_DOCUMENT_ID;
  return {
    async read() {
      try {
        const response = await container.item(id, id).read<Doc>();
        return response.resource ? { doc: response.resource, etag: response.etag ?? "" } : null;
      } catch (err) { if ((err as { code?: number })?.code === 404) return null; throw err; }
    },
    async save(doc, etag) {
      const value = { ...doc, id, scopeId: id };
      try {
        const response = etag
          ? await container.item(id, id).replace(value, { accessCondition: { type: "IfMatch", condition: etag } })
          : await container.items.create(value);
        return response.etag ?? null;
      } catch (err) { if ([409, 412, 404].includes((err as { code?: number })?.code ?? 0)) return null; throw err; }
    },
  };
}

export function createMemoryLimitsStore(): LimitsStore & { current: { doc: Doc; etag: string } | null } {
  let n = 0;
  const store = {
    current: null as { doc: Doc; etag: string } | null,
    async read() { return store.current ? structuredClone(store.current) : null; },
    async save(doc: Doc, etag: string | null) {
      if ((store.current?.etag ?? null) !== etag) return null;
      store.current = { doc: structuredClone(doc), etag: `"limits-${++n}"` };
      return store.current.etag;
    },
  };
  return store;
}
