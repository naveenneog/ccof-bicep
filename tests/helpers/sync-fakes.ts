// Fakes for the sync tests: Microsoft Graph pages and in-memory Cosmos stores
// with the etag semantics the real containers have (409 on a duplicate create,
// 412 on a stale replace). Nothing here reaches Azure.

import type { FetchLike, FetchResponseLike } from "../../src/sync/graph.ts";
import type { EntitlementWriter, ExistingEntitlement } from "../../src/sync/plan-types.ts";
import type { LeaseDocument, LeaseStore } from "../../src/sync/lease.ts";
import type { FamilyPolicy, ModelFamily, TokenLimit } from "../../src/contracts/model-families.ts";

export const TENANT = "00000000-0000-4000-8000-000000000111";
export const GROUP_STD = "11111111-1111-4111-8111-111111111111";
export const GROUP_PRM = "22222222-2222-4222-8222-222222222222";
export const GROUP_CYB = "33333333-3333-4333-8333-333333333333";
export const GROUP_OTHER = "44444444-4444-4444-8444-444444444444";
export const PERSON_A = "00000000-0000-4000-8000-000001100111";
export const PERSON_B = "00000000-0000-4000-8000-000001101000";
export const PERSON_C = "00000000-0000-4000-8000-000001101001";
export const SP_TEST = "dddddddd-0000-4000-8000-000000000004";
export const NESTED_GROUP = "00000000-0000-4000-8000-000001101010";

export function tokenLimits(personQuota: number | null = 500000): FamilyPolicy["aggregateLimits"] {
  return {
    person: {
      tokensPerMinute: 1000000,
      tokenQuota: personQuota,
      tokenQuotaPeriod: personQuota === null ? null : "Daily",
    },
    group: { tokensPerMinute: null, tokenQuota: 2000000, tokenQuotaPeriod: "Daily" },
  };
}

export function familyPolicy(models: string[] = ["claude-haiku-4-5", "claude-sonnet-5"]): FamilyPolicy {
  const families: FamilyPolicy["families"] = {};
  const unlimited = (): TokenLimit => ({ tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null });
  const fixtures: Record<string, ModelFamily> = {
    "claude-haiku-4-5": "haiku",
    "claude-sonnet-5": "sonnet",
    "claude-opus-5": "opus",
  };
  for (const model of models) {
    const family = fixtures[model];
    if (!family) throw new Error("unknown fixture model");
    const entry = families[family] ?? { models: [], person: unlimited(), group: unlimited() };
    entry.models.push(model);
    families[family] = entry;
  }
  return { aggregateLimits: tokenLimits(), families };
}

export function classification(groupId: string, models: string[] = ["claude-haiku-4-5"]) {
  return {
    groupId,
    familyPolicy: familyPolicy(models),
    personBudget: { amount: 25000, currency: "CCU", period: "monthly" },
    aggregateBudget: null,
    aggregateMode: "notify",
    onboardingMode: "block",
  };
}

export function projectDoc(projectId = "PILOT1", overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: projectId,
    projectId,
    displayName: "Pilot",
    status: "active",
    backendId: "foundry-sample-hub",
    designatedSubscriptionId: "00000000-0000-4000-8000-000000001000",
    classifications: {
      STD: classification(GROUP_STD, ["claude-haiku-4-5", "claude-sonnet-5"]),
      PRM: classification(GROUP_PRM, ["claude-haiku-4-5", "claude-opus-5"]),
    },
    supersedes: null,
    retiredAt: null,
    ...overrides,
  };
}

export function member(id: string, type = "#microsoft.graph.user"): Record<string, unknown> {
  return { "@odata.type": type, id };
}

interface FakeResponse {
  status: number;
  body?: unknown;
  headers?: Record<string, string>;
}

export function response({ status, body, headers = {} }: FakeResponse): FetchResponseLike {
  const lower = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
  return {
    status,
    headers: { get: (name: string) => lower[name.toLowerCase()] ?? null },
    text: async () => (body === undefined ? "" : typeof body === "string" ? body : JSON.stringify(body)),
  };
}

export function page(members: Record<string, unknown>[], nextLink?: string): FakeResponse {
  const body: Record<string, unknown> = { value: members };
  if (nextLink) body["@odata.nextLink"] = nextLink;
  return { status: 200, body };
}

