// Runs the on-error section of a rendered gateway policy for one error, as API Management would,
// so a test can check the answer a given context.LastError gets: status, reason phrase, headers,
// body, traces, and any outgoing call.
//
// The section's expressions are C#. The simulator runs the subset they use: string, number and
// boolean values; == != && || ! ?: ??; if, switch and return; StartsWith(..., Ordinal), EndsWith,
// Contains, ToLowerInvariant, Convert.ToString; JObject and JProperty; DateTime.UtcNow.ToString("o")
// (a fixed time). It evaluates every variable, condition, trace message, status, header and body it
// meets. Any other construct is left as it is and fails to run, and reading a variable that was never
// set throws (APIM's KeyNotFoundException), so an expression the simulator does not understand fails
// the test.

import { runInNewContext } from "node:vm";

import type { XmlElement } from "../../infra/gateway/apim-xml.ts";
import { attr, textOf } from "../../infra/gateway/apim-xml.ts";

export interface GatewayError {
  source: string | null;
  reason: string | null;
  policyId?: string | null;
  section?: string | null;
  message?: string;
  // context.Response.StatusCode when on-error starts.
  statusCode: number;
  variables?: Record<string, unknown>;
  method?: string;
  path?: string;
}

export interface GatewayAnswer {
  status: number;
  reason: string;
  // Lower-case header names.
  headers: Record<string, string>;
  body: string | null;
  // The source of each trace written, and each trace's evaluated message, in order.
  traces: string[];
  traceMessages: string[];
  // Policies that send a request out of the gateway, in the order they ran.
  calls: string[];
}

const OUTGOING = new Set(["forward-request", "send-request", "send-one-way-request", "log-to-eventhub"]);
const STRING_LITERAL = /"(?:[^"\\\n]|\\.)*"/g;

