// Template mechanics for the gateway policy: %%NAME%% placeholders and the
// scanner that keeps environment values out of the template files (AC2).
//
// Placeholder values are either validated scalars (ids, URLs, header names,
// integers) or XML the renderer generated itself. Scalars are checked again
// here against a character set that is safe in an XML attribute, XML text and a
// C# string literal, so a value cannot break out of the place it is put even if
// it bypassed configuration validation.

export const PLACEHOLDER = /%%([A-Z][A-Z0-9_]*)%%/g;

export type TemplateValue = string | { xml: string };

const SAFE_SCALAR = /^[A-Za-z0-9._:/~-]*$/;

export function placeholdersIn(text: string): string[] {
  return [...text.matchAll(PLACEHOLDER)].map((m) => m[1]);
}

export function fillPlaceholders(text: string, values: Readonly<Record<string, TemplateValue>>, fileName: string): string {
  return text.replace(PLACEHOLDER, (_, name: string) => {
    if (!Object.hasOwn(values, name)) throw new Error(`${fileName}: unknown placeholder %%${name}%%`);
    const value = values[name];
    if (typeof value !== "string") return value.xml;
    if (!SAFE_SCALAR.test(value)) throw new Error(`${fileName}: value for %%${name}%% is unsafe to place in a policy`);
    return value;
  });
}

const GUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
const URL_LITERAL = /\b(?:https?|api):\/\//i;
// Lower-case host names: environment hosts are lower case, and C# namespaces
// such as System.Net are not.
const HOST_NAME = /\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|net|org|io|us|cn|de|ms|test|local|internal)\b/;
const NAMED_VALUE = /\{\{(?!%%[A-Z][A-Z0-9_]*%%\}\})[^}]*\}\}/;
// Attributes that carry limits, TTLs or timeouts: a placeholder or an
// expression only, never a number written into the template.
const LIMIT_ATTRIBUTES = ["calls", "renewal-period", "max-count", "timeout", "duration", "tokens-per-minute", "token-quota", "clock-skew", "increment-count"];
const LIMIT_LITERAL = new RegExp(`\\s(${LIMIT_ATTRIBUTES.join("|")})="\\s*\\d`);

export function findTemplateLiterals(text: string, fileName: string): string[] {
  const problems: string[] = [];
  text.split(/\r?\n/).forEach((line, i) => {
    const at = `${fileName}:${i + 1}`;
    if (GUID.test(line)) problems.push(`${at}: GUID literal`);
    if (URL_LITERAL.test(line)) problems.push(`${at}: URL literal`);
    if (HOST_NAME.test(line)) problems.push(`${at}: host name literal`);
    if (NAMED_VALUE.test(line)) problems.push(`${at}: named value reference not taken from configuration`);
    const limit = LIMIT_LITERAL.exec(line);
    if (limit) problems.push(`${at}: literal ${limit[1]} value`);
  });
  return problems;
}
