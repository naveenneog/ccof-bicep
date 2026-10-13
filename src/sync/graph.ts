// Direct members of one Entra group, read from Microsoft Graph
// (GET /v1.0/groups/{id}/members?$select=id,accountEnabled). Groups are flat by
// policy, so a nested group is returned as a member of kind "group" and never
// expanded.
//
// v1.0 members does not list service principals (a known issue, seen live on
// 2026-10-12). Where they are admitted, a second read takes them from the OData
// cast members/microsoft.graph.servicePrincipal, which needs
// ConsistencyLevel: eventual and $count; the header is sent on every page.
//
// accountEnabled (P-9) is carried only when Graph returns true or false. An app
// that cannot read users or service principals gets null for it (Learn "List
// group members", retrieved 2026-10-13): that is an unknown state, never a
// disabled one. Any other value fails the read.
//
// A failed read is never an empty group: every failure returns a reason code,
// and the planner leaves that group's project unchanged (ADR-0016).
//
// Sources, retrieved 2026-10-11: Learn "List group members" (page size default
// 100, maximum 999; "This operation is not transitive"); Learn "Microsoft Graph
// throttling guidance" (429 with Retry-After in seconds) and "Microsoft Graph
// error responses" (503: retry after the Retry-After delay). Retrieved
// 2026-10-12: Learn "List group members" and "Known issues with Microsoft Graph
// APIs" (service principals; the OData cast and its ConsistencyLevel header);
// Learn "Paging Microsoft Graph data in your app" (custom headers are not
// carried to later pages).

import { GUID } from "./types.ts";
import type { SyncConfig } from "./config.ts";

export const GRAPH_BASE = "https://graph.microsoft.com/v1.0/";
export const GRAPH_SCOPE = "https://graph.microsoft.com/.default";

export type MemberKind = "user" | "servicePrincipal" | "group" | "unknown";

export interface GroupMember {
  id: string;
  kind: MemberKind;
  // Present only when Graph returned true or false.
  accountEnabled?: boolean;
}

export type GraphFailureReason =
  | "graph_permission_missing"
  | "graph_unauthorized"
  | "graph_group_not_found"
  | "graph_throttled"
  | "graph_unavailable"
  | "graph_request_failed"
  | "graph_response_invalid"
  | "graph_token_failed"
  | "graph_group_not_read"
  | "snapshot_group_missing";

export type GroupReadResult =
  | { ok: true; groupId: string; members: GroupMember[]; pages: number; retries: number }
  | { ok: false; groupId: string; reason: GraphFailureReason; httpStatus: number | null; graphErrorCode: string | null; retries: number };

export interface FetchResponseLike {
  status: number;
  headers: { get(name: string): string | null };
  text(): Promise<string>;
}

export type FetchLike = (url: string, init: { headers: Record<string, string>; signal?: AbortSignal }) => Promise<FetchResponseLike>;

export interface GraphReaderOptions {
  fetch: FetchLike;
  getToken: () => Promise<string>;
  sleep: (ms: number) => Promise<void>;
  maxRetries: number;
  maxRetryAfterSeconds: number;
  timeoutSeconds: number;
  // Also read the service-principal members, which v1.0 members omits.
  readServicePrincipals: boolean;
  // Runs before every request, retries included: the run renews its lease
  // here, and a lost lease stops the read by throwing.
  beforeRequest?: () => Promise<void>;
  now?: () => number;
}

const KINDS: Record<string, MemberKind> = {
  "#microsoft.graph.user": "user",
  "#microsoft.graph.servicePrincipal": "servicePrincipal",
  "#microsoft.graph.group": "group",
};

const SERVICE_PRINCIPAL_TYPE = "#microsoft.graph.servicePrincipal";
// The collection a cast page names, live: ".../v1.0/$metadata#servicePrincipals(id)".
const SERVICE_PRINCIPALS_CONTEXT = /^https:\/\/graph\.microsoft\.com\/v1\.0\/\$metadata#servicePrincipals(\(|$)/;

const ERROR_CODE = /^[A-Za-z0-9_.]{1,64}$/;

export function membersUrl(groupId: string): string {
  return `${GRAPH_BASE}groups/${groupId}/members?$select=id,accountEnabled&$top=999`;
}

export function servicePrincipalsUrl(groupId: string): string {
  return `${GRAPH_BASE}groups/${groupId}/members/microsoft.graph.servicePrincipal?$select=id,accountEnabled&$top=999&$count=true`;
}

