// Fakes for the reconciler's run tests: an in-memory lease store and a manual
// clock (the same shapes as tests/helpers/sync-fakes.ts on wp/sync), and an
// in-memory Cosmos and Log Analytics that record every call.

import { readFileSync } from "node:fs";
import type { LeaseDocument, LeaseStore } from "../../src/reconciler/lease.ts";
import { LEDGER_COLUMNS } from "../../src/reconciler/ledger.ts";
import type { AggregateBudgetStateDocument, BudgetStateDocument } from "../../src/reconciler/documents.ts";
import type { RunDependencies } from "../../src/reconciler/run.ts";

let etagCounter = 0;
const nextEtag = (): string => `"etag-${++etagCounter}"`;

export class MemoryLeases implements LeaseStore {
  readonly docs = new Map<string, { doc: LeaseDocument; etag: string }>();
  readonly ops: string[] = [];
  failNextReplace = false;

  async read(id: string) {
    this.ops.push(`read:${id}`);
    const entry = this.docs.get(id);
    return entry ? { doc: structuredClone(entry.doc) as unknown as Record<string, unknown>, etag: entry.etag } : null;
  }

  async create(doc: LeaseDocument) {
    this.ops.push(`create:${doc.id}`);
    if (this.docs.has(doc.id)) return { conflict: true as const };
    const etag = nextEtag();
    this.docs.set(doc.id, { doc: structuredClone(doc), etag });
    return { etag };
  }

  async replace(doc: LeaseDocument, etag: string) {
    this.ops.push(`replace:${doc.id}`);
    const current = this.docs.get(doc.id);
    if (this.failNextReplace || !current || current.etag !== etag) {
      this.failNextReplace = false;
      return { conflict: true as const };
    }
    const next = nextEtag();
    this.docs.set(doc.id, { doc: structuredClone(doc), etag: next });
    return { etag: next };
  }
}

// A clock the tests move by hand.
export class ManualClock {
  private ms: number;
  constructor(iso: string) {
    this.ms = Date.parse(iso);
  }
  now = (): Date => new Date(this.ms);
  advance(seconds: number): void {
    this.ms += seconds * 1000;
  }
}

export const LEDGER_KQL = readFileSync(new URL("../../analytics/ledger.kql", import.meta.url), "utf8");

// A query API answer in the shape the live workspace returned on 2026-10-11.
export function ledgerBody(rows: ReadonlyArray<Record<string, unknown>>): Record<string, unknown> {
  return {
    tables: [
      {
        name: "PrimaryResult",
        columns: LEDGER_COLUMNS.map((name) => ({ name, type: "dynamic" })),
        rows: rows.map((row) => LEDGER_COLUMNS.map((column) => row[column])),
      },
    ],
  };
}

// The continuity query's answer (DR-05): one row per gateway with records in the period.
export function continuityBody(rows: ReadonlyArray<{ gatewayResourceId: string; earliest: string; newest: string }>): Record<string, unknown> {
  return {
    tables: [
      {
        name: "PrimaryResult",
        columns: [{ name: "gatewayResourceId", type: "string" }, { name: "earliest", type: "datetime" }, { name: "newest", type: "datetime" }],
        rows: rows.map((r) => [r.gatewayResourceId, r.earliest, r.newest]),
      },
    ],
  };
}

export interface FakeAzureOptions {
  projects?: unknown[];
  entitlements?: unknown[];
  ledger?: unknown | (() => Promise<unknown>);
  // The continuity gate's per-gateway answer (DR-05); any query that is not the ledger query gets it.
  continuity?: unknown | (() => Promise<unknown>);
  // Budget states already in Cosmos, by document id (DR-05 continuity gate reads them).
  persistedBudgetStates?: Record<string, unknown>;
  persistedAggregateStates?: Record<string, unknown>;
  failStateRead?: unknown;
  // The query API's Age header, in seconds, for an answer served from its cache; null for a fresh answer.
  ledgerAgeSeconds?: number | null;
  // Fail the nth state write (1-based) with this error.
  failWrite?: { at: number; error: unknown };
  failProjects?: unknown;
}

export class FakeAzure {
  readonly leases = new MemoryLeases();
  readonly calls: string[] = [];
  readonly queries: Array<{ query: string; timespan: string }> = [];
  readonly budgetStates: BudgetStateDocument[] = [];
  readonly aggregateStates: AggregateBudgetStateDocument[] = [];
  private writes = 0;
  private readonly options: FakeAzureOptions;

  constructor(options: FakeAzureOptions) {
    this.options = options;
  }

  get writeCount(): number {
    return this.budgetStates.length + this.aggregateStates.length;
  }

  deps(): RunDependencies {
    return {
      leases: this.leases,
      readProjects: async () => {
        this.calls.push("readProjects");
        if (this.options.failProjects !== undefined) throw this.options.failProjects;
        return this.options.projects ?? [];
      },
      readEntitlements: async () => {
        this.calls.push("readEntitlements");
        return this.options.entitlements ?? [];
      },
      queryLedger: async (query, timespan) => {
        this.calls.push("queryLedger");
        this.queries.push({ query, timespan });
        const answer = query.includes("CcofUsageLedger(") ? this.options.ledger : this.options.continuity;
        const body = typeof answer === "function" ? await (answer as () => Promise<unknown>)() : answer;
        return { body, responseAgeSeconds: this.options.ledgerAgeSeconds ?? null };
      },
      readBudgetState: async (id, personId) => {
        this.calls.push(`readBudgetState:${id}:${personId}`);
        if (this.options.failStateRead !== undefined) throw this.options.failStateRead;
        return structuredClone(this.options.persistedBudgetStates?.[id] ?? null);
      },
      readAggregateState: async (id) => {
        this.calls.push(`readAggregateState:${id}`);
        if (this.options.failStateRead !== undefined) throw this.options.failStateRead;
        return structuredClone(this.options.persistedAggregateStates?.[id] ?? null);
      },
      writeBudgetState: async (doc) => this.write(() => this.budgetStates.push(structuredClone(doc))),
      writeAggregateState: async (doc) => this.write(() => this.aggregateStates.push(structuredClone(doc))),
    };
  }

  private async write(store: () => void): Promise<void> {
    this.writes += 1;
    this.calls.push("write");
    if (this.options.failWrite && this.writes === this.options.failWrite.at) throw this.options.failWrite.error;
    store();
  }
}
