"use client";
import { useMemo, type ReactNode } from "react";
import useSWR from "swr";
import {
  ArrowDownLeft, ArrowUpRight, FileCheck2, GitCompareArrows, LayoutGrid,
  ListChecks, Lock, PieChart, Receipt, Repeat, TrendingUp, Users, type LucideIcon,
} from "lucide-react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import { formatMoney, periodRange } from "@/components/transactions/transaction-helpers";
import {
  STUB_LABEL, UNMATCHED_COLUMNS, UNMATCHED_STATUSES, unmatchedLabel,
  type CardDef, type UnmatchedTxn,
} from "./dashboard-helpers";

const CARD_ICON: Record<string, LucideIcon> = {
  monthly_overview: TrendingUp, income_overview: ArrowDownLeft, expense_overview: ArrowUpRight,
  vat_summary: Receipt, subscription_recurring_totals: Repeat, client_invoice_aging: Users,
  evidence_collection_status: FileCheck2, recent_finalizations: Lock, tax_treatment_breakdown: PieChart,
  unmatched_transactions: GitCompareArrows, unresolved_review_items: ListChecks,
};

const income = "var(--color-status-success-text)";
const expense = "var(--color-status-danger-text)";

export function DashboardCard({ def, businessIds, onOpen }: { def: CardDef; businessIds: string[]; onOpen: (def: CardDef) => void }) {
  switch (def.card_id) {
    case "monthly_overview": return <MonthlyCard def={def} businessIds={businessIds} onOpen={onOpen} />;
    case "unresolved_review_items": return <ReviewsCard def={def} businessIds={businessIds} onOpen={onOpen} />;
    case "unmatched_transactions": return <UnmatchedCard def={def} businessIds={businessIds} onOpen={onOpen} />;
    case "recent_finalizations": return <FinalizationsCard def={def} businessIds={businessIds} onOpen={onOpen} />;
    default: return <AnalyticsCard def={def} businessIds={businessIds} onOpen={onOpen} />;
  }
}

/* ── shell ─────────────────────────────────────────────────────────────── */
function Shell({ def, onOpen, children }: { def: CardDef; onOpen: (d: CardDef) => void; children: ReactNode }) {
  const Icon = CARD_ICON[def.card_id] ?? LayoutGrid;
  return (
    <button type="button" onClick={() => onOpen(def)}
      className="group relative flex h-full w-full flex-col gap-3 rounded-xl border border-border-subtle bg-surface-default p-4 text-left shadow-1 transition-all duration-150 hover:-translate-y-px hover:border-border-default hover:shadow-2">
      <div className="flex items-center justify-between gap-2">
        <span className="flex items-center gap-2 text-[11px] font-semibold uppercase tracking-[0.06em] text-text-muted">
          <Icon size={14} strokeWidth={1.75} aria-hidden="true" />{def.display_name}
        </span>
        <ArrowUpRight size={15} strokeWidth={1.75} aria-hidden="true" className="text-text-muted opacity-0 transition-opacity group-hover:opacity-100" />
      </div>
      {children}
    </button>
  );
}

function Hero({ value, sub, color, underline }: { value: string; sub?: ReactNode; color?: string; underline?: boolean }) {
  return (
    <div className="flex flex-col gap-0.5">
      <span className="font-mono text-[28px] font-semibold leading-none tracking-tight tabular-nums"
        style={{ color: color ?? "var(--color-text-primary)", ...(underline ? { backgroundImage: "linear-gradient(var(--color-accent-bronze), var(--color-accent-bronze))", backgroundRepeat: "no-repeat", backgroundPosition: "0 100%", backgroundSize: "44px 2px", paddingBottom: "5px", width: "fit-content" } : {}) }}>
        {value}
      </span>
      {sub && <span className="text-xs text-text-muted">{sub}</span>}
    </div>
  );
}

