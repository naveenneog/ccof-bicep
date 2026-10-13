import { strict as assert } from "node:assert";
import { test } from "node:test";
import { gitBlobId, pilotRateCardGitBlob, pilotRateCardText, workbookRateCard } from "./helpers/workbook-fixtures.ts";

const load = () => import("../analytics/workbooks/rate-card.ts");

test("the WP-COST pilot card compiles to exact CCU per token, with the dated Haiku alias and prompt tiers", async () => {
  const { compileRateCard } = await load();
  const text = pilotRateCardText();
  assert.equal(gitBlobId(text), pilotRateCardGitBlob);
  const card = compileRateCard(JSON.parse(text));
  assert.equal(card.version, "2026-10-11");
  assert.deepEqual(card.sourceDates, ["2026-10-11"]);
  assert.equal(card.rows.length, 21);
  const row = (model: string, geo: string, tier = 0) => card.rows.filter(r => r.model === model && r.geo === geo)[tier];
  // USD per million tokens x 100 CCU per USD / 1,000,000 tokens, times the geography multiplier.
  assert.deepEqual(row("claude-sonnet-5", "global").rates,
    { input: "0.0002", output: "0.001", cacheWrite5m: "0.00025", cacheWrite1h: "0.0004", cacheRead: "0.00002" });
  assert.deepEqual(row("claude-opus-5-5", "us").rates,
    { input: "0.00044", output: "0.0022", cacheWrite5m: "0.00055", cacheWrite1h: "0.00088", cacheRead: "0.000022" });
  assert.equal(row("claude-haiku-4-5", "global").modelKey, "claudehaiku45");
  assert.equal(card.rows.filter(r => r.model === "claude-haiku-4-5").length, 1);
  assert.equal(row("claude-haiku-5-5", "global", 0).promptTokensUpTo, 100000);
  assert.equal(row("claude-haiku-5-5", "global", 1).promptTokensOver, 100000);
  assert.deepEqual(row("claude-haiku-5-5", "global", 1).rates,
    { input: "0.00005", output: "0.00025", cacheWrite5m: "0.0000625", cacheWrite1h: "0.0001", cacheRead: "0.000005" });
});

