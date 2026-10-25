import type { Plan } from "../../src/token-planner.ts";

export interface Limit { tokensPerMinute: number | null; tokenQuota: number | null; tokenQuotaPeriod: string | null }
export interface LimitsPatch {
  aggregateLimits: { person: Limit; group?: Limit };
  families: Record<string, { person: Limit; group?: Limit }>;
}

export function limitsFromPlan(plan: Plan): LimitsPatch {
  if (!plan.applicable || !plan.families.length) throw new Error("Adjust the plan before applying its limits.");
  const limit = (tokensPerMinute: number, tokenQuota: number): Limit => ({ tokensPerMinute, tokenQuota, tokenQuotaPeriod: "Monthly" });
  const families: LimitsPatch["families"] = {};
  let personTpm = 0, personQuota = 0, groupTpm = 0, groupQuota = 0;
  for (const f of plan.families) {
    families[f.family] = { person: limit(f.personTokensPerMinute, f.personMonthlyTokens) };
    personTpm += f.personTokensPerMinute; personQuota += f.personMonthlyTokens;
    if (f.groupMonthlyTokens !== null && f.groupTokensPerMinute !== null) {
      families[f.family].group = limit(f.groupTokensPerMinute, f.groupMonthlyTokens);
      groupTpm += f.groupTokensPerMinute; groupQuota += f.groupMonthlyTokens;
    }
  }
  return { aggregateLimits: { person: limit(personTpm, personQuota),
    ...(plan.groupBudgetUsd !== null ? { group: limit(groupTpm, groupQuota) } : {}) }, families };
}