// The reader settings of a run (timer and CLI): service principals are read
// only where SYNC_MEMBER_TYPES admits them, so a users-only sync makes the
// same requests as before.
export function readerSettings(
  config: Pick<SyncConfig, "memberTypes" | "graphMaxRetries" | "graphMaxRetryAfterSeconds" | "graphTimeoutSeconds">,
): Pick<GraphReaderOptions, "maxRetries" | "maxRetryAfterSeconds" | "timeoutSeconds" | "readServicePrincipals"> {
  return {
    maxRetries: config.graphMaxRetries,
    maxRetryAfterSeconds: config.graphMaxRetryAfterSeconds,
    timeoutSeconds: config.graphTimeoutSeconds,
    readServicePrincipals: config.memberTypes.includes("servicePrincipal"),
  };
}

// The kind of one member, or null when the page cannot be trusted.
type Classify = (item: Record<string, unknown>, page: Record<string, unknown>) => MemberKind | null;

// Every member of a directoryObject collection carries its type. Without it
// the page's shape is not what Graph documents, so it is not trusted.
const typedMember: Classify = (item) => {
  const type = item["@odata.type"];
  return typeof type === "string" ? (KINDS[type] ?? "unknown") : null;
};

// Cast items may omit their type (live, 2026-10-12): an untyped item counts
// only on a page that names the servicePrincipals collection, and a typed item
// must name the service principal type.
const castServicePrincipal: Classify = (item, page) => {
  const type = item["@odata.type"];
  if (type !== undefined) return type === SERVICE_PRINCIPAL_TYPE ? "servicePrincipal" : null;
  const context = page["@odata.context"];
  return typeof context === "string" && SERVICE_PRINCIPALS_CONTEXT.test(context) ? "servicePrincipal" : null;
};

// Retry-After is delta-seconds or an HTTP date (RFC 9110 §10.2.3).
export function parseRetryAfter(value: string | null, nowMs: number): number | null {
  if (value === null) return null;
  const trimmed = value.trim();
  if (/^\d{1,9}$/.test(trimmed)) return Number(trimmed);
  if (!/^[A-Za-z]{3}, /.test(trimmed)) return null;
  const at = Date.parse(trimmed);
  return Number.isFinite(at) ? Math.max(0, Math.ceil((at - nowMs) / 1000)) : null;
}

function graphErrorCode(body: string): string | null {
  try {
    const code = (JSON.parse(body) as { error?: { code?: unknown } })?.error?.code;
    return typeof code === "string" && ERROR_CODE.test(code) ? code : null;
  } catch {
    return null;
  }
}

function failureFor(status: number): GraphFailureReason {
  if (status === 401) return "graph_unauthorized";
  if (status === 403) return "graph_permission_missing";
  if (status === 404) return "graph_group_not_found";
  if (status === 429) return "graph_throttled";
  if (status >= 500) return "graph_unavailable";
  return "graph_request_failed";
}

type PageOutcome =
  | { kind: "page"; members: GroupMember[]; nextLink: string | null }
  | { kind: "failed"; reason: GraphFailureReason; httpStatus: number | null; graphErrorCode: string | null };

function parsePage(body: string, classify: Classify): PageOutcome {
  const invalid: PageOutcome = { kind: "failed", reason: "graph_response_invalid", httpStatus: 200, graphErrorCode: null };
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return invalid;
  }
  const value = (parsed as { value?: unknown })?.value;
  if (!Array.isArray(value)) return invalid;
  const members: GroupMember[] = [];
  for (const item of value) {
    const id = (item as { id?: unknown })?.id;
    if (typeof id !== "string" || !GUID.test(id)) return invalid;
    const kind = classify(item as Record<string, unknown>, parsed as Record<string, unknown>);
    if (kind === null) return invalid;
    const state = (item as { accountEnabled?: unknown }).accountEnabled;
    if (state !== undefined && state !== null && typeof state !== "boolean") return invalid;
    members.push(typeof state === "boolean" ? { id: id.toLowerCase(), kind, accountEnabled: state } : { id: id.toLowerCase(), kind });
  }
  const next = (parsed as Record<string, unknown>)["@odata.nextLink"];
  if (next === undefined || next === null) return { kind: "page", members, nextLink: null };
  // The bearer token goes with the next request: only follow links that stay
  // on Microsoft Graph v1.0.
  if (typeof next !== "string" || !next.startsWith(GRAPH_BASE)) return invalid;
  return { kind: "page", members, nextLink: next };
}

type GroupReadFailure = Extract<GroupReadResult, { ok: false }>;

function failure(groupId: string, reason: GraphFailureReason, httpStatus: number | null, graphErrorCode: string | null, retries: number): GroupReadFailure {
  return { ok: false, groupId, reason, httpStatus, graphErrorCode, retries };
}

