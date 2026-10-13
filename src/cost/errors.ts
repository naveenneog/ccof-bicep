// Named errors for the cost configuration (ADR-0011 decision 2). Each one
// names the configuration field at fault as a path such as
// "entries[3].promptTiers[0].rates.cacheWrite1h" (owner rule, 2026-10-11).

export type CostConfigErrorCode =
  | "invalid_json"
  | "invalid_value"
  | "missing_field"
  | "unknown_field"
  | "unsupported_schema_version"
  | "missing_category"
  | "non_positive_rate"
  | "non_positive_multiplier"
  | "invalid_interval"
  | "overlapping_interval"
  | "tier_partition"
  | "ambiguous_model_key"
  | "invalid_discount"
  | "model_not_in_rate_card";

export class CostConfigError extends Error {
  readonly config: string;
  readonly field: string;
  readonly code: CostConfigErrorCode;

  constructor(config: string, field: string, code: CostConfigErrorCode, detail: string) {
    super(`${config}: ${field} ${detail} (${code})`);
    this.name = new.target.name;
    this.config = config;
    this.field = field;
    this.code = code;
  }
}

export class RateCardError extends CostConfigError {
  constructor(field: string, code: CostConfigErrorCode, detail: string) {
    super("rate card", field, code, detail);
  }
}

export class ContractScheduleError extends CostConfigError {
  constructor(field: string, code: CostConfigErrorCode, detail: string) {
    super("contract schedule", field, code, detail);
  }
}

export class BudgetConfigError extends CostConfigError {
  constructor(field: string, code: CostConfigErrorCode, detail: string) {
    super("budget", field, code, detail);
  }
}

// A ledger row handed to pricing is malformed (not merely incomplete: missing
// token counts are a pricing outcome, not an error).
export class UsageRowError extends Error {
  readonly field: string;

  constructor(field: string, detail: string) {
    super(`usage row: ${field} ${detail}`);
    this.name = "UsageRowError";
    this.field = field;
  }
}