export function toJavaScript(csharp: string): string {
  const literals: string[] = [];
  let code = csharp.replace(STRING_LITERAL, (s) => `__s${literals.push(s) - 1}__`);
  const literal = "(__s\\d+__)";
  const rules: Array<[RegExp, string]> = [
    [/\((?:string|int|long|bool)\)\s*(?=[A-Za-z_(])/g, ""],
    [/\bGetValueOrDefault<(?:string|int|long|bool)>\(/g, "GetValueOrDefault("],
    [/\bvar\b/g, "let"],
    [/\bstring(?=\s+[A-Za-z_]\w*\s*[=;])/g, "let"],
    [new RegExp(`\\.StartsWith\\(${literal}, StringComparison\\.Ordinal\\)`, "g"), ".startsWith($1)"],
    [new RegExp(`\\.EndsWith\\(${literal}\\)`, "g"), ".endsWith($1)"],
    [new RegExp(`\\.Contains\\(${literal}\\)`, "g"), ".includes($1)"],
    [/\.ToLowerInvariant\(\)/g, ".toLowerCase()"],
    [/\.ToString\(Newtonsoft\.Json\.Formatting\.None\)/g, ".ToString()"],
    [new RegExp(`\\bDateTime\\.UtcNow\\.ToString\\(${literal}\\)`, "g"), "__utcNow($1)"],
  ];
  for (const [pattern, replacement] of rules) code = code.replace(pattern, replacement);
  return code.replace(/__s(\d+)__/g, (_, i: string) => literals[Number(i)]);
}

class JProperty {
  name: string;
  value: unknown;
  constructor(name: string, value: unknown) {
    this.name = name;
    this.value = value;
  }
}

class JObject {
  properties: JProperty[];
  constructor(...properties: JProperty[]) {
    this.properties = properties;
  }
  toJSON(): Record<string, unknown> {
    return Object.fromEntries(this.properties.map((p) => [p.name, p.value]));
  }
  ToString(): string {
    return JSON.stringify(this);
  }
}

function variableStore(initial: Record<string, unknown>) {
  const values = new Map(Object.entries(initial));
  const methods: Record<string, unknown> = {
    GetValueOrDefault: (name: string, fallback: unknown) => (values.has(name) ? values.get(name) : fallback),
    ContainsKey: (name: string) => values.has(name),
  };
  const view = new Proxy({}, {
    get(_, key) {
      if (typeof key !== "string") return undefined;
      if (Object.hasOwn(methods, key)) return methods[key];
      if (!values.has(key)) throw new Error(`KeyNotFoundException: context.Variables["${key}"] was never set`);
      return values.get(key);
    },
  });
  return { values, view };
}

const elementsOf = (el: XmlElement) => el.children.filter((n): n is XmlElement => n.kind === "element");

export function simulateOnError(onError: XmlElement, error: GatewayError, requestId: string): GatewayAnswer {
  const { values, view } = variableStore(error.variables ?? {});
  const sandbox = {
    context: {
      LastError: {
        Source: error.source,
        Reason: error.reason,
        Message: error.message ?? "",
        Section: error.section ?? null,
        PolicyId: error.policyId ?? null,
        Scope: null,
        Path: null,
      },
      Response: { StatusCode: error.statusCode },
      Request: { Method: error.method ?? "POST", Url: { Path: error.path ?? "/" } },
      RequestId: { ToString: () => requestId },
      Variables: view,
    },
    JObject,
    JProperty,
    Convert: { ToString: (v: unknown) => String(v) },
    __utcNow: (format: string) => {
      if (format !== "o") throw new Error(`DateTime format "${format}" is not simulated`);
      return "2026-10-13T00:00:00.0000000Z";
    },
  };
  const valueOf = (raw: string | undefined, what: string): unknown => {
    if (raw === undefined) throw new Error(`${what} is missing`);
    if (!raw.startsWith("@(") && !raw.startsWith("@{")) return raw;
    const code = toJavaScript(raw.slice(2, -1));
    const body = raw.startsWith("@(") ? `return (${code});` : code;
    return runInNewContext(`(function () { "use strict"; ${body} })()`, sandbox, { timeout: 1000 });
  };
  const traces: string[] = [];
  const traceMessages: string[] = [];
  const calls: string[] = [];
  let answer: Omit<GatewayAnswer, "traces" | "traceMessages" | "calls"> | null = null;

  const respond = (el: XmlElement) => {
    let status = Number.NaN;
    let reason = "";
    let body: string | null = null;
    const headers: Record<string, string> = {};
    for (const child of elementsOf(el)) {
      if (child.name === "set-status") {
        status = Number(valueOf(attr(child, "code"), "set-status code"));
        reason = String(valueOf(attr(child, "reason"), "set-status reason"));
      } else if (child.name === "set-header") {
        headers[attr(child, "name")!.toLowerCase()] = elementsOf(child).map((v) => String(valueOf(textOf(v).trim(), "header value"))).join(",");
      } else if (child.name === "set-body") {
        body = String(valueOf(textOf(child).trim(), "set-body"));
      } else {
        throw new Error(`the simulator cannot run <${child.name}> in <return-response>`);
      }
    }
    if (!Number.isInteger(status)) throw new Error("<return-response> sets no integer status");
    return { status, reason, headers, body };
  };

  const run = (el: XmlElement): boolean => {
    switch (el.name) {
      case "base":
        return false;
      case "set-variable":
        values.set(attr(el, "name")!, valueOf(attr(el, "value"), "set-variable value"));
        return false;
      case "choose": {
        const chosen = elementsOf(el).find((branch) => {
          if (branch.name === "otherwise") return true;
          const condition = valueOf(attr(branch, "condition"), "when condition");
          if (typeof condition !== "boolean") throw new Error(`a <when> condition gave ${typeof condition}, not a boolean`);
          return condition;
        });
        return chosen ? elementsOf(chosen).some(run) : false;
      }
      case "trace":
        for (const child of elementsOf(el)) {
          if (child.name !== "message") throw new Error(`the simulator cannot run <${child.name}> in <trace>`);
          const message = valueOf(textOf(child).trim(), "trace message");
          if (typeof message !== "string") throw new Error(`a <trace> message gave ${typeof message}, not a string`);
          traceMessages.push(message);
        }
        traces.push(attr(el, "source") ?? "");
        return false;
      case "return-response":
        answer = respond(el);
        return true;
      default:
        if (OUTGOING.has(el.name)) {
          calls.push(el.name);
          return false;
        }
        throw new Error(`the simulator cannot run <${el.name}>`);
    }
  };

  elementsOf(onError).some(run);
  if (answer === null) throw new Error("on-error ended without <return-response>");
  return { ...(answer as Omit<GatewayAnswer, "traces" | "traceMessages" | "calls">), traces, traceMessages, calls };
}
