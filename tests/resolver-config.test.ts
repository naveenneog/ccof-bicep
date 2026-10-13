// The resolver's configuration (ADR-0008 decision 5; docs/PILOT.md C-3): every
// value comes from an app setting, none from the code. Missing or invalid
// settings are reported by name and problem, and never replaced by a guess.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readResolverConfig, RESOLVER_SETTINGS } from "../src/resolver/config.ts";

const completeEnv = {
  COSMOS_ENDPOINT: "https://sample-pilot-cosmos.documents.azure.com:443/",
  COSMOS_DATABASE: "ccof",
  RESOLVER_COSMOS_REQUEST_TIMEOUT_MS: "1500",
  RESOLVER_COSMOS_RETRY_ATTEMPTS: "1",
  RESOLVER_COSMOS_RETRY_MAX_WAIT_SECONDS: "1",
  RESOLVER_REQUEST_DEADLINE_MS: "3000",
  RESOLVER_BUDGET_ENFORCEMENT: "budget-state",
  RESOLVER_BUDGET_STATE_GRACE_SECONDS: "600",
  RESOLVER_BUDGET_STATE_HARD_LIMIT_SECONDS: "3600",
};

const pilotEnv = {
  COSMOS_ENDPOINT: "https://sample-pilot-cosmos.documents.azure.com:443/",
  COSMOS_DATABASE: "ccof",
  RESOLVER_COSMOS_REQUEST_TIMEOUT_MS: "1500",
  RESOLVER_COSMOS_RETRY_ATTEMPTS: "1",
  RESOLVER_COSMOS_RETRY_MAX_WAIT_SECONDS: "1",
  RESOLVER_REQUEST_DEADLINE_MS: "3000",
  RESOLVER_BUDGET_ENFORCEMENT: "token-limits-only",
};

const cosmos = {
  endpoint: "https://sample-pilot-cosmos.documents.azure.com:443/",
  databaseName: "ccof",
  requestTimeoutMs: 1500,
  retryAttempts: 1,
  retryMaxWaitSeconds: 1,
};

function problemsOf(env: Record<string, string | undefined>) {
  const result = readResolverConfig(env);
  if (result.ok) assert.fail("expected the configuration to be invalid");
  return result.problems;
}

test("the setting names are the documented app settings", () => {
  assert.deepEqual(RESOLVER_SETTINGS, {
    cosmosEndpoint: "COSMOS_ENDPOINT",
    cosmosDatabase: "COSMOS_DATABASE",
    cosmosRequestTimeoutMs: "RESOLVER_COSMOS_REQUEST_TIMEOUT_MS",
    cosmosRetryAttempts: "RESOLVER_COSMOS_RETRY_ATTEMPTS",
    cosmosRetryMaxWaitSeconds: "RESOLVER_COSMOS_RETRY_MAX_WAIT_SECONDS",
    requestDeadlineMs: "RESOLVER_REQUEST_DEADLINE_MS",
    budgetEnforcement: "RESOLVER_BUDGET_ENFORCEMENT",
    budgetStateGraceSeconds: "RESOLVER_BUDGET_STATE_GRACE_SECONDS",
    budgetStateHardLimitSeconds: "RESOLVER_BUDGET_STATE_HARD_LIMIT_SECONDS",
  });
});

test("a complete budget-state configuration is read exactly as set", () => {
  assert.deepEqual(readResolverConfig(completeEnv), {
    ok: true,
    config: {
      cosmos,
      requestDeadlineMs: 3000,
      budgetEnforcement: { mode: "budget-state", staleness: { graceSeconds: 600, hardLimitSeconds: 3600 } },
    },
  });
});

test("an empty environment reports every required setting missing and picks no value", () => {
  // Which staleness settings are required depends on the mode, so without a
  // mode only the mode is reported; budget-state's own requirement is below.
  assert.deepEqual(problemsOf({}), [
    { setting: "COSMOS_ENDPOINT", problem: "missing" },
    { setting: "COSMOS_DATABASE", problem: "missing" },
    { setting: "RESOLVER_COSMOS_REQUEST_TIMEOUT_MS", problem: "missing" },
    { setting: "RESOLVER_COSMOS_RETRY_ATTEMPTS", problem: "missing" },
    { setting: "RESOLVER_COSMOS_RETRY_MAX_WAIT_SECONDS", problem: "missing" },
    { setting: "RESOLVER_REQUEST_DEADLINE_MS", problem: "missing" },
    { setting: "RESOLVER_BUDGET_ENFORCEMENT", problem: "missing" },
  ]);
});

