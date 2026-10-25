// The gateway id list contract (DR-05): whatever pattern a caller passes, an accepted entry never
// holds a character that could end or split the KQL string literal the list is joined into.

import { test } from "node:test";
import assert from "node:assert/strict";
import { gatewayListProblem, splitGatewayList } from "../src/contracts/gateway-resource-ids.ts";

test("an entry with a comma, quote or backslash is invalid even when the caller's pattern would admit it", () => {
  const anything = /^.+$/;
  for (const entry of ["a,b", "a'b", 'a"b', "a\\b"]) {
    assert.equal(gatewayListProblem(["/ok", entry], anything), "invalid", entry);
  }
  assert.equal(gatewayListProblem(["/ok", "/also-ok"], anything), undefined);
});

test("a setting value splits on commas into trimmed entries, keeping an empty entry so it is refused", () => {
  assert.deepEqual(splitGatewayList(" a , b ,, "), ["a", "b", "", ""]);
});
