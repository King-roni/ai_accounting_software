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
  STUB_LABEL, STUB_VARIANT, UNMATCHED_COLUMNS, UNMATCHED_STATUSES, unmatchedLabel,
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
    default: return <StubCard def={def} onOpen={onOpen} />;
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

/* ── stub cards: bespoke faint chart + "Awaiting data" + label ───────────── */
function AwaitingChip() {
  return (
    <span className="inline-flex items-center gap-2 rounded-full border border-border-default bg-surface-default px-3 py-1 text-[11px] font-semibold text-text-secondary shadow-1">
      <span className="relative h-[7px] w-[7px] rounded-full bg-action-primary"><span className="absolute -inset-1 animate-ping rounded-full border border-action-primary opacity-40" /></span>
      Awaiting data
    </span>
  );
}
const DONUT_LEGEND: Record<string, string[]> = {
  vat_summary: ["Input VAT", "Output VAT", "Net VAT"],
  tax_treatment_breakdown: ["Standard 19%", "Reduced 9/5%", "Reverse charge"],
};
function StubCard({ def, onOpen }: { def: CardDef; onOpen: (d: CardDef) => void }) {
  const variant = STUB_VARIANT[def.card_id] ?? "bars";
  return (
    <Shell def={def} onOpen={onOpen}>
      <div className="relative flex-1">
        <div>
          {variant === "bars" && (
            <div className="flex h-20 items-end justify-between gap-1.5 px-1">
              {[40, 62, 48, 78, 55, 88, 70].map((h, i) => <span key={i} className="flex-1 rounded-t-sm bg-border-default" style={{ height: `${h}%` }} />)}
            </div>
          )}
          {variant === "line" && (
            <svg viewBox="0 0 400 80" className="h-20 w-full" preserveAspectRatio="none"><polyline points="0,60 57,55 114,57 171,43 228,47 285,33 342,37 400,23" fill="none" stroke="var(--color-border-strong)" strokeWidth="2.5" vectorEffect="non-scaling-stroke" /></svg>
          )}
          {variant === "ring" && (
            <div className="flex h-20 items-center justify-center">
              <svg width="74" height="74" viewBox="0 0 74 74" className="-rotate-90"><circle cx="37" cy="37" r="31" fill="none" stroke="var(--color-bg-raised)" strokeWidth="8" /><circle cx="37" cy="37" r="31" fill="none" stroke="var(--color-border-strong)" strokeWidth="8" strokeDasharray="120 75" /></svg>
            </div>
          )}
          {(variant === "donut") && (
            <div className="flex h-20 items-center gap-3">
              <svg width="74" height="74" viewBox="0 0 42 42" className="-rotate-90 shrink-0"><circle cx="21" cy="21" r="15.9" fill="none" stroke="var(--color-bg-raised)" strokeWidth="6" /><circle cx="21" cy="21" r="15.9" fill="none" stroke="var(--color-border-strong)" strokeWidth="6" strokeDasharray="38 62" /></svg>
              <ul className="flex min-w-0 flex-1 flex-col gap-1 text-xs">
                {(DONUT_LEGEND[def.card_id] ?? ["—", "—", "—"]).map((n) => (
                  <li key={n} className="flex items-center gap-1.5"><span className="h-2 w-2 shrink-0 rounded-full bg-border-strong" /><span className="truncate text-text-secondary">{n}</span><span className="ml-auto text-text-muted">—</span></li>
                ))}
              </ul>
            </div>
          )}
          {variant === "aging" && (
            <div className="flex flex-col gap-2">
              {["Current", "1–30 days", "31–60 days", "60+ days"].map((b, i) => (
                <div key={b} className="flex items-center gap-3 text-xs"><span className="w-20 shrink-0 text-text-muted">{b}</span><div className="h-2.5 flex-1 overflow-hidden rounded-sm bg-bg-raised"><div className="h-full rounded-sm bg-border-default" style={{ width: `${[60, 28, 14, 6][i]}%` }} /></div><span className="w-6 text-right text-text-muted">—</span></div>
              ))}
            </div>
          )}
        </div>
        <div className="absolute inset-0 grid place-items-center"><AwaitingChip /></div>
      </div>
      {STUB_LABEL[def.card_id] && <p className="text-center text-[11px] text-text-muted">{STUB_LABEL[def.card_id]}</p>}
    </Shell>
  );
}
