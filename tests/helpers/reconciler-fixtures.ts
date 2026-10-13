// Shared fixtures for the reconciler tests: settings, registry documents and
// ledger rows. Ids are synthetic GUIDs; nothing here names a person.

import { readFileSync } from "node:fs";
import { parseContractScheduleJson } from "../../src/cost/contract-schedule.ts";
import type { ContractSchedule } from "../../src/cost/contract-schedule.ts";
import { parseRateCardJson } from "../../src/cost/rate-card.ts";
import type { RateCard } from "../../src/cost/rate-card.ts";

export function validSettings(overrides: Record<string, string> = {}): Record<string, string | undefined> {
  return {
    RECONCILER_MANAGED_IDENTITY_CLIENT_ID: "00000000-0000-4000-8000-000000000100",
    RECONCILER_SCHEDULE: "0 */2 * * * *",
    RECONCILER_VALIDITY_SECONDS: "600",
    RECONCILER_LEASE_SECONDS: "300",
    RECONCILER_LOG_ANALYTICS_WORKSPACE_ID: "00000000-0000-4000-8000-000001100000",
    RECONCILER_LOG_ANALYTICS_ENDPOINT: "https://api.loganalytics.io",
    RECONCILER_LEDGER_GATEWAY_RESOURCE_ID:
      "/subscriptions/00000000-0000-4000-8000-000000000110/resourceGroups/sample-pilot-rg/providers/Microsoft.ApiManagement/service/sample-pilot-apim",
    RECONCILER_LEDGER_TIMEOUT_SECONDS: "60",
    RECONCILER_LEDGER_MAX_ROWS: "100000",
    RECONCILER_MAX_STATES: "10000",
    RECONCILER_WRITE_CONCURRENCY: "8",
    COSMOS_ENDPOINT: "https://sample-pilot-cosmos.documents.azure.com:443/",
    COSMOS_DATABASE: "ccof",
    RECONCILER_PROJECTS_CONTAINER: "projects",
    RECONCILER_ENTITLEMENT_CONTAINER: "entitlement",
    RECONCILER_BUDGET_STATE_CONTAINER: "budgetState",
    RECONCILER_AGGREGATE_STATE_CONTAINER: "aggregateBudgetState",
    RECONCILER_LEASE_CONTAINER: "reconcilerLease",
    ...overrides,
  };
}

const repoFile = (relative: string): string => readFileSync(new URL(`../../${relative}`, import.meta.url), "utf8");

// The packaged rate card and contract schedule (WP-COST), exactly as deployed.
export function packagedRateCard(): RateCard {
  return parseRateCardJson(repoFile("config/rate-card.json"));
}

export function packagedSchedule(card: RateCard): ContractSchedule {
  return parseContractScheduleJson(repoFile("config/contract-schedule.json"), card);
}

export const PERSON_A = "00000000-0000-4000-8000-000001100001";
export const PERSON_B = "00000000-0000-4000-8000-000001100010";
export const PERSON_C = "00000000-0000-4000-8000-000001100011";
export const GROUP_STD = "00000000-0000-4000-8000-000001100100";
export const GROUP_PRM = "00000000-0000-4000-8000-000001100101";
export const GROUP_CYB = "00000000-0000-4000-8000-000001100110";

const limits = (tokensPerMinute: number | null) => ({
  person: { tokensPerMinute, tokenQuota: 500000, tokenQuotaPeriod: "Daily" },
  group: { tokensPerMinute: null, tokenQuota: 2000000, tokenQuotaPeriod: "Daily" },
});

const budget = (amount: number | string, currency = "CCU") => ({ amount, currency, period: "monthly" });
const familyPolicy = (premium: boolean, tokensPerMinute: number | null) => ({
  aggregateLimits: limits(tokensPerMinute),
  families: {
    haiku: { models: ["claude-haiku-4-5"], ...limits(tokensPerMinute) },
    sonnet: { models: ["claude-sonnet-5"], ...limits(tokensPerMinute) },
    ...(premium ? { opus: { models: ["claude-opus-5", "claude-opus-5-5"], ...limits(tokensPerMinute) } } : {}),
  },
});

