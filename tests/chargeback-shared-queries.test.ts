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
  // DR-05 changed the ledger (a list of gateways, one row per request id), so every digest below changed.
  assert.equal(chargeback.contentSha256, "dc37a1320c3b3b4ed63486ccb33b25d281913ebacd0b1e61208dd7cb3f9c5783");
  // ce48… before DR-05: budgets.kql reports the ADR 0035 "warning" state, and the layout text explains it.
  assert.equal(workbook.contentSha256, "cfb7ebe8a3a184256d79ce864508384749dfc2726c71caed4e9697a429374d2c");
  assert.deepEqual(Object.fromEntries(Object.entries(chargeback.queries).map(([k, v]) => [k, sha(v as string)])), {
    health: "a5216c22ff9ddb21aaca226f32b4a44a0ab0c8ef4bf69c2a78e8662df237b984",
    developers: "efc2d2890001b3d08cc8d4f386d5f7856eed696962b6d21e974ad2bf10f5c9ac",
    usage: "0f97c42dd68d439ca5013f5b8d0e0d450357f3a6cc95ec0b9c23248416e18212",
    groups: "aa796800662a77bb86f4aa11c5d1768af5ff890058d78cea02aa48031add53fe",
    models: "889f33572673d07c0ea8a835586e222aa7dfc51a94d4e6b2ba3a070c8fc0a159",
    families: "bc7968bc0634f8d0fa581f80a1e0538eb1e8fc653e8017c2a23487dc10ccbca1",
    totals: "8bf750270cd32f26e7246a99c4a2b6d63565cbb327e1010a76fa5b16a9f054e2",
    trends: "53c506b866c2592833ac589b6e6866c9bc56b0364cc467ed163c95e3ae9ef375",
    diagnostics: "3153f340edecef03f75221cfacac3c15eab10ac888081d6ffaa7e1c95e689d79",
    unpriced: "012c2df67cecb76018de5f92bc35d5a5942e56eefeb3eb52490b7eb5c273e552",
  });
});
