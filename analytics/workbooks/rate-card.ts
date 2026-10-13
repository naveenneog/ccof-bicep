import { Decimal } from "decimal.js";

const Money = Decimal.clone({ precision: 60 });
export const categories = ["input", "output", "cacheWrite5m", "cacheWrite1h", "cacheRead"] as const;
type Category = typeof categories[number];
type Fields = Record<string, unknown>;

export interface RateRow {
  model: string;
  modelKey: string;
  effectiveFrom: string;
  effectiveTo: string | null;
  geo: string;
  promptTokensOver: number | null;
  promptTokensUpTo: number | null;
  countedCategories: string[];
  sourceDate: string;
  sourceUrl: string;
  rates: Record<Category, string>;
}

export interface CompiledCard {
  version: string;
  sourceDates: string[];
  rows: RateRow[];
  kql: string;
}

export function fields(value: unknown, name: string, required: string[], optional: string[] = []): Fields {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error(`${name}: object_required`);
  const object = value as Fields;
  for (const key of required) {
    if (!Object.hasOwn(object, key)) throw new Error(`${name}.${key}: required`);
  }
  for (const key of Object.keys(object)) {
    if (![...required, ...optional].includes(key)) throw new Error(`${name}: unknown_field`);
  }
  return object;
}

export function text(value: unknown, name: string): string {
  if (typeof value !== "string" || !value.trim() || /[\u0000-\u001f]/.test(value)) throw new Error(`${name}: nonempty_text_required`);
  return value;
}

export function positiveInteger(value: unknown, name: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) throw new Error(`${name}: positive_integer_required`);
  return value;
}

function array(value: unknown, name: string): unknown[] {
  if (!Array.isArray(value) || value.length === 0) throw new Error(`${name}: nonempty_array_required`);
  return value;
}

function decimalText(value: unknown, name: string): Decimal {
  if (typeof value !== "string" || !/^\d+(?:\.\d+)?$/.test(value) || !new Money(value).gt(0)) {
    throw new Error(`${name}: positive_decimal_string_required`);
  }
  const decimal = new Money(value);
  decimalLiteral(decimal, name);
  return decimal;
}

function decimalLiteral(value: Decimal, name: string): string {
  if (value.precision() > 28 || value.decimalPlaces() > 28 || value.abs().gte("1e28")) {
    throw new Error(`${name}: decimal_precision_exceeds_kql`);
  }
  return value.toFixed();
}

function utc(value: unknown, name: string): string {
  const result = text(value, name);
  if (!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,3})?Z$/.test(result)
    || !Number.isFinite(Date.parse(result))
    || new Date(result).toISOString().slice(0, 10) !== result.slice(0, 10)) {
    throw new Error(`${name}: utc_instant_required`);
  }
  return result;
}

function citation(value: unknown, name: string): { date: string; url: string } {
  const source = fields(value, name, ["url", "retrieved"], ["quote"]);
  const url = text(source.url, `${name}.url`);
  if (!URL.canParse(url) || new URL(url).protocol !== "https:" || new URL(url).username || new URL(url).password) {
    throw new Error(`${name}.url: https_source_required`);
  }
  const date = text(source.retrieved, `${name}.retrieved`);
  if (!/^\d{4}-\d\d-\d\d$/.test(date) || !Number.isFinite(Date.parse(date))
    || new Date(date).toISOString().slice(0, 10) !== date) throw new Error(`${name}.retrieved: date_required`);
  if (source.quote !== undefined) text(source.quote, `${name}.quote`);
  return { date, url };
}

function counted(value: unknown, tierCount: number, name: string): string[] {
  if (value === undefined && tierCount === 1) return [];
  const items = array(value, name);
  if (items.some(item => !categories.includes(item as Category)) || new Set(items).size !== items.length) {
    throw new Error(`${name}: distinct_token_categories_required`);
  }
  return items as string[];
}

function optionalMetadata(object: Fields, name: string): void {
  for (const key of ["description", "displayName"]) if (object[key] !== undefined) text(object[key], `${name}.${key}`);
  if (object.notes !== undefined) {
    if (!Array.isArray(object.notes)) throw new Error(`${name}.notes: string_array_required`);
    object.notes.forEach(value => text(value, `${name}.notes`));
  }
}