test("the Cosmos client limits are whole numbers; the request timeout is at least 1 ms", () => {
  assert.deepEqual(problemsOf({ ...pilotEnv, RESOLVER_COSMOS_REQUEST_TIMEOUT_MS: "0" }), [
    { setting: "RESOLVER_COSMOS_REQUEST_TIMEOUT_MS", problem: "out_of_range" },
  ]);
  for (const [name, value] of [
    ["RESOLVER_COSMOS_REQUEST_TIMEOUT_MS", "2.5"],
    ["RESOLVER_COSMOS_RETRY_ATTEMPTS", "-1"],
    ["RESOLVER_COSMOS_RETRY_MAX_WAIT_SECONDS", "2s"],
  ]) {
    assert.deepEqual(problemsOf({ ...pilotEnv, [name]: value }), [{ setting: name, problem: "not_whole_number" }], name);
  }
  const zeroRetries = readResolverConfig({ ...pilotEnv, RESOLVER_COSMOS_RETRY_ATTEMPTS: "0", RESOLVER_COSMOS_RETRY_MAX_WAIT_SECONDS: "0" });
  assert.equal(zeroRetries.ok, true);
});

test("the request deadline is a whole number of milliseconds, at least 1", () => {
  assert.deepEqual(problemsOf({ ...pilotEnv, RESOLVER_REQUEST_DEADLINE_MS: "0" }), [
    { setting: "RESOLVER_REQUEST_DEADLINE_MS", problem: "out_of_range" },
  ]);
  for (const value of ["3s", "3000.5", "-1", " 3000"]) {
    assert.deepEqual(
      problemsOf({ ...pilotEnv, RESOLVER_REQUEST_DEADLINE_MS: value }),
      [{ setting: "RESOLVER_REQUEST_DEADLINE_MS", problem: "not_whole_number" }],
      JSON.stringify(value),
    );
  }
  const oneMs = readResolverConfig({ ...pilotEnv, RESOLVER_REQUEST_DEADLINE_MS: "1" });
  assert.equal(oneMs.ok && oneMs.config.requestDeadlineMs, 1);
});

// Node runs a longer setTimeout after 1 ms, and AbortSignal.timeout throws from
// 2^32, so a larger value would refuse every request while health says healthy.
test("millisecond settings stop at 2147483647, the longest timer Node runs as written", () => {
  for (const name of ["RESOLVER_REQUEST_DEADLINE_MS", "RESOLVER_COSMOS_REQUEST_TIMEOUT_MS"]) {
    for (const value of ["2147483648", "4294967296"]) {
      assert.deepEqual(problemsOf({ ...pilotEnv, [name]: value }), [{ setting: name, problem: "out_of_range" }], `${name}=${value}`);
    }
    assert.equal(readResolverConfig({ ...pilotEnv, [name]: "2147483647" }).ok, true, name);
  }
});

test("budget-state mode requires both durations", () => {
  assert.deepEqual(
    problemsOf({ ...pilotEnv, RESOLVER_BUDGET_ENFORCEMENT: "budget-state" }),
    [
      { setting: "RESOLVER_BUDGET_STATE_GRACE_SECONDS", problem: "missing" },
      { setting: "RESOLVER_BUDGET_STATE_HARD_LIMIT_SECONDS", problem: "missing" },
    ],
  );
});

test("token-limits-only needs no duration and ignores any that is set", () => {
  const expected = {
    ok: true,
    config: { cosmos, requestDeadlineMs: 3000, budgetEnforcement: { mode: "token-limits-only" } },
  };
  assert.deepEqual(readResolverConfig(pilotEnv), expected);
  assert.deepEqual(
    readResolverConfig({ ...pilotEnv, RESOLVER_BUDGET_STATE_GRACE_SECONDS: "600", RESOLVER_BUDGET_STATE_HARD_LIMIT_SECONDS: "3600" }),
    expected,
  );
});

