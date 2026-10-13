// The snapshot fallback (docs/SYNC.md, "Without the Graph application
// permission"). A person's delegated Graph sign-in reads the registered groups
// on a workstation (takeSnapshot); the snapshot is carried into the VNet and
// applied there with the same plan, lease and removal limits as the timer
// (snapshotReader + runSync). Ids, member types and account states only: no
// names or UPNs are ever read.

import { createHash } from "node:crypto";
import type { GraphSettings } from "./config.ts";
import { readGroupMembers } from "./graph.ts";
import type { GraphReaderOptions, GroupMember, GroupReadResult, MemberKind } from "./graph.ts";
import { GUID, parseZonedTimestamp } from "./types.ts";

export const SNAPSHOT_SCHEMA = "ccof.sync.snapshot.v1";

export interface SnapshotGroup {
  groupId: string;
  // accountEnabled only where Graph returned true or false (P-9).
  members: { id: string; type: MemberKind; accountEnabled?: boolean }[];
}

export interface Snapshot {
  schema: typeof SNAPSHOT_SCHEMA;
  tenantId: string;
  readAt: string;
  groups: SnapshotGroup[];
}

export interface SnapshotLimits {
  maxAgeSeconds: number;
  maxBytes: number;
  maxGroups: number;
  maxMembers: number;
}

const KINDS: readonly MemberKind[] = ["user", "servicePrincipal", "group", "unknown"];

export function buildSnapshot(reads: GroupReadResult[], tenantId: string, readAt: Date): Snapshot {
  const groups = reads.map((read) => {
    if (!read.ok) throw new Error("a snapshot holds complete group reads only");
    return {
      groupId: read.groupId,
      members: read.members.map((m) => (m.accountEnabled === undefined ? { id: m.id, type: m.kind } : { id: m.id, type: m.kind, accountEnabled: m.accountEnabled })),
    };
  });
  return { schema: SNAPSHOT_SCHEMA, tenantId: tenantId.toLowerCase(), readAt: readAt.toISOString(), groups };
}

export type TakeResult = { ok: true; snapshot: Snapshot } | { ok: false; groupId: string | null; reason: string };

// The snapshot command's reader. It reads service principals whatever a later
// apply admits: a snapshot is directory evidence, and apply-snapshot admits
// them only where its own SYNC_MEMBER_TYPES lists them.
export function snapshotGroupReader(
  settings: GraphSettings,
  io: Pick<GraphReaderOptions, "fetch" | "getToken" | "sleep">,
): (groupId: string) => Promise<GroupReadResult> {
  return (groupId) =>
    readGroupMembers(groupId, {
      ...io,
      maxRetries: settings.graphMaxRetries,
      maxRetryAfterSeconds: settings.graphMaxRetryAfterSeconds,
      timeoutSeconds: settings.graphTimeoutSeconds,
      readServicePrincipals: true,
    });
}

// Reads every group, in id order, and fails as a whole on the first failure:
// a partial snapshot would look like groups of nobody once applied.
export async function takeSnapshot(
  groupIds: readonly string[],
  tenantId: string,
  read: (groupId: string) => Promise<GroupReadResult>,
  now: () => Date,
): Promise<TakeResult> {
  const ids = groupIds.map((id) => (typeof id === "string" ? id.toLowerCase() : ""));
  if (ids.length === 0 || ids.some((id) => !GUID.test(id)) || new Set(ids).size !== ids.length) {
    return { ok: false, groupId: null, reason: "snapshot_input_invalid" };
  }
  const reads: GroupReadResult[] = [];
  for (const groupId of [...ids].sort()) {
    const result = await read(groupId);
    if (!result.ok) return { ok: false, groupId, reason: result.reason };
    reads.push(result);
  }
  return { ok: true, snapshot: buildSnapshot(reads, tenantId, now()) };
}

