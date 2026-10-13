import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync } from "node:fs";
import { workbookAnswers } from "./helpers/workbook-fixtures.ts";

const groupName = `  Platform & R&D <"One"> / O'Brien \\ Ω  `;
const groups = [{ projectId: "SYNTHETIC", classification: "STD",
  groupId: "44444444-4444-4444-8444-444444444444", displayName: groupName }];
const card = JSON.parse(readFileSync(new URL("../config/rate-card.json", import.meta.url), "utf8"));
const ledger = readFileSync(new URL("../analytics/ledger.kql", import.meta.url), "utf8");

test("chargeback workbook uses exact Graph names with stable IDs, not classification as label", async () => {
  const { buildChargebackWorkbook } = await import("../analytics/workbooks/chargeback.ts");
  const built = buildChargebackWorkbook(workbookAnswers(), card, ledger, groups);
  assert.equal(built.groups[0].displayName, groupName);
  assert.match(built.queries.usage, /classificationGroupId/);
  assert.ok(built.queries.usage.includes(JSON.stringify(groupName)));
  assert.match(built.queries.usage, /current_mapping_historical_unverified/);
  assert.match(built.queries.usage, /unknown historical group/);
  assert.doesNotMatch(built.queries.usage, /classificationGroup = iff/);
  assert.deepEqual(JSON.parse(JSON.stringify(built.groups)), groups);
});

test("reporting has no budget/reconciler table dependency and family derives from model prefix", async () => {
  const { buildChargebackWorkbook } = await import("../analytics/workbooks/chargeback.ts");
  const built = buildChargebackWorkbook(workbookAnswers(), card, ledger, groups);
  for (const name of ["usage", "groups", "models", "families", "totals", "trends", "diagnostics"] as const) {
    assert.ok(built.queries[name], name);
    assert.doesNotMatch(built.queries[name], /FunctionAppLogs|BudgetSnapshots|ReconcilerRuns/);
  }
  assert.match(built.queries.families, /claude-\(haiku\|sonnet\|opus\|fable\|mythos\)/);
  assert.match(JSON.stringify(built.workbook), /cache read/i);
  assert.match(JSON.stringify(built.workbook), /cache write/i);
  assert.match(built.queries.models, /cacheReadCostUsd/);
  assert.match(built.queries.models, /cacheWrite5mCostUsd/);
  assert.match(built.queries.models, /cacheWrite1hCostUsd/);
  assert.match(built.queries.diagnostics, /traceConflict/);
});

test("reporting excludes unverified Fable/Mythos rates while retaining unpriced usage", async () => {
  const { buildChargebackWorkbook } = await import("../analytics/workbooks/chargeback.ts");
  const built = buildChargebackWorkbook(workbookAnswers(), card, ledger, []);
  assert.ok(built.rateCard.rows.some(r => r.model === "claude-haiku-4-5"));
  assert.ok(!built.rateCard.rows.some(r => /fable|mythos/.test(r.model)));
  assert.match(built.queries.totals, /unpricedRequests/);
  assert.match(built.queries.totals, /cacheReadUnknownRequests/);
});

test("directory metadata refuses mismatched/malformed identity but preserves exact text", async () => {
  const { validateGroups } = await import("../analytics/workbooks/chargeback.ts");
  assert.deepEqual(validateGroups(groups), groups);
  assert.throws(() => validateGroups([{ ...groups[0], groupId: "not-an-object-id" }]), /groupId/);
  assert.throws(() => validateGroups([{ ...groups[0], displayName: 123 }]), /displayName/);
  assert.throws(() => validateGroups([groups[0], { ...groups[0], groupId: workbookAnswers().tenantId }]), /duplicate/);
});

test("ledger exposes trusted group snapshots and outcome diagnostics without directory lookups", () => {
  assert.match(ledger, /payload\.classificationGroupId/);
  assert.match(ledger, /payload\.classificationGroupDisplayName/);
  assert.match(ledger, /requestFailed/);
  assert.match(ledger, /gatewayOutcomeKnown/);
  assert.match(ledger, /noBackendCall/);
});

test("zero input/output with missing cache stays partial, never disappears as factual zero", async () => {
  const { buildChargebackWorkbook } = await import("../analytics/workbooks/chargeback.ts");
  const q = buildChargebackWorkbook(workbookAnswers(), card, ledger, groups).queries.totals;
  for (const category of ["cacheRead", "cacheWrite5m", "cacheWrite1h"]) {
    assert.match(q, new RegExp(`${category}TokensKnown and ${category}Tokens == 0`));
  }
  assert.doesNotMatch(q, /coalesce\(cacheReadTokens, 0\) == 0/);
});

