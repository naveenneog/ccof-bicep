// The budget period (docs/PILOT.md C-7, ADR-0018 decision 1). `monthly` is
// the only period a `projects` budget allows (C-5), and C-7 reads the
// ledger for the current UTC month. Half-open: [start, end).

export interface BudgetPeriod {
  // "YYYY-MM", the UTC month.
  label: string;
  start: Date;
  end: Date;
}

export function budgetPeriodAt(at: Date): BudgetPeriod {
  const ms = at.getTime();
  if (Number.isNaN(ms)) throw new RangeError("budgetPeriodAt needs a valid Date");
  const year = at.getUTCFullYear();
  const month = at.getUTCMonth();
  return {
    label: `${String(year).padStart(4, "0")}-${String(month + 1).padStart(2, "0")}`,
    start: new Date(Date.UTC(year, month, 1)),
    end: new Date(Date.UTC(year, month + 1, 1)),
  };
}

export function isInPeriod(period: BudgetPeriod, at: Date): boolean {
  const ms = at.getTime();
  return ms >= period.start.getTime() && ms < period.end.getTime();
}
