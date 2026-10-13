// The projection plan (ADR-0016): what each person's `entitlement` document
// should hold. Pure: every input is passed in, including the clock.
//
// Safety rules:
// - A project whose document is invalid, or any of whose groups could not be
//   read, is frozen: its memberships are carried over unchanged and nobody is
//   added to it. A failed read is never an empty group.
// - Removals are withheld (carried over) when they exceed both configured
//   limits, or when a project document cannot even be attributed to a project.
// - A person in two classification groups of one project keeps the incumbent
//   classification if it is one of them, and otherwise gets neither.
// - A member Graph reports disabled is not admitted (P-9); an account state
//   Graph did not return is never read as disabled.
// - A document that already matches is not written (ADR-0008).

import { buildMembership, canonical, isActive, parseExisting, sortByProject, withoutDuplicateActive } from "./membership.ts";
import type { ParsedExisting, RawMembership } from "./membership.ts";
import type { ClassificationRegistration } from "./projects.ts";
import type { Plan, PlanCounts, PlanInput, PlannedWrite, RemovalLimits, RemovalsWithheld, SyncEvent } from "./plan-types.ts";
import type { EntitlementRecord, ProjectMembership } from "./types.ts";

const FRACTION_SCALE = 1_000_000;

// Refuse only when removals exceed both limits: the count is a floor that is
// always allowed (a small pilot can remove its last member), and the fraction
// bounds what one run can remove from a large population.
export function removalLimitExceeded(removals: number, existingMemberships: number, limits: RemovalLimits): boolean {
  if (removals <= limits.maxRemovalsPerRun) return false;
  const scaledFraction = Math.round(limits.maxRemovalFraction * FRACTION_SCALE);
  return removals * FRACTION_SCALE > scaledFraction * existingMemberships;
}

interface ProjectState {
  registrations: Map<string, ClassificationRegistration[]>;
  frozen: Set<string>;
  unidentified: boolean;
}

function assessProjects(input: PlanInput, events: SyncEvent[]): ProjectState {
  const frozen = new Set<string>();
  let unidentified = false;
  const seen = new Map<string, number>();
  for (const result of input.projects) {
    if (result.projectId !== null) seen.set(result.projectId, (seen.get(result.projectId) ?? 0) + 1);
  }
  for (const [projectId, count] of [...seen].sort()) {
    if (count > 1) {
      frozen.add(projectId);
      events.push({ event: "refusal", reason: "project_document_duplicate", projectId });
    }
  }
  for (const result of input.projects) {
    if (result.ok) continue;
    if (result.projectId === null) {
      unidentified = true;
      events.push({ event: "refusal", reason: "project_document_unidentified", projectId: null, problems: result.problems });
    } else if (!frozen.has(result.projectId)) {
      frozen.add(result.projectId);
      events.push({ event: "refusal", reason: "project_document_invalid", projectId: result.projectId, problems: result.problems });
    }
  }

  const registrations = new Map<string, ClassificationRegistration[]>();
  for (const result of input.projects) {
    if (!result.ok || frozen.has(result.projectId)) continue;
    let readable = true;
    for (const reg of result.classifications) {
      const read = input.groups.get(reg.groupId);
      if (read?.ok) continue;
      readable = false;
      events.push({
        event: "refusal",
        reason: read ? read.reason : "graph_group_not_read",
        projectId: reg.projectId,
        groupId: reg.groupId,
        httpStatus: read && !read.ok ? read.httpStatus : null,
        graphErrorCode: read && !read.ok ? read.graphErrorCode : null,
      });
    }
    if (readable) registrations.set(result.projectId, result.classifications);
    else frozen.add(result.projectId);
  }
  return { registrations, frozen, unidentified };
}

interface Admission {
  admitted: Map<string, Set<string>>;
  // Members not admitted because their account is disabled, by group.
  disabled: { groupId: string; memberId: string }[];
}

// Admitted member ids per group, with one event per member that is not.
// A member whose account Graph reports disabled is admitted nowhere in this
// run (P-9): its memberships become removals, bounded by the removal limits.
// An account state Graph did not return keeps the member's admission as it
// was, and is counted: it is never read as disabled.
function admitMembers(input: PlanInput, groupIds: string[], events: SyncEvent[], counts: PlanCounts): Admission {
  const disabledIds = new Set<string>();
  for (const read of input.groups.values()) {
    if (read.ok) for (const member of read.members) if (member.accountEnabled === false) disabledIds.add(member.id);
  }
  const admitted = new Map<string, Set<string>>();
  const disabled: Admission["disabled"] = [];
  for (const groupId of groupIds) {
    const read = input.groups.get(groupId);
    if (!read?.ok) continue;
    const ids = new Set<string>();
    counts.membersRead += read.members.length;
    for (const member of read.members) {
      if ((member.kind === "user" || member.kind === "servicePrincipal") && input.memberTypes.includes(member.kind)) {
        if (disabledIds.has(member.id)) {
          counts.membersDisabled += 1;
          disabled.push({ groupId, memberId: member.id });
          continue;
        }
        if (member.accountEnabled === undefined) counts.membersAccountStateUnread += 1;
        ids.add(member.id);
        continue;
      }
      const reason = member.kind === "group" ? "nested_group_not_expanded" : member.kind === "unknown" ? "member_type_unknown" : "member_type_not_admitted";
      events.push({ event: "notice", reason, groupId, memberId: member.id });
    }
    counts.membersAdmitted += ids.size;
    admitted.set(groupId, ids);
  }
  return { admitted, disabled };
}

