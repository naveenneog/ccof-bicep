import { createContext, useContext, useEffect, useId, useRef, useState } from "react";
import type { ReactNode } from "react";
import { BLANK, ago, human } from "../lib/format.ts";
import { errorMessage } from "../lib/api.ts";

// ---- Icons: one stroke style, 20px grid, currentColor. Decorative unless labelled by their control. ----
const paths: Record<string, string> = {
  overview: "M3 3h6v8H3zM11 3h6v5h-6zM11 10h6v7h-6zM3 13h6v4H3z",
  projects: "M3 5h14M3 10h14M3 15h14M3 5v0",
  chargeback: "M10 2v16M14 5.5c0-1.4-1.8-2.5-4-2.5s-4 1.1-4 2.5S7.8 8 10 8.5s4 1.1 4 2.75S12.2 14 10 14s-4-1.1-4-2.5",
  budgets: "M10 3a7 7 0 1 0 7 7h-7z M12 2.5A7 7 0 0 1 17.5 8H12z",
  reconciler: "M4 10a6 6 0 0 1 10.5-4M16 10a6 6 0 0 1-10.5 4M14 2.5V6h-3.5M6 17.5V14h3.5",
  foundry: "M10 2l7 4v8l-7 4-7-4V6zM3 6l7 4 7-4M10 10v8",
  health: "M2 10h4l2-5 4 10 2-5h4",
  audit: "M5 2.5h7l3 3V17.5H5zM8 8h5M8 11h5M8 14h3",
  cost: "M3 4h14v12H3zM3 8h14M7 12h2M11 12h3",
  help: "M10 18a8 8 0 1 0 0-16 8 8 0 0 0 0 16zM7.8 7.5a2.3 2.3 0 0 1 4.4.8c0 1.5-2.2 2-2.2 3.2M10 14.2v.3",
  collapse: "M12.5 5l-5 5 5 5",
  expand: "M7.5 5l5 5-5 5",
  menu: "M3 6h14M3 10h14M3 14h14",
  close: "M5 5l10 10M15 5L5 15",
  refresh: "M16 10a6 6 0 1 1-1.8-4.3M16 3.5V7h-3.5",
  sun: "M10 13.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM10 1.5v2M10 16.5v2M1.5 10h2M16.5 10h2M4 4l1.4 1.4M14.6 14.6L16 16M4 16l1.4-1.4M14.6 5.4L16 4",
  moon: "M16.5 12.5A7 7 0 0 1 7.5 3.5a7 7 0 1 0 9 9z",
  system: "M3 4h14v9H3zM7 17h6M10 13v4",
  plus: "M10 4v12M4 10h12",
  download: "M10 3v10M6 9l4 4 4-4M4 16h12",
  upload: "M10 14V4M6 8l4-4 4 4M4 16h12",
  check: "M4 10.5l4 4 8-9",
  warn: "M10 3l8 14H2zM10 8v4M10 14.5v.2",
  arrow: "M4 10h12M12 6l4 4-4 4",
  user: "M10 10a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM3.5 17.5a6.5 6.5 0 0 1 13 0",
};
export function Icon({ name, size = 18, label }: { name: string; size?: number; label?: string }) {
  return (
    <svg className="icon" width={size} height={size} viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.6"
      strokeLinecap="round" strokeLinejoin="round" aria-hidden={label ? undefined : true} role={label ? "img" : undefined} aria-label={label}>
      <path d={paths[name] ?? ""} />
    </svg>
  );
}

export function Button({ children, variant = "default", size, icon, busy, ...rest }: {
  children?: ReactNode; variant?: "default" | "primary" | "quiet" | "danger"; size?: "small"; icon?: string; busy?: boolean;
} & React.ButtonHTMLAttributes<HTMLButtonElement>) {
  return (
    <button type="button" {...rest} className={`btn btn-${variant}${size ? ` btn-${size}` : ""}${rest.className ? ` ${rest.className}` : ""}`}
      aria-busy={busy || undefined} disabled={rest.disabled || busy}>
      {icon && <Icon name={icon} size={16} />}
      {children}
    </button>
  );
}

