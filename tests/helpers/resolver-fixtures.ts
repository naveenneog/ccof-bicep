// Shared fixtures for the resolver unit tests. Shapes follow docs/LLD.md §1 and
// docs/design/model-family-quotas.md. The clock is fixed: every test passes
// RESOLVE_NOW, so no test depends on the machine's time.

import type { ResolveDependencies, ResolveContext } from "../../src/resolver/decide.ts";
import type { BudgetStalenessPolicy } from "../../src/resolver/freshness.ts";

export const RESOLVE_NOW = new Date("2026-10-09T06:15:00Z");

export const POLICY = { graceSeconds: 600, hardLimitSeconds: 3600 };

// budget-state mode (ADR-0008), the mode every pre-M1.7 test was written for.
export function context(overrides: { now?: Date; budgetStaleness?: BudgetStalenessPolicy } = {}): ResolveContext {
  return {
    now: overrides.now ?? RESOLVE_NOW,
    budgetEnforcement: { mode: "budget-state", staleness: overrides.budgetStaleness ?? POLICY },
  };
}

// The pilot's mode (docs/PILOT.md C-3): no budget document is read.
export function tokenLimitsOnlyContext(now: Date = RESOLVE_NOW): ResolveContext {
  return { now, budgetEnforcement: { mode: "token-limits-only" } };
}

export const STD_TOKEN_LIMITS = {
  person: { tokensPerMinute: 1000000, tokenQuota: 500000, tokenQuotaPeriod: "Daily" as const },
  group: { tokensPerMinute: null, tokenQuota: 2000000, tokenQuotaPeriod: "Daily" as const },
};

export const STD_FAMILY_POLICY = {
  aggregateLimits: STD_TOKEN_LIMITS,
  families: {
    haiku: {
      models: ["claude-haiku-4-5"],
      person: { tokensPerMinute: 200000, tokenQuota: 250000, tokenQuotaPeriod: "Daily" as const },
      group: { tokensPerMinute: 500000, tokenQuota: 1000000, tokenQuotaPeriod: "Daily" as const },
    },
    sonnet: {
      models: ["claude-sonnet-5"],
      person: { tokensPerMinute: 100000, tokenQuota: 250000, tokenQuotaPeriod: "Daily" as const },
      group: { tokensPerMinute: null, tokenQuota: 1000000, tokenQuotaPeriod: "Daily" as const },
    },
  },
};

export const activeSubscriptionIndex = {
  id: "sub-abc",
  subscriptionId: "sub-abc",
  personId: "person-1",
  projectId: "SAMPLEORGAIAZ103",
  classification: "STD",
  issuedAt: "2026-10-09T00:00:00Z",
  status: "active",
};

export const activeMembership = {
  projectId: "SAMPLEORGAIAZ103",
  classification: "STD",
  classificationGroupId: "22222222-2222-2222-2222-222222222222",
  subscriptionId: "sub-abc",
  familyPolicy: STD_FAMILY_POLICY,
  backendId: "foundry-sample-hub",
  aggregateMode: "notify" as "notify" | "strict",
  denormalizedAt: "2026-10-09T04:00:00Z",
  joinedAt: "2026-10-09T00:00:00Z",
  status: "active",
};

// The persistent shape (ADR-0008): no expiresAt.
export const entitlementWithMembership = {
  id: "person-1",
  personId: "person-1",
  projectMemberships: [activeMembership],
  generation: 1,
  lastVerifiedAt: "2026-10-09T06:00:00Z",
};

export const activeBudgetState = {
  id: "person-1:SAMPLEORGAIAZ103",
  personId: "person-1",
  projectId: "SAMPLEORGAIAZ103",
  classification: "STD",
  spentSoFar: 10,
  currency: "USD",
  realtimeCeilingTokensPerMinute: 4200,
  exhausted: false,
  reconciledAt: "2026-10-09T06:12:00Z",
  validUntil: "2026-10-09T06:17:00Z",
};

export const aggregateRecord = {
  id: "SAMPLEORGAIAZ103:STD",
  scopeId: "SAMPLEORGAIAZ103:STD",
  activeMemberCount: 42,
  spentSoFar: 18250.6,
  worstCasePotential: 10500,
  currency: "USD",
  exhausted: false,
  reconciledAt: "2026-10-09T06:12:00Z",
  validUntil: "2026-10-09T06:17:00Z",
};

export const strictEntitlement = {
  ...entitlementWithMembership,
  projectMemberships: [{ ...activeMembership, aggregateMode: "strict" as const }],
};

// Loosely typed on purpose: malformed records are what several tests feed in.
export type FakeReadOverrides = Partial<Record<keyof ResolveDependencies, (...args: never[]) => Promise<unknown>>>;

export function fakeReads(overrides: FakeReadOverrides = {}): ResolveDependencies {
  return {
    readSubscriptionIndex: async () => activeSubscriptionIndex,
    readEntitlement: async () => entitlementWithMembership,
    readBudgetState: async () => activeBudgetState,
    // Read in both aggregate modes since C-7 (notify reads it for the flag).
    readAggregateBudgetState: async () => aggregateRecord,
    // No registry document: the gateway's own configuration applies (C-8).
    readBackend: async () => null,
    ...overrides,
  } as ResolveDependencies;
}

// Seconds after validUntil (2026-10-09T06:17:00Z), as a clock value.
export function secondsAfterValidUntil(seconds: number): Date {
  return new Date(Date.parse(activeBudgetState.validUntil) + seconds * 1000);
}
