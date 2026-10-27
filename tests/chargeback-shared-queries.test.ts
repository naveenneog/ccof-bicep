import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { workbookAnswers } from "./helpers/workbook-fixtures.ts";

// The admin console V3 and the chargeback workbook share one query builder
// (analytics/workbooks/chargeback-queries.ts). These digests were recorded from the workbook build
// before that refactor; matching them proves the refactor left the deployed workbook content and
// every query unchanged. A deliberate change to the report, ledger or rate card updates them.
const card = JSON.parse(readFileSync(new URL("../config/rate-card.json", import.meta.url), "utf8"));
const ledger = readFileSync(new URL("../analytics/ledger.kql", import.meta.url), "utf8");
const groups = [{ projectId: "P1", classification: "STD", groupId: "6f3a2c1e-4b5d-4e8f-9a0b-1c2d3e4f5a6b", displayName: "P1 std" }];
const sha = (s: string) => createHash("sha256").update(s).digest("hex");

test("the shared query builder leaves the chargeback and fixed-price workbooks byte-for-byte unchanged", async () => {
  const { buildChargebackWorkbook } = await import("../analytics/workbooks/chargeback.ts");
  const { buildWorkbook } = await import("../analytics/workbooks/build.ts");
  const chargeback = buildChargebackWorkbook(workbookAnswers(), card, ledger, groups);
  const workbook = buildWorkbook(workbookAnswers(), card, ledger);
  // Every digest below changed with the ledger: DR-05 (a list of gateways, one row per request id), then
  // 2026-10-27 (a client disconnect without a backend response is a failed request, ADR 0036).
  assert.equal(chargeback.contentSha256, "cc009b152294401c4532bf563398801ba2c7a618eca326c4b2e31da7d0a768ba");
  // ce48… before DR-05: budgets.kql reports the ADR 0035 "warning" state, and the layout text explains it.
  assert.equal(workbook.contentSha256, "ac93c43f7e82be04a22cd5dbbc3a6c7e427d5817834923c0bd6d7f985457ca55");
  assert.deepEqual(Object.fromEntries(Object.entries(chargeback.queries).map(([k, v]) => [k, sha(v as string)])), {
    health: "ba2ef2dc82f7b3f437d8110ddf8f2faf19f9bc30e45384c9284cdee4c31f75a5",
    developers: "8ada5522da69cf7303d59a6feb68e126cb8ae1d04d53f452239433950126e69c",
    usage: "f4168b36639f1a121b8532aca564ef1f9450eaf9a847108211df4cb18c680112",
    groups: "e8dd536c5382cd42d97130b6f63b23ffb5d02431df48d18a225a7014932a5626",
    models: "b13a62c7c06f393e089ac17447f939d06b3e1e99a49df1a0c7ef449b028c38b2",
    families: "5da59058693abe9ecc99dff0a4a9396176689d7eab33d7e82e9ab5a657c602fc",
    totals: "e9a78e32b0b53c4e977eec5b758cd477c1daaabd74e64df9dc7a83107585b00f",
    trends: "a839eb39ae226fb699e2754adc7927cc39dd20f558bff4bfa211f38090c4e0c8",
    diagnostics: "e0f6e73187c1bafd96c48637ba31513d0b488e5966b6a7292d9296d953087035",
    unpriced: "c30f7aedfffdf6db9eb9ad977266c3f27c0ccb2fab6c8bfa5e0f589a76835bf9",
  });
});
