import { useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";

// Hand-rolled SVG charts: geometry is set with SVG attributes and colour with classes from app.css,
// so nothing needs inline styles under the strict CSP. Every chart is paired with a data table by
// its caller; the SVG carries a text summary for assistive technology.

export function useWidth<T extends HTMLElement>(): [React.RefObject<T | null>, number] {
  const ref = useRef<T>(null);
  const [width, setWidth] = useState(600);
  useEffect(() => {
    if (!ref.current) return;
    const ro = new ResizeObserver((entries) => { const w = Math.floor(entries[0].contentRect.width); if (w > 0) setWidth(w); });
    ro.observe(ref.current);
    return () => ro.disconnect();
  }, []);
  return [ref, width];
}

function niceMax(v: number): number {
  if (v <= 0) return 1;
  const p = 10 ** Math.floor(Math.log10(v));
  const n = v / p;
  return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10) * p;
}

export interface Category { key: string; label: string }
export function Legend({ categories, className = "series" }: { categories: Category[]; className?: string }) {
  return (
    <ul className="legend" aria-label="Legend">
      {categories.map((c) => (
        <li key={c.key}><svg width="12" height="12" aria-hidden="true"><rect width="12" height="12" rx="3" className={`${className}-${c.key}`} /></svg>{c.label}</li>
      ))}
    </ul>
  );
}