// A scripted Graph: each URL maps to a queue of responses, consumed in order.
// An unscripted URL fails the test loudly rather than looking like an empty group.
export class FakeGraph {
  readonly calls: { url: string; authorization: string | undefined; consistencyLevel: string | undefined }[] = [];
  private readonly scripts = new Map<string, (FakeResponse | Error)[]>();

  on(url: string, ...responses: (FakeResponse | Error)[]): this {
    this.scripts.set(url, [...(this.scripts.get(url) ?? []), ...responses]);
    return this;
  }

  readonly fetch: FetchLike = async (url, init) => {
    this.calls.push({ url, authorization: init.headers.Authorization, consistencyLevel: init.headers.ConsistencyLevel });
    const queue = this.scripts.get(url);
    if (!queue || queue.length === 0) throw new Error(`unscripted Graph call: ${url}`);
    const next = queue.shift() as FakeResponse | Error;
    if (next instanceof Error) throw next;
    return response(next);
  };
}

// The member reads select accountEnabled with the id (P-9).
export function membersUrl(groupId: string): string {
  return `https://graph.microsoft.com/v1.0/groups/${groupId}/members?$select=id,accountEnabled&$top=999`;
}

// The OData cast that lists a group's service principals (v1.0 members omits them).
export function servicePrincipalsUrl(groupId: string): string {
  return `https://graph.microsoft.com/v1.0/groups/${groupId}/members/microsoft.graph.servicePrincipal?$select=id,accountEnabled&$top=999&$count=true`;
}

export const SERVICE_PRINCIPALS_CONTEXT = "https://graph.microsoft.com/v1.0/$metadata#servicePrincipals(id)";

// A cast page as Graph returned it live on 2026-10-12: a servicePrincipals
// collection whose items hold only their id.
export function servicePrincipalPage(ids: string[], nextLink?: string, context: string | null = SERVICE_PRINCIPALS_CONTEXT): FakeResponse {
  const body: Record<string, unknown> = { value: ids.map((id) => ({ id })) };
  if (context !== null) body["@odata.context"] = context;
  if (nextLink) body["@odata.nextLink"] = nextLink;
  return { status: 200, body };
}

let etagCounter = 0;
function nextEtag(): string {
  etagCounter += 1;
  return `"etag-${etagCounter}"`;
}

export class MemoryEntitlements implements EntitlementWriter {
  readonly docs = new Map<string, { doc: Record<string, unknown>; etag: string }>();
  readonly writes: { op: "create" | "replace"; id: string }[] = [];
  failNextWriteFor = new Set<string>();

  seed(doc: Record<string, unknown>): void {
    this.docs.set(String(doc.id), { doc: structuredClone(doc), etag: nextEtag() });
  }

  async readAll(): Promise<ExistingEntitlement[]> {
    return [...this.docs.values()].map(({ doc, etag }) => ({ doc: structuredClone(doc), etag }));
  }

  async create(doc: { id: string }): Promise<"created" | "conflict"> {
    this.maybeFail(doc.id);
    if (this.docs.has(doc.id)) return "conflict";
    this.docs.set(doc.id, { doc: structuredClone(doc) as Record<string, unknown>, etag: nextEtag() });
    this.writes.push({ op: "create", id: doc.id });
    return "created";
  }

  async replace(doc: { id: string }, etag: string): Promise<"replaced" | "conflict"> {
    this.maybeFail(doc.id);
    const current = this.docs.get(doc.id);
    if (!current || current.etag !== etag) return "conflict";
    this.docs.set(doc.id, { doc: structuredClone(doc) as Record<string, unknown>, etag: nextEtag() });
    this.writes.push({ op: "replace", id: doc.id });
    return "replaced";
  }

  // Changes a document behind the planner's back, as a concurrent writer would.
  touch(id: string): void {
    const current = this.docs.get(id);
    if (current) current.etag = nextEtag();
  }

  private maybeFail(id: string): void {
    if (this.failNextWriteFor.delete(id)) {
      throw Object.assign(new Error("service unavailable"), { code: 503 });
    }
  }
}

export class MemoryLeases implements LeaseStore {
  readonly docs = new Map<string, { doc: LeaseDocument; etag: string }>();
  readonly ops: string[] = [];

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
    if (!current || current.etag !== etag) return { conflict: true as const };
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