// A `projects` document in the WP-ONB Stage 3 shape (C-5), with the pilot's
// E2E defaults (docs/PILOT.md).
export function pilotProject(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "CCOFPILOT01",
    projectId: "CCOFPILOT01",
    displayName: "Pilot project 01",
    status: "active",
    backendId: "foundry-sample-hub",
    designatedSubscriptionId: "00000000-0000-4000-8000-000000001000",
    classifications: {
      STD: {
        groupId: GROUP_STD,
        familyPolicy: familyPolicy(false, 1000000),
        personBudget: budget(25000),
        aggregateBudget: budget(2000000),
        aggregateMode: "strict",
        onboardingMode: "block",
      },
      PRM: {
        groupId: GROUP_PRM,
        familyPolicy: familyPolicy(true, 1000000),
        personBudget: budget(100000),
        aggregateBudget: budget(1500000),
        aggregateMode: "notify",
        onboardingMode: "warn",
      },
      CYB: {
        groupId: GROUP_CYB,
        familyPolicy: familyPolicy(true, null),
        personBudget: budget(250000),
        aggregateBudget: null,
        aggregateMode: "notify",
        onboardingMode: "warn",
      },
    },
    supersedes: null,
    retiredAt: null,
    ...overrides,
  };
}

export interface MembershipSpec {
  projectId: string;
  classification: string;
  status?: string;
}

// An `entitlement` document in the C-4 shape the sync writes.
export function entitlementDoc(personId: string, memberships: MembershipSpec[]): Record<string, unknown> {
  return {
    id: personId,
    personId,
    projectMemberships: memberships.map((m) => ({
      projectId: m.projectId,
      classification: m.classification,
      classificationGroupId: GROUP_STD,
      familyPolicy: familyPolicy(false, 1000000),
      backendId: "foundry-sample-hub",
      aggregateMode: "strict",
      denormalizedAt: "2026-10-11T10:00:00Z",
      joinedAt: "2026-10-11T10:00:00Z",
      status: m.status ?? "active",
    })),
    generation: 3,
    lastVerifiedAt: "2026-10-11T10:00:00Z",
  };
}

export interface LedgerRowSpec {
  timestamp?: string;
  ingestedAt?: string;
  personId?: string;
  projectId?: string;
  classification?: string;
  attributionKnown?: boolean;
  model?: string;
  inferenceGeo?: string;
  usageSource?: string;
  input?: number | null;
  output?: number | null;
  cacheWrite5m?: number | null;
  cacheWrite1h?: number | null;
  cacheRead?: number | null;
  requestId?: string;
}

let requestCounter = 0;

// One row of `CcofUsageLedger` as the reconciler projects it, with the
// column names of analytics/ledger.kql.
export function ledgerRow(spec: LedgerRowSpec = {}): Record<string, unknown> {
  requestCounter += 1;
  return {
    timestamp: spec.timestamp ?? "2026-10-11T12:00:00.0000000Z",
    ingestedAt: spec.ingestedAt ?? "2026-10-11T12:01:30.0000000Z",
    gatewayRequestId: spec.requestId ?? `00000000-0000-4000-8000-${String(requestCounter).padStart(12, "0")}`,
    personId: spec.personId ?? PERSON_A,
    projectId: spec.projectId ?? "CCOFPILOT01",
    classification: spec.classification ?? "STD",
    attributionKnown: spec.attributionKnown ?? true,
    model: spec.model ?? "claude-haiku-4-5-20251001",
    inference_geo: spec.inferenceGeo ?? "global",
    usageSource: spec.usageSource ?? "body",
    inputTokens: spec.input === undefined ? 1000 : spec.input,
    outputTokens: spec.output === undefined ? 100 : spec.output,
    cacheWrite5mTokens: spec.cacheWrite5m === undefined ? 0 : spec.cacheWrite5m,
    cacheWrite1hTokens: spec.cacheWrite1h === undefined ? 0 : spec.cacheWrite1h,
    cacheReadTokens: spec.cacheRead === undefined ? 0 : spec.cacheRead,
  };
}
