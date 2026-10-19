import { useCallback, useEffect, useRef, useState } from "react";
import { token } from "./auth.ts";

export class ApiFailure extends Error {
  status: number; code: string; problems: string[]; requestId: string | null; detail: string | null;
  constructor(status: number, body: Record<string, unknown> | null) {
    super(String(body?.error ?? `http_${status}`));
    this.status = status;
    this.code = String(body?.error ?? `http_${status}`);
    this.problems = Array.isArray(body?.problems) ? body.problems.map(String) : [];
    this.requestId = typeof body?.requestId === "string" ? body.requestId : null;
    this.detail = typeof body?.detail === "string" ? body.detail : null;
  }
}

export interface ApiOptions { method?: string; body?: unknown; ifMatch?: string | null; ifNoneMatch?: string; signal?: AbortSignal }
export interface ApiResult<T> { data: T; etag: string | null; status: number }

export async function api<T = any>(path: string, opts: ApiOptions = {}): Promise<ApiResult<T>> {
  const headers: Record<string, string> = { authorization: `Bearer ${await token()}` };
  if (opts.body !== undefined) headers["content-type"] = "application/json";
  if (opts.ifMatch) headers["if-match"] = opts.ifMatch;
  if (opts.ifNoneMatch) headers["if-none-match"] = opts.ifNoneMatch;
  const res = await fetch(path, {
    method: opts.method ?? "GET", headers, signal: opts.signal, cache: "no-store",
    body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
  });
  let body: any = null;
  try { body = await res.json(); } catch { body = null; }
  if (!res.ok) throw new ApiFailure(res.status, body);
  return { data: body as T, etag: res.headers.get("etag"), status: res.status };
}

export interface QueryState<T> { data: T | null; error: ApiFailure | Error | null; loading: boolean; etag: string | null; reload: () => void; observedAt: Date | null }

// GET with cancellation: a new path (filters changed) aborts the request in flight.
export function useQuery<T = any>(path: string | null): QueryState<T> {
  const [state, setState] = useState<{ data: T | null; error: any; loading: boolean; etag: string | null; observedAt: Date | null }>({ data: null, error: null, loading: Boolean(path), etag: null, observedAt: null });
  const [tick, setTick] = useState(0);
  const reload = useCallback(() => setTick((n) => n + 1), []);
  const pathRef = useRef(path);
  pathRef.current = path;
  useEffect(() => {
    if (!path) { setState({ data: null, error: null, loading: false, etag: null, observedAt: null }); return; }
    const controller = new AbortController();
    setState((s) => ({ ...s, loading: true, error: null }));
    api<T>(path, { signal: controller.signal }).then(
      (r) => { if (!controller.signal.aborted) setState({ data: r.data, error: null, loading: false, etag: r.etag, observedAt: new Date() }); },
      (err) => { if (!controller.signal.aborted) setState((s) => ({ ...s, error: err, loading: false, observedAt: new Date() })); },
    );
    return () => controller.abort();
  }, [path, tick]);
  return { ...state, reload };
}

export const qs = (params: Record<string, string | number | null | undefined | boolean>) => {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== null && v !== undefined && v !== "" && v !== false) p.set(k, String(v));
  const s = p.toString();
  return s ? `?${s}` : "";
};

export function errorMessage(err: unknown): string {
  if (err instanceof ApiFailure) {
    const known: Record<string, string> = {
      etag_mismatch: "Someone else changed this since you opened it. Reload to see their change, then make yours again.",
      if_match_required: "This change needs the current version tag. Reload and try again.",
      write_permission_required: "Your role can read but not change this. Ask for the CCOF.Projects.Write role.",
      registry_unavailable: "The project registry (Cosmos DB) did not respond. Check the admin app's network path and data role.",
      project_store_not_configured: "The project registry is not configured on this admin app (COSMOS_ENDPOINT, COSMOS_DATABASE).",
      invalid_project: "The registry refused the project.",
      project_exists: "A project with this ID already exists.",
      bearer_token_required: "Your session expired. Sign in again.",
      invalid_access_token: "Your session expired. Sign in again.",
      admin_auth_not_configured: "Sign-in is not configured on the admin app.",
      administrator_not_allowed: "Your account is not an administrator of this console.",
      rate_card_version_must_change: "Give the rate card a new version before saving.",
      historical_rate_edit_forbidden: "Recorded rates can't be edited. Close the old entry and add a new one from a future date.",
      effective_date_in_past: "A new price can't take effect in the past: that would reprice usage already recorded.",
      catalog_store_not_configured: "Saving cost definitions needs ADMIN_CONFIG_CONTAINER and a Cosmos data role.",
    };
    const base = known[err.code] ?? (err.detail ? err.detail : `The request failed (${err.code}).`);
    return err.problems.length ? `${base} ${err.problems.join(", ")}` : base;
  }
  return err instanceof Error ? err.message : "Something went wrong.";
}