/* ── 1 · Monthly overview (REAL: money in/out/net from transactions) ─────── */
function MonthlyCard({ def, businessIds, onOpen }: { def: CardDef; businessIds: string[]; onOpen: (d: CardDef) => void }) {
  const { period } = useShell();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const { data } = useSWR(["monthly", businessIds.join(","), period.year, period.month], async () => {
    const { start, end } = periodRange(period);
    const { data } = await supabase.from("transactions").select("amount, currency").in("business_id", businessIds).gte("transaction_date", start).lte("transaction_date", end);
    const rows = (data ?? []) as { amount: number; currency: string }[];
    const cur = rows[0]?.currency ?? "EUR";
    const inAmt = rows.filter((r) => r.amount > 0).reduce((a, r) => a + r.amount, 0);
    const outAmt = rows.filter((r) => r.amount < 0).reduce((a, r) => a + r.amount, 0);
    return { inAmt, outAmt, net: inAmt + outAmt, cur };
  });
  const net = data?.net ?? 0;
  return (
    <Shell def={def} onOpen={onOpen}>
      <Hero value={`${net >= 0 ? "+" : ""}${formatMoney(net, data?.cur ?? "EUR")}`} color={net >= 0 ? income : expense} underline
        sub={`Net position · ${new Intl.DateTimeFormat("en-GB", { month: "long", year: "numeric" }).format(new Date(period.year, period.month - 1))}`} />
      <div className="mt-auto grid grid-cols-2 gap-3 border-t border-border-subtle pt-3">
        <div><div className="text-[11px] text-text-muted">Money in</div><div className="font-mono text-sm font-semibold tabular-nums" style={{ color: income }}>{`+${formatMoney(data?.inAmt ?? 0, data?.cur ?? "EUR")}`}</div></div>
        <div><div className="text-[11px] text-text-muted">Money out</div><div className="font-mono text-sm font-semibold tabular-nums" style={{ color: expense }}>{formatMoney(data?.outAmt ?? 0, data?.cur ?? "EUR")}</div></div>
      </div>
    </Shell>
  );
}

/* ── 6 · Unresolved review items (REAL: review_issues with severity) ─────── */
const SEV: Record<string, { dot: string; label: string }> = {
  BLOCKING: { dot: expense, label: "Blocking" },
  HIGH: { dot: "var(--color-status-warning)", label: "High" },
  MEDIUM: { dot: "var(--color-status-warning)", label: "Medium" },
  LOW: { dot: "var(--color-status-info)", label: "Low" },
};
function ReviewsCard({ def, businessIds, onOpen }: { def: CardDef; businessIds: string[]; onOpen: (d: CardDef) => void }) {
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const { data } = useSWR(["dash-reviews", businessIds.join(",")], async () => {
    const { data } = await supabase.from("review_issues").select("id, severity, plain_language_title, issue_group").in("business_id", businessIds).eq("status", "OPEN");
    return (data ?? []) as { id: string; severity: string; plain_language_title: string; issue_group: string }[];
  });
  const rows = data ?? [];
  const order = ["BLOCKING", "HIGH", "MEDIUM", "LOW"];
  const sorted = [...rows].sort((a, b) => order.indexOf(a.severity) - order.indexOf(b.severity));
  const blocking = rows.filter((r) => r.severity === "BLOCKING").length;
  const high = rows.filter((r) => r.severity === "HIGH").length;
  return (
    <Shell def={def} onOpen={onOpen}>
      <Hero value={`${rows.length} open`} sub={`${blocking} blocking · ${high} high priority`} />
      <div className="mt-1 flex flex-col">
        {sorted.slice(0, 3).map((r) => {
          const s = SEV[r.severity] ?? SEV.LOW;
          return (
            <div key={r.id} className="flex items-center justify-between gap-3 border-t border-border-subtle py-2 first:border-t-0">
              <div className="flex min-w-0 items-center gap-2.5">
                <span className="h-2 w-2 shrink-0 rounded-full" style={{ background: s.dot }} aria-hidden="true" />
                <div className="min-w-0"><p className="truncate text-sm text-text-primary">{r.plain_language_title}</p><p className="truncate text-xs text-text-muted">{r.issue_group?.replaceAll("_", " ").toLowerCase()}</p></div>
              </div>
              <span className="shrink-0 text-[11px] font-semibold" style={{ color: s.dot }}>{s.label}</span>
            </div>
          );
        })}
      </div>
    </Shell>
  );
}

/* ── 9 · Unmatched transactions (REAL: transactions filtered by match_status) ─
   The generic operational drill-down returns ALL transactions unfiltered, so we
   query `transactions` directly for the states that mean "no confirmed match",
   scoped to the selected period — the count now reflects the real backlog. */
