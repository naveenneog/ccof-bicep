// The five token categories Anthropic prices separately (docs/MARKETPLACE-COST.md
// §2, ADR-0005). These names are the rate card's field names; the rates
// themselves live in config/rate-card.json.

export const TOKEN_CATEGORIES = ["input", "cacheWrite5m", "cacheWrite1h", "cacheRead", "output"] as const;

export type TokenCategory = (typeof TOKEN_CATEGORIES)[number];

export function isTokenCategory(value: unknown): value is TokenCategory {
  return typeof value === "string" && (TOKEN_CATEGORIES as readonly string[]).includes(value);
}
