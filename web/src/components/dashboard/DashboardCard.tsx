"use client";
import { useMemo } from "react";
import useSWR from "swr";
import {
  ArrowDownLeft, ArrowUpRight, FileCheck2, GitCompareArrows, LayoutGrid,
  ListChecks, Lock, PieChart, Receipt, Repeat, TrendingUp, Users,
  type LucideIcon,
} from "lucide-react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import {
  categorySeries, isStubResult, summarizeRow, valueSeries,
  type CardDef, type DrillResult,
} from "./dashboard-helpers";
import { BarChart, DonutChart, Sparkline } from "./Charts";

const CARD_ICON: Record<string, LucideIcon> = {
  monthly_overview: TrendingUp,
  income_overview: ArrowDownLeft,
  expense_overview: ArrowUpRight,
  vat_summary: Receipt,
  subscription_recurring_totals: Repeat,
  client_invoice_aging: Users,
  evidence_collection_status: FileCheck2,
  recent_finalizations: Lock,
  tax_treatment_breakdown: PieChart,
  unmatched_transactions: GitCompareArrows,
  unresolved_review_items: ListChecks,
};

export function DashboardCard({ def, businessIds, onOpen }: { def: CardDef; businessIds: string[]; onOpen: (def: CardDef) => void }) {
  const { user } = useShell();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const Icon = CARD_ICON[def.card_id] ?? LayoutGrid;

  const { data, isLoading } = useSWR<DrillResult | null>(
    businessIds.length ? ["card", def.card_id, businessIds.join(",")] : null,
    async () => {
      const { data, error } = await supabase.rpc("dashboard_route_drill_down", {
        p_card_id: def.card_id, p_business_ids: businessIds, p_actor_user_id: user.id, p_filters: {}, p_page_size: 8, p_context: {},
      });
      if (error) throw new Error(error.message);
      return data as DrillResult;
    },
  );

  const rows = data?.rows ?? [];
  const stub = isStubResult(rows);

  return (
    <button
      type="button"
      onClick={() => onOpen(def)}
      className="group relative flex h-full w-full flex-col gap-3 rounded-xl border border-border-subtle bg-surface-default p-4 text-left shadow-1 transition-all duration-150 hover:-translate-y-px hover:border-border-default hover:shadow-2"
    >
      <div className="flex items-center justify-between gap-2">
        <span className="flex items-center gap-2 text-[11px] font-semibold uppercase tracking-[0.06em] text-text-muted">
          <Icon size={14} strokeWidth={1.75} aria-hidden="true" />
          {def.display_name}
        </span>
        <ArrowUpRight size={15} strokeWidth={1.75} aria-hidden="true" className="text-text-muted opacity-0 transition-opacity group-hover:opacity-100" />
      </div>

      {isLoading ? (
        <div className="flex h-20 flex-col justify-center gap-2"><div className="h-7 w-20 rounded skel" /><div className="h-3 w-full rounded skel" /></div>
      ) : stub ? (
        <StubBody description={def.description} />
      ) : (
        <CardBody def={def} rows={rows} />
      )}
    </button>
  );
}

function StubBody({ description }: { description: string | null }) {
  return (
    <>
      <div className="relative h-20 overflow-hidden">
        <div className="flex h-full items-end justify-between gap-1.5 px-1 opacity-60">
          {[40, 62, 48, 72, 55, 80, 60].map((h, i) => (
            <span key={i} className="flex-1 rounded-t-sm bg-border-default" style={{ height: `${h}%` }} />
          ))}
        </div>
        <div className="absolute inset-0 grid place-items-center">
          <span className="inline-flex items-center gap-2 rounded-full border border-border-default bg-surface-default px-3 py-1 text-[11px] font-semibold text-text-secondary shadow-1">
            <span className="relative h-[7px] w-[7px] rounded-full bg-action-primary">
              <span className="absolute -inset-1 animate-ping rounded-full border border-action-primary opacity-40" />
            </span>
            Awaiting data
          </span>
        </div>
      </div>
      {description && <p className="text-center text-[11px] text-text-muted">{description}</p>}
    </>
  );
}

function CardBody({ def, rows }: { def: CardDef; rows: DrillResult["rows"] }) {
  const count = rows.length;
  const cats = categorySeries(rows);
  const values = valueSeries(rows);
  if (count === 0) return <p className="py-3 text-sm text-text-muted">{def.description ?? "Nothing to show."}</p>;

  switch (def.chart_type) {
    case "BAR":
      return cats.length ? <BarChart data={cats.slice(0, 6)} ariaLabel={`${def.display_name} by category`} /> : <Hero count={count} underline />;
    case "DONUT":
      return cats.length ? <DonutChart data={cats.slice(0, 6)} ariaLabel={`${def.display_name} distribution`} /> : <Hero count={count} underline />;
    case "LINE":
      return values.length >= 2 ? <Sparkline values={values} ariaLabel={`${def.display_name} trend`} /> : <Hero count={count} underline />;
    case "KPI_NUMBER":
      return <Hero count={count} underline />;
    default:
      return (
        <div className="flex flex-col gap-2">
          <Hero count={count} />
          {values.length >= 2 && <Sparkline values={values} ariaLabel={`${def.display_name} amounts`} />}
          <ul className="flex flex-col gap-1 border-t border-border-subtle pt-2">
            {rows.slice(0, 3).map((r) => {
              const s = summarizeRow(r.payload);
              return (
                <li key={r.id ?? s.primary} className="flex items-center justify-between gap-2 text-sm">
                  <span className="truncate text-text-secondary">{s.primary}</span>
                  {s.secondary && <span className="shrink-0 font-mono text-xs tabular-nums text-text-muted">{s.secondary}</span>}
                </li>
              );
            })}
          </ul>
        </div>
      );
  }
}

function Hero({ count, underline }: { count: number; underline?: boolean }) {
  return (
    <div className="flex flex-col gap-0.5">
      <span
        className="font-mono text-[32px] font-semibold leading-none tracking-tight tabular-nums text-text-primary"
        style={underline ? { backgroundImage: "linear-gradient(var(--color-accent-bronze), var(--color-accent-bronze))", backgroundRepeat: "no-repeat", backgroundPosition: "0 100%", backgroundSize: "44px 2px", paddingBottom: "4px", width: "fit-content" } : undefined}
      >
        {count}{count === 8 ? "+" : ""}
      </span>
    </div>
  );
}