function UnmatchedCard({ def, businessIds, onOpen }: { def: CardDef; businessIds: string[]; onOpen: (d: CardDef) => void }) {
  const { period } = useShell();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const { data } = useSWR(["dash-unmatched", businessIds.join(","), period.year, period.month], async () => {
    const { start, end } = periodRange(period);
    const { data } = await supabase
      .from("transactions").select(UNMATCHED_COLUMNS)
      .in("business_id", businessIds)
      .in("match_status", UNMATCHED_STATUSES as unknown as string[])
      .gte("transaction_date", start).lte("transaction_date", end)
      .order("transaction_date", { ascending: false });
    return (data ?? []) as unknown as UnmatchedTxn[];
  });
  const rows = data ?? [];
  return (
    <Shell def={def} onOpen={onOpen}>
      <Hero value={String(rows.length)} sub="transactions without a confirmed match" />
      <ul className="mt-1 flex flex-col">
        {rows.slice(0, 3).map((r) => (
          <li key={r.id} className="flex items-center justify-between gap-2 border-t border-border-subtle py-2 text-sm first:border-t-0">
            <span className="truncate text-text-secondary">{unmatchedLabel(r)}</span>
            <span className="shrink-0 font-mono text-xs tabular-nums text-text-muted">{formatMoney(r.amount, r.currency)}</span>
          </li>
        ))}
      </ul>
    </Shell>
  );
}

/* ── 10 · Recent finalizations (REAL: archive_packages) ──────────────────── */
function FinalizationsCard({ def, businessIds, onOpen }: { def: CardDef; businessIds: string[]; onOpen: (d: CardDef) => void }) {
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const { data } = useSWR(["dash-finalizations", businessIds.join(",")], async () => {
    const { data } = await supabase.from("archive_packages").select("id, period_start, original_finalization, created_at").in("business_id", businessIds).order("created_at", { ascending: false }).limit(4);
    return (data ?? []) as { id: string; period_start: string; original_finalization: boolean; created_at: string }[];
  });
  const rows = data ?? [];
  return (
    <Shell def={def} onOpen={onOpen}>
      {rows.length === 0 ? (
        <div className="flex flex-1 items-center justify-center py-6 text-center text-sm text-text-muted">No finalized periods yet</div>
      ) : (
        <ul className="flex flex-col">
          {rows.map((r) => (
            <li key={r.id} className="flex items-center gap-2.5 border-t border-border-subtle py-2 first:border-t-0">
              <Lock size={14} className="shrink-0" style={{ color: "var(--color-accent-bronze-strong)" }} aria-hidden="true" />
              <div className="min-w-0"><p className="truncate text-sm text-text-primary">{new Intl.DateTimeFormat("en-GB", { month: "long", year: "numeric", timeZone: "UTC" }).format(new Date(r.period_start))} · {r.original_finalization ? "Original" : "Adjustment"}</p><p className="font-mono text-xs text-text-muted">Sealed {new Date(r.created_at).toLocaleDateString("en-GB")}</p></div>
            </li>
          ))}
        </ul>
      )}
    </Shell>
  );
}

/* ── analytics cards (REAL: analytics.* projections via dashboard_analytics_card) ─ */
const num = (x: unknown): number => (typeof x === "number" ? x : Number(x) || 0);
const TITLE = (s: string) => s.replace(/\b\w/g, (c) => c.toUpperCase());
const SEG_PALETTE = ["var(--color-brand-500)", "var(--color-accent-bronze)", "var(--color-status-info)", "var(--color-text-muted)"];