// This is a compiler for ADR-0011's file format, not a second runtime price source.
export function compileRateCard(value: unknown): CompiledCard {
  const card = fields(value, "rateCard", ["schemaVersion", "version", "rateUnit", "entries"], ["description", "notes"]);
  if (card.schemaVersion !== 1) throw new Error("rateCard.schemaVersion: must_be_1");
  optionalMetadata(card, "rateCard");
  const version = text(card.version, "rateCard.version");
  const unit = fields(card.rateUnit, "rateUnit", ["currency", "perTokens", "source"]);
  if (unit.currency !== "USD") throw new Error("rateUnit.currency: USD_required");
  const perTokens = positiveInteger(unit.perTokens, "rateUnit.perTokens");
  if (!Number.isInteger(Math.log10(perTokens))) throw new Error("rateUnit.perTokens: decimal_power_of_ten_required");
  const sourceDates = new Set([citation(unit.source, "rateUnit.source").date]);
  const intervals = new Map<string, Array<{ model: string; from: number; to: number }>>();
  const rows: RateRow[] = [];
  array(card.entries, "entries").forEach((raw, index) => {
    const name = `entries[${index}]`;
    const entry = fields(raw, name,
      ["model", "effectiveFrom", "effectiveTo", "source", "inferenceGeoMultipliers", "promptTiers"],
      ["displayName", "promptTokensCountedCategories", "notes"]);
    optionalMetadata(entry, name);
    const model = text(entry.model, `${name}.model`);
    const modelKey = model.toLowerCase().replace(/[^a-z0-9]/g, "");
    if (!modelKey) throw new Error(`${name}.model: alphanumeric_required`);
    const effectiveFrom = utc(entry.effectiveFrom, `${name}.effectiveFrom`);
    const effectiveTo = entry.effectiveTo === null ? null : utc(entry.effectiveTo, `${name}.effectiveTo`);
    const span = { model, from: Date.parse(effectiveFrom), to: effectiveTo === null ? Infinity : Date.parse(effectiveTo) };
    if (span.to <= span.from) throw new Error(`${name}.effectiveTo: must_follow_start`);
    const prior = intervals.get(modelKey) ?? [];
    if (prior.some(other => other.model !== model)) throw new Error(`${name}.model: ambiguous_model`);
    if (prior.some(other => span.from < other.to && other.from < span.to)) throw new Error(`${name}: overlapping_rate_intervals`);
    intervals.set(modelKey, [...prior, span]);
    const source = citation(entry.source, `${name}.source`);
    sourceDates.add(source.date);
    const geos = entry.inferenceGeoMultipliers;
    if (!geos || typeof geos !== "object" || Array.isArray(geos) || Object.keys(geos).length === 0) {
      throw new Error(`${name}.inferenceGeoMultipliers: nonempty_object_required`);
    }
    const multipliers = Object.entries(geos).map(([geo, multiplier]) => {
      if (!/^[a-z][a-z0-9_-]*$/.test(geo) || geo === "unknown") throw new Error(`${name}.inferenceGeoMultipliers: invalid_geo`);
      return { geo, multiplier: decimalText(multiplier, `${name}.inferenceGeoMultipliers`) };
    });
    const tiers = array(entry.promptTiers, `${name}.promptTiers`);
    const countedCategories = counted(entry.promptTokensCountedCategories, tiers.length, `${name}.promptTokensCountedCategories`);
    let previousUpper: number | null = null;
    tiers.forEach((rawTier, tierIndex) => {
      const tierName = `${name}.promptTiers[${tierIndex}]`;
      const tier = fields(rawTier, tierName, ["rates"], ["promptTokensOver", "promptTokensUpTo"]);
      const over = tier.promptTokensOver === undefined ? null : positiveInteger(tier.promptTokensOver, `${tierName}.promptTokensOver`);
      const upTo = tier.promptTokensUpTo === undefined ? null : positiveInteger(tier.promptTokensUpTo, `${tierName}.promptTokensUpTo`);
      if (over !== previousUpper || (tierIndex < tiers.length - 1 && upTo === null)
        || (tierIndex === tiers.length - 1 && upTo !== null) || (upTo !== null && over !== null && upTo <= over)) {
        throw new Error(`${tierName}: tier_partition`);
      }
      previousUpper = upTo;
      const sourceRates = fields(tier.rates, `${tierName}.rates`, [...categories]);
      const rates = Object.fromEntries(categories.map(category =>
        [category, decimalText(sourceRates[category], `${tierName}.rates.${category}`)])) as Record<Category, Decimal>;
      for (const { geo, multiplier } of multipliers) {
        rows.push({
          model, modelKey, effectiveFrom, effectiveTo, geo,
          promptTokensOver: over, promptTokensUpTo: upTo, countedCategories,
          sourceDate: source.date, sourceUrl: source.url,
          rates: Object.fromEntries(categories.map(category => [category,
            decimalLiteral(rates[category].mul(multiplier).mul(100).div(perTokens), `${tierName}.rates.${category}`),
          ])) as Record<Category, string>,
        });
      }
    });
  });
  const dates = [...sourceDates].sort();
  return { version, sourceDates: dates, rows, kql: datatable(version, dates, rows) };
}

export const kqlString = (value: string): string => JSON.stringify(value);

function datatable(version: string, sourceDates: string[], rows: RateRow[]): string {
  const date = (value: string | null) => `datetime(${value ?? "null"})`;
  const bound = (value: number | null) => value === null ? "long(null)" : String(value);
  const values = rows.map(row => [
    kqlString(row.modelKey), kqlString(row.model), date(row.effectiveFrom), date(row.effectiveTo),
    kqlString(row.geo), bound(row.promptTokensOver), bound(row.promptTokensUpTo),
    `dynamic(${JSON.stringify(row.countedCategories)})`,
    ...categories.map(category => `decimal(${row.rates[category]})`),
    date(row.sourceDate), kqlString(row.sourceUrl),
  ].join(", ")).join(",\n");
  return `let RateCardVersion = ${kqlString(version)};
let RateCardSourceDates = dynamic(${JSON.stringify(sourceDates)});
let RateCard = datatable(
  modelKey:string, rateModel:string, effectiveFrom:datetime, effectiveTo:datetime,
  rateGeo:string, tierOver:long, tierUpTo:long, countedCategories:dynamic,
  inputRate:decimal, outputRate:decimal, cacheWrite5mRate:decimal, cacheWrite1hRate:decimal, cacheReadRate:decimal,
  rateSourceDate:datetime, rateSourceUrl:string
)[
${values}
];`;
}
