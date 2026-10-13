// Which of the person's memberships a request is for. Two paths:
// - the key path (ADR-0002): subscriptionIndex names the project and the
//   person's own entitlement record must confirm it;
// - the selector path (docs/PILOT.md C-1, ADR-0006's rule): no key; an
//   optional projectId selector chooses among the person's active memberships,
//   and with no selector the single active project is used.
// Either way the selector only chooses; authorization comes from the record.

import type { EntitlementRecord, ProjectMembership, ResolveDependencies, ResolveInput } from "./decide.ts";
import { checkEntitlementRecord } from "./freshness.ts";
import type { ResolveRefusal } from "./refusals.ts";
import { refuse, settledValue } from "./refusals.ts";

export type Selection = { membership: ProjectMembership } | ResolveRefusal;

type Usable = { record: EntitlementRecord } | { refusal: ResolveRefusal };

// A missing document and an empty membership list are the same refusal (C-4);
// a malformed record is a per-record 503 (ADR-0008).
function usableEntitlement(entitlement: EntitlementRecord | null, nowMs: number, projectId?: string): Usable {
  if (!entitlement) return { refusal: refuse("no_entitlement", projectId) };
  const verdict = checkEntitlementRecord(entitlement, nowMs);
  if (!verdict.usable) {
    const detail = verdict.reason === "entitlement_record_invalid" ? verdict.detail : undefined;
    return { refusal: refuse(verdict.reason, projectId, detail) };
  }
  if (entitlement.projectMemberships.length === 0) return { refusal: refuse("no_entitlement", projectId) };
  return { record: entitlement };
}

const isActive = (membership: ProjectMembership | null | undefined): membership is ProjectMembership =>
  membership?.status === "active";

// One active membership per project is the rule (docs/LLD.md §4). Two leave the
// classification ambiguous, and picking one could pick the more privileged one,
// so the record is malformed for that project on every path.
function pickInProject(active: ProjectMembership[], projectId: string, logProjectId: boolean): Selection {
  const inProject = active.filter((m) => m.projectId === projectId);
  if (inProject.length === 0) return refuse("project_mismatch", logProjectId ? projectId : undefined);
  if (inProject.length > 1) return refuse("entitlement_record_invalid", projectId, "duplicate_active_membership");
  return { membership: inProject[0] };
}

export async function selectByKey(
  input: ResolveInput & { subscriptionId: string },
  deps: ResolveDependencies,
  nowMs: number,
  signal?: AbortSignal,
): Promise<Selection> {
  // Both keys come from the request, so both reads start together.
  const [subIndexRead, entitlementRead] = await Promise.allSettled([
    deps.readSubscriptionIndex(input.subscriptionId, signal),
    deps.readEntitlement(input.personId, signal),
  ]);

  const subIndex = settledValue(subIndexRead);
  if (!subIndex || subIndex.status !== "active") return refuse("unknown_subscription");
  const keyProjectId = subIndex.projectId;
  if (subIndex.personId !== input.personId) return refuse("subscription_person_mismatch", keyProjectId);
  // A selector sent with a key must name the key's own project.
  if (input.projectId !== undefined && input.projectId !== keyProjectId) return refuse("project_mismatch", keyProjectId);

  const usable = usableEntitlement(settledValue(entitlementRead), nowMs, keyProjectId);
  if ("refusal" in usable) return usable.refusal;
  const selection = pickInProject(usable.record.projectMemberships.filter(isActive), keyProjectId, true);
  if ("refused" in selection) return selection;
  if (selection.membership.classification !== subIndex.classification) {
    return refuse("classification_mismatch", keyProjectId);
  }
  return selection;
}

export async function selectBySelector(
  input: ResolveInput,
  deps: ResolveDependencies,
  nowMs: number,
  signal?: AbortSignal,
): Promise<Selection> {
  const usable = usableEntitlement(await deps.readEntitlement(input.personId, signal), nowMs);
  if ("refusal" in usable) return usable.refusal;
  const active = usable.record.projectMemberships.filter(isActive);

  // A selector that is not one of the person's projects gets the same collapsed
  // 403 as any other refusal and is not echoed (ADR-0006 decisions 3 and 4).
  if (input.projectId !== undefined) return pickInProject(active, input.projectId, false);

  const projects = new Set(active.map((m) => m.projectId));
  if (projects.size === 0) return refuse("no_entitlement");
  if (projects.size > 1) return refuse("project_selection_required");
  return pickInProject(active, active[0].projectId, true);
}
