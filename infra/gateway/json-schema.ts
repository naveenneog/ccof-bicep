// A small JSON Schema interpreter for the gateway configuration
// (infra/gateway/gateway-config.schema.json). It supports only the keywords in
// SUPPORTED and refuses a schema that uses any other, so the schema file
// cannot silently depend on a feature this code ignores. Problems are reported
// with a JSON path, for example `entra.audiences[1]`.

export type JsonSchema = { [keyword: string]: unknown };

const ANNOTATIONS = new Set(["$comment", "$schema", "$id", "$defs", "title", "description"]);
const SUPPORTED = new Set([
  "$ref", "type", "properties", "required", "additionalProperties", "propertyNames",
  "pattern", "enum", "const", "minimum", "maximum", "minLength", "maxLength",
  "items", "minItems", "maxItems", "uniqueItems",
]);

type JsonType = "object" | "array" | "string" | "integer" | "number" | "boolean" | "null";

function typeOf(value: unknown): JsonType | "undefined" {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  if (typeof value === "number") return Number.isInteger(value) ? "integer" : "number";
  if (typeof value === "string" || typeof value === "boolean" || typeof value === "object") return typeof value as JsonType;
  return "undefined";
}

function matchesType(value: unknown, expected: string): boolean {
  const actual = typeOf(value);
  return actual === expected || (expected === "number" && actual === "integer");
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function childPath(path: string, key: string | number): string {
  if (typeof key === "number") return `${path}[${key}]`;
  return path === "" ? key : `${path}.${key}`;
}

// Throws for a schema that uses a keyword outside SUPPORTED: a schema error is
// a defect in this repository, not in the administrator's configuration.
export function assertSupportedSchema(schema: unknown, where = "#"): void {
  if (!isObject(schema)) throw new Error(`schema at ${where} is not an object`);
  for (const [keyword, value] of Object.entries(schema)) {
    if (ANNOTATIONS.has(keyword)) {
      if (keyword === "$defs" && isObject(value)) {
        for (const [name, def] of Object.entries(value)) assertSupportedSchema(def, `${where}/$defs/${name}`);
      }
      continue;
    }
    if (!SUPPORTED.has(keyword)) throw new Error(`schema at ${where} uses unsupported keyword "${keyword}"`);
    if (keyword === "properties" && isObject(value)) {
      for (const [name, sub] of Object.entries(value)) assertSupportedSchema(sub, `${where}/properties/${name}`);
    } else if ((keyword === "items" || keyword === "propertyNames") && isObject(value)) {
      assertSupportedSchema(value, `${where}/${keyword}`);
    } else if (keyword === "additionalProperties" && isObject(value)) {
      assertSupportedSchema(value, `${where}/additionalProperties`);
    }
  }
}

function resolveRef(root: JsonSchema, ref: string): JsonSchema {
  const match = /^#\/\$defs\/([A-Za-z0-9_-]+)$/.exec(ref);
  const defs = root.$defs;
  if (!match || !isObject(defs) || !isObject(defs[match[1]])) throw new Error(`schema $ref "${ref}" does not resolve`);
  return defs[match[1]] as JsonSchema;
}

export function validateAgainstSchema(root: JsonSchema, value: unknown): string[] {
  const problems: string[] = [];
  visit(root, root, value, "", problems);
  return problems;
}

function visit(root: JsonSchema, schema: JsonSchema, value: unknown, path: string, problems: string[]): void {
  const at = path === "" ? "(root)" : path;
  if (typeof schema.$ref === "string") visit(root, resolveRef(root, schema.$ref), value, path, problems);

  if (schema.type !== undefined) {
    const allowed = Array.isArray(schema.type) ? (schema.type as string[]) : [schema.type as string];
    if (!allowed.some((t) => matchesType(value, t))) {
      problems.push(`${at}: expected ${allowed.join(" or ")}, got ${value === undefined ? "nothing" : typeOf(value)}`);
      return;
    }
  }
  if ("const" in schema && value !== schema.const) problems.push(`${at}: must be ${JSON.stringify(schema.const)}`);
  if (Array.isArray(schema.enum) && !schema.enum.includes(value as never)) {
    problems.push(`${at}: must be one of ${schema.enum.map((v) => JSON.stringify(v)).join(", ")}`);
  }

  if (typeof value === "string") checkString(schema, value, at, problems);
  if (typeof value === "number") checkNumber(schema, value, at, problems);
  if (Array.isArray(value)) checkArray(root, schema, value, path, problems);
  if (isObject(value)) checkObject(root, schema, value, path, problems);
}

function checkString(schema: JsonSchema, value: string, at: string, problems: string[]): void {
  if (typeof schema.minLength === "number" && value.length < schema.minLength) problems.push(`${at}: shorter than ${schema.minLength}`);
  if (typeof schema.maxLength === "number" && value.length > schema.maxLength) problems.push(`${at}: longer than ${schema.maxLength}`);
  if (typeof schema.pattern === "string" && !new RegExp(schema.pattern, "u").test(value)) {
    problems.push(`${at}: does not match ${schema.pattern}`);
  }
}

function checkNumber(schema: JsonSchema, value: number, at: string, problems: string[]): void {
  if (typeof schema.minimum === "number" && value < schema.minimum) problems.push(`${at}: below the minimum ${schema.minimum}`);
  if (typeof schema.maximum === "number" && value > schema.maximum) problems.push(`${at}: above the maximum ${schema.maximum}`);
}

function checkArray(root: JsonSchema, schema: JsonSchema, value: unknown[], path: string, problems: string[]): void {
  const at = path === "" ? "(root)" : path;
  if (typeof schema.minItems === "number" && value.length < schema.minItems) problems.push(`${at}: needs at least ${schema.minItems} item(s)`);
  if (typeof schema.maxItems === "number" && value.length > schema.maxItems) problems.push(`${at}: allows at most ${schema.maxItems} item(s)`);
  if (schema.uniqueItems === true) {
    const seen = new Set(value.map((v) => JSON.stringify(v)));
    if (seen.size !== value.length) problems.push(`${at}: items must be unique`);
  }
  if (isObject(schema.items)) value.forEach((item, i) => visit(root, schema.items as JsonSchema, item, childPath(path, i), problems));
}

function checkObject(root: JsonSchema, schema: JsonSchema, value: Record<string, unknown>, path: string, problems: string[]): void {
  const properties = isObject(schema.properties) ? (schema.properties as Record<string, JsonSchema>) : {};
  if (Array.isArray(schema.required)) {
    for (const name of schema.required as string[]) {
      if (!Object.hasOwn(value, name)) problems.push(`${childPath(path, name)}: is required`);
    }
  }
  for (const [name, child] of Object.entries(value)) {
    if (isObject(schema.propertyNames)) visit(root, schema.propertyNames as JsonSchema, name, childPath(path, name), problems);
    if (Object.hasOwn(properties, name)) {
      visit(root, properties[name], child, childPath(path, name), problems);
    } else if (schema.additionalProperties === false) {
      problems.push(`${childPath(path, name)}: is not a known setting`);
    } else if (isObject(schema.additionalProperties)) {
      visit(root, schema.additionalProperties as JsonSchema, child, childPath(path, name), problems);
    }
  }
}
