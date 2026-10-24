// Display formatting. Money arrives as exact decimal text; it is rounded only for display and a
// blank (null) amount is shown as "—" with its reason, never as 0.
export const BLANK = "—";

export function usd(v: unknown, digits = 2): string {
  if (v === null || v === undefined || v === "") return BLANK;
  const n = Number(v);
  if (!Number.isFinite(n)) return BLANK;
  return n.toLocaleString("en-US", { style: "currency", currency: "USD", minimumFractionDigits: digits, maximumFractionDigits: digits });
}
export function ccu(v: unknown): string {
  if (v === null || v === undefined || v === "") return BLANK;
  const n = Number(v);
  return Number.isFinite(n) ? `${n.toLocaleString("en-US", { maximumFractionDigits: 2 })} CCU` : BLANK;
}
export function int(v: unknown): string {
  if (v === null || v === undefined || v === "") return BLANK;
  const n = Number(v);
  return Number.isFinite(n) ? Math.round(n).toLocaleString("en-US") : BLANK;
}
export function compact(v: unknown): string {
  if (v === null || v === undefined || v === "") return BLANK;
  const n = Number(v);
  if (!Number.isFinite(n)) return BLANK;
  return n.toLocaleString("en-US", { notation: "compact", maximumFractionDigits: 1 });
}
export function pct(v: unknown, digits = 1): string {
  if (v === null || v === undefined || v === "") return BLANK;
  const n = Number(v);
  return Number.isFinite(n) ? `${n.toFixed(digits)}%` : BLANK;
}
export function when(v: unknown): string {
  if (typeof v !== "string" || !v) return BLANK;
  const d = new Date(v);
  if (Number.isNaN(d.getTime())) return BLANK;
  return d.toLocaleString("en-GB", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit", timeZone: "UTC" }) + " UTC";
}
export function day(v: unknown): string {
  if (typeof v !== "string" || !v) return BLANK;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? BLANK : d.toLocaleDateString("en-GB", { day: "2-digit", month: "short", timeZone: "UTC" });
}
export function ago(v: unknown, now = Date.now()): string {
  const t = typeof v === "string" ? Date.parse(v) : v instanceof Date ? v.getTime() : NaN;
  if (!Number.isFinite(t)) return BLANK;
  const s = Math.max(0, Math.round((now - t) / 1000));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return `${Math.round(s / 86400)} d ago`;
}
export const shortId = (id: unknown) => typeof id === "string" && id.length > 13 ? `${id.slice(0, 8)}…${id.slice(-4)}` : String(id ?? BLANK);
export const human = (code: unknown) => String(code ?? "").replace(/_/g, " ");

export function toCsv(columns: string[], rows: Record<string, unknown>[], meta: Record<string, unknown>): string {
  const cell = (v: unknown) => {
    const s = v === null || v === undefined ? "" : typeof v === "object" ? JSON.stringify(v) : String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const head = Object.entries(meta).map(([k, v]) => `# ${k}: ${v}`).join("\n");
  return `${head}\n${columns.map(cell).join(",")}\n${rows.map((r) => columns.map((c) => cell(r[c])).join(",")).join("\n")}\n`;
}

export function download(name: string, text: string, type = "text/csv") {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const a = document.createElement("a");
  a.href = url; a.download = name;
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
