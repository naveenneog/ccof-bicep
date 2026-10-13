// Model-name matching (ADR-0011 decision 3). Names on the wire differ from
// the rate card's spelling: the reference repository measured
// "claude-haiku-4-5-20251001" on the wire against a book entry
// "claude-haiku-4.5" (accel/analytics/chargeback-cost.kql, 2026-09-17).
// Models before the 4.6 generation carry a trailing YYYYMMDD snapshot date
// (https://platform.claude.com/docs/en/about-claude/models/model-ids-and-versions,
// retrieved 2026-10-11). Matching lower-cases a name and keeps only letters
// and digits; a name that still finds nothing is retried without a trailing
// calendar date.

const NON_ALPHANUMERIC = /[^a-z0-9]/g;
const TRAILING_DATE = /^(.+?)20\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])$/;

export function modelKey(name: string): string {
  return name.toLowerCase().replace(NON_ALPHANUMERIC, "");
}

export function undatedModelKey(key: string): string | null {
  const match = TRAILING_DATE.exec(key);
  return match ? match[1] : null;
}
