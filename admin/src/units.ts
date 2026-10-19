// Exact unit conversions for rate cards and budgets, shared by the server and the V3 browser bundle.
// 100 CCU = USD 1 (src/cost/budget-units.ts), so converting is a decimal-point shift: no floating
// point and no rounding, ever. The stored canonical rate stays USD per rateUnit.perTokens, as
// src/cost/rate-card.ts parses it; CCU is a display and editing unit only.

export const DECIMAL_TEXT = /^\d{1,30}(?:\.\d{1,30})?$/;
export type RateUnit = "USD" | "CCU";

function normalize(intPart: string, fracPart: string): string {
  const i = intPart.replace(/^0+(?=\d)/, "") || "0";
  const f = fracPart.replace(/0+$/, "");
  return f ? `${i}.${f}` : i;
}

// Multiplies a non-negative decimal string by 10^places (places may be negative), exactly.
export function shiftDecimal(value: string, places: number): string {
  if (!DECIMAL_TEXT.test(value)) throw new Error("decimal_text_required");
  if (!Number.isInteger(places) || Math.abs(places) > 30) throw new Error("shift_out_of_range");
  const [intPart, fracPart = ""] = value.split(".");
  const digits = intPart + fracPart;
  const point = intPart.length + places;
  if (point <= 0) return normalize("0", "0".repeat(-point) + digits);
  if (point >= digits.length) return normalize(digits + "0".repeat(point - digits.length), "");
  return normalize(digits.slice(0, point), digits.slice(point));
}

export const usdToCcuText = (usd: string): string => shiftDecimal(usd, 2);
export const ccuToUsdText = (ccu: string): string => shiftDecimal(ccu, -2);

// A rate card rate (USD per rateUnit.perTokens) as USD or CCU per million tokens.
export function rateForDisplay(rateUsd: string, perTokens: number, unit: RateUnit): string {
  const exponent = Math.log10(perTokens);
  if (!Number.isInteger(exponent) || exponent < 0) throw new Error("perTokens_power_of_ten_required");
  const perMTok = shiftDecimal(rateUsd, 6 - exponent);
  return unit === "CCU" ? usdToCcuText(perMTok) : perMTok;
}

// The inverse: an edited per-million-token value back to the canonical stored USD rate.
export function rateFromDisplay(value: string, perTokens: number, unit: RateUnit): string {
  const exponent = Math.log10(perTokens);
  if (!Number.isInteger(exponent) || exponent < 0) throw new Error("perTokens_power_of_ten_required");
  const usdPerMTok = unit === "CCU" ? ccuToUsdText(value) : shiftDecimal(value, 0);
  return shiftDecimal(usdPerMTok, exponent - 6);
}