function AwaitingChip() {
  return (
    <span className="inline-flex items-center gap-2 rounded-full border border-border-default bg-surface-default px-3 py-1 text-[11px] font-semibold text-text-secondary shadow-1">
      <span className="relative h-[7px] w-[7px] rounded-full bg-action-primary"><span className="absolute -inset-1 animate-ping rounded-full border border-action-primary opacity-40" /></span>
      Awaiting data
    </span>
  );
}
function Awaiting({ label }: { label?: string }) {
  return (
    <div className="relative flex-1">
      <div className="absolute inset-0 grid place-items-center"><AwaitingChip /></div>
      {label && <p className="absolute inset-x-0 bottom-0 text-center text-[11px] text-text-muted">{label}</p>}
    </div>
  );
}
/** Segmented donut (circumference ≈ 100 at r=15.9155). Decorative; real values in text. */
function Donut({ segments }: { segments: { frac: number; color: string }[] }) {
  const arcs = segments
    .filter((s) => s.frac > 0.0001)
    .map((s) => ({ dash: Math.min(100, s.frac * 100), color: s.color }));
  const withOffset = arcs.map((a, i) => ({ ...a, offset: arcs.slice(0, i).reduce((sum, x) => sum + x.dash, 0) }));
  return (
    <svg width="60" height="60" viewBox="0 0 42 42" className="-rotate-90 shrink-0" aria-hidden="true">
      <circle cx="21" cy="21" r="15.9155" fill="none" stroke="var(--color-bg-raised)" strokeWidth="6" />
      {withOffset.map((a, i) => (
        <circle key={i} cx="21" cy="21" r="15.9155" fill="none" stroke={a.color} strokeWidth="6" strokeDasharray={`${a.dash} ${100 - a.dash}`} strokeDashoffset={-a.offset} />
      ))}
    </svg>
  );
}
function Ring({ pct }: { pct: number }) {
  const c = 2 * Math.PI * 31, dash = Math.max(0, Math.min(100, pct)) / 100 * c;
  return (
    <svg width="60" height="60" viewBox="0 0 74 74" className="-rotate-90 shrink-0" aria-hidden="true">
      <circle cx="37" cy="37" r="31" fill="none" stroke="var(--color-bg-raised)" strokeWidth="8" />
      <circle cx="37" cy="37" r="31" fill="none" stroke="var(--color-status-success)" strokeWidth="8" strokeLinecap="round" strokeDasharray={`${dash} ${c - dash}`} />
    </svg>
  );
}
function Legend({ items }: { items: { label: string; value: string; color: string }[] }) {
  return (
    <ul className="flex min-w-0 flex-1 flex-col gap-1 text-xs">
      {items.map((it) => (
        <li key={it.label} className="flex items-center gap-1.5">
          <span className="h-2 w-2 shrink-0 rounded-full" style={{ background: it.color }} aria-hidden="true" />
          <span className="truncate text-text-secondary">{it.label}</span>
          <span className="ml-auto font-mono tabular-nums text-text-muted">{it.value}</span>
        </li>
      ))}
    </ul>
  );
}

type Metric = Record<string, unknown>;

function AnalyticsCard({ def, businessIds, onOpen }: { def: CardDef; businessIds: string[]; onOpen: (d: CardDef) => void }) {
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const { data, isLoading } = useSWR<Metric>(["analytics-card", def.card_id, businessIds.join(",")], async () => {
    const { data } = await supabase.rpc("dashboard_analytics_card", { p_card_id: def.card_id, p_business_ids: businessIds });
    return (data ?? {}) as Metric;
  });
  return (
    <Shell def={def} onOpen={onOpen}>
      {isLoading || !data ? <Awaiting /> : <AnalyticsBody cardId={def.card_id} m={data} />}
    </Shell>
  );
}

