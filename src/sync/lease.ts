// One run at a time (ADR-0016). A lease document in its own container, taken
// with create (409 when it exists) and taken over or renewed with an etag
// condition (412 when someone else changed it). A lease left by a stopped run
// expires by itself. The timer app and a manual CLI run share it.
//
// Clock skew between hosts shortens or lengthens a lease by the skew; the
// configured duration must be much longer than any expected skew.

import { parseZonedTimestamp } from "./types.ts";

// A protocol constant, not configuration: every writer must use the same id,
// or two writers could each hold "the" lease.
export const LEASE_ID = "ccof-entitlement-sync";

export interface LeaseDocument {
  id: string;
  holder: string;
  acquiredAt: string;
  renewedAt: string;
  leaseExpiresAt: string;
  released: boolean;
  // The newest directory evidence applied (a Graph run's start, or a
  // snapshot's readAt): an older snapshot is refused, so it cannot undo a
  // newer apply. Carried across every renewal and takeover.
  evidenceAt: string | null;
}

export type LeaseWrite = { etag: string } | { conflict: true };

export interface LeaseStore {
  read(id: string): Promise<{ doc: Record<string, unknown>; etag: string } | null>;
  create(doc: LeaseDocument): Promise<LeaseWrite>;
  replace(doc: LeaseDocument, etag: string): Promise<LeaseWrite>;
}

export class LeaseLostError extends Error {
  constructor() {
    super("lease_lost");
    this.name = "LeaseLostError";
  }
}

export interface Lease {
  readonly holder: string;
  // Renews when a third of the lease has passed; throws LeaseLostError when
  // another run holds it now. Call before every write and Graph request.
  ensure(): Promise<void>;
  // Expires the lease now, recording newer evidence when given. False when it
  // was already taken over.
  release(evidenceAt?: string | null): Promise<boolean>;
}

export type AcquireResult =
  | { acquired: true; lease: Lease; previousEvidenceAt: string | null }
  | { acquired: false; heldBy: string | null; leaseExpiresAt: string | null };

export interface AcquireOptions {
  holder: string;
  leaseSeconds: number;
  now: () => Date;
}

function leaseDocument(holder: string, acquiredAt: string, at: Date, leaseSeconds: number, evidenceAt: string | null): LeaseDocument {
  return {
    id: LEASE_ID,
    holder,
    acquiredAt,
    renewedAt: at.toISOString(),
    leaseExpiresAt: new Date(at.getTime() + leaseSeconds * 1000).toISOString(),
    released: false,
    evidenceAt,
  };
}

function evidenceOf(doc: Record<string, unknown>): string | null {
  return parseZonedTimestamp(doc.evidenceAt) === null ? null : (doc.evidenceAt as string);
}

function later(a: string | null, b: string | null | undefined): string | null {
  const ta = parseZonedTimestamp(a);
  const tb = parseZonedTimestamp(b);
  if (tb === null) return a;
  return ta === null || tb > ta ? (b as string) : a;
}

function isFree(doc: Record<string, unknown>, nowMs: number): boolean {
  if (doc.released === true) return true;
  // A malformed expiry counts as passed, so a broken document cannot block
  // every run; taking it over still needs its etag.
  const expires = parseZonedTimestamp(doc.leaseExpiresAt);
  return expires === null || expires <= nowMs;
}

function heldLease(store: LeaseStore, initial: LeaseDocument, initialEtag: string, options: AcquireOptions): Lease {
  let doc = initial;
  let etag = initialEtag;
  let renewedMs = Date.parse(initial.renewedAt);
  return {
    holder: options.holder,
    async ensure() {
      const now = options.now();
      if (now.getTime() - renewedMs < (options.leaseSeconds * 1000) / 3) return;
      const next = leaseDocument(options.holder, doc.acquiredAt, now, options.leaseSeconds, doc.evidenceAt);
      const result = await store.replace(next, etag);
      if ("conflict" in result) throw new LeaseLostError();
      doc = next;
      etag = result.etag;
      renewedMs = now.getTime();
    },
    async release(evidenceAt?: string | null) {
      const now = options.now().toISOString();
      const result = await store.replace({ ...doc, renewedAt: now, leaseExpiresAt: now, released: true, evidenceAt: later(doc.evidenceAt, evidenceAt) }, etag);
      return !("conflict" in result);
    },
  };
}

export async function acquireLease(store: LeaseStore, options: AcquireOptions): Promise<AcquireResult> {
  const now = options.now();
  const doc = leaseDocument(options.holder, now.toISOString(), now, options.leaseSeconds, null);
  const created = await store.create(doc);
  if (!("conflict" in created)) return { acquired: true, lease: heldLease(store, doc, created.etag, options), previousEvidenceAt: null };

  const held = await store.read(LEASE_ID);
  if (held === null) {
    // Deleted between our create and read: try once more, then give up.
    const again = await store.create(doc);
    if ("conflict" in again) return { acquired: false, heldBy: null, leaseExpiresAt: null };
    return { acquired: true, lease: heldLease(store, doc, again.etag, options), previousEvidenceAt: null };
  }
  if (!isFree(held.doc, now.getTime())) {
    const heldBy = typeof held.doc.holder === "string" ? held.doc.holder : null;
    const leaseExpiresAt = typeof held.doc.leaseExpiresAt === "string" ? held.doc.leaseExpiresAt : null;
    return { acquired: false, heldBy, leaseExpiresAt };
  }
  const previousEvidenceAt = evidenceOf(held.doc);
  const carried = { ...doc, evidenceAt: previousEvidenceAt };
  const takeover = await store.replace(carried, held.etag);
  if ("conflict" in takeover) return { acquired: false, heldBy: null, leaseExpiresAt: null };
  return { acquired: true, lease: heldLease(store, carried, takeover.etag, options), previousEvidenceAt };
}
