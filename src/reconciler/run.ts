// One reconciler run (docs/PILOT.md C-7, ADR-0018): lease → registry →
// ledger → price and compute (pure) → [continuity gate, DR-05R, only when
// on] → write every state → one run line.
// Every dependency is injected, so the whole run is tested with fakes
// (tests/reconciler-run.test.ts); function-app.ts wires Cosmos and the Log
// Analytics query API. Nothing is written unless every read succeeded.

import type { ContractSchedule } from "../cost/contract-schedule.ts";
import type { RateCard } from "../cost/rate-card.ts";
import type { AggregateBudgetStateDocument, BudgetStateDocument } from "./documents.ts";
import { buildContinuityQuery, compareSpend, coverageBaselineIssue, effectiveCoverageStartAt, parseContinuityResponse, plannedStates } from "./continuity.ts";
import { LeaseLostError, acquireLease } from "./lease.ts";
import type { Lease, LeaseStore } from "./lease.ts";
import { LedgerReadError, buildLedgerQuery, parseLedgerResponse } from "./ledger.ts";
import type { LedgerAnswer } from "./ledger.ts";
import { budgetPeriodAt } from "./period.ts";
import type { BudgetPeriod } from "./period.ts";
import { classifyRow } from "./price-rows.ts";
import { reconcile } from "./reconcile.ts";
import type { ReconcileResult } from "./reconcile.ts";
import { readRegistry } from "./registry.ts";
import type { Registry } from "./registry.ts";
import type { ContinuityGate, ReconcilerSettings, SettingProblem } from "./settings.ts";
import { groupBudgetLine, personBudgetLine, runLine } from "./telemetry.ts";
import type { LineContext, RunLine } from "./telemetry.ts";

export interface RunDependencies {
  leases: LeaseStore;
  readProjects(): Promise<unknown[]>;
  readEntitlements(): Promise<unknown[]>;
  // Returns the query API's JSON body and the age of a cached answer; throws LedgerReadError on a failed call.
  queryLedger(query: string, timespan: string): Promise<LedgerAnswer>;
  // Point reads of the persisted states (null when absent); used only by the continuity gate (DR-05).
  readBudgetState(id: string, personId: string): Promise<unknown>;
  readAggregateState(id: string): Promise<unknown>;
  writeBudgetState(doc: BudgetStateDocument): Promise<void>;
  writeAggregateState(doc: AggregateBudgetStateDocument): Promise<void>;
}

export interface RunContext {
  now: () => Date;
  newRunId: () => string;
  log: (line: string) => void;
}

export interface RunAssets {
  rateCard: RateCard;
  schedule: ContractSchedule;
  ledgerKql: string;
}

const ERROR_CODE = /^[A-Za-z0-9_.-]{1,40}$/;

function errorCodeOf(error: unknown): string | undefined {
  if (error instanceof LedgerReadError) return error.code;
  const value = typeof error === "object" && error !== null ? ((error as { code?: unknown }).code ?? (error as { statusCode?: unknown }).statusCode) : undefined;
  const code = value === undefined ? (error instanceof Error ? error.name : undefined) : String(value);
  return code !== undefined && ERROR_CODE.test(code) ? code : undefined;
}

class Failure extends Error {
  readonly reason: string;
  readonly cause: unknown;
  constructor(reason: string, cause?: unknown) {
    super(reason);
    this.reason = reason;
    this.cause = cause;
  }
}

// A write failure after `written` states were written.
class WriteFailure extends Failure {
  readonly written: number;
  constructor(reason: string, cause: unknown, written: number) {
    super(reason, cause);
    this.written = written;
  }
}

// The continuity gate refused the run (DR-05): no write, outcome "refused".
class Refusal extends Failure {
  readonly fields: Record<string, unknown>;
  constructor(reason: string, fields: Record<string, unknown>) {
    super(reason);
    this.fields = fields;
  }
}