test("an unknown enforcement mode is a problem, never a default", () => {
  for (const value of ["Token-Limits-Only", "token_limits_only", "budget_state", "none", " budget-state", "budget-state "]) {
    assert.deepEqual(
      problemsOf({ ...pilotEnv, RESOLVER_BUDGET_ENFORCEMENT: value }),
      [{ setting: "RESOLVER_BUDGET_ENFORCEMENT", problem: "unknown_mode" }],
      JSON.stringify(value),
    );
  }
});

test("each missing or blank setting is named on its own", () => {
  for (const name of Object.keys(completeEnv)) {
    if (name === "RESOLVER_BUDGET_ENFORCEMENT") continue; // its own test: the mode decides what else is required
    assert.deepEqual(problemsOf({ ...completeEnv, [name]: undefined }), [{ setting: name, problem: "missing" }], name);
    assert.deepEqual(problemsOf({ ...completeEnv, [name]: "" }), [{ setting: name, problem: "missing" }], name);
  }
  assert.deepEqual(problemsOf({ ...completeEnv, RESOLVER_BUDGET_ENFORCEMENT: "" }), [
    { setting: "RESOLVER_BUDGET_ENFORCEMENT", problem: "missing" },
  ]);
});

test("durations must be whole seconds written as digits", () => {
  for (const value of ["-1", "1.5", "10s", " 600", "600 ", "PT10M", "1e3", "+600", "0x10"]) {
    assert.deepEqual(
      problemsOf({ ...completeEnv, RESOLVER_BUDGET_STATE_GRACE_SECONDS: value }),
      [{ setting: "RESOLVER_BUDGET_STATE_GRACE_SECONDS", problem: "not_whole_seconds" }],
      JSON.stringify(value),
    );
  }
});

test("a duration too large to compute with is out of range, not truncated", () => {
  assert.deepEqual(
    problemsOf({ ...completeEnv, RESOLVER_BUDGET_STATE_HARD_LIMIT_SECONDS: "9".repeat(20) }),
    [{ setting: "RESOLVER_BUDGET_STATE_HARD_LIMIT_SECONDS", problem: "out_of_range" }],
  );
});

test("zero is a valid duration for both settings", () => {
  const result = readResolverConfig({
    ...completeEnv,
    RESOLVER_BUDGET_STATE_GRACE_SECONDS: "0",
    RESOLVER_BUDGET_STATE_HARD_LIMIT_SECONDS: "0",
  });
  assert.equal(result.ok, true);
});

test("a grace window longer than the hard limit is invalid", () => {
  assert.deepEqual(
    problemsOf({ ...completeEnv, RESOLVER_BUDGET_STATE_GRACE_SECONDS: "3601" }),
    [{ setting: "RESOLVER_BUDGET_STATE_GRACE_SECONDS", problem: "grace_exceeds_hard_limit" }],
  );
});

test("a grace window equal to the hard limit is valid", () => {
  const result = readResolverConfig({ ...completeEnv, RESOLVER_BUDGET_STATE_GRACE_SECONDS: "3600" });
  assert.equal(result.ok, true);
});

test("COSMOS_ENDPOINT must be an https URL", () => {
  for (const value of ["http://sample-pilot-cosmos.documents.azure.com/", "sample-pilot-cosmos", "not a url"]) {
    assert.deepEqual(
      problemsOf({ ...completeEnv, COSMOS_ENDPOINT: value }),
      [{ setting: "COSMOS_ENDPOINT", problem: "not_https_url" }],
      value,
    );
  }
});

test("COSMOS_DATABASE must be a usable database id", () => {
  for (const value of ["cc/of", "c#of", " ccof", "ccof?", "a".repeat(256)]) {
    assert.deepEqual(
      problemsOf({ ...completeEnv, COSMOS_DATABASE: value }),
      [{ setting: "COSMOS_DATABASE", problem: "invalid_database_name" }],
      value,
    );
  }
});

test("several problems are all reported, in setting order", () => {
  assert.deepEqual(
    problemsOf({
      ...pilotEnv,
      COSMOS_ENDPOINT: undefined,
      RESOLVER_BUDGET_ENFORCEMENT: "budget-state",
      RESOLVER_BUDGET_STATE_GRACE_SECONDS: "x",
      RESOLVER_BUDGET_STATE_HARD_LIMIT_SECONDS: "60",
    }),
    [
      { setting: "COSMOS_ENDPOINT", problem: "missing" },
      { setting: "RESOLVER_BUDGET_STATE_GRACE_SECONDS", problem: "not_whole_seconds" },
    ],
  );
});