// A disabled member is reported when this run removes, or withholds the
// removal of, one of its memberships in that group's project. A disabled
// account that holds nothing there any more is only counted, so a state that
// lasts does not repeat a notice every run.
function reportDisabled(admission: Admission, state: ProjectState, drafts: PersonDraft[], events: SyncEvent[]): void {
  const projectsOf = new Map<string, string[]>();
  for (const [projectId, regs] of state.registrations) {
    for (const reg of regs) projectsOf.set(reg.groupId, [...(projectsOf.get(reg.groupId) ?? []), projectId]);
  }
  const removed = new Map(drafts.map((d) => [d.personId, new Set(d.removed)]));
  for (const { groupId, memberId } of admission.disabled) {
    if ((projectsOf.get(groupId) ?? []).some((projectId) => removed.get(memberId)?.has(projectId))) {
      events.push({ event: "notice", reason: "member_account_disabled", groupId, memberId });
    }
  }
}

interface PersonDraft {
  personId: string;
  existing: ParsedExisting | null;
  planned: (ProjectMembership | RawMembership)[];
  removed: string[];
  // Memberships kept without a successful read in this run (frozen or withheld).
  carried: number;
}

function draftPerson(
  personId: string,
  existing: ParsedExisting | null,
  wanted: Map<string, string[]>,
  state: ProjectState,
  nowIso: string,
  events: SyncEvent[],
  counts: PlanCounts,
): PersonDraft {
  const memberships = existing?.effective ?? [];
  const active = memberships.filter(isActive);
  const planned: (ProjectMembership | RawMembership)[] = memberships.filter((m) => typeof m.projectId === "string" && state.frozen.has(m.projectId));
  const carried = planned.length;
  for (const projectId of [...wanted.keys()].sort()) {
    const codes = [...(wanted.get(projectId) ?? [])].sort();
    const incumbent = active.find((m) => m.projectId === projectId);
    let code: string | null = codes.length === 1 ? codes[0] : null;
    if (codes.length > 1) {
      code = incumbent && codes.includes(String(incumbent.classification)) ? String(incumbent.classification) : null;
      counts.conflicts += 1;
      events.push({ event: "conflict", reason: "classification_conflict", projectId, personId, classifications: codes, kept: code });
    }
    if (code === null) continue;
    const reg = state.registrations.get(projectId)?.find((r) => r.classification === code);
    if (!reg) continue;
    const prior = active.find((m) => m.projectId === projectId && m.classification === code);
    planned.push(buildMembership(reg, prior, nowIso));
  }
  const kept = new Set(planned.map((m) => m.projectId));
  const removed = [...new Set(active.map((m) => m.projectId))].filter((p) => !state.frozen.has(p) && !kept.has(p)).sort();
  return { personId, existing, planned, removed, carried };
}

function toWrite(draft: PersonDraft, nowIso: string, events: SyncEvent[], counts: PlanCounts): PlannedWrite | null {
  const planned = withoutDuplicateActive(sortByProject(draft.planned)) as ProjectMembership[];
  const existing = draft.existing;
  if (existing === null) {
    if (planned.length === 0) return null;
    counts.creates += 1;
    const document: EntitlementRecord = { id: draft.personId, personId: draft.personId, projectMemberships: planned, generation: 1, lastVerifiedAt: nowIso };
    return { personId: draft.personId, kind: "create", etag: null, document };
  }
  const keepExpiry = existing.liveExpiresAt !== null && draft.carried > 0;
  // Order does not matter to the resolver; the sync writes memberships sorted by project.
  const sameMemberships = canonical(planned) === canonical(sortByProject(existing.memberships));
  if (sameMemberships && existing.problems.length === 0 && (!existing.legacyExpiry || keepExpiry)) {
    counts.unchanged += 1;
    return null;
  }
  if (existing.problems.length > 0) {
    events.push({ event: "notice", reason: "entitlement_record_repaired", personId: draft.personId, problems: existing.problems });
  }
  if (planned.length === 0 && existing.memberships.length > 0) counts.emptiedDocuments += 1;
  counts.replaces += 1;
  const generation = existing.generation === null ? 1 : existing.generation + 1;
  const document: EntitlementRecord = { id: draft.personId, personId: draft.personId, projectMemberships: planned, generation, lastVerifiedAt: nowIso };
  if (keepExpiry && existing.liveExpiresAt !== null) document.expiresAt = existing.liveExpiresAt;
  return { personId: draft.personId, kind: "replace", etag: existing.etag, document };
}

