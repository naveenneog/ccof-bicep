// One reconciler run at a time (docs/PILOT.md C-7, ADR-0018 decision 8). The
// protocol of src/sync/lease.ts on wp/sync at f809a87 (ADR-0016), copied
// with the reconciler's own lease id and container: a lease document taken
// with create (409 when it exists) and taken over or renewed with an etag
// condition (412 when someone else changed it). A lease left by a stopped
// run expires by itself. A shared module is a later refactor (WP-SYNC agreed).
//
// Clock skew between hosts shortens or lengthens a lease by the skew; the
// configured duration must be much longer than any expected skew.

// A protocol constant, not configuration: every reconciler writer must use
// the same id, or two writers could each hold "the" lease.
export const RECONCILER_LEASE_ID = "ccof-budget-reconciler";

export interface LeaseDocument {
  id: string;
  holder: string;
  acquiredAt: string;
  renewedAt: string;
  leaseExpiresAt: string;
  released: boolean;
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
  // another run holds it now. Called before every write.
  ensure(): Promise<void>;
  // Expires the lease now. False when it was already taken over.
  release(): Promise<boolean>;
}

export type AcquireResult =
  | { acquired: true; lease: Lease }
  | { acquired: false; heldBy: string | null; leaseExpiresAt: string | null };

export interface AcquireOptions {
  holder: string;
  leaseSeconds: number;
  now: () => Date;
}

const ZONED = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/;

function expiryOf(value: unknown): number | null {
  if (typeof value !== "string" || !ZONED.test(value)) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : null;
}

function leaseDocument(holder: string, acquiredAt: string, at: Date, leaseSeconds: number): LeaseDocument {
  return {
    id: RECONCILER_LEASE_ID,
    holder,
    acquiredAt,
    renewedAt: at.toISOString(),
    leaseExpiresAt: new Date(at.getTime() + leaseSeconds * 1000).toISOString(),
    released: false,
  };
}

function isFree(doc: Record<string, unknown>, nowMs: number): boolean {
  if (doc.released === true) return true;
  // A malformed expiry counts as passed, so a broken document cannot block
  // every run; taking it over still needs its etag.
  const expires = expiryOf(doc.leaseExpiresAt);
  return expires === null || expires <= nowMs;
}

function heldLease(store: LeaseStore, initial: LeaseDocument, initialEtag: string, options: AcquireOptions): Lease {
  let doc = initial;
  let etag = initialEtag;
  let renewedMs = Date.parse(initial.renewedAt);
  // Concurrent writers share one renewal: each renewing with the same etag
  // would make all but one fail with 412 and lose a lease the run still holds.
  let renewal: Promise<void> | null = null;
  let lost = false;
  return {
    holder: options.holder,
    async ensure() {
      if (lost) throw new LeaseLostError();
      if (renewal) return renewal;
      const now = options.now();
      if (now.getTime() - renewedMs < (options.leaseSeconds * 1000) / 3) return;
      renewal = (async () => {
        const next = leaseDocument(options.holder, doc.acquiredAt, now, options.leaseSeconds);
        const result = await store.replace(next, etag);
        if ("conflict" in result) {
          lost = true;
          throw new LeaseLostError();
        }
        doc = next;
        etag = result.etag;
        renewedMs = now.getTime();
      })();
      try {
        await renewal;
      } finally {
        renewal = null;
      }
    },
    async release() {
      const now = options.now().toISOString();
      const result = await store.replace({ ...doc, renewedAt: now, leaseExpiresAt: now, released: true }, etag);
      return !("conflict" in result);
    },
  };
}

export async function acquireLease(store: LeaseStore, options: AcquireOptions): Promise<AcquireResult> {
  const now = options.now();
  const doc = leaseDocument(options.holder, now.toISOString(), now, options.leaseSeconds);
  const created = await store.create(doc);
  if (!("conflict" in created)) return { acquired: true, lease: heldLease(store, doc, created.etag, options) };

  const held = await store.read(RECONCILER_LEASE_ID);
  if (held === null) {
    // Deleted between our create and read: try once more, then give up.
    const again = await store.create(doc);
    if ("conflict" in again) return { acquired: false, heldBy: null, leaseExpiresAt: null };
    return { acquired: true, lease: heldLease(store, doc, again.etag, options) };
  }
  if (!isFree(held.doc, now.getTime())) {
    const heldBy = typeof held.doc.holder === "string" ? held.doc.holder : null;
    const leaseExpiresAt = typeof held.doc.leaseExpiresAt === "string" ? held.doc.leaseExpiresAt : null;
    return { acquired: false, heldBy, leaseExpiresAt };
  }
  const takeover = await store.replace(doc, held.etag);
  if ("conflict" in takeover) return { acquired: false, heldBy: null, leaseExpiresAt: null };
  return { acquired: true, lease: heldLease(store, doc, takeover.etag, options) };
}