async function step<T>(reason: string, work: () => Promise<T>): Promise<T> {
  try {
    return await work();
  } catch (error) {
    if (error instanceof Failure) throw error;
    throw new Failure(error instanceof LedgerReadError ? error.reason : reason, error);
  }
}

function problemCodes(result: Pick<ReconcileResult, "problems">): string[] {
  return result.problems.map((p) =>
    [p.code, p.projectId, p.classification, "field" in p ? p.field : undefined, "personId" in p ? p.personId : undefined].filter((v) => v !== undefined).join(":"),
  );
}

// A missing or invalid setting: one run line naming them, no Azure call.
export function settingsFailure(problems: readonly SettingProblem[], context: RunContext): void {
  context.log(
    runLine({ runId: context.newRunId(), outcome: "settings_invalid", reason: "settings_invalid", problems: problems.map((p) => `${p.setting}:${p.problem}`) }),
  );
}

interface Planned {
  registry: Registry;
  result: ReconcileResult;
}

interface RunClock {
  period: BudgetPeriod;
  computedAt: Date;
  validUntil: Date;
}

async function readAndCompute(settings: ReconcilerSettings, assets: RunAssets, deps: RunDependencies, clock: RunClock, timings: Record<string, number | null>, now: () => Date): Promise<Planned> {
  const { period, computedAt, validUntil } = clock;
  const t0 = now().getTime();
  const [projects, entitlements] = await step("registry_read_failed", () => Promise.all([deps.readProjects(), deps.readEntitlements()]));
  const t1 = now().getTime();
  const query = await step("ledger_query_invalid", async () => buildLedgerQuery(assets.ledgerKql, period, settings.gatewayResourceIds));
  const answer = await step("ledger_read_failed", () => deps.queryLedger(query, `${period.start.toISOString()}/${period.end.toISOString()}`));
  const rows = await step("ledger_read_failed", async () =>
    parseLedgerResponse(answer.body, settings.ledgerMaxRows).map((row) => classifyRow(row, period, assets.rateCard, assets.schedule)),
  );
  timings.registryReadMs = t1 - t0;
  timings.ledgerReadMs = now().getTime() - t1;
  // Null: a fresh answer. A number: the query API served a cached answer that many seconds old (WP-E2E G6).
  timings.ledgerResponseAgeSeconds = answer.responseAgeSeconds;
  const registry = readRegistry(projects, entitlements);
  const result = reconcile({
    registry,
    rows,
    rateCard: assets.rateCard,
    contractScheduleVersion: assets.schedule.version,
    period,
    computedAt,
    validUntil,
    pacing: settings.pacing,
    ledgerCoverageStartAt: settings.continuity ? effectiveCoverageStartAt(period, settings.continuity.coverageStartAt) : undefined,
  });
  return { registry, result };
}

// At most this many scope ids are logged for spend_would_decrease; the count is always logged.
const LOGGED_SCOPES_MAX = 20;

async function readPersisted(planned: Planned, deps: RunDependencies, concurrency: number): Promise<Map<string, unknown>> {
  const reads: Array<[string, () => Promise<unknown>]> = [
    ...planned.result.persons.map(({ doc }) => [`person:${doc.id}`, () => deps.readBudgetState(doc.id, doc.personId)] as [string, () => Promise<unknown>]),
    ...planned.result.groups.map(({ doc }) => [`group:${doc.id}`, () => deps.readAggregateState(doc.id)] as [string, () => Promise<unknown>]),
  ];
  const persisted = new Map<string, unknown>();
  let next = 0;
  const worker = async (): Promise<void> => {
    while (next < reads.length) {
      const [key, read] = reads[next++];
      persisted.set(key, await read());
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, reads.length) }, worker));
  return persisted;
}

