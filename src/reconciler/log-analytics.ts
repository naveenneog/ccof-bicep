// The Log Analytics query API client (docs/PILOT.md C-7): one POST per run
// to /v1/workspaces/<id>/query with the managed identity's token (Learn,
// "Access the Azure Monitor Log Analytics API"). The `Prefer: wait=` header
// bounds the server's time and an abort signal the client's (Learn,
// "Timeouts", retrieved 2026-10-11: default 3 minutes, 504 when exceeded).
// Every failure is a LedgerReadError with a code; no body or token is ever
// placed in an error. Every run sends the same query and timespan for a
// month, and the API keeps an answer for 2 minutes unless the request says
// `Cache-Control: no-cache` (Learn, "Caching", retrieved 2026-10-13): each
// read asks for a fresh answer, and the `Age` of a cached one is returned so
// the run line shows it (WP-E2E G6).

import { LedgerReadError } from "./ledger.ts";
import type { LedgerAnswer } from "./ledger.ts";

export type FetchLike = (
  url: string,
  init: { method: "POST"; headers: Record<string, string>; body: string; signal: AbortSignal },
) => Promise<{ status: number; headers: { get(name: string): string | null }; text(): Promise<string> }>;

export interface LedgerClientOptions {
  // An https origin such as https://api.loganalytics.io; also the token audience.
  endpoint: string;
  workspaceId: string;
  timeoutSeconds: number;
  getToken: () => Promise<string>;
  fetch: FetchLike;
}

export function logAnalyticsScope(endpoint: string): string {
  return `${endpoint}/.default`;
}

const NAME = /^[A-Za-z]{1,40}$/;

function transportFailure(error: unknown): LedgerReadError {
  const name = error instanceof Error ? error.name : "";
  if (name === "TimeoutError" || name === "AbortError") return new LedgerReadError("ledger_timeout");
  return new LedgerReadError("ledger_request_failed", NAME.test(name) ? name : undefined);
}

// The Age header is whole seconds (RFC 9111, 5.1); anything else reads as unknown.
function ageSeconds(value: string | null): number | null {
  return value !== null && /^\d{1,9}$/.test(value) ? Number(value) : null;
}

export function createLedgerQuery(options: LedgerClientOptions): (query: string, timespan: string) => Promise<LedgerAnswer> {
  const url = `${options.endpoint}/v1/workspaces/${options.workspaceId}/query`;
  return async (query, timespan) => {
    let token: string;
    try {
      token = await options.getToken();
    } catch {
      throw new LedgerReadError("ledger_request_failed", "token");
    }
    let text: string;
    let responseAgeSeconds: number | null;
    try {
      const response = await options.fetch(url, {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json", "cache-control": "no-cache", prefer: `wait=${options.timeoutSeconds}` },
        body: JSON.stringify({ query, timespan }),
        signal: AbortSignal.timeout(options.timeoutSeconds * 1000),
      });
      if (response.status === 504) throw new LedgerReadError("ledger_timeout", "504");
      if (response.status !== 200) throw new LedgerReadError("ledger_http_error", String(response.status));
      responseAgeSeconds = ageSeconds(response.headers.get("age"));
      text = await response.text();
    } catch (error) {
      throw error instanceof LedgerReadError ? error : transportFailure(error);
    }
    try {
      return { body: JSON.parse(text) as unknown, responseAgeSeconds };
    } catch {
      throw new LedgerReadError("ledger_response_invalid", "json");
    }
  };
}