export function Field({ label, hint, error, children, id }: { label: ReactNode; hint?: ReactNode; error?: string | null; children: (id: string, describedBy?: string) => ReactNode; id?: string }) {
  const auto = useId();
  const fieldId = id ?? `f${auto.replace(/:/g, "")}`;
  const describedBy = [hint ? `${fieldId}-hint` : "", error ? `${fieldId}-error` : ""].filter(Boolean).join(" ") || undefined;
  return (
    <div className={`field${error ? " field-invalid" : ""}`}>
      <label htmlFor={fieldId}>{label}</label>
      {children(fieldId, describedBy)}
      {hint && <p className="hint" id={`${fieldId}-hint`}>{hint}</p>}
      {error && <p className="field-error" id={`${fieldId}-error`}>{error}</p>}
    </div>
  );
}

const TONE: Record<string, string> = {
  available: "ok", complete: "ok", current: "ok", observed_token_usage_complete: "ok", endpoint_responding: "ok", on_schedule: "ok", written: "ok",
  updated: "ok", created: "ok", observed: "ok", Succeeded: "ok", configured: "ok", strict: "neutral", notify: "neutral", no_cap: "neutral",
  partial: "warn", expired: "warn", incomplete: "warn", late: "warn", unpriced_usage: "warn", retention_truncated: "warn", disabled: "neutral",
  permission_required: "warn", historical: "neutral", skipped_lease_held: "neutral", no_data_not_zero: "neutral", historical_group_unverified: "warn",
  unavailable: "danger", exhausted: "danger", failed: "danger", refused: "danger", stale: "danger", not_found: "danger", unreachable: "danger",
  endpoint_refused: "danger", invalid_event: "danger", access_denied: "danger", unknown: "neutral",
};
export function StatePill({ state, label }: { state: unknown; label?: string }) {
  const s = String(state ?? "unknown");
  return <span className={`pill pill-${TONE[s] ?? "neutral"}`}>{label ?? human(s)}</span>;
}

export function Skeleton({ rows = 4, height }: { rows?: number; height?: "chart" }) {
  return (
    <div className={`skeleton${height === "chart" ? " skeleton-chart" : ""}`} aria-hidden="true">
      {Array.from({ length: height === "chart" ? 1 : rows }, (_, i) => <span key={i} className="skeleton-line" />)}
    </div>
  );
}
export function Loading({ label = "Loading", rows, chart }: { label?: string; rows?: number; chart?: boolean }) {
  return <div role="status" aria-live="polite"><span className="visually-hidden">{label}…</span><Skeleton rows={rows} height={chart ? "chart" : undefined} /></div>;
}

export function Empty({ title, children, action }: { title: string; children?: ReactNode; action?: ReactNode }) {
  return (
    <div className="empty">
      <p className="empty-title">{title}</p>
      {children && <div className="empty-body">{children}</div>}
      {action}
    </div>
  );
}

export function ErrorNote({ error, retry }: { error: unknown; retry?: () => void }) {
  return (
    <div className="notice notice-danger" role="alert">
      <Icon name="warn" />
      <div><p>{errorMessage(error)}</p>{retry && <Button size="small" onClick={retry}>Try again</Button>}</div>
    </div>
  );
}

// An optional integration that is not available renders its state and the permission that enables it.
export function CapabilityNotice({ cap, what }: { cap: { state: string; reason?: string; permission?: string; observedAt?: string }; what: string }) {
  const title: Record<string, string> = {
    disabled: `${what} is not configured`, permission_required: `${what} needs a permission`, unavailable: `${what} is unavailable right now`,
  };
  return (
    <div className={`notice ${cap.state === "unavailable" ? "notice-danger" : "notice-warn"}`} role="status">
      <Icon name="warn" />
      <div>
        <p><strong>{title[cap.state] ?? `${what}: ${human(cap.state)}`}</strong> <StatePill state={cap.state} /></p>
        {cap.reason && <p className="muted">Reason: <code>{cap.reason}</code></p>}
        {cap.permission && <p className="muted">Enable it with: {cap.permission}</p>}
        <p className="hint">Other parts of the console keep working. See Help → Permissions.</p>
      </div>
    </div>
  );
}

