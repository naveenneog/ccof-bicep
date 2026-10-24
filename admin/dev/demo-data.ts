// Demo-only synthetic telemetry for the local V3 console (dev/serve.ts). NEVER packaged or used in Azure:
// Build-AdminPackage.ps1 ships dist/ (compiled from src/ only), ui-dist/, ui-dist-v3/ and kql/.
// It answers the same server-built V3 queries by view and validated filters (QueryMeta), so every
// server-side path (validation, KQL build and binding, caching, paging, shaping) still runs locally.
// Pricing follows the workbook's rules in miniature: a row priced only when a rate is in force for
// its model and geography; blank (null) is never shown as zero.

import type { LogTable, QueryMeta } from "../src/operations.ts";
import type { Doc } from "../src/validation.ts";

interface Rates { input: number; output: number; cacheRead: number; cacheWrite5m: number; cacheWrite1h: number }
interface Card { version: string; entries: { model: string; effectiveFrom: string; effectiveTo: string | null; inferenceGeoMultipliers: Record<string, string>; promptTiers: { rates: Record<string, string> }[] }[] }
export interface DemoGroup { projectId: string; classification: string; groupId: string; groupName: string; members: number; personBudgetUsd: number; groupBudgetUsd: number | null; backendId: string; models: string[] }
interface Row {
  at: number; projectId: string; classification: string; groupId: string; groupName: string; personId: string; model: string; family: string;
  backendId: string; geo: string; requests: number; input: number; output: number; cacheRead: number; cacheWrite5m: number; cacheWrite1h: number;
  failed: number; priced: boolean; reason: string | null; cost: Rates | null;
}