export type ValidatedSnapshot =
  | { ok: true; sha256: string; tenantId: string; readAt: string; groups: Map<string, GroupMember[]> }
  | { ok: false; problems: string[] };

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function readGroups(value: unknown, limits: SnapshotLimits): Map<string, GroupMember[]> | string {
  if (!Array.isArray(value)) return "groups:invalid";
  if (value.length > limits.maxGroups) return "groups:too_many";
  const groups = new Map<string, GroupMember[]>();
  let total = 0;
  for (const group of value) {
    if (!isObject(group) || typeof group.groupId !== "string" || !GUID.test(group.groupId) || !Array.isArray(group.members)) return "groups:invalid_group";
    const groupId = group.groupId.toLowerCase();
    if (groups.has(groupId)) return "groups:duplicate_group";
    const members: GroupMember[] = [];
    const seen = new Set<string>();
    for (const member of group.members) {
      if (!isObject(member) || typeof member.id !== "string" || !GUID.test(member.id) || !(KINDS as readonly unknown[]).includes(member.type)) {
        return "groups:invalid_member";
      }
      if (member.accountEnabled !== undefined && typeof member.accountEnabled !== "boolean") return "groups:invalid_member";
      const id = member.id.toLowerCase();
      if (seen.has(id)) return "groups:duplicate_member";
      seen.add(id);
      const kind = member.type as MemberKind;
      members.push(typeof member.accountEnabled === "boolean" ? { id, kind, accountEnabled: member.accountEnabled } : { id, kind });
    }
    total += members.length;
    groups.set(groupId, members);
  }
  return total > limits.maxMembers ? "members:too_many" : groups;
}

// Checks a snapshot before anything is written: size first, then schema,
// tenant, age and shape. Problems are codes, never values.
export function validateSnapshot(text: string, options: { tenantId: string; now: Date; limits: SnapshotLimits }): ValidatedSnapshot {
  const { limits } = options;
  if (Buffer.byteLength(text, "utf8") > limits.maxBytes) return { ok: false, problems: ["snapshot:too_large"] };
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { ok: false, problems: ["snapshot:not_json"] };
  }
  if (!isObject(parsed)) return { ok: false, problems: ["snapshot:not_an_object"] };
  const problems: string[] = [];
  if (Object.keys(parsed).some((k) => !["schema", "tenantId", "readAt", "groups"].includes(k))) problems.push("snapshot:unexpected_key");
  if (parsed.schema !== SNAPSHOT_SCHEMA) problems.push("schema:unsupported");
  if (typeof parsed.tenantId !== "string" || !GUID.test(parsed.tenantId)) problems.push("tenantId:invalid");
  else if (parsed.tenantId.toLowerCase() !== options.tenantId.toLowerCase()) problems.push("tenantId:not_the_configured_tenant");
  const readAt = parseZonedTimestamp(parsed.readAt);
  const nowMs = options.now.getTime();
  if (readAt === null) problems.push("readAt:invalid");
  else if (readAt > nowMs) problems.push("readAt:in_future");
  else if (nowMs - readAt > limits.maxAgeSeconds * 1000) problems.push("readAt:older_than_max_age");
  const groups = readGroups(parsed.groups, limits);
  if (typeof groups === "string") problems.push(groups);
  if (problems.length > 0 || typeof groups === "string") return { ok: false, problems };
  const sha256 = createHash("sha256").update(text, "utf8").digest("hex");
  return { ok: true, sha256, tenantId: (parsed.tenantId as string).toLowerCase(), readAt: parsed.readAt as string, groups };
}

export interface SnapshotReader {
  readGroup(groupId: string, beforeRequest: () => Promise<void>): Promise<GroupReadResult>;
  // Every group in the snapshot must be registered by a valid project: a
  // snapshot taken for another registry state is refused as a whole.
  checkGroups(registered: ReadonlySet<string>): { reason: string; groupIds: string[] } | null;
}

export function snapshotReader(snapshot: Extract<ValidatedSnapshot, { ok: true }>): SnapshotReader {
  return {
    async readGroup(groupId, beforeRequest) {
      await beforeRequest();
      const members = snapshot.groups.get(groupId);
      if (members === undefined) return { ok: false, groupId, reason: "snapshot_group_missing", httpStatus: null, graphErrorCode: null, retries: 0 };
      return { ok: true, groupId, members: members.map((m) => ({ ...m })), pages: 1, retries: 0 };
    },
    checkGroups(registered) {
      const unregistered = [...snapshot.groups.keys()].filter((id) => !registered.has(id)).sort();
      return unregistered.length > 0 ? { reason: "snapshot_group_unregistered", groupIds: unregistered } : null;
    },
  };
}
