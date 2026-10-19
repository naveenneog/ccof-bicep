import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { planBudget } from "../src/token-planner.ts";
import { planModels } from "../src/rate-cards.ts";
import { limitsFromPlan } from "../ui-v3/lib/planner.ts";
import { ReadCache, readTtl } from "../ui-v3/lib/read-cache.ts";
import { normalizeTheme } from "../ui-v3/lib/prefs.ts";

const card = JSON.parse(await readFile(new URL("../../config/rate-card.json", import.meta.url), "utf8"));
const mix = { outputPercentOfTokens: 20, cacheReadPercentOfInput: 50, cacheWrite5mPercentOfInput: 10, cacheWrite1hPercentOfInput: 0 };
const family = { family: "sonnet", model: "test-sonnet", budgetPercent: 100,
  rates: { input: "2", output: "10", cacheRead: "0.2", cacheWrite5m: "2.5", cacheWrite1h: "4" } };
const base = { personMonthlyBudgetUsd: "100", sizing: "guaranteed" as const, mix, families: [family] };

test("BB-02: per-person quota is independent of optional whole-group budget and membership", () => {
  const alone = planBudget(base);
  const shared = planBudget({ ...base, groupMonthlyBudgetUsd: "1000" });
  assert.equal(alone.families[0].personMonthlyTokens, 10_000_000);
  assert.equal(shared.families[0].personMonthlyTokens, alone.families[0].personMonthlyTokens);
  assert.equal(shared.families[0].groupMonthlyTokens, 100_000_000);
  const patch = limitsFromPlan(alone);
  assert.equal(Object.hasOwn(patch.aggregateLimits, "group"), false);
  assert.equal(Object.hasOwn(patch.families.sonnet, "group"), false);
  assert.equal(limitsFromPlan(shared).aggregateLimits.group?.tokenQuota, 100_000_000);
});

test("BB-04: zero family allocations and unsupported limits cannot silently become one token", () => {
  const zero = planBudget({ ...base, families: [{ ...family, budgetPercent: 0 }, { ...family, family: "haiku", budgetPercent: 100 }] });
  assert.equal(zero.families[0].personMonthlyTokens, 0);
  assert.equal(zero.applicable, false);
  assert.throws(() => limitsFromPlan(zero), /Adjust the plan/);
  const huge = planBudget({ ...base, personMonthlyBudgetUsd: 10_000_000,
    families: [{ ...family, rates: { input: "0.000001", output: "0.000001", cacheRead: "0.000001", cacheWrite5m: "0.000001", cacheWrite1h: "0.000001" } }] });
  assert.equal(huge.applicable, false);
});

test("BB-05: conservative sizing uses all prompt tiers, not just the cheap base tier", () => {
  const custom = structuredClone(card);
  const source = structuredClone(custom.entries.find((e: { model: string }) => e.model === "claude-sonnet-5"));
  source.promptTiers = [{ promptTokensOver: null, promptTokensUpTo: 200000, rates: family.rates },
    { promptTokensOver: 200000, promptTokensUpTo: null, rates: { ...family.rates, output: "20" } }];
  custom.entries = [source];
  const model = planModels(custom, new Date("2026-10-19T12:00:00Z"))[0];
  assert.equal(model.worstRates.output, "20");
  const plan = planBudget({ ...base, families: [{ ...family, rates: model.rates, worstRates: model.worstRates }] });
  assert.equal(plan.families[0].personMonthlyTokens, 5_000_000);
  assert.equal(plan.worstCaseSpendUsd, "100.00");
});

test("BB-07: read cache expires, is bounded, and prevents in-flight data repopulating after mutation", () => {
  const cache = new ReadCache<string>(2);
  const generation = cache.generation;
  cache.put("/api/v3/a", "a", 100, generation, 0);
  assert.equal(cache.get("/api/v3/a", 99), "a");
  assert.equal(cache.get("/api/v3/a", 100), undefined);
  cache.put("a", "a", 100, generation, 0);
  cache.put("b", "b", 100, generation, 0);
  cache.put("c", "c", 100, generation, 0);
  assert.equal(cache.get("a", 1), undefined);
  cache.clear();
  cache.put("old-read", "old", 100, generation, 0);
  assert.equal(cache.get("old-read", 1), undefined);
  assert.equal(cache.get("c", 1), undefined);
  assert.equal(readTtl("/api/v2/health"), 10_000);
  assert.equal(readTtl("/api/projects/P1"), 15_000);
  assert.equal(readTtl("/api/v3/chargeback/projects?period=month"), 60_000);
  assert.equal(readTtl("/api/v2/catalog"), 30_000);
});

test("BB-01: V3 uses no datalists; dropdown options use the application theme", async () => {
  for (const page of ["projects", "new-project", "project-detail", "chargeback"]) {
    const source = await readFile(new URL(`../ui-v3/pages/${page}.tsx`, import.meta.url), "utf8");
    assert.doesNotMatch(source, /<datalist/);
  }
  const css = await readFile(new URL("../ui-v3/app.css", import.meta.url), "utf8");
  assert.match(css, /select\.input option.*var\(--surface\)/);
});

test("BB-09: admin host keeps all V2/API URLs while adding a root redirect", async () => {
  const host = JSON.parse(await readFile(new URL("../host.json", import.meta.url), "utf8"));
  assert.equal(host.extensions.http.routePrefix, "");
  const app = await readFile(new URL("../src/function-app.ts", import.meta.url), "utf8");
  const routes = [...app.matchAll(/route: "([^"]+)"/g)].map((m) => m[1]);
  assert.ok(routes.includes("{root:maxlength(0)?}"), "root redirect uses a template that matches only the empty path");
  assert.ok(!routes.some((r) => r.startsWith("/")), "route templates cannot start with a slash");
  assert.ok(routes.includes("api/console/{asset?}"));
  assert.ok(routes.includes("api/v3/{*rest}"));
  assert.ok(routes.every((r) => r === "{root:maxlength(0)?}" || r.startsWith("api/")));
  assert.match(app, /v3Enabled\(process\.env\) \? "\/api\/console-v3#\/overview" : "\/api\/console"/);
});

test("BB-13: invalid persisted theme names cannot leave controls with a mismatched scheme", () => {
  assert.equal(normalizeTheme("light"), "light");
  assert.equal(normalizeTheme("dark"), "dark");
  assert.equal(normalizeTheme("old-theme"), "system");
  assert.equal(normalizeTheme(null), "system");
});