test("workbook card emits every model, effective interval, geo and tier at exact CCU per token", async () => {
  const { compileRateCard } = await load();
  const result = compileRateCard(workbookRateCard());
  assert.equal(result.version, "fixture-2026-10");
  assert.deepEqual(result.sourceDates, ["2026-10-01", "2026-10-02"]);
  assert.equal(result.rows.length, 4);
  assert.deepEqual(result.rows[0].rates, {
    input: "0.2", output: "1", cacheWrite5m: "0.25", cacheWrite1h: "0.4", cacheRead: "0.02",
  });
  assert.equal(result.rows[1].rates.input, "0.22");
  assert.equal(result.rows[0].modelKey, "modela");
  assert.equal(result.rows[2].promptTokensUpTo, 100);
  assert.equal(result.rows[3].promptTokensOver, 100);
  assert.deepEqual(result.rows[3].countedCategories, ["input", "cacheWrite5m", "cacheWrite1h", "cacheRead"]);
  assert.equal(result.rows[0].effectiveTo, null);
  assert.match(result.kql, /datatable\(/);
  assert.match(result.kql, /inputRate:decimal/);
  assert.match(result.kql, /decimal\(0\.22\)/);
  assert.match(result.kql, /datetime\(null\)/);
  assert.match(result.kql, /fixture-2026-10/);
  assert.match(result.kql, /2026-10-02/);
});

test("workbook card datatable is derived from the file, never an embedded model or price list", async () => {
  const { compileRateCard } = await load();
  const card = workbookRateCard();
  card.entries[0].model = "changed-served-model";
  card.entries[0].source.url = "https://example.invalid/changed-served-model";
  card.entries[0].promptTiers[0].rates.input = "7.123456789";
  card.rateUnit.perTokens = 1000000;
  const result = compileRateCard(card);
  assert.equal(result.rows[0].rates.input, "0.0007123456789");
  assert.match(result.kql, /changed-served-model/);
  assert.doesNotMatch(result.kql, /model-a/);
});

test("every generated rate-card datatable cell matches the source fixture", async () => {
  const { compileRateCard } = await load();
  const body = compileRateCard(workbookRateCard()).kql.split(")[\n")[1].split("\n];")[0];
  assert.equal(body, [
    '"modela", "model-a", datetime(2026-10-01T00:00:00Z), datetime(null), "global", long(null), long(null), dynamic([]), decimal(0.2), decimal(1), decimal(0.25), decimal(0.4), decimal(0.02), datetime(2026-10-01), "https://example.invalid/model-a"',
    '"modela", "model-a", datetime(2026-10-01T00:00:00Z), datetime(null), "us", long(null), long(null), dynamic([]), decimal(0.22), decimal(1.1), decimal(0.275), decimal(0.44), decimal(0.022), datetime(2026-10-01), "https://example.invalid/model-a"',
    '"modelb", "model-b", datetime(2026-10-01T00:00:00Z), datetime(null), "global", long(null), 100, dynamic(["input","cacheWrite5m","cacheWrite1h","cacheRead"]), decimal(0.1), decimal(0.5), decimal(0.125), decimal(0.2), decimal(0.01), datetime(2026-10-02), "https://example.invalid/model-b"',
    '"modelb", "model-b", datetime(2026-10-01T00:00:00Z), datetime(null), "global", 100, long(null), dynamic(["input","cacheWrite5m","cacheWrite1h","cacheRead"]), decimal(0.2), decimal(1), decimal(0.25), decimal(0.4), decimal(0.02), datetime(2026-10-02), "https://example.invalid/model-b"',
  ].join(",\n"));
});

test("workbook card permits adjacent rate intervals but refuses an overlapping or ambiguous model", async () => {
  const { compileRateCard } = await load();
  const card = workbookRateCard();
  const older = structuredClone(card.entries[0]);
  older.effectiveFrom = "2026-09-01T00:00:00Z";
  (older as { effectiveTo: string | null }).effectiveTo = "2026-10-01T00:00:00Z";
  card.entries.push(older);
  assert.equal(compileRateCard(card).rows.length, 6);
  (older as { effectiveTo: string | null }).effectiveTo = null;
  assert.throws(() => compileRateCard(card), /overlapping_rate_intervals/);
  const ambiguous = workbookRateCard();
  ambiguous.entries[1].model = "MODEL.A";
  assert.throws(() => compileRateCard(ambiguous), /ambiguous_model/);
});

type CardMutation = (card: any) => void;
const invalidCards: Array<[string, CardMutation, RegExp]> = [
  ["schema", c => { c.schemaVersion = 2; }, /schemaVersion/],
  ["version missing", c => { delete c.version; }, /version/],
  ["unknown field", c => { c.secret = "not-allowed"; }, /unknown_field/],
  ["empty entries", c => { c.entries = []; }, /entries/],
  ["currency", c => { c.rateUnit.currency = "CCU"; }, /currency/],
  ["unit zero", c => { c.rateUnit.perTokens = 0; }, /perTokens/],
  ["non-terminating unit", c => { c.rateUnit.perTokens = 3; }, /perTokens/],
  ["model empty", c => { c.entries[0].model = "---"; }, /model/],
  ["source missing", c => { delete c.entries[0].source; }, /source/],
  ["source protocol", c => { c.entries[0].source.url = "http://example.invalid/rate"; }, /source/],
  ["source date", c => { c.entries[0].source.retrieved = "2026-02-30"; }, /retrieved/],
  ["non UTC date", c => { c.entries[0].effectiveFrom = "2026-10-01"; }, /effectiveFrom/],
  ["reversed dates", c => { c.entries[0].effectiveTo = "2026-09-01T00:00:00Z"; }, /effectiveTo/],
  ["geo missing", c => { c.entries[0].inferenceGeoMultipliers = {}; }, /inferenceGeoMultipliers/],
  ["geo unknown sentinel", c => { c.entries[0].inferenceGeoMultipliers.unknown = "1"; }, /inferenceGeoMultipliers/],
  ["geo zero", c => { c.entries[0].inferenceGeoMultipliers.global = "0"; }, /positive_decimal/],
  ["missing category", c => { delete c.entries[0].promptTiers[0].rates.cacheRead; }, /cacheRead/],
  ["number rate", c => { c.entries[0].promptTiers[0].rates.input = 2; }, /positive_decimal/],
  ["zero rate", c => { c.entries[0].promptTiers[0].rates.input = "0"; }, /positive_decimal/],
  ["negative rate", c => { c.entries[0].promptTiers[0].rates.input = "-2"; }, /positive_decimal/],
  ["malformed rate", c => { c.entries[0].promptTiers[0].rates.input = "1); print bad=1"; }, /positive_decimal/],
  ["excess precision", c => { c.entries[0].promptTiers[0].rates.input = "0.00000000000000000000000000001"; }, /decimal_precision/],
  ["tier gap", c => { c.entries[1].promptTiers[1].promptTokensOver = 101; }, /tier_partition/],
  ["tier overlap", c => { c.entries[1].promptTiers[1].promptTokensOver = 99; }, /tier_partition/],
  ["unbounded first tier", c => { delete c.entries[1].promptTiers[0].promptTokensUpTo; }, /tier_partition/],
  ["missing counted categories", c => { delete c.entries[1].promptTokensCountedCategories; }, /promptTokensCountedCategories/],
  ["invalid counted category", c => { c.entries[1].promptTokensCountedCategories = ["made-up"]; }, /promptTokensCountedCategories/],
  ["duplicate counted category", c => { c.entries[1].promptTokensCountedCategories = ["input", "input"]; }, /promptTokensCountedCategories/],
];

for (const [name, mutate, reason] of invalidCards) {
  test(`workbook card refuses ${name}`, async () => {
    const { compileRateCard } = await load();
    const card = workbookRateCard();
    mutate(card);
    assert.throws(() => compileRateCard(card), reason);
  });
}

test("workbook KQL string encoding contains quotes and line breaks inside one literal", async () => {
  const { kqlString } = await load();
  assert.equal(kqlString('a";\nprint injected=1\\x'), '"a\\";\\nprint injected=1\\\\x"');
});
