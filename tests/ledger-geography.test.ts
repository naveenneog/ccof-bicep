import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

test("body inference_geo not_available is treated as absent", () => {
  const source = readFileSync(new URL("../analytics/ledger.kql", import.meta.url), "utf8");
  assert.match(source, /bodyInferenceGeo\s*=\s*iff\(bodyUsageKnown\s+and\s+tostring\(usage\.inference_geo\)\s*!=\s*"not_available"/);
});