function AnalyticsBody({ cardId, m }: { cardId: string; m: Metric }) {
  const refreshed = !!m.last_refreshed_at;
  const label = STUB_LABEL[cardId];

  if (cardId === "vat_summary") {
    if (!refreshed) return <Awaiting label={label} />;
    const output = num(m.output_vat), input = num(m.input_vat), net = num(m.net_position), total = output + input;
    return (
      <>
        <Hero value={formatMoney(net, "EUR")} color={net >= 0 ? income : expense} sub="Net VAT position" />
        <div className="mt-auto flex items-center gap-3">
          <Donut segments={[{ frac: total ? output / total : 0.5, color: "var(--color-brand-500)" }, { frac: total ? input / total : 0.5, color: "var(--color-accent-bronze)" }]} />
          <Legend items={[{ label: "Output VAT", value: formatMoney(output, "EUR"), color: "var(--color-brand-500)" }, { label: "Input VAT", value: formatMoney(input, "EUR"), color: "var(--color-accent-bronze)" }]} />
        </div>
      </>
    );
  }

  if (cardId === "income_overview" || cardId === "expense_overview") {
    const inc = cardId === "income_overview";
    const series = (Array.isArray(m.monthly_series) ? m.monthly_series : []) as { month: string; value: number }[];
    if (!refreshed || series.length === 0) return <Awaiting label={label} />;
    const max = Math.max(...series.map((s) => num(s.value)), 1);
    const col = inc ? "var(--color-status-success)" : "var(--color-status-danger)";
    return (
      <>
        <Hero value={`${inc ? "+" : ""}${formatMoney(num(m.mtd), "EUR")}`} color={inc ? income : expense} sub="This month" />
        <div className="mt-auto flex h-16 items-end gap-1.5" aria-hidden="true">
          {series.slice(-12).map((s, i) => <span key={i} title={`${s.month}: ${formatMoney(num(s.value), "EUR")}`} className="flex-1 rounded-t-sm" style={{ height: `${Math.max(6, (num(s.value) / max) * 100)}%`, background: col, opacity: 0.5 }} />)}
        </div>
        <p className="text-[11px] text-text-muted">12-month total {formatMoney(num(m.rolling_12m), "EUR")}</p>
      </>
    );
  }

  if (cardId === "subscription_recurring_totals") {
    if (!refreshed) return <Awaiting label={label} />;
    const count = num(m.vendor_count);
    const suppliers = (Array.isArray(m.suppliers) ? m.suppliers : []) as { tag: string; amount: number }[];
    if (count === 0) return <Awaiting label={label} />;
    return (
      <>
        <Hero value={formatMoney(num(m.total_monthly), "EUR")} color={expense} sub={`${count} recurring vendor${count === 1 ? "" : "s"} · per month`} />
        <ul className="mt-1 flex flex-col">
          {suppliers.slice(0, 3).map((s, i) => (
            <li key={i} className="flex items-center justify-between gap-2 border-t border-border-subtle py-2 text-sm first:border-t-0">
              <span className="truncate text-text-secondary">{s.tag ?? "Vendor"}</span>
              <span className="shrink-0 font-mono text-xs tabular-nums text-text-muted">{formatMoney(num(s.amount), "EUR")}</span>
            </li>
          ))}
        </ul>
      </>
    );
  }

  if (cardId === "client_invoice_aging") {
    if (!refreshed) return <Awaiting label={label} />;
    const b = (m.buckets ?? {}) as Record<string, unknown>;
    const rows: [string, number][] = [["Current", num(b.current)], ["1–30 days", num(b.d1_30)], ["31–60 days", num(b.d31_60)], ["60+ days", num(b.d60_plus)]];
    const max = Math.max(...rows.map((r) => r[1]), 1);
    return (
      <>
        <Hero value={formatMoney(num(m.total_outstanding), "EUR")} sub="Outstanding receivables" />
        <div className="mt-auto flex flex-col gap-2">
          {rows.map(([lbl, val]) => (
            <div key={lbl} className="flex items-center gap-3 text-xs">
              <span className="w-[72px] shrink-0 text-text-muted">{lbl}</span>
              <div className="h-2.5 flex-1 overflow-hidden rounded-sm bg-bg-raised"><div className="h-full rounded-sm" style={{ width: `${Math.max(2, (val / max) * 100)}%`, background: "var(--color-accent-bronze)" }} aria-hidden="true" /></div>
              <span className="w-16 text-right font-mono tabular-nums text-text-secondary">{formatMoney(val, "EUR")}</span>
            </div>
          ))}
        </div>
      </>
    );
  }

  if (cardId === "evidence_collection_status") {
    const total = num(m.total_transactions);
    if (!refreshed || total === 0) return <Awaiting label={label} />;
    const outstanding = num(m.outstanding_count), matched = Math.max(0, total - outstanding);
    const rate = Math.round((matched / total) * 100);
    return (
      <>
        <Hero value={String(outstanding)} sub="transactions awaiting evidence" />
        <div className="mt-auto flex items-center gap-3">
          <Ring pct={rate} />
          <div><div className="font-mono text-lg font-semibold tabular-nums text-text-primary">{rate}%</div><div className="text-[11px] text-text-muted">{matched} of {total} matched</div></div>
        </div>
      </>
    );
  }

  if (cardId === "tax_treatment_breakdown") {
    const treatments = (Array.isArray(m.treatments) ? m.treatments : []) as { treatment: string; amount: number; count: number }[];
    if (treatments.length === 0) return <Awaiting label={label} />;
    const total = treatments.reduce((a, t) => a + num(t.amount), 0) || 1;
    return (
      <>
        <Hero value={String(treatments.length)} sub={`VAT treatment${treatments.length === 1 ? "" : "s"} in use`} />
        <div className="mt-auto flex items-center gap-3">
          <Donut segments={treatments.map((t, i) => ({ frac: num(t.amount) / total, color: SEG_PALETTE[i % SEG_PALETTE.length] }))} />
          <Legend items={treatments.slice(0, 4).map((t, i) => ({ label: TITLE(t.treatment.replace(/_/g, " ").toLowerCase()), value: formatMoney(num(t.amount), "EUR"), color: SEG_PALETTE[i % SEG_PALETTE.length] }))} />
        </div>
      </>
    );
  }

  return <Awaiting label={label} />;
}
