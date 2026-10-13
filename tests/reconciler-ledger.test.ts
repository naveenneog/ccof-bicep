// The ledger read (docs/PILOT.md C-7, ADR-0010): the KQL sent to the Log
// Analytics query API and the checks on its response. A failed, partial or
// malformed response is an error, never "no usage" (ADR-0014).

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { LEDGER_COLUMNS, LedgerReadError, buildLedgerQuery, parseLedgerResponse } from "../src/reconciler/ledger.ts";
import { budgetPeriodAt } from "../src/reconciler/period.ts";

const LEDGER_KQL = readFileSync(new URL("../analytics/ledger.kql", import.meta.url), "utf8");
const APIM = "/subscriptions/00000000-0000-4000-8000-000000000110/resourceGroups/sample-pilot-rg/providers/Microsoft.ApiManagement/service/sample-pilot-apim";
const OCTOBER = budgetPeriodAt(new Date("2026-10-11T13:00:00Z"));

const recorded = (name: string): unknown =>
  JSON.parse(readFileSync(new URL(`./fixtures/reconciler/${name}`, import.meta.url), "utf8"));

function response(rows: unknown[][], columns: readonly string[] = LEDGER_COLUMNS): Record<string, unknown> {
  return { tables: [{ name: "PrimaryResult", columns: columns.map((name) => ({ name, type: "string" })), rows }] };
}

function rowValues(overrides: Record<string, unknown> = {}): unknown[] {
  const base: Record<string, unknown> = {
    timestamp: "2026-10-11T12:00:00Z",
    ingestedAt: "2026-10-11T12:01:00Z",
    gatewayRequestId: "00000000-0000-4000-8000-000001101011",
    personId: "00000000-0000-4000-8000-000001100001",
    projectId: "CCOFPILOT01",
    classification: "STD",
    attributionKnown: true,
    model: "claude-haiku-4-5-20251001",
    inference_geo: "unknown",
    inputTokens: 14,
    outputTokens: 4,
    cacheWrite5mTokens: null,
    cacheWrite1hTokens: null,
    cacheReadTokens: null,
    ...overrides,
  };
  return LEDGER_COLUMNS.map((column) => base[column]);
}

test("the query is WP-TEL's ledger function invoked over the half-open UTC month for one gateway", () => {
  const query = buildLedgerQuery(LEDGER_KQL, OCTOBER, APIM);
  assert.ok(query.startsWith(LEDGER_KQL), "the ledger function text is used unchanged");
  assert.ok(
    query.includes(`CcofUsageLedger(datetime(2026-10-01T00:00:00.000Z), datetime(2026-11-01T00:00:00.000Z), '${APIM}')`),
    query.slice(LEDGER_KQL.length),
  );
  assert.ok(query.trimEnd().endsWith(`| where usageSource != "no-backend-call"\n| project ${LEDGER_COLUMNS.join(", ")}`), query.slice(LEDGER_KQL.length));
});

test("requests refused before any backend call are filtered in the query, so they never count toward the row limit (council finding)", () => {
  const query = buildLedgerQuery(LEDGER_KQL, OCTOBER, APIM);
  assert.equal(query.split('| where usageSource != "no-backend-call"').length - 1, 1);
});

test("the query refuses a gateway id that could break out of its KQL string literal", () => {
  for (const id of [`${APIM}'`, `${APIM}' | take 1 //`, "/subscriptions/x/resourceGroups/rg/providers/Microsoft.ApiManagement/service/a\\b"]) {
    assert.throws(() => buildLedgerQuery(LEDGER_KQL, OCTOBER, id), /gateway resource id/);
  }
});

test("the query refuses a ledger text that does not define CcofUsageLedger (a packaging defect)", () => {
  assert.throws(() => buildLedgerQuery("ApiManagementGatewayLlmLog | take 1", OCTOBER, APIM), /CcofUsageLedger/);
});

test("a response recorded from sample-pilot-law on 2026-10-11 parses into one record per row, keyed by column", () => {
  const rows = parseLedgerResponse(recorded("ledger-response-2026-10-11.json"), 100000);
  assert.ok(rows.length > 0);
  for (const row of rows) assert.deepEqual(Object.keys(row).sort(), [...LEDGER_COLUMNS].sort());
});

test("columns are matched by name, whatever order the service returns them in", () => {
  const reversed = [...LEDGER_COLUMNS].reverse();
  const values = rowValues();
  const byName = Object.fromEntries(LEDGER_COLUMNS.map((c, i) => [c, values[i]]));
  const [row] = parseLedgerResponse(response([reversed.map((c) => byName[c])], reversed), 10);
  assert.equal(row.model, "claude-haiku-4-5-20251001");
  assert.equal(row.inputTokens, 14);
});

test("a PartialError (HTTP 200 with an error property) fails the read: truncated data is not usage", () => {
  const body = { ...response([rowValues()]), error: { code: "PartialError", message: "query exceeded limits" } };
  assert.throws(() => parseLedgerResponse(body, 10), (e: unknown) => e instanceof LedgerReadError && e.reason === "ledger_partial_result");
});

test("a row count at the configured limit fails the read rather than risk a silently truncated period", () => {
  const body = response([rowValues(), rowValues(), rowValues()]);
  assert.throws(() => parseLedgerResponse(body, 3), (e: unknown) => e instanceof LedgerReadError && e.reason === "ledger_row_limit_reached");
  assert.equal(parseLedgerResponse(body, 4).length, 3);
});

test("an empty table is a valid answer: no usage yet in the period", () => {
  assert.deepEqual(parseLedgerResponse(response([]), 10), []);
});

test("a malformed response fails the read: no tables, no PrimaryResult, a missing column, a ragged row", () => {
  const missingColumn = LEDGER_COLUMNS.filter((c) => c !== "cacheReadTokens");
  const malformed: Array<[string, unknown]> = [
    ["not an object", "<html>"],
    ["no tables", {}],
    ["tables not an array", { tables: {} }],
    ["no PrimaryResult", { tables: [{ name: "Other", columns: [], rows: [] }] }],
    ["missing column", response([missingColumn.map(() => null)], missingColumn)],
    ["ragged row", response([rowValues().slice(1)])],
    ["row not an array", { tables: [{ name: "PrimaryResult", columns: LEDGER_COLUMNS.map((name) => ({ name })), rows: [{}] }] }],
  ];
  for (const [label, body] of malformed) {
    assert.throws(() => parseLedgerResponse(body, 10), (e: unknown) => e instanceof LedgerReadError && e.reason === "ledger_response_invalid", label);
  }
});
