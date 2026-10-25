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
  assert.equal(chargeback.contentSha256, "100f393e18730b997101bbc1cc7f50e4863c4c8eb7079204252c9c33551e80f4");
  // ce48…: budgets.kql reports the ADR 0035 "warning" state, and the layout text explains it.
  assert.equal(workbook.contentSha256, "ce4881593dfbcc22ba6214b3ca04fc624a315ed4419406a67a47e8c6a016a441");
  assert.deepEqual(Object.fromEntries(Object.entries(chargeback.queries).map(([k, v]) => [k, sha(v as string)])), {
    health: "591561b2327edcd657b8dbf813aec9eb9459542a5ddbbe7d713e73183aa00090",
    developers: "33a31a7d9dfa4c54992228ae161b18ae3a5586671f052f204040b9ca54094944",
    usage: "b47221f3eec4a6973cd3d39231bad2a664f30e27471e9fe2b6a2adb10b9087fa",
    groups: "7c86856f161fa04568bf93d5b2fe9d26124a6673acc9a01654dd52deed0d15b9",
    models: "8189f06c2963d0ff29d4e0b0d13d1e2ff988a8393b1ea463b4edd645b9678e9e",
    families: "223586465a491e8ba4e2947775d494a7424cda1ef8455d34aaa90e6d6b6a5a0e",
    totals: "7a0a86e967c32b745535c08616db9f1cc282d8e1bc86697b41263a320543457a",
    trends: "a8bf09f4ae2bd38b9517a785c086b01160055197e7ca4459a57fd612c3675cdf",
    diagnostics: "37bb7e6e132391e20a9255bd4a4c7ee12479c5c2f5c4550a93b719a2b460f58a",
    unpriced: "9c9995436f9a508a2fa98994ee4902dff02b642f0afb6fd43a8baceeeb8e3ca9",
  });
});
