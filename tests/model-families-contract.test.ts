import { test } from "node:test";
import assert from "node:assert/strict";
import { admittedModelFamily, parseFamilyPolicy } from "../src/contracts/model-families.ts";
import type { FamilyPolicy, TokenLimit } from "../src/contracts/model-families.ts";

const unlimited = (): TokenLimit => ({ tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null });
function policy(): FamilyPolicy {
  return {
    aggregateLimits: { person: unlimited(), group: unlimited() },
    families: { haiku: { models: ["claude-haiku-4-5", "claude-haiku-4-5-20251001", "deployment_alias"], person: unlimited(), group: unlimited() } },
  };
}
function rejected(value: unknown, classification = "STD", detail = "invalid_family_policy") {
  assert.deepEqual(parseFamilyPolicy(value, classification), { ok: false, detail });
}

test("pure API preserves the complete policy and admits only exact registered IDs", () => {
  const p = policy();
  assert.deepEqual(parseFamilyPolicy(p, "STD"), { ok: true, value: p });
  for (const model of p.families.haiku!.models) assert.equal(admittedModelFamily(p, "STD", model), "haiku");
  for (const model of ["claude-haiku-unknown", "claude-haiku-4-5-20251002", "Claude-haiku-4-5", "CLAUDE-HAIKU-4-5", "deployment", "claude-sonnet-5", "claude-haikux-5"]) {
    assert.equal(admittedModelFamily(p, "STD", model), null, model);
  }
});

test("all required object boundaries reject missing, non-object and additional fields", () => {
  for (const value of [undefined, null, [], "policy", {}, { ...policy(), extra: 1 }]) rejected(value);
  for (const path of [[], ["aggregateLimits"], ["aggregateLimits", "person"], ["aggregateLimits", "group"], ["families"], ["families", "haiku"], ["families", "haiku", "person"], ["families", "haiku", "group"]]) {
    for (const mutation of ["missing", "null", "array", "unknown"] as const) {
      const p = policy() as unknown as Record<string, unknown>;
      if (path.length === 0) continue;
      let parent = p;
      for (const key of path.slice(0, -1)) parent = parent[key] as Record<string, unknown>;
      const key = path.at(-1)!;
      if (mutation === "missing") delete parent[key];
      if (mutation === "null") parent[key] = null;
      if (mutation === "array") parent[key] = [];
      if (mutation === "unknown") (parent[key] as Record<string, unknown>).extra = true;
      rejected(p);
    }
  }
  rejected({ ...policy(), families: {} });
  rejected({ ...policy(), families: { Haiku: policy().families.haiku } });
});

test("numeric bounds, periods and paired nulls apply identically at aggregate and family scopes", () => {
  for (const scope of ["aggregate", "family"] as const) {
    for (const owner of ["person", "group"] as const) {
      for (const field of ["tokensPerMinute", "tokenQuota", "tokenQuotaPeriod"] as const) {
        const invalid = field === "tokenQuotaPeriod"
          ? ["daily", "", "Forever", 1, undefined]
          : [0, -1, 0.5, "1", true, NaN, Infinity, -Infinity, undefined, field === "tokensPerMinute" ? 2147483648 : 9007199254740992];
        for (const value of invalid) {
          const p = policy();
          const limit = scope === "aggregate" ? p.aggregateLimits[owner] : p.families.haiku![owner];
          if (field === "tokenQuota") limit.tokenQuotaPeriod = "Daily";
          if (field === "tokenQuotaPeriod") limit.tokenQuota = 1;
          (limit as unknown as Record<string, unknown>)[field] = value;
          rejected(p);
        }
        const p = policy();
        const limit = scope === "aggregate" ? p.aggregateLimits[owner] : p.families.haiku![owner];
        delete (limit as unknown as Record<string, unknown>)[field];
        rejected(p);
      }
      for (const period of ["Hourly", "Daily", "Weekly", "Monthly", "Yearly"] as const) {
        const p = policy();
        const limit = scope === "aggregate" ? p.aggregateLimits[owner] : p.families.haiku![owner];
        Object.assign(limit, { tokensPerMinute: 2147483647, tokenQuota: Number.MAX_SAFE_INTEGER, tokenQuotaPeriod: period });
        assert.equal(parseFamilyPolicy(p, "STD").ok, true);
      }
      for (const value of [{ tokenQuota: 1, tokenQuotaPeriod: null }, { tokenQuota: null, tokenQuotaPeriod: "Daily" }]) {
        const p = policy();
        Object.assign(scope === "aggregate" ? p.aggregateLimits[owner] : p.families.haiku![owner], value);
        rejected(p);
      }
    }
  }
});

test("canonical consistency, explicit alias syntax, lengths and duplicate IDs are strict", () => {
  for (const model of ["claude-sonnet-5", "claude-haikux-5", "claude-haiku-", "claude-HAIKU-5", "claude-haiku-5\n", "claude-haiku-5 ", "claude-haiku-*", "bad/alias", "_alias", "", "a".repeat(121), `claude-haiku-${"a".repeat(107)}`]) {
    const p = policy();
    p.families.haiku!.models = [model];
    rejected(p);
    assert.equal(admittedModelFamily(p, "STD", model), null);
  }
  for (const model of ["a".repeat(120), `claude-haiku-${"a".repeat(106)}`, "Explicit.Alias-1"]) {
    const p = policy();
    p.families.haiku!.models = [model];
    assert.equal(parseFamilyPolicy(p, "STD").ok, true);
    assert.equal(admittedModelFamily(p, "STD", model), "haiku");
  }
  for (const models of [[], ["alias", "alias"], [1], [null]]) {
    const p = policy();
    p.families.haiku!.models = models as string[];
    rejected(p);
  }
  const p = policy();
  p.families.sonnet = { models: ["deployment_alias"], person: unlimited(), group: unlimited() };
  rejected(p);
  assert.equal(admittedModelFamily(p, "STD", "deployment_alias"), null);
});

test("Fable and Mythos require authoritative exact CYB even for empty or malformed entries", () => {
  for (const family of ["fable", "mythos"] as const) {
    for (const classification of ["STD", "PRM", "cyb", "CYB-extra", "CYB Approved", ""]) {
      for (const entry of [{ models: [`claude-${family}-registered`], person: unlimited(), group: unlimited() }, {}, null]) {
        const p = policy();
        p.families[family] = entry as never;
        rejected(p, classification, "family_classification_forbidden");
        assert.equal(admittedModelFamily(p, classification, `claude-${family}-registered`), null);
      }
    }
    const p = policy();
    p.families[family] = { models: [`claude-${family}-registered`], person: unlimited(), group: unlimited() };
    assert.equal(parseFamilyPolicy(p, "CYB").ok, true);
    assert.equal(admittedModelFamily(p, "CYB", `claude-${family}-registered`), family);
  }
});

test("inherited fields cannot satisfy required own properties", () => {
  rejected(Object.create(policy()));
  const p = policy();
  p.aggregateLimits.person = Object.create(unlimited());
  rejected(p);
});