// The ledger continuity gate (DR-05R, continuity.ts). Returns the run-line fields; throws a Refusal
// when the gate refuses, and a Failure when a read fails. Writes nothing.
async function checkContinuity(gate: ContinuityGate, settings: ReconcilerSettings, deps: RunDependencies, planned: Planned, clock: RunClock): Promise<Record<string, unknown>> {
  const { period, computedAt } = clock;
  const coverageStartAt = await step("ledger_query_invalid", async () => effectiveCoverageStartAt(period, gate.coverageStartAt));
  const fields: Record<string, unknown> = {
    continuityGate: "refused",
    continuityCoverageStartAt: coverageStartAt,
    continuityGaps: [],
  };
  const refuse = (reason: string, extra: Record<string, unknown>): never => {
    Object.assign(fields, extra);
    throw new Refusal(reason, fields);
  };
  if (Date.parse(coverageStartAt) > computedAt.getTime()) {
    refuse("ledger_coverage_start_future", { continuityCondition: "coverage_start_future" });
  }
  const query = await step("ledger_query_invalid", async () => buildContinuityQuery(period, settings.gatewayResourceIds, coverageStartAt));
  const answer = await step("ledger_read_failed", () => deps.queryLedger(query, `${period.start.toISOString()}/${period.end.toISOString()}`));
  const gaps = await step("ledger_read_failed", async () => parseContinuityResponse(answer.body));
  fields.continuityGaps = gaps.map((gap) => ({
    gatewayResourceId: gap.gatewayResourceId,
    gapKind: gap.gapKind,
    issueCount: gap.issueCount,
    firstAt: gap.firstAt.toISOString(),
  }));
  if (gaps.length > 0) {
    const issueCount = gaps.reduce((sum, gap) => sum + gap.issueCount, 0);
    refuse("ledger_continuity_gap", { continuityCondition: gaps[0].gapKind, continuityGapCount: issueCount });
  }
  const persisted = await step("budget_state_read_failed", () => readPersisted(planned, deps, settings.writeConcurrency));
  const states = plannedStates(planned.result.persons, planned.result.groups);
  const baselineIssue = await step("budget_state_read_failed", async () => coverageBaselineIssue(states, persisted, period, coverageStartAt));
  if (baselineIssue) refuse(baselineIssue, { continuityCondition: baselineIssue });
  if (planned.result.counts.unattributedRequests > 0) {
    refuse("ledger_attribution_missing", { unattributedRequests: planned.result.counts.unattributedRequests });
  }
  const { persistedSpendNonZero, decreasedScopes } = await step("budget_state_read_failed", async () => compareSpend(states, persisted, period));
  fields.persistedSpendNonZero = persistedSpendNonZero;
  if (decreasedScopes.length > 0) {
    refuse("spend_would_decrease", { decreasedScopes: decreasedScopes.slice(0, LOGGED_SCOPES_MAX), decreasedScopeCount: decreasedScopes.length });
  }
  fields.continuityGate = "passed";
  return fields;
}

// Writes every state with bounded concurrency; the lease is checked before
// each write, and the first failure stops further writes.
async function writeStates(planned: Planned, deps: RunDependencies, lease: Lease, concurrency: number, lines: LineContext, log: (line: string) => void): Promise<number> {
  const { registry, result } = planned;
  const work: Array<() => Promise<string>> = [
    ...result.persons.map(({ doc, tally }) => async () => {
      await deps.writeBudgetState(doc);
      return personBudgetLine(lines, doc, tally);
    }),
    ...result.groups.map(({ doc, tally }) => async () => {
      await deps.writeAggregateState(doc);
      const scope = registry.scopes.get(doc.scopeId);
      if (scope === undefined) throw new Error("scope_missing");
      return groupBudgetLine(lines, doc, scope, tally);
    }),
  ];
  let next = 0;
  let written = 0;
  let failure: unknown;
  const worker = async (): Promise<void> => {
    while (failure === undefined && next < work.length) {
      const item = work[next++];
      try {
        await lease.ensure();
        log(await item());
        written += 1;
      } catch (error) {
        failure ??= error;
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, work.length) }, worker));
  if (failure !== undefined) throw new WriteFailure(failure instanceof LeaseLostError ? "lease_lost" : "state_write_failed", failure, written);
  return written;
}

