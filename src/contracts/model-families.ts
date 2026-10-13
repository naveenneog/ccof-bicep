export type ModelFamily = "haiku" | "sonnet" | "opus" | "fable" | "mythos";
export type TokenQuotaPeriod = "Hourly" | "Daily" | "Weekly" | "Monthly" | "Yearly";

export interface TokenLimit {
  tokensPerMinute: number | null;
  tokenQuota: number | null;
  tokenQuotaPeriod: TokenQuotaPeriod | null;
}

export interface FamilyEntry {
  models: string[];
  person: TokenLimit;
  group: TokenLimit;
}

export interface FamilyPolicy {
  aggregateLimits: { person: TokenLimit; group: TokenLimit };
  families: Partial<Record<ModelFamily, FamilyEntry>>;
}

const families: readonly ModelFamily[] = ["haiku", "sonnet", "opus", "fable", "mythos"];
const periods: readonly TokenQuotaPeriod[] = ["Hourly", "Daily", "Weekly", "Monthly", "Yearly"];
const canonicalModel = /^claude-(haiku|sonnet|opus|fable|mythos)-[A-Za-z0-9][A-Za-z0-9._-]{0,105}$/;
const aliasModel = /^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/;

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function exactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const actual = Object.keys(value);
  return actual.length === keys.length && keys.every((key) => Object.hasOwn(value, key));
}

function positiveInteger(value: unknown, max: number): value is number | null {
  return value === null || (typeof value === "number" && Number.isSafeInteger(value) && value > 0 && value <= max);
}

function tokenLimit(value: unknown): TokenLimit | null {
  if (!object(value) || !exactKeys(value, ["tokensPerMinute", "tokenQuota", "tokenQuotaPeriod"])) return null;
  if (!positiveInteger(value.tokensPerMinute, 2147483647) || !positiveInteger(value.tokenQuota, Number.MAX_SAFE_INTEGER)) return null;
  if (value.tokenQuotaPeriod !== null && !periods.includes(value.tokenQuotaPeriod as TokenQuotaPeriod)) return null;
  if ((value.tokenQuota === null) !== (value.tokenQuotaPeriod === null)) return null;
  return {
    tokensPerMinute: value.tokensPerMinute,
    tokenQuota: value.tokenQuota,
    tokenQuotaPeriod: value.tokenQuotaPeriod as TokenQuotaPeriod | null,
  };
}

function validModel(model: unknown, family: ModelFamily): model is string {
  if (typeof model !== "string") return false;
  if (model.startsWith("claude-")) {
    const match = canonicalModel.exec(model);
    // Prefix consistency never substitutes for matching the entire registered ID.
    return match !== null && match[0] === model && match[1] === family;
  }
  return aliasModel.exec(model)?.[0] === model;
}

export function parseFamilyPolicy(
  value: unknown,
  classification: string,
): { ok: true; value: FamilyPolicy } | { ok: false; detail: "invalid_family_policy" | "family_classification_forbidden" } {
  const invalid = { ok: false, detail: "invalid_family_policy" } as const;
  if (!object(value) || !exactKeys(value, ["aggregateLimits", "families"]) || !object(value.families)) return invalid;
  if (classification !== "CYB" && (Object.hasOwn(value.families, "fable") || Object.hasOwn(value.families, "mythos"))) {
    return { ok: false, detail: "family_classification_forbidden" };
  }
  if (!object(value.aggregateLimits) || !exactKeys(value.aggregateLimits, ["person", "group"])) return invalid;
  const person = tokenLimit(value.aggregateLimits.person);
  const group = tokenLimit(value.aggregateLimits.group);
  if (!person || !group) return invalid;
  const keys = Object.keys(value.families);
  if (keys.length === 0 || keys.some((key) => !families.includes(key as ModelFamily))) return invalid;
  const parsed: FamilyPolicy = { aggregateLimits: { person, group }, families: {} };
  const registered = new Set<string>();
  for (const key of keys) {
    const family = key as ModelFamily;
    const entry = value.families[key];
    if (!object(entry) || !exactKeys(entry, ["models", "person", "group"]) || !Array.isArray(entry.models) || entry.models.length === 0) return invalid;
    const familyPerson = tokenLimit(entry.person);
    const familyGroup = tokenLimit(entry.group);
    if (!familyPerson || !familyGroup) return invalid;
    const models: string[] = [];
    for (const model of entry.models) {
      if (!validModel(model, family) || registered.has(model)) return invalid;
      registered.add(model);
      models.push(model);
    }
    parsed.families[family] = { models, person: familyPerson, group: familyGroup };
  }
  return { ok: true, value: parsed };
}

export function admittedModelFamily(policy: FamilyPolicy, classification: string, model: string): ModelFamily | null {
  const parsed = parseFamilyPolicy(policy, classification);
  if (!parsed.ok) return null;
  for (const family of families) {
    if (parsed.value.families[family]?.models.includes(model)) return family;
  }
  return null;
}
