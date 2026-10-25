// The admin console's removal-limit override (src/sync/removal-limits.ts): applied only while enabled,
// valid and unexpired; anything else falls back to the sync's app settings.

import { test } from "node:test";
import assert from "node:assert/strict";
import { effectiveRemovalLimits, removalLimitsProblems } from "../src/sync/removal-limits.ts";

const SETTINGS = { maxRemovalsPerRun: 5, maxRemovalFraction: 0.1 };
const NOW = new Date("2026-10-22T12:00:00.000Z");
const doc = (o: Record<string, unknown> = {}) => ({
  schemaVersion: 1, enabled: true, maxRemovalsPerRun: 500, maxRemovalFraction: "0.5", expiresAt: "2026-10-23T12:00:00.000Z",
  reason: "Reorganisation of business units", ...o,
});

test("an enabled, valid, unexpired override replaces the app settings", () => {
  const r = effectiveRemovalLimits(SETTINGS, { ok: true, doc: doc() }, NOW);
  assert.deepEqual(r, { limits: { maxRemovalsPerRun: 500, maxRemovalFraction: 0.5 }, source: "admin", reason: null, expiresAt: "2026-10-23T12:00:00.000Z" });
  assert.equal(effectiveRemovalLimits(SETTINGS, { ok: true, doc: doc({ expiresAt: null }) }, NOW).source, "admin", "no expiry is allowed");
});

test("absent, disabled, expired, invalid and unreadable overrides all fall back to the app settings", () => {
  const cases: [string, Parameters<typeof effectiveRemovalLimits>[1]][] = [
    ["override_absent", { ok: true, doc: null }],
    ["override_disabled", { ok: true, doc: doc({ enabled: false }) }],
    ["override_expired", { ok: true, doc: doc({ expiresAt: "2026-10-22T12:00:00.000Z" }) }],
    ["override_invalid", { ok: true, doc: doc({ maxRemovalFraction: 0.5 }) }],
    ["override_invalid", { ok: true, doc: doc({ maxRemovalsPerRun: -1 }) }],
    ["override_unreadable", { ok: false }],
  ];
  for (const [reason, read] of cases) {
    const r = effectiveRemovalLimits(SETTINGS, read, NOW);
    assert.deepEqual([r.source, r.reason, r.limits], ["settings", reason, SETTINGS], reason);
  }
});

test("field problems name the field, never the value", () => {
  assert.deepEqual(removalLimitsProblems(doc()), []);
  assert.deepEqual(removalLimitsProblems(doc({ schemaVersion: 2, enabled: "yes", maxRemovalsPerRun: 1.5, maxRemovalFraction: "1.5", expiresAt: "tomorrow", reason: "" })).sort(),
    ["enabled:invalid", "expiresAt:invalid", "maxRemovalFraction:invalid", "maxRemovalsPerRun:invalid", "reason:invalid", "schemaVersion:invalid"]);
  assert.deepEqual(removalLimitsProblems([]), ["document:not_an_object"]);
});