export async function runReconciler(settings: ReconcilerSettings, assets: RunAssets, deps: RunDependencies, context: RunContext): Promise<RunLine> {
  const runId = context.newRunId();
  const computedAt = context.now();
  const period = budgetPeriodAt(computedAt);
  const validUntil = new Date(computedAt.getTime() + settings.validitySeconds * 1000);
  const base = {
    runId,
    period: period.label,
    periodStart: period.start.toISOString(),
    periodEnd: period.end.toISOString(),
    rateCardVersion: assets.rateCard.version,
    contractScheduleVersion: assets.schedule.version,
    computedAt: computedAt.toISOString(),
    validUntil: validUntil.toISOString(),
  };
  const timings: Record<string, number | null> = {};
  const finish = (line: RunLine): RunLine => {
    const done: RunLine = { ...base, ...line, ...timings, durationMs: context.now().getTime() - computedAt.getTime() };
    context.log(runLine(done));
    return done;
  };

  let acquired: Awaited<ReturnType<typeof acquireLease>>;
  try {
    acquired = await acquireLease(deps.leases, { holder: runId, leaseSeconds: settings.leaseSeconds, now: context.now });
  } catch (error) {
    return finish({ runId, outcome: "failed", reason: "lease_unavailable", errorCode: errorCodeOf(error) });
  }
  if (!acquired.acquired) return finish({ runId, outcome: "skipped_lease_held", reason: "lease_held", heldBy: acquired.heldBy, leaseExpiresAt: acquired.leaseExpiresAt });
  const { lease } = acquired;

  let summary: RunLine;
  let planned: Planned | undefined;
  let continuity: Record<string, unknown> = {};
  let written = 0;
  try {
    planned = await readAndCompute(settings, assets, deps, { period, computedAt, validUntil }, timings, context.now);
    const { result } = planned;
    if (result.persons.length + result.groups.length > settings.maxStates) throw new Failure("state_limit_exceeded");
    if (settings.continuity !== null) {
      continuity = { continuityGate: "read_failed" };
      continuity = await checkContinuity(settings.continuity, settings, deps, planned, { period, computedAt, validUntil });
    }
    const writeStart = context.now().getTime();
    const lines: LineContext = { runId, period, rateCardVersion: assets.rateCard.version };
    try {
      written = await writeStates(planned, deps, lease, settings.writeConcurrency, lines, context.log);
    } catch (error) {
      if (error instanceof WriteFailure) written = error.written;
      throw error;
    } finally {
      timings.writeMs = context.now().getTime() - writeStart;
    }
    summary = { runId, outcome: "written", reason: null };
  } catch (error) {
    if (error instanceof Refusal) {
      continuity = error.fields;
      summary = { runId, outcome: "refused", reason: error.reason };
    } else {
      const failure = error instanceof Failure ? error : new Failure("run_failed", error);
      summary = { runId, outcome: "failed", reason: failure.reason, errorCode: errorCodeOf(failure.cause) };
    }
  } finally {
    await lease.release().catch(() => false);
  }
  return finish({ ...summary, ...(planned ? describe(planned) : {}), ...continuity, statesWritten: written });
}

function describe({ result }: Planned): Record<string, unknown> {
  const { counts } = result;
  const lowerBound = counts.partialRequests + counts.unpricedRequests + counts.unattributedRequests > 0;
  return {
    ...counts,
    unattributedCcu: result.unattributedCcu.toFixed(),
    unpricedReasons: result.unpricedReasons,
    personStates: result.persons.length,
    groupStates: result.groups.length,
    exhaustedPersons: result.persons.filter((p) => p.doc.exhausted).length,
    exhaustedGroups: result.groups.filter((g) => g.doc.exhausted).length,
    completeness: lowerBound ? "partial" : "complete",
    maxIngestionDelaySeconds: result.maxIngestionDelaySeconds,
    newestIngestedAt: result.newestIngestedAt,
    newestRowIngestionDelaySeconds: result.newestRowIngestionDelaySeconds,
    problems: problemCodes(result),
  };
}
