// Types shared by the planner, the run and the stores.

import type { MemberType } from "./config.ts";
import type { GroupReadResult } from "./graph.ts";
import type { ProjectReadResult } from "./projects.ts";
import type { EntitlementRecord } from "./types.ts";

// A document as read from the `entitlement` container, with its etag.
export interface ExistingEntitlement {
  doc: Record<string, unknown>;
  etag: string;
}

// Writes with optimistic concurrency: "conflict" means the document was
// created or changed by someone else since it was read (409 or 412).
export interface EntitlementWriter {
  create(doc: EntitlementRecord): Promise<"created" | "conflict">;
  replace(doc: EntitlementRecord, etag: string): Promise<"replaced" | "conflict">;
}

export interface RemovalLimits {
  maxRemovalsPerRun: number;
  maxRemovalFraction: number;
}

export interface PlanInput {
  projects: ProjectReadResult[];
  groups: ReadonlyMap<string, GroupReadResult>;
  existing: ReadonlyArray<ExistingEntitlement>;
  memberTypes: ReadonlyArray<MemberType>;
  removalLimits: RemovalLimits;
  now: Date;
}

// One line of `ccof.sync.event.v1`: ids, reason codes and counts only.
export interface SyncEvent {
  event: "refusal" | "conflict" | "notice";
  reason: string;
  projectId?: string | null;
  groupId?: string;
  personId?: string;
  memberId?: string;
  classifications?: string[];
  kept?: string | null;
  problems?: string[];
  httpStatus?: number | null;
  graphErrorCode?: string | null;
  errorCode?: string;
  counts?: Record<string, number>;
}

export interface PlannedWrite {
  personId: string;
  kind: "create" | "replace";
  etag: string | null;
  document: EntitlementRecord;
}

export type RemovalsWithheld = "removal_limit_exceeded" | "project_document_unidentified" | null;

export interface PlanCounts {
  projectsRead: number;
  projectsValid: number;
  projectsFrozen: number;
  membersRead: number;
  membersAdmitted: number;
  // Not admitted because Graph reported the account disabled (P-9).
  membersDisabled: number;
  // Admitted without an account state: Graph returned none (P-9).
  membersAccountStateUnread: number;
  documentsRead: number;
  documentsIgnored: number;
  creates: number;
  replaces: number;
  unchanged: number;
  removedMemberships: number;
  withheldRemovals: number;
  emptiedDocuments: number;
  conflicts: number;
}

export interface Plan {
  writes: PlannedWrite[];
  events: SyncEvent[];
  frozenProjects: string[];
  // Projects whose document was valid and whose every group was read.
  evaluatedProjects: number;
  removalsWithheld: RemovalsWithheld;
  counts: PlanCounts;
}
