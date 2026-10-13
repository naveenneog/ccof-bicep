import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { buildWorkbook } from "../analytics/workbooks/build.ts";
import { buildChargebackWorkbook } from "../analytics/workbooks/chargeback.ts";
import { workbookAnswers, workbookRateCard } from "./helpers/workbook-fixtures.ts";

// The portal sends timeContext durationMs 0 as PT0S, clipping all rows.
// Queries enforce their own period within the supported retained-history envelope.
const ledger = readFileSync(new URL("../analytics/ledger.kql", import.meta.url), "utf8");
const day = 86_400_000;

function assertWideWindows(items: { type: number; name?: string; content: Record<string, unknown> }[]) {
  const queries = items.filter(item => item.type === 3);
  assert.ok(queries.length > 0);
  for (const item of queries) {
    const context = item.content.timeContext as { durationMs?: number } | undefined;
    assert.ok(context && typeof context.durationMs === "number", `${item.name} has a time context`);
    assert.ok(context.durationMs! >= 730 * day, `${item.name} window ${context.durationMs} must not clip the query's own period`);
  }
}

test("workbook query items never send a zero-length portal timespan", () => {
  assertWideWindows(buildWorkbook(workbookAnswers(), workbookRateCard(), ledger).workbook.items as any);
});

test("chargeback workbook query items never send a zero-length portal timespan", () => {
  const rawCard = JSON.parse(readFileSync(new URL("../config/rate-card.json", import.meta.url), "utf8"));
  assertWideWindows(buildChargebackWorkbook(workbookAnswers(), rawCard, ledger, []).workbook.items as any);
});