export function StackedColumns({ buckets, categories, format, label, height = 240, tickLabel }: {
  buckets: { key: string; values: Record<string, number | null> }[]; categories: Category[]; format: (n: number) => string;
  label: string; height?: number; tickLabel: (key: string) => string;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const pad = { l: 56, r: 8, t: 10, b: 26 };
  const totals = buckets.map((b) => categories.reduce((s, c) => s + (b.values[c.key] ?? 0), 0));
  const max = niceMax(Math.max(0, ...totals));
  const innerW = Math.max(10, width - pad.l - pad.r), innerH = height - pad.t - pad.b;
  const step = innerW / Math.max(1, buckets.length);
  const barW = Math.max(1, Math.min(28, step * 0.72));
  const y = (v: number) => pad.t + innerH - (v / max) * innerH;
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((f) => f * max);
  const every = Math.max(1, Math.ceil(buckets.length / Math.max(2, Math.floor(innerW / 70))));
  const total = totals.reduce((a, b) => a + b, 0);
  return (
    <div className="chart" ref={ref}>
      <svg width={width} height={height} role="img" aria-label={`${label}. ${buckets.length} periods, total ${format(total)}. The table below lists every value.`}>
        {ticks.map((t) => (
          <g key={t}>
            <line x1={pad.l} x2={width - pad.r} y1={y(t)} y2={y(t)} className="grid-line" />
            <text x={pad.l - 6} y={y(t)} dy="0.32em" textAnchor="end" className="axis-label">{format(t)}</text>
          </g>
        ))}
        {buckets.map((b, i) => {
          let acc = 0;
          const x = pad.l + i * step + (step - barW) / 2;
          return (
            <g key={b.key}>
              {categories.map((c) => {
                const v = b.values[c.key] ?? 0;
                if (v <= 0) return null;
                const y0 = y(acc), y1 = y(acc + v);
                acc += v;
                return <rect key={c.key} x={x} y={y1} width={barW} height={Math.max(0.5, y0 - y1)} className={`series-${c.key}`}><title>{`${tickLabel(b.key)} · ${c.label}: ${format(v)}`}</title></rect>;
              })}
              {i % every === 0 && <text x={x + barW / 2} y={height - 8} textAnchor="middle" className="axis-label">{tickLabel(b.key)}</text>}
            </g>
          );
        })}
        <line x1={pad.l} x2={width - pad.r} y1={y(0)} y2={y(0)} className="axis-line" />
      </svg>
      <Legend categories={categories.filter((c) => buckets.some((b) => (b.values[c.key] ?? 0) > 0))} />
    </div>
  );
}

export function HBars({ items, format, label, className = "series-primary" }: { items: { key: string; label: ReactNode; value: number | null; note?: ReactNode }[]; format: (n: number | null) => string; label: string; className?: string }) {
  const max = Math.max(0, ...items.map((i) => i.value ?? 0)) || 1;
  return (
    <ol className="hbars" aria-label={label}>
      {items.map((i) => (
        <li key={i.key}>
          <span className="hbar-label">{i.label}</span>
          <svg className="hbar-track" viewBox="0 0 100 8" preserveAspectRatio="none" aria-hidden="true">
            <rect x="0" y="0" width="100" height="8" rx="2" className="track" />
            {i.value !== null && i.value > 0 && <rect x="0" y="0" width={Math.max(0.6, (i.value / max) * 100)} height="8" rx="2" className={className} />}
          </svg>
          <span className="hbar-value">{format(i.value)}{i.note && <span className="hint"> {i.note}</span>}</span>
        </li>
      ))}
    </ol>
  );
}

export function SplitBar({ parts, format, label }: { parts: { key: string; label: string; value: number | null }[]; format: (n: number | null) => string; label: string }) {
  const known = parts.filter((p) => p.value !== null && p.value > 0);
  const total = known.reduce((s, p) => s + (p.value ?? 0), 0);
  let x = 0;
  return (
    <div className="splitbar">
      <svg viewBox="0 0 100 10" preserveAspectRatio="none" role="img" aria-label={`${label}: ${parts.map((p) => `${p.label} ${format(p.value)}`).join(", ")}`}>
        {total === 0 ? <rect x="0" y="0" width="100" height="10" className="track" /> : known.map((p) => {
          const w = ((p.value ?? 0) / total) * 100;
          const r = <rect key={p.key} x={x} y="0" width={Math.max(0.3, w - 0.3)} height="10" className={`cat-${p.key}`}><title>{`${p.label}: ${format(p.value)}`}</title></rect>;
          x += w;
          return r;
        })}
      </svg>
      <Legend categories={parts.map((p) => ({ key: p.key, label: `${p.label} ${total > 0 && p.value ? `${Math.round(((p.value ?? 0) / total) * 100)}%` : ""}` }))} className="cat" />
    </div>
  );
}

// Cumulative spend against a monthly budget: actual line, the even-burn line, and the budget ceiling.
export function BurnDown({ points, budget, daysInPeriod, format, label, height = 220 }: {
  points: { day: number; cumulative: number }[]; budget: number | null; daysInPeriod: number; format: (n: number) => string; label: string; height?: number;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const pad = { l: 56, r: 12, t: 12, b: 24 };
  const last = points.at(-1)?.cumulative ?? 0;
  const max = niceMax(Math.max(budget ?? 0, last) * 1.05);
  const innerW = Math.max(10, width - pad.l - pad.r), innerH = height - pad.t - pad.b;
  const x = (d: number) => pad.l + (d / daysInPeriod) * innerW;
  const y = (v: number) => pad.t + innerH - (v / max) * innerH;
  const path = points.map((p, i) => `${i ? "L" : "M"}${x(p.day).toFixed(1)},${y(p.cumulative).toFixed(1)}`).join(" ");
  const ticks = [0, 0.5, 1].map((f) => f * max);
  return (
    <div className="chart" ref={ref}>
      <svg width={width} height={height} role="img" aria-label={`${label}. Spent ${format(last)}${budget !== null ? ` of ${format(budget)}` : ", no budget cap"}. The table below lists each day.`}>
        {ticks.map((t) => (
          <g key={t}><line x1={pad.l} x2={width - pad.r} y1={y(t)} y2={y(t)} className="grid-line" />
            <text x={pad.l - 6} y={y(t)} dy="0.32em" textAnchor="end" className="axis-label">{format(t)}</text></g>
        ))}
        {budget !== null && <>
          <line x1={pad.l} x2={width - pad.r} y1={y(budget)} y2={y(budget)} className="budget-line" />
          <line x1={x(0)} y1={y(0)} x2={x(daysInPeriod)} y2={y(budget)} className="ideal-line" />
          <text x={width - pad.r} y={y(budget) - 6} textAnchor="end" className="axis-label">Budget {format(budget)}</text>
        </>}
        {points.length > 0 && <path d={path} className="actual-line" />}
        {points.length > 0 && <circle cx={x(points.at(-1)!.day)} cy={y(last)} r="3.5" className="actual-dot" />}
        {[1, Math.round(daysInPeriod / 2), daysInPeriod].map((d, i) => <text key={d} x={x(d)} y={height - 6} textAnchor={i === 0 ? "start" : i === 2 ? "end" : "middle"} className="axis-label">Day {d}</text>)}
      </svg>
      <ul className="legend" aria-label="Legend">
        <li><svg width="16" height="12" aria-hidden="true"><line x1="0" x2="16" y1="6" y2="6" className="actual-line" /></svg>Spent (cumulative)</li>
        {budget !== null && <li><svg width="16" height="12" aria-hidden="true"><line x1="0" x2="16" y1="6" y2="6" className="ideal-line" /></svg>Even burn</li>}
        {budget !== null && <li><svg width="16" height="12" aria-hidden="true"><line x1="0" x2="16" y1="6" y2="6" className="budget-line" /></svg>Budget</li>}
      </ul>
    </div>
  );
}

export function Meter({ value, max, label }: { value: number | null; max: number | null; label: string }) {
  const pct = value !== null && max ? Math.min(100, (value / max) * 100) : 0;
  const tone = pct >= 100 ? "danger" : pct >= 80 ? "warn" : "ok";
  return (
    <svg className={`meter meter-${tone}`} viewBox="0 0 100 6" preserveAspectRatio="none" role="img" aria-label={label}>
      <rect x="0" y="0" width="100" height="6" rx="3" className="track" />
      {pct > 0 && <rect x="0" y="0" width={Math.max(2, pct)} height="6" rx="3" className="meter-fill" />}
    </svg>
  );
}
