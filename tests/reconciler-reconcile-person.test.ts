// RED-first unit tests for the reconciler's per-tick orchestration
// (docs/COST-MODEL.md's sequence diagram): read usage, compute spend,
// compute the next ceiling, write budgetState. Pure orchestration, same
// dependency-injection pattern as tests/resolver-decide.test.ts - no real
// Log Analytics or Cosmos client.

import { test } from "node:test";
import assert from "node:assert/strict";
import { reconcilePerson } from "../src/reconciler/reconcile-person.ts";

const rates = {
  "claude-haiku-4-5": { input: 0.1, output: 0.5 },
  "claude-sonnet-5": { input: 1, output: 3 },
};

function fakeDeps(overrides: Partial<Parameters<typeof reconcilePerson>[1]> = {}) {
  return {
    readUsageSince: async () => [
      { model: "claude-haiku-4-5", category: "input" as const, tokens: 100_000 },
      { model: "claude-haiku-4-5", category: "output" as const, tokens: 50_000 },
    ],
    writeBudgetState: async () => {},
    ...overrides,
  };
}

test("reconcilePerson computes cumulative spend since period start and writes it", async () => {
  const writes: unknown[] = [];
  const deps = fakeDeps({ writeBudgetState: async (state) => { writes.push(state); } });

  const result = await reconcilePerson(
    {
      personId: "person-1",
      projectId: "SAMPLEORGAIAZ103",
      classification: "STD",
      personBudgetUsd: 250,
      modelAllowList: ["claude-haiku-4-5", "claude-sonnet-5"],
      rates,
    },
    deps,
    { reconciledAt: new Date("2026-10-09T06:12:00Z"), validUntil: new Date("2026-10-09T06:17:00Z") },
  );

  // 100,000/1000*0.1 + 50,000/1000*0.5 = 10 + 25 = 35
  assert.equal(result.spentSoFarUsd, 35);
  assert.equal(writes.length, 1);
  assert.deepEqual(writes[0], result);
});

test("reconcilePerson computes the realtime ceiling against the most expensive allowed model", async () => {
  const result = await reconcilePerson(
    {
      personId: "person-1",
      projectId: "SAMPLEORGAIAZ103",
      classification: "STD",
      personBudgetUsd: 250,
      modelAllowList: ["claude-haiku-4-5", "claude-sonnet-5"],
      rates,
    },
    fakeDeps(),
    { reconciledAt: new Date("2026-10-09T06:12:00Z"), validUntil: new Date("2026-10-09T06:17:00Z") },
  );

  // spent = 35, remaining = 215, most expensive output rate = $3/1000 tokens
  // ceiling = 215 / 3 * 1000 = 71666.67 tokens
  assert.equal(result.spentSoFarUsd, 35);
  assert.ok(Math.abs(result.realtimeCeilingTokensPerMinute - 71666.67) < 1);
});

test("reconcilePerson rejects an empty modelAllowList with a clear error, not -Infinity propagating silently", async () => {
  await assert.rejects(
    () =>
      reconcilePerson(
        {
          personId: "person-1",
          projectId: "SAMPLEORGAIAZ103",
          classification: "STD",
          personBudgetUsd: 250,
          modelAllowList: [],
          rates,
        },
        fakeDeps(),
        { reconciledAt: new Date(), validUntil: new Date() },
      ),
    /modelAllowList is empty/,
  );
});

test("reconcilePerson refuses an allow-list containing a model with no rate, rather than silently skipping it", async () => {
  await assert.rejects(
    () =>
      reconcilePerson(
        {
          personId: "person-1",
          projectId: "SAMPLEORGAIAZ103",
          classification: "STD",
          personBudgetUsd: 250,
          modelAllowList: ["claude-haiku-4-5", "claude-unknown-model"],
          rates,
        },
        fakeDeps(),
        { reconciledAt: new Date(), validUntil: new Date() },
      ),
    /no rate for allow-listed model claude-unknown-model/,
  );
});