function rng(seed: number) {
  return () => { seed |= 0; seed = seed + 0x6d2b79f5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
}
const guid = (r: () => number) => "xxxxxxxx-xxxx-4xxx-8xxx-xxxxxxxxxxxx".replace(/x/g, () => Math.floor(r() * 16).toString(16));
const family = (model: string) => /^claude-(haiku|sonnet|opus|fable|mythos)/.exec(model)?.[1] ?? "unknown";
const usd = (n: number) => n.toFixed(6).replace(/\.?0+$/, "") || "0";

export function createDemoTelemetry(card: Card, groups: DemoGroup[], now = new Date()) {
  const r = rng(20261019);
  const people = new Map(groups.map((g) => [`${g.projectId}:${g.classification}`, Array.from({ length: g.members }, () => guid(r))]));
  const rateFor = (model: string, geo: string, at: number): Rates | null => {
    const e = card.entries.find((x) => x.model === model && Date.parse(x.effectiveFrom) <= at && (x.effectiveTo === null || Date.parse(x.effectiveTo) > at));
    const m = e?.inferenceGeoMultipliers[geo];
    if (!e || m === undefined) return null;
    const t = e.promptTiers[0].rates;
    const k = Number(m);
    return { input: Number(t.input) * k, output: Number(t.output) * k, cacheRead: Number(t.cacheRead) * k, cacheWrite5m: Number(t.cacheWrite5m) * k, cacheWrite1h: Number(t.cacheWrite1h) * k };
  };
  const rows: Row[] = [];
  // Usage starts three days before the rate card takes effect, so the demo shows unpriced rows (blank, not zero).
  const earliest = Math.min(...card.entries.map((e) => Date.parse(e.effectiveFrom)));
  const start = Math.max(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1), Math.floor(earliest / 86_400_000) * 86_400_000 - 3 * 86_400_000);
  for (let day = start; day < now.getTime(); day += 86_400_000) {
    const weekday = new Date(day).getUTCDay();
    const intensity = weekday === 0 || weekday === 6 ? 0.15 : 1;
    for (const g of groups) {
      const persons = people.get(`${g.projectId}:${g.classification}`) ?? [];
      persons.forEach((personId, pi) => {
        const heavy = pi === 0 ? 2.4 : pi === 1 ? 1.5 : 1;
        for (const model of g.models) {
          for (const hour of [9, 13, 16]) {
            const at = day + hour * 3_600_000 + Math.floor(r() * 3_000_000);
            if (at >= now.getTime() || r() > 0.82 * intensity + 0.05) continue;
            const scale = (family(model) === "haiku" ? 3 : family(model) === "opus" ? 0.35 : 1) * heavy * (0.4 + r() * 1.2);
            const input = Math.round(42_000 * scale), output = Math.round(9_000 * scale);
            const cacheRead = Math.round(input * (0.35 + r() * 0.3)), cacheWrite5m = Math.round(input * 0.08 * r()), cacheWrite1h = r() > 0.85 ? Math.round(input * 0.03) : 0;
            const geo = g.backendId === "foundry-swc" && family(model) === "haiku" && r() > 0.7 ? "us" : "global";
            const rate = rateFor(model, geo, at);
            const cost = rate ? { input: input * rate.input / 1e6, output: output * rate.output / 1e6, cacheRead: cacheRead * rate.cacheRead / 1e6, cacheWrite5m: cacheWrite5m * rate.cacheWrite5m / 1e6, cacheWrite1h: cacheWrite1h * rate.cacheWrite1h / 1e6 } : null;
            const reason = rate ? null : card.entries.some((x) => x.model === model && Date.parse(x.effectiveFrom) <= at) ? "geography_not_in_rate_card" : "no_rate_in_force";
            rows.push({ at, projectId: g.projectId, classification: g.classification, groupId: g.groupId, groupName: g.groupName, personId, model, family: family(model),
              backendId: g.backendId, geo, requests: 3 + Math.floor(r() * 30 * scale), input, output, cacheRead, cacheWrite5m, cacheWrite1h,
              failed: r() > 0.93 ? 1 : 0, priced: rate !== null, reason, cost });
          }
        }
      });
    }
  }

  function filterRows(f: Doc): Row[] {
    const period = f.period as { from: string; to: string };
    const a = Date.parse(period.from), b = Date.parse(period.to);
    return rows.filter((x) => x.at >= a && x.at < b && (!f.project || x.projectId === f.project) && (!f.group || x.groupId === f.group) &&
      (!f.developer || x.personId === f.developer) && (!f.model || x.model === f.model) && (!f.backend || x.backendId === f.backend) && (!f.family || x.family === f.family) &&
      (!f.classification || x.classification === f.classification) && (!Array.isArray(f.projectSet) || (f.projectSet as string[]).includes(x.projectId)));
  }

  function rollup(list: Row[], period: { from: string; to: string }): Doc {
    const sum = (k: keyof Row) => list.reduce((s, x) => s + (x[k] as number), 0);
    const priced = list.filter((x) => x.priced);
    const unpriced = list.length - priced.length;
    const c = (k: keyof Rates) => priced.reduce((s, x) => s + (x.cost?.[k] ?? 0), 0);
    const known = priced.length ? c("input") + c("output") + c("cacheRead") + c("cacheWrite5m") + c("cacheWrite1h") : null;
    const reqs = sum("requests");
    const cacheReadRate = (x: Row) => x.cost && x.cacheRead ? x.cost.cacheRead / x.cacheRead : 0;
    const savings = priced.reduce((s, x) => s + (x.cost ? x.cacheRead * ((x.cost.input / Math.max(1, x.input)) - cacheReadRate(x)) : 0), 0);
    return {
      requests: reqs, pricedRequests: priced.reduce((s, x) => s + x.requests, 0), partialRequests: 0,
      unpricedRequests: list.filter((x) => !x.priced).reduce((s, x) => s + x.requests, 0), unattributedRequests: 0,
      knownCostRequests: priced.reduce((s, x) => s + x.requests, 0), failedRequests: sum("failed"),
      inputTokens: sum("input"), outputTokens: sum("output"), cacheReadTokens: sum("cacheRead"), cacheWrite5mTokens: sum("cacheWrite5m"), cacheWrite1hTokens: sum("cacheWrite1h"),
      knownListCcu: known === null ? null : usd(known * 100), listCcu: known !== null && unpriced === 0 ? usd(known * 100) : null,
      knownListUsd: known === null ? null : usd(known), listUsd: known !== null && unpriced === 0 ? usd(known) : null,
      totalCostUsd: known !== null && unpriced === 0 ? usd(known) : null, knownTokenCostUsd: known === null ? null : usd(known),
      inputCostUsd: priced.length ? usd(c("input")) : null, outputCostUsd: priced.length ? usd(c("output")) : null,
      cacheReadCostUsd: priced.length ? usd(c("cacheRead")) : null, cacheWrite5mCostUsd: priced.length ? usd(c("cacheWrite5m")) : null,
      cacheWrite1hCostUsd: priced.length ? usd(c("cacheWrite1h")) : null,
      knownCacheReadSavingsUsd: priced.length ? usd(savings) : null,
      observedCacheHitRequestPercent: list.length ? 100 * list.filter((x) => x.cacheRead > 0).length / list.length : null,
      tokensSpent: sum("input") + sum("output") + sum("cacheRead") + sum("cacheWrite5m") + sum("cacheWrite1h"),
      completeness: unpriced > 0 ? "unpriced_usage" : "complete", currency: "USD",
      periodStart: period.from, periodEnd: period.to, basis: "fixed list price, not invoice", rateCardVersion: card.version, retentionTruncated: false,
    };
  }

  function grouped(list: Row[], key: (x: Row) => string, label: (k: string, sample: Row) => Doc, period: { from: string; to: string }) {
    const groupsMap = new Map<string, Row[]>();
    for (const x of list) { const k = key(x); groupsMap.set(k, [...(groupsMap.get(k) ?? []), x]); }
    return [...groupsMap.entries()].map(([k, l]) => ({ ...label(k, l[0]), ...rollup(l, period) }));
  }

  function table(rowsOut: Doc[], offset = 0, limit = rowsOut.length, bounded = true): LogTable {
    const page = rowsOut.slice(offset, offset + limit).map((x) => bounded ? { ...x, reportRows: rowsOut.length, displayedLimit: limit, truncated: rowsOut.length > offset + limit } : x);
    const names = [...new Set(page.flatMap((x) => Object.keys(x)))];
    if (!names.length) names.push("reportRows");
    return { columns: names.map((name) => ({ name, type: /Ccu$|Usd$/.test(name) ? "decimal" : "string" })), rows: page.map((x) => names.map((n) => x[n] ?? null)) };
  }
  const byCost = (a: Doc, b: Doc) => Number(b.knownListUsd ?? -1) - Number(a.knownListUsd ?? -1);

  function chargeback(view: string, f: Doc): LogTable {
    const list = filterRows(f);
    const period = f.period as { from: string; to: string };
    const offset = Number(f.offset ?? 0), limit = Number(f.limit ?? 100);
    switch (view) {
      case "totals": return table([{ ...rollup(list, period) }]);
      case "groups": return table(grouped(list, (x) => x.groupId, (k, s) => ({ groupId: k, groupNameSnapshots: [s.groupName], groupProjects: [s.projectId] }), period).sort(byCost), offset, limit);
      case "developers": return table(grouped(list, (x) => x.personId, (k) => ({ person: k }), period).sort(byCost), offset, limit);
      case "models": return table(grouped(list, (x) => x.model, (k) => ({ model: k }), period).sort(byCost), offset, limit);
      case "families": return table(grouped(list, (x) => x.family, (k) => ({ modelFamily: k }), period).sort(byCost), offset, limit);
      case "projects": return table(grouped(list, (x) => x.projectId, (k) => ({ projectLabel: k }), period).sort(byCost), offset, limit);
      case "classifications": return table(grouped(list, (x) => `${x.projectId}|${x.classification}`, (k) => ({ projectLabel: k.split("|")[0], classification: k.split("|")[1] }), period).sort(byCost), offset, limit);
      case "trend": {
        const bin = f.interval === "hour" ? 3_600_000 : 86_400_000;
        const out = grouped(list, (x) => `${Math.floor(x.at / bin) * bin}|${x.family}`, (k) => ({ bucket: new Date(Number(k.split("|")[0])).toISOString(), modelFamily: k.split("|")[1] }), period)
          .sort((a, b) => String(a.bucket).localeCompare(String(b.bucket)) || String(a.modelFamily).localeCompare(String(b.modelFamily)));
        return table(out, 0, 2000);
      }
      case "coverage": {
        const unpriced = list.filter((x) => !x.priced).reduce((s, x) => s + x.requests, 0);
        const latest = list.reduce((m, x) => Math.max(m, x.at), 0);
        return table([{
          observedRequests: list.reduce((s, x) => s + x.requests, 0), pricedRequests: list.filter((x) => x.priced).reduce((s, x) => s + x.requests, 0),
          partialRequests: 0, unpricedRequests: unpriced, unattributedRequests: 0,
          latestRequest: latest ? new Date(latest).toISOString() : null, latestIngested: latest ? new Date(latest + 240_000).toISOString() : null,
          requestToIngestSeconds: latest ? 240 : null,
          reportState: list.length === 0 ? "no_data_not_zero" : unpriced > 0 ? "incomplete" : "observed_token_usage_complete",
          noBackendCallRequests: 3, zeroTokenRequests: 1, noUsageRequests: 4, retentionTruncated: false,
          periodStart: period.from, periodEnd: period.to, asOfUtc: new Date().toISOString(),
          latestRequestAgeSeconds: latest ? Math.round((Date.now() - latest) / 1000) : null, rateCardVersion: card.version,
        }], 0, 1, false);
      }
      case "unpriced": {
        const out = list.filter((x) => !x.priced).sort((a, b) => b.at - a.at).map((x, i) => ({
          timestamp: new Date(x.at).toISOString(), gatewayRequestId: `demo-${x.at.toString(36)}-${i}`, person: x.personId, projectLabel: x.projectId,
          groupId: x.groupId, groupDisplayName: x.groupName, model: x.model, modelFamily: x.family, pricingStatus: "unpriced", pricingReason: x.reason,
          knownListCcu: null, listCcu: null, knownListUsd: null, inputTokens: x.input, outputTokens: x.output, cacheReadTokens: x.cacheRead,
          cacheWrite5mTokens: x.cacheWrite5m, cacheWrite1hTokens: x.cacheWrite1h, rateCardVersion: card.version,
        }));
        return table(out, offset, limit);
      }
      case "diagnostics": {
        const out = list.filter((x) => x.failed > 0).sort((a, b) => b.at - a.at).map((x, i) => ({
          timestamp: new Date(x.at).toISOString(), gatewayRequestId: `demo-f-${x.at.toString(36)}-${i}`, personId: x.personId, projectId: x.projectId,
          groupId: x.groupId, groupDisplayName: x.groupName, groupAttribution: "request_group_id", model: x.model, modelFamily: x.family,
          usageSource: "log", attributionKnown: true, requestFailed: true, gatewayOutcomeKnown: true, traceConflict: false, llmConflict: false,
          inputTokens: x.input, outputTokens: null, cacheReadTokens: null, cacheWrite5mTokens: null, cacheWrite1hTokens: null,
        }));
        return table(out, offset, limit);
      }
    }
    return table([]);
  }

  // Reconciler state, derived from the same synthetic ledger for the current month.
  const monthStart = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1);
  const computedAt = new Date(now.getTime() - 4 * 60_000).toISOString();
  const validUntil = new Date(now.getTime() + 11 * 60_000).toISOString();
  const runId = guid(r);
  function snapshotRows(): Doc[] {
    const month = rows.filter((x) => x.at >= monthStart);
    const out: Doc[] = [];
    const period = { period: new Date(monthStart).toISOString().slice(0, 7), periodStart: new Date(monthStart).toISOString(), periodEnd: new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1)).toISOString() };
    for (const g of groups) {
      const mine = month.filter((x) => x.projectId === g.projectId && x.classification === g.classification);
      const spend = (l: Row[]) => l.reduce((s, x) => s + (x.cost ? x.cost.input + x.cost.output + x.cost.cacheRead + x.cost.cacheWrite5m + x.cost.cacheWrite1h : 0), 0) * 100;
      const partial = mine.some((x) => !x.priced);
      const gs = spend(mine), gb = g.groupBudgetUsd === null ? null : g.groupBudgetUsd * 100;
      out.push({ scope: "group", scopeId: `${g.projectId}:${g.classification}`, projectId: g.projectId, classification: g.classification, personId: "", ...period,
        spentCcu: usd(gs), budgetCcu: gb === null ? null : usd(gb), budgetState: gb === null ? "no_cap" : gs >= gb ? "exhausted" : "available",
        exhausted: gb !== null && gs >= gb, mode: "strict", completeness: partial ? "partial" : "complete",
        pricedRequests: mine.filter((x) => x.priced).length, partialRequests: 0, unpricedRequests: mine.filter((x) => !x.priced).length,
        activeMemberCount: g.members, computedAt, validUntil, snapshotAgeSeconds: 240, eventDeliverySeconds: 35, snapshotState: "current",
        rateCardVersion: card.version, rateCardMismatch: false, runId });
      for (const personId of people.get(`${g.projectId}:${g.classification}`) ?? []) {
        const pl = mine.filter((x) => x.personId === personId);
        const ps = spend(pl), pb = g.personBudgetUsd * 100;
        out.push({ scope: "person", scopeId: `${personId}:${g.projectId}`, projectId: g.projectId, classification: g.classification, personId, ...period,
          spentCcu: usd(ps), budgetCcu: usd(pb), budgetState: ps >= pb ? "exhausted" : "available", exhausted: ps >= pb, mode: "strict",
          completeness: pl.some((x) => !x.priced) ? "partial" : "complete", pricedRequests: pl.filter((x) => x.priced).length, partialRequests: 0,
          unpricedRequests: pl.filter((x) => !x.priced).length, activeMemberCount: null, computedAt,
          validUntil: personId.startsWith("a") ? new Date(now.getTime() - 30 * 60_000).toISOString() : validUntil,
          snapshotAgeSeconds: 240, eventDeliverySeconds: 35, snapshotState: personId.startsWith("a") ? "expired" : "current",
          rateCardVersion: card.version, rateCardMismatch: false, runId });
      }
    }
    return out;
  }

  function reconciler(view: string, f: Doc): LogTable {
    if (view === "runs") {
      const at = (m: number) => new Date(now.getTime() - m * 60_000).toISOString();
      return table([
        { outcome: "written", reason: "", runs: 2120, latestRunAt: at(4), latestAgeSeconds: 240, runId, statesWritten: snapshotRows().length,
          personStates: snapshotRows().filter((x) => x.scope === "person").length, groupStates: groups.length, completeness: "partial",
          maxIngestionDelaySeconds: 212, unattributedRequests: 2, unattributedCcu: "4.21", unpricedRequests: rows.filter((x) => !x.priced && x.at >= monthStart).length,
          computedAt: at(4), validUntil: at(-11), logDeliverySeconds: 38 },
        { outcome: "skipped_lease_held", reason: "lease_held", runs: 14, latestRunAt: at(124), latestAgeSeconds: 7440, runId: guid(r), statesWritten: null,
          personStates: null, groupStates: null, completeness: "", maxIngestionDelaySeconds: null, unattributedRequests: null, unattributedCcu: null,
          unpricedRequests: null, computedAt: null, validUntil: null, logDeliverySeconds: 41 },
        { outcome: "failed", reason: "ledger_query_timeout", runs: 3, latestRunAt: at(60 * 27), latestAgeSeconds: 97200, runId: guid(r), statesWritten: 0,
          personStates: 0, groupStates: 0, completeness: "", maxIngestionDelaySeconds: null, unattributedRequests: null, unattributedCcu: null,
          unpricedRequests: null, computedAt: null, validUntil: null, logDeliverySeconds: 52 },
      ], 0, 50);
    }
    const all = snapshotRows().filter((x) => (!f.scope || x.scope === f.scope) && (!f.project || x.projectId === f.project) &&
      (!f.classification || x.classification === f.classification) && (!f.person || x.personId === f.person) &&
      (!f.state || x.snapshotState === f.state) && (!f.budgetState || x.budgetState === f.budgetState));
    const period = f.period as { mode: string };
    const list = period.mode === "month" || period.mode === "custom" ? all : [];
    if (view === "summary") {
      const keys = new Map<string, Doc[]>();
      for (const x of list) keys.set(`${x.scope}|${x.snapshotState}`, [...(keys.get(`${x.scope}|${x.snapshotState}`) ?? []), x]);
      return table([...keys.entries()].map(([k, l]) => ({
        scope: k.split("|")[0], snapshotState: k.split("|")[1], snapshots: l.length, exhausted: l.filter((x) => x.exhausted).length,
        partial: l.filter((x) => x.completeness === "partial").length, spentCcu: usd(l.reduce((s, x) => s + Number(x.spentCcu), 0)),
        budgetCcu: usd(l.reduce((s, x) => s + Number(x.budgetCcu ?? 0), 0)), uncapped: l.filter((x) => x.budgetCcu === null).length, latestComputedAt: computedAt,
      })), 0, 100, false);
    }
    const sorted = list.sort((a, b) => String(a.projectId).localeCompare(String(b.projectId)) || String(a.classification).localeCompare(String(b.classification)) ||
      String(a.scope).localeCompare(String(b.scope)) || String(a.scopeId).localeCompare(String(b.scopeId)));
    return table(sorted, Number(f.offset ?? 0), Number(f.limit ?? 100));
  }

  return {
    rows, people,
    query(meta: QueryMeta, audit: Doc[]): LogTable {
      if (meta.kind === "chargeback") return chargeback(meta.view, meta.filters);
      if (meta.kind === "reconciler") return reconciler(meta.view, meta.filters);
      const f = meta.filters;
      const list = audit.filter((x) => (!f.project || x.projectId === f.project) && (!f.actor || x.actorOid === f.actor) &&
        (!f.operation || x.operation === f.operation) && (!f.outcome || x.outcome === f.outcome) &&
        String(x.at) >= String(f.from) && String(x.at) < String(f.to)).sort((a, b) => String(b.at).localeCompare(String(a.at)));
      return table(list, Number(f.offset ?? 0), Number(f.limit ?? 50));
    },
    groupBudgetLines(): Doc[] {
      return snapshotRows().filter((x) => x.scope === "group").map((x) => ({ ...x, scopeId: x.scopeId, observedAt: computedAt }));
    },
  };
}