export interface Column<T> { key: string; label: ReactNode; render?: (row: T) => ReactNode; align?: "end"; width?: string; sortValue?: (row: T) => string | number }
export function DataTable<T extends Record<string, any>>({ columns, rows, caption, onRowClick, rowKey, empty, dense, maxHeight }: {
  columns: Column<T>[]; rows: T[]; caption: string; onRowClick?: (row: T) => void; rowKey?: (row: T, i: number) => string;
  empty?: ReactNode; dense?: boolean; maxHeight?: boolean;
}) {
  if (!rows.length) return <>{empty ?? <Empty title="No rows" />}</>;
  return (
    <div className={`table-wrap${maxHeight ? " table-wrap-scroll" : ""}`} tabIndex={0} role="region" aria-label={caption}>
      <table className={`table${dense ? " table-dense" : ""}${onRowClick ? " table-clickable" : ""}`}>
        <caption className="visually-hidden">{caption}</caption>
        <thead><tr>{columns.map((c) => <th key={c.key} scope="col" className={c.align === "end" ? "num" : undefined}>{c.label}</th>)}</tr></thead>
        <tbody>
          {rows.map((row, i) => (
            <tr key={rowKey ? rowKey(row, i) : i} onClick={onRowClick ? () => onRowClick(row) : undefined}
              onKeyDown={onRowClick ? (e) => { if (e.key === "Enter") onRowClick(row); } : undefined} tabIndex={onRowClick ? 0 : undefined}>
              {columns.map((c) => <td key={c.key} className={c.align === "end" ? "num" : undefined}>{c.render ? c.render(row) : row[c.key] ?? BLANK}</td>)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function Pager({ offset, limit, returned, matched, onPage, label = "rows" }: { offset: number; limit: number; returned: number; matched: number | null; onPage: (offset: number) => void; label?: string }) {
  return (
    <nav className="pager" aria-label={`${label} pages`}>
      <span className="muted">{returned ? `${offset + 1}–${offset + returned}` : "0"}{matched !== null ? ` of ${matched.toLocaleString()}` : ""} {label}</span>
      <div className="pager-buttons">
        <Button size="small" disabled={offset === 0} onClick={() => onPage(Math.max(0, offset - limit))}>Previous</Button>
        <Button size="small" disabled={matched === null ? returned < limit : offset + returned >= matched} onClick={() => onPage(offset + limit)}>Next</Button>
      </div>
    </nav>
  );
}

export function Tabs({ tabs, active, onChange, label }: { tabs: { id: string; label: string }[]; active: string; onChange: (id: string) => void; label: string }) {
  const refs = useRef<Record<string, HTMLButtonElement | null>>({});
  const key = (e: React.KeyboardEvent, i: number) => {
    const n = e.key === "ArrowRight" ? i + 1 : e.key === "ArrowLeft" ? i - 1 : e.key === "Home" ? 0 : e.key === "End" ? tabs.length - 1 : null;
    if (n === null) return;
    e.preventDefault();
    const t = tabs[(n + tabs.length) % tabs.length];
    onChange(t.id);
    refs.current[t.id]?.focus();
  };
  return (
    <div className="tabs" role="tablist" aria-label={label}>
      {tabs.map((t, i) => (
        <button key={t.id} ref={(el) => { refs.current[t.id] = el; }} role="tab" type="button" id={`tab-${t.id}`} aria-selected={active === t.id}
          aria-controls={`panel-${t.id}`} tabIndex={active === t.id ? 0 : -1} className="tab" onClick={() => onChange(t.id)} onKeyDown={(e) => key(e, i)}>
          {t.label}
        </button>
      ))}
    </div>
  );
}

export function Segmented<T extends string>({ options, value, onChange, label }: { options: { value: T; label: string; icon?: string }[]; value: T; onChange: (v: T) => void; label: string }) {
  return (
    <div className="segmented" role="radiogroup" aria-label={label}>
      {options.map((o) => (
        <button key={o.value} type="button" role="radio" aria-checked={value === o.value} className="segment" onClick={() => onChange(o.value)}
          title={o.icon ? o.label : undefined}>
          {o.icon && <Icon name={o.icon} size={16} />}
          <span className={o.icon ? "visually-hidden-narrow" : undefined}>{o.label}</span>
        </button>
      ))}
    </div>
  );
}

export function PageHeader({ title, subtitle, observedAt, onRefresh, actions, busy }: { title: string; subtitle?: ReactNode; observedAt?: Date | string | null; onRefresh?: () => void; actions?: ReactNode; busy?: boolean }) {
  const [, force] = useState(0);
  useEffect(() => { const t = setInterval(() => force((n) => n + 1), 30_000); return () => clearInterval(t); }, []);
  return (
    <header className="page-header">
      <div className="page-title">
        <h1 id="page-title" tabIndex={-1}>{title}</h1>
        {subtitle && <p className="page-subtitle">{subtitle}</p>}
      </div>
      <div className="page-actions">
        {observedAt && <span className="observed" title="When the figures on this page were read">Observed {ago(observedAt)}</span>}
        {onRefresh && <Button variant="quiet" icon="refresh" onClick={onRefresh} busy={busy} aria-label="Refresh">Refresh</Button>}
        {actions}
      </div>
    </header>
  );
}

export function Section({ title, description, actions, children, id }: { title: ReactNode; description?: ReactNode; actions?: ReactNode; children: ReactNode; id?: string }) {
  return (
    <section className="section" aria-labelledby={id ? `${id}-title` : undefined}>
      <div className="section-head">
        <div><h2 id={id ? `${id}-title` : undefined}>{title}</h2>{description && <p className="section-desc">{description}</p>}</div>
        {actions && <div className="section-actions">{actions}</div>}
      </div>
      {children}
    </section>
  );
}

export function Stat({ label, value, sub, tone }: { label: string; value: ReactNode; sub?: ReactNode; tone?: "warn" | "danger" | "ok" }) {
  return (
    <div className={`stat${tone ? ` stat-${tone}` : ""}`}>
      <dt>{label}</dt>
      <dd><span className="stat-value">{value}</span>{sub && <span className="stat-sub">{sub}</span>}</dd>
    </div>
  );
}

// ---- Toasts ----
const ToastContext = createContext<(message: string, tone?: "ok" | "danger") => void>(() => {});
export const useToast = () => useContext(ToastContext);
export function ToastHost({ children }: { children: ReactNode }) {
  const [toast, setToast] = useState<{ message: string; tone: string; id: number } | null>(null);
  useEffect(() => { if (!toast) return; const t = setTimeout(() => setToast(null), 5000); return () => clearTimeout(t); }, [toast]);
  return (
    <ToastContext.Provider value={(message, tone = "ok") => setToast({ message, tone, id: Date.now() })}>
      {children}
      <div className="toast-region" role="status" aria-live="polite">{toast && <div key={toast.id} className={`toast toast-${toast.tone}`}>{toast.message}</div>}</div>
    </ToastContext.Provider>
  );
}

// ---- Field-level change review: every write is shown as before → after before it is sent ----
export interface Change { path: string; before: unknown; after: unknown }
export function diff(before: unknown, after: unknown, path = "", out: Change[] = []): Change[] {
  const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
  if (isObj(before) && isObj(after)) {
    for (const k of [...new Set([...Object.keys(before), ...Object.keys(after)])].sort()) diff(before[k], after[k], path ? `${path}.${k}` : k, out);
    return out;
  }
  if (JSON.stringify(before) !== JSON.stringify(after)) out.push({ path, before: before ?? null, after: after ?? null });
  return out;
}
const show = (v: unknown) => v === null || v === undefined ? <span className="muted">(none)</span> : <code>{typeof v === "object" ? JSON.stringify(v) : String(v)}</code>;
export function Review({ changes, onConfirm, onCancel, busy, error, title = "Review changes", confirmLabel = "Save changes", note }: {
  changes: Change[]; onConfirm: () => void; onCancel: () => void; busy?: boolean; error?: unknown; title?: string; confirmLabel?: string; note?: ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => { ref.current?.focus(); }, []);
  return (
    <div className="review" ref={ref} tabIndex={-1} role="region" aria-label={title}>
      <div className="review-head">
        <h3>{title}</h3>
        <span className="muted">{changes.length} field{changes.length === 1 ? "" : "s"} change</span>
      </div>
      {note && <p className="hint">{note}</p>}
      {changes.length === 0 ? <p className="muted">Nothing changed.</p> : (
        <div className="table-wrap" tabIndex={0} role="region" aria-label="Changed fields">
          <table className="table table-dense review-table">
            <thead><tr><th scope="col">Field</th><th scope="col">Before</th><th scope="col">After</th></tr></thead>
            <tbody>{changes.map((c) => <tr key={c.path}><td><code>{c.path}</code></td><td className="diff-before">{show(c.before)}</td><td className="diff-after">{show(c.after)}</td></tr>)}</tbody>
          </table>
        </div>
      )}
      {error ? <ErrorNote error={error} /> : null}
      <div className="review-actions">
        <Button variant="primary" onClick={onConfirm} busy={busy} disabled={changes.length === 0}>{confirmLabel}</Button>
        <Button variant="quiet" onClick={onCancel} disabled={busy}>Back to editing</Button>
      </div>
    </div>
  );
}
