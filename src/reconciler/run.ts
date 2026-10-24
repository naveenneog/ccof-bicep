// One reconciler run (docs/PILOT.md C-7, ADR-0018): lease → registry →
// ledger → price and compute (pure) → write every state → one run line.
// Every dependency is injected, so the whole run is tested with fakes
// (tests/reconciler-run.test.ts); function-app.ts wires Cosmos and the Log
// Analytics query API. Nothing is written unless every read succeeded.

import type { ContractSchedule } from "../cost/contract-schedule.ts";
import type { RateCard } from "../cost/rate-card.ts";
import type { AggregateBudgetStateDocument, BudgetStateDocument } from "./documents.ts";
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
import type { ReconcilerSettings, SettingProblem } from "./settings.ts";
import { groupBudgetLine, personBudgetLine, runLine } from "./telemetry.ts";
import type { LineContext, RunLine } from "./telemetry.ts";

export interface RunDependencies {
  leases: LeaseStore;
  readProjects(): Promise<unknown[]>;
  readEntitlements(): Promise<unknown[]>;
  // Returns the query API's JSON body and the age of a cached answer; throws LedgerReadError on a failed call.
  queryLedger(query: string, timespan: string): Promise<LedgerAnswer>;
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
  const query = await step("ledger_query_invalid", async () => buildLedgerQuery(assets.ledgerKql, period, settings.gatewayResourceId));
  const answer = await step("ledger_read_failed", () => deps.queryLedger(query, `${period.start.toISOString()}/${period.end.toISOString()}`));
  const rows = await step("ledger_read_failed", async () =>
    parseLedgerResponse(answer.body, settings.ledgerMaxRows).map((row) => classifyRow(row, period, assets.rateCard, assets.schedule)),
  );
  timings.registryReadMs = t1 - t0;
  timings.ledgerReadMs = now().getTime() - t1;
  // Null: a fresh answer. A number: the query API served a cached answer that many seconds old (WP-E2E G6).
  timings.ledgerResponseAgeSeconds = answer.responseAgeSeconds;
  const registry = readRegistry(projects, entitlements);
  const result = reconcile({ registry, rows, rateCard: assets.rateCard, contractScheduleVersion: assets.schedule.version, period, computedAt, validUntil, pacing: settings.pacing });
  return { registry, result };
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
  let written = 0;
  try {
    planned = await readAndCompute(settings, assets, deps, { period, computedAt, validUntil }, timings, context.now);
    const { result } = planned;
    if (result.persons.length + result.groups.length > settings.maxStates) throw new Failure("state_limit_exceeded");
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
    const failure = error instanceof Failure ? error : new Failure("run_failed", error);
    summary = { runId, outcome: "failed", reason: failure.reason, errorCode: errorCodeOf(failure.cause) };
  } finally {
    await lease.release().catch(() => false);
  }
  return finish({ ...summary, ...(planned ? describe(planned) : {}), statesWritten: written });
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