test("unknown-price rows remain in token totals and request-ID dedup preserves retry attempts", async () => {
  const { buildChargebackWorkbook } = await import("../analytics/workbooks/chargeback.ts");
  const q = buildChargebackWorkbook(workbookAnswers(), card, ledger, groups).queries.totals;
  assert.match(q, /by gatewayResourceId, gatewayRequestId/);
  assert.match(q, /llmVariants = make_set\(llmSignature, 2\)/);
  assert.match(q, /traceVariants = make_set\(traceMessage, 2\)/);
  assert.match(q, /failedRequests = countif\(requestFailed\)/);
  assert.match(q, /unpricedRequests = countif\(pricingStatus == "unpriced"\)/);
});

test("Cloud Shell step2 builds reporting content and step3 refuses an empty replacement", () => {
  const wrapper = readFileSync(new URL("../infra/quickstart/Deploy-Quickstart.ps1", import.meta.url), "utf8");
  assert.match(wrapper, /function Get-QsWorkbookGroups/);
  assert.match(wrapper, /chargeback\.ts/);
  assert.match(wrapper, /workbook_content_required/);
  assert.match(wrapper, /workbookContentTags/);
});

test("shared renderer resolves every reporting filter using safe base64 without changing legacy callers", async () => {
  const { buildChargebackWorkbook } = await import("../analytics/workbooks/chargeback.ts");
  const { renderQuery } = await import("../analytics/workbooks/render.ts");
  const built = buildChargebackWorkbook(workbookAnswers(), card, ledger, groups);
  for (const query of Object.values(built.queries)) {
    const rendered = renderQuery(query, { period: "month", project: "*", from: null, to: null });
    assert.doesNotMatch(rendered, /\{(?:Group|Developer|Model|Project|Period|TimeRange)[:}]/);
  }
  const malicious = `x"; print "not-code`;
  const rendered = renderQuery(built.queries.usage, {
    period: "month", project: "*", from: null, to: null, model: malicious,
  });
  assert.ok(rendered.includes(Buffer.from(malicious).toString("base64")));
  assert.ok(!rendered.includes(malicious));
});

test("group totals cannot claim settled complete attribution using only a current baseline mapping", async () => {
  const { buildChargebackWorkbook } = await import("../analytics/workbooks/chargeback.ts");
  const built = buildChargebackWorkbook(workbookAnswers(), card, ledger, groups);
  assert.match(built.queries.groups, /groupUnverifiedRequests = countif\(groupAttribution != "request_group_id"\)/);
  assert.match(built.queries.groups, /historical_group_unverified/);
});

test("serialized artifact integrity refuses tampered full content and empty shells", async () => {
  const { buildChargebackWorkbook, verifyChargebackArtifact } = await import("../analytics/workbooks/chargeback.ts");
  const built = buildChargebackWorkbook(workbookAnswers(), card, ledger, groups);
  assert.equal(verifyChargebackArtifact({ parameters: built.parameters }), built.contentSha256);
  const tampered = structuredClone(built.parameters);
  tampered.workbookContent.value.items[0].content.json = "tampered";
  assert.throws(() => verifyChargebackArtifact({ parameters: tampered }), /content_digest_mismatch/);
  assert.throws(() => verifyChargebackArtifact({ parameters: { workbookContent: { value: {} } } }), /workbook_content_required/);
});

test("prefix-family reports stay independent while preserving trusted admission-family mismatch diagnostics", async () => {
  const { buildChargebackWorkbook } = await import("../analytics/workbooks/chargeback.ts");
  const built = buildChargebackWorkbook(workbookAnswers(), card, ledger, groups);
  assert.match(ledger, /payload\.modelFamily/);
  assert.match(built.queries.families, /familyAttribution = "model-prefix-reporting"/);
  assert.match(built.queries.diagnostics, /familyAdmissionMismatch/);
});

test("failure diagnostics retain even fully attributed requests with complete usage", async () => {
  const { buildChargebackWorkbook } = await import("../analytics/workbooks/chargeback.ts");
  const built = buildChargebackWorkbook(workbookAnswers(), card, ledger, groups);
  assert.match(built.queries.diagnostics, /\| where requestFailed or/);
  assert.match(built.queries.diagnostics, /requestFailed, gatewayOutcomeKnown/);
});
