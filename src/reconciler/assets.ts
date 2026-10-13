// The files packaged with the reconciler, read once per host (docs/PILOT.md
// C-7: the rate card "is read once from the package"): WP-COST's rate card
// and contract schedule, validated by WP-COST's loaders, and WP-TEL's ledger
// function. A missing or invalid file is named; the run then refuses before
// any Azure call.

import { parseContractScheduleJson } from "../cost/contract-schedule.ts";
import { CostConfigError } from "../cost/errors.ts";
import { parseRateCardJson } from "../cost/rate-card.ts";
import type { RunAssets } from "./run.ts";
import type { SettingProblem } from "./settings.ts";

// Paths relative to the package root (the Function App's wwwroot).
export const ASSET_FILES = {
  rateCard: "config/rate-card.json",
  contractSchedule: "config/contract-schedule.json",
  ledgerKql: "analytics/ledger.kql",
} as const;

export type AssetsResult = { ok: true; assets: RunAssets } | { ok: false; problem: SettingProblem };

const LEDGER_FUNCTION = /\blet\s+CcofUsageLedger\s*=\s*\(/;

class AssetProblem extends Error {
  readonly problem: SettingProblem;
  constructor(path: string, problem: "unreadable" | "invalid") {
    super(problem);
    this.problem = { setting: `package:${path}`, problem };
  }
}

async function readText(read: (path: string) => Promise<string>, path: string): Promise<string> {
  try {
    return await read(path);
  } catch {
    throw new AssetProblem(path, "unreadable");
  }
}

function parsed<T>(path: string, parse: () => T): T {
  try {
    return parse();
  } catch (error) {
    if (error instanceof CostConfigError) throw new AssetProblem(path, "invalid");
    throw error;
  }
}

export async function loadRunAssets(read: (path: string) => Promise<string>): Promise<AssetsResult> {
  try {
    const cardText = await readText(read, ASSET_FILES.rateCard);
    const rateCard = parsed(ASSET_FILES.rateCard, () => parseRateCardJson(cardText));
    const scheduleText = await readText(read, ASSET_FILES.contractSchedule);
    const schedule = parsed(ASSET_FILES.contractSchedule, () => parseContractScheduleJson(scheduleText, rateCard));
    const ledgerKql = await readText(read, ASSET_FILES.ledgerKql);
    if (!LEDGER_FUNCTION.test(ledgerKql)) throw new AssetProblem(ASSET_FILES.ledgerKql, "invalid");
    return { ok: true, assets: { rateCard, schedule, ledgerKql } };
  } catch (error) {
    if (error instanceof AssetProblem) return { ok: false, problem: error.problem };
    throw error;
  }
}