test("reconcilePerson clamps the ceiling to zero once spend has already reached the budget", async () => {
  const result = await reconcilePerson(
    {
      personId: "person-1",
      projectId: "SAMPLEORGAIAZ103",
      classification: "STD",
      personBudgetUsd: 10, // less than the $35 this tick's usage costs
      modelAllowList: ["claude-haiku-4-5", "claude-sonnet-5"],
      rates,
    },
    fakeDeps(),
    { reconciledAt: new Date(), validUntil: new Date() },
  );

  assert.equal(result.spentSoFarUsd, 35);
  assert.equal(result.realtimeCeilingTokensPerMinute, 0);
});

test("reconcilePerson records reconciledAt and validUntil exactly as given by the caller", async () => {
  const reconciledAt = new Date("2026-10-09T06:12:00Z");
  const validUntil = new Date("2026-10-09T06:17:00Z");
  const result = await reconcilePerson(
    {
      personId: "person-1",
      projectId: "SAMPLEORGAIAZ103",
      classification: "STD",
      personBudgetUsd: 250,
      modelAllowList: ["claude-haiku-4-5"],
      rates,
    },
    fakeDeps(),
    { reconciledAt, validUntil },
  );
  assert.equal(result.reconciledAt, reconciledAt.toISOString());
  assert.equal(result.validUntil, validUntil.toISOString());
  assert.equal(result.personId, "person-1");
  assert.equal(result.projectId, "SAMPLEORGAIAZ103");
});

test("reconcilePerson counts all five token categories in spentSoFar, cache writes at their own rates", async () => {
  const fiveCategoryRates = {
    "claude-sonnet-5": { input: 0.002, cacheWrite5m: 0.0025, cacheWrite1h: 0.004, cacheRead: 0.0002, output: 0.01 },
  };
  const result = await reconcilePerson(
    {
      personId: "person-1",
      projectId: "SAMPLEORGAIAZ103",
      classification: "STD",
      personBudgetUsd: 250,
      modelAllowList: ["claude-sonnet-5"],
      rates: fiveCategoryRates,
    },
    fakeDeps({
      readUsageSince: async () => [
        { model: "claude-sonnet-5", category: "input" as const, tokens: 1_000 },
        { model: "claude-sonnet-5", category: "cacheWrite5m" as const, tokens: 10_000 },
        { model: "claude-sonnet-5", category: "cacheWrite1h" as const, tokens: 10_000 },
        { model: "claude-sonnet-5", category: "cacheRead" as const, tokens: 100_000 },
        { model: "claude-sonnet-5", category: "output" as const, tokens: 1_000 },
      ],
    }),
    { reconciledAt: new Date("2026-10-11T06:12:00Z"), validUntil: new Date("2026-10-11T06:17:00Z") },
  );
  // 1 x 0.002 + 10 x 0.0025 + 10 x 0.004 + 100 x 0.0002 + 1 x 0.01 = 0.002 + 0.025 + 0.04 + 0.02 + 0.01 = 0.097
  assert.equal(result.spentSoFarUsd, 0.097);
});

test("reconcilePerson refuses usage in the undivided legacy cacheWrite category", async () => {
  const legacyRates = { "claude-sonnet-5": { input: 0.002, cacheWrite: 0.0025, output: 0.01 } };
  await assert.rejects(
    () =>
      reconcilePerson(
        {
          personId: "person-1",
          projectId: "SAMPLEORGAIAZ103",
          classification: "STD",
          personBudgetUsd: 250,
          modelAllowList: ["claude-sonnet-5"],
          rates: legacyRates as unknown as Parameters<typeof reconcilePerson>[0]["rates"],
        },
        fakeDeps({
          readUsageSince: async () =>
            [{ model: "claude-sonnet-5", category: "cacheWrite", tokens: 1_000 }] as unknown as Awaited<
              ReturnType<Parameters<typeof reconcilePerson>[1]["readUsageSince"]>
            >,
        }),
        { reconciledAt: new Date(), validUntil: new Date() },
      ),
    /unknown usage category cacheWrite/,
  );
});