function emptyCounts(): PlanCounts {
  return {
    projectsRead: 0,
    projectsValid: 0,
    projectsFrozen: 0,
    membersRead: 0,
    membersAdmitted: 0,
    membersDisabled: 0,
    membersAccountStateUnread: 0,
    documentsRead: 0,
    documentsIgnored: 0,
    creates: 0,
    replaces: 0,
    unchanged: 0,
    removedMemberships: 0,
    withheldRemovals: 0,
    emptiedDocuments: 0,
    conflicts: 0,
  };
}

export function planSync(input: PlanInput): Plan {
  const events: SyncEvent[] = [];
  const counts = emptyCounts();
  const nowIso = input.now.toISOString();
  const state = assessProjects(input, events);
  counts.projectsRead = input.projects.length;
  counts.projectsValid = input.projects.filter((p) => p.ok).length;

  const existing = new Map<string, ParsedExisting>();
  for (const entry of input.existing) {
    counts.documentsRead += 1;
    const parsed = parseExisting(entry, input.now.getTime());
    if (parsed === null || existing.has(parsed.personId)) counts.documentsIgnored += 1;
    else existing.set(parsed.personId, parsed);
  }

  // A membership whose project has no document at all is kept: a deleted or
  // recreated document is not directory evidence that anyone left.
  const documented = new Set(input.projects.map((p) => p.projectId).filter((id): id is string => id !== null));
  const missing = new Set<string>();
  for (const e of existing.values()) {
    for (const m of e.effective.filter(isActive)) if (!documented.has(m.projectId)) missing.add(m.projectId);
  }
  for (const projectId of [...missing].sort()) {
    state.frozen.add(projectId);
    events.push({ event: "refusal", reason: "project_document_missing", projectId });
  }
  counts.projectsFrozen = state.frozen.size;

  const groupIds = [...new Set([...state.registrations.values()].flat().map((r) => r.groupId))].sort();
  const admission = admitMembers(input, groupIds, events, counts);
  const wanted = new Map<string, Map<string, string[]>>();
  for (const regs of state.registrations.values()) {
    for (const reg of regs) {
      for (const personId of admission.admitted.get(reg.groupId) ?? []) {
        const projects = wanted.get(personId) ?? new Map<string, string[]>();
        projects.set(reg.projectId, [...(projects.get(reg.projectId) ?? []), reg.classification]);
        wanted.set(personId, projects);
      }
    }
  }

  const people = [...new Set([...existing.keys(), ...wanted.keys()])].sort();
  const drafts = people.map((personId) =>
    draftPerson(personId, existing.get(personId) ?? null, wanted.get(personId) ?? new Map(), state, nowIso, events, counts),
  );
  reportDisabled(admission, state, drafts, events);

  const removals = drafts.reduce((n, d) => n + d.removed.length, 0);
  const existingMemberships = [...existing.values()].reduce((n, e) => n + new Set(e.effective.filter(isActive).map((m) => m.projectId)).size, 0);
  let removalsWithheld: RemovalsWithheld = state.unidentified ? "project_document_unidentified" : null;
  if (!removalsWithheld && removalLimitExceeded(removals, existingMemberships, input.removalLimits)) {
    removalsWithheld = "removal_limit_exceeded";
    events.push({
      event: "refusal",
      reason: "removal_limit_exceeded",
      counts: { removals, existingMemberships, maxRemovalsPerRun: input.removalLimits.maxRemovalsPerRun, maxRemovalFraction: input.removalLimits.maxRemovalFraction },
    });
  }
  if (removalsWithheld) {
    counts.withheldRemovals = removals;
    for (const draft of drafts) {
      const withheld = new Set(draft.removed);
      const back = (draft.existing?.effective ?? []).filter((m) => typeof m.projectId === "string" && withheld.has(m.projectId));
      draft.planned.push(...back);
      draft.carried += back.length;
    }
  } else {
    counts.removedMemberships = removals;
  }

  const writes = drafts.map((d) => toWrite(d, nowIso, events, counts)).filter((w): w is PlannedWrite => w !== null);
  return { writes, events, frozenProjects: [...state.frozen].sort(), evaluatedProjects: state.registrations.size, removalsWithheld, counts };
}
