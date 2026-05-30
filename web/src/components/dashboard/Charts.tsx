"use client";
import { useId } from "react";

/** Lightweight, dependency-free SVG charts for the dashboard (R3e). Each is
 *  decorative+labelled: role="img" with an aria-label summary for screen readers. */

export interface Datum {
  label: string;
  value: number;
}

const PALETTE = [
  "var(--color-action-primary)",
  "var(--color-status-success)",
  "var(--color-status-warning)",
  "var(--color-status-info)",
  "var(--color-severity-medium-icon, var(--color-status-warning))",
  "var(--color-text-muted)",
];

function fmt(n: number): string {
  return new Intl.NumberFormat("en-GB", { notation: "compact", maximumFractionDigits: 1 }).format(n);
}

/** Horizontal bars — readable with few categories and long labels. */
export function BarChart({ data, ariaLabel }: { data: Datum[]; ariaLabel: string }) {
  const max = Math.max(1, ...data.map((d) => Math.abs(d.value)));
  return (
    <div role="img" aria-label={ariaLabel} className="flex flex-col gap-1.5">
      {data.map((d, i) => (
        <div key={`${d.label}-${i}`} className="flex items-center gap-2 text-xs">
          <span className="w-20 shrink-0 truncate text-text-muted" title={d.label}>{d.label}</span>
          <div className="h-3 flex-1 overflow-hidden rounded-sm bg-bg-raised">
            <div className="h-full rounded-sm" style={{ width: `${(Math.abs(d.value) / max) * 100}%`, background: PALETTE[i % PALETTE.length] }} />
          </div>
          <span className="w-12 shrink-0 text-right tabular-nums text-text-secondary">{fmt(d.value)}</span>
        </div>
      ))}
    </div>
  );
}

/** Donut — share of a total across categories. */
export function DonutChart({ data, ariaLabel }: { data: Datum[]; ariaLabel: string }) {
  const id = useId();
  const total = data.reduce((a, d) => a + Math.abs(d.value), 0) || 1;
  const r = 36, c = 2 * Math.PI * r;
  const fracs = data.map((d) => Math.abs(d.value) / total);
  const segments = fracs.map((frac, i) => ({
    dash: frac * c,
    offset: fracs.slice(0, i).reduce((a, b) => a + b, 0) * c,
    color: PALETTE[i % PALETTE.length],
  }));
  return (
    <div role="img" aria-label={ariaLabel} className="flex items-center gap-3">
      <svg viewBox="0 0 100 100" className="h-24 w-24 shrink-0 -rotate-90">
        <circle cx="50" cy="50" r={r} fill="none" stroke="var(--color-bg-raised)" strokeWidth="14" />
        {segments.map((s, i) => (
          <circle key={`${id}-${i}`} cx="50" cy="50" r={r} fill="none" stroke={s.color} strokeWidth="14"
            strokeDasharray={`${s.dash} ${c - s.dash}`} strokeDashoffset={-s.offset} />
        ))}
      </svg>
      <ul className="flex min-w-0 flex-col gap-1 text-xs">
        {data.slice(0, 5).map((d, i) => (
          <li key={`${d.label}-${i}`} className="flex items-center gap-1.5">
            <span className="h-2 w-2 shrink-0 rounded-full" style={{ background: PALETTE[i % PALETTE.length] }} aria-hidden="true" />
            <span className="min-w-0 truncate text-text-secondary" title={d.label}>{d.label}</span>
            <span className="ml-auto tabular-nums text-text-muted">{Math.round((Math.abs(d.value) / total) * 100)}%</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

/** Sparkline — a value trend across rows (time-ordered upstream). */
export function Sparkline({ values, ariaLabel }: { values: number[]; ariaLabel: string }) {
  if (values.length < 2) return null;
  const w = 240, h = 40, pad = 2;
  const min = Math.min(...values), max = Math.max(...values);
  const span = max - min || 1;
  const pts = values.map((v, i) => {
    const x = pad + (i / (values.length - 1)) * (w - 2 * pad);
    const y = h - pad - ((v - min) / span) * (h - 2 * pad);
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  });
  return (
    <svg role="img" aria-label={ariaLabel} viewBox={`0 0 ${w} ${h}`} className="h-10 w-full" preserveAspectRatio="none">
      <polyline points={pts.join(" ")} fill="none" stroke="var(--color-action-primary)" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" vectorEffect="non-scaling-stroke" />
    </svg>
  );
}