// Shared by the reads of one group: a URL is fetched once, and pages and
// retries are counted across both reads.
interface ReadState {
  visited: Set<string>;
  pages: number;
  retries: number;
}

// Every page of one read, from its first URL to its last @odata.nextLink.
async function readPages(groupId: string, firstUrl: string, fetchPage: FetchLike, classify: Classify, options: GraphReaderOptions, state: ReadState): Promise<GroupMember[] | GroupReadFailure> {
  const now = options.now ?? Date.now;
  const fail = (reason: GraphFailureReason, httpStatus: number | null, code: string | null, retries: number) => failure(groupId, reason, httpStatus, code, retries);
  const members: GroupMember[] = [];
  const visited = state.visited;
  let url: string | null = firstUrl;
  let pages = state.pages;
  let retries = state.retries;

  while (url !== null) {
    if (visited.has(url)) return fail("graph_response_invalid", null, null, retries);
    visited.add(url);
    let outcome: PageOutcome | null = null;
    for (let attempt = 0; outcome === null; attempt++) {
      if (options.beforeRequest) await options.beforeRequest();
      let token: string;
      try {
        token = await options.getToken();
      } catch {
        return fail("graph_token_failed", null, null, retries);
      }
      let status: number;
      let retryAfter: string | null = null;
      let body = "";
      try {
        const response = await fetchPage(url, {
          headers: { Authorization: `Bearer ${token}` },
          signal: AbortSignal.timeout(options.timeoutSeconds * 1000),
        });
        status = response.status;
        retryAfter = response.headers.get("retry-after");
        body = await response.text();
      } catch {
        status = 0; // network failure or timeout: retried like a 503
      }

      if (status === 200) {
        outcome = parsePage(body, classify);
        break;
      }
      const retryable = status === 429 || status === 503 || status === 0;
      const code = status === 0 ? null : graphErrorCode(body);
      const reason = status === 0 ? "graph_unavailable" : failureFor(status);
      if (!retryable || attempt >= options.maxRetries) return fail(reason, status === 0 ? null : status, code, retries);
      const told = parseRetryAfter(retryAfter, now());
      if (told !== null && told > options.maxRetryAfterSeconds) return fail(reason, status, code, retries);
      const waitSeconds = told ?? Math.min(2 ** attempt, options.maxRetryAfterSeconds);
      retries += 1;
      await options.sleep(waitSeconds * 1000);
    }
    if (outcome.kind === "failed") return fail(outcome.reason, outcome.httpStatus, outcome.graphErrorCode, retries);
    pages += 1;
    members.push(...outcome.members);
    url = outcome.nextLink;
  }
  state.pages = pages;
  state.retries = retries;
  return members;
}

// A service principal listed by both reads counts once; one id with two types
// is not a membership Graph documents, so the read is not trusted. Its account
// state is false when either read says so; otherwise a known state wins.
function withServicePrincipals(direct: GroupMember[], principals: GroupMember[]): GroupMember[] | null {
  const byId = new Map(direct.map((m) => [m.id, m]));
  const members = [...direct];
  for (const principal of principals) {
    const known = byId.get(principal.id);
    if (known === undefined) {
      byId.set(principal.id, principal);
      members.push(principal);
    } else if (known.kind !== "servicePrincipal") return null;
    else if (principal.accountEnabled === false || known.accountEnabled === undefined) {
      if (principal.accountEnabled !== undefined) known.accountEnabled = principal.accountEnabled;
    }
  }
  return members;
}

export async function readGroupMembers(groupId: string, options: GraphReaderOptions): Promise<GroupReadResult> {
  if (!GUID.test(groupId)) return failure(groupId, "graph_request_failed", null, null, 0);
  const state: ReadState = { visited: new Set(), pages: 0, retries: 0 };
  const direct = await readPages(groupId, membersUrl(groupId), options.fetch, typedMember, options, state);
  if (!Array.isArray(direct)) return direct;
  if (!options.readServicePrincipals) return { ok: true, groupId, members: direct, pages: state.pages, retries: state.retries };

  const fetchCast: FetchLike = (url, init) => options.fetch(url, { ...init, headers: { ...init.headers, ConsistencyLevel: "eventual" } });
  const principals = await readPages(groupId, servicePrincipalsUrl(groupId), fetchCast, castServicePrincipal, options, state);
  if (!Array.isArray(principals)) return principals;
  const members = withServicePrincipals(direct, principals);
  if (members === null) return failure(groupId, "graph_response_invalid", null, null, state.retries);
  return { ok: true, groupId, members, pages: state.pages, retries: state.retries };
}
