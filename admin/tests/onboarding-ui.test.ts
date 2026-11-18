// ADR 0040: the console wizard's client-side rules. The server re-checks everything; these only keep
// the admin from sending a request that is certain to be refused.

import { test } from "node:test";
import assert from "node:assert/strict";
import { onboardingBody, onboardingProblems, suggestBackendId } from "../ui-v3/lib/onboarding.ts";

const SUB = "/subscriptions/00000000-0000-0000-0000-000000000001";
const ACCOUNT = `${SUB}/resourceGroups/rg-ai/providers/Microsoft.CognitiveServices/accounts/Foundry2-east`;
const scope = { resourceIds: [], discoveryScopes: [`${SUB}/resourceGroups/rg-ai`] };
const draft = { foundryResourceId: ACCOUNT, backendId: "foundry2-east", displayName: "", deployments: "", inferenceGeo: "global" };

test("the suggested backend ID is the lower-case account name, valid for APIM and the registry", () => {
  assert.equal(suggestBackendId(ACCOUNT), "foundry2-east");
  assert.equal(suggestBackendId(`${SUB}/resourceGroups/r/providers/Microsoft.CognitiveServices/accounts/ccof-x`), "x");
  assert.equal(suggestBackendId("not an id"), "");
});

test("a complete in-scope draft has no problems and sends only the keys the server accepts", () => {
  assert.deepEqual(onboardingProblems(draft, scope), {});
  assert.deepEqual(onboardingBody(draft), { backendId: "foundry2-east", foundryResourceId: ACCOUNT, inferenceGeo: "global" });
  assert.deepEqual(onboardingBody({ ...draft, displayName: "  East 2 ", deployments: "a, b,," }),
    { backendId: "foundry2-east", foundryResourceId: ACCOUNT, inferenceGeo: "global", displayName: "East 2", deployments: ["a", "b"] });
});

test("bad IDs, out-of-scope accounts and ccof- backend IDs are flagged before any request", () => {
  assert.ok(onboardingProblems({ ...draft, foundryResourceId: "/subscriptions/x/accounts/y" }, scope).foundryResourceId);
  assert.ok(onboardingProblems({ ...draft, foundryResourceId: ACCOUNT.replace("rg-ai", "rg-other") }, scope).foundryResourceId);
  assert.deepEqual(onboardingProblems({ ...draft, foundryResourceId: ACCOUNT.replace("rg-ai", "rg-other") },
    { resourceIds: [ACCOUNT.replace("rg-ai", "rg-other").toUpperCase()], discoveryScopes: [] }), {});
  for (const id of ["", "ccof-a", "a/b", "a b", "-a", "x".repeat(81), "<script>"]) {
    assert.ok(onboardingProblems({ ...draft, backendId: id }, scope).backendId, id);
  }
  assert.ok(onboardingProblems({ ...draft, displayName: "x".repeat(121) }, scope).displayName);
  assert.ok(onboardingProblems({ ...draft, inferenceGeo: "mars" }, scope).inferenceGeo);
});
