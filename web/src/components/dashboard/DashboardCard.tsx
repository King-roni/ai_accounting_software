"use client";
import { useMemo } from "react";
import useSWR from "swr";
import { ArrowRight, Clock } from "lucide-react";
import { Badge, Card, CardBody, Skeleton } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import {
  CHART_TYPE_LABEL, DATA_SOURCE_BADGE, categorySeries, isStubResult, summarizeRow, valueSeries,
  type CardDef, type DrillResult,
} from "./dashboard-helpers";
import { BarChart, DonutChart, Sparkline } from "./Charts";

export function DashboardCard({ def, businessIds, onOpen }: { def: CardDef; businessIds: string[]; onOpen: (def: CardDef) => void }) {
  const { user } = useShell();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);

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
  const ds = DATA_SOURCE_BADGE[def.data_source];

  return (
    <Card interactive onClick={() => onOpen(def)} className="flex flex-col">
      <CardBody className="flex flex-1 flex-col gap-3 pt-5">
        <div className="flex items-start justify-between gap-2">
          <div className="min-w-0">
            <h3 className="truncate font-semibold text-text-primary">{def.display_name}</h3>
            {def.description && <p className="line-clamp-1 text-xs text-text-muted">{def.description}</p>}
          </div>
          <Badge variant={ds.variant} size="sm">{ds.label}</Badge>
        </div>

        <div className="flex-1">
          {isLoading ? (
            <div className="flex flex-col gap-2"><Skeleton height={28} className="w-16" /><Skeleton height={40} /></div>
          ) : stub ? (
            <div className="flex items-center gap-2 rounded-md bg-bg-raised px-3 py-4 text-xs text-text-muted">
              <Clock size={14} aria-hidden="true" className="shrink-0" />
              <span>Analytics for this card populate once the period’s data is aggregated.</span>
            </div>
          ) : (
            <CardViz def={def} rows={rows} />
          )}
        </div>

        <div className="mt-auto flex items-center gap-1 pt-1 text-xs font-medium text-action-primary">
          View details <ArrowRight size={13} aria-hidden="true" />
        </div>
      </CardBody>
    </Card>
  );
}

function CardViz({ def, rows }: { def: CardDef; rows: DrillResult["rows"] }) {
  const count = rows.length;
  const cats = categorySeries(rows);
  const values = valueSeries(rows);

  if (count === 0) return <p className="py-4 text-sm text-text-muted">Nothing to show.</p>;

  switch (def.chart_type) {
    case "BAR":
      return cats.length ? <BarChart data={cats.slice(0, 6)} ariaLabel={`${def.display_name} by category`} />
        : <Count count={count} type={def.chart_type} />;
    case "DONUT":
      return cats.length ? <DonutChart data={cats.slice(0, 6)} ariaLabel={`${def.display_name} distribution`} />
        : <Count count={count} type={def.chart_type} />;
    case "LINE":
      return values.length >= 2 ? <Sparkline values={values} ariaLabel={`${def.display_name} trend`} />
        : <Count count={count} type={def.chart_type} />;
    case "KPI_NUMBER":
      return <Count count={count} type={def.chart_type} />;
    default:
      // LIST / TABLE — a preview, with a trend sparkline when the rows carry amounts.
      return (
        <div className="flex flex-col gap-2">
          <Count count={count} type={def.chart_type} />
          {values.length >= 2 && <Sparkline values={values} ariaLabel={`${def.display_name} amounts`} />}
          <ul className="flex flex-col gap-1">
            {rows.slice(0, 3).map((r) => {
              const s = summarizeRow(r.payload);
              return (
                <li key={r.id ?? s.primary} className="flex items-center justify-between gap-2 text-sm">
                  <span className="truncate text-text-secondary">{s.primary}</span>
                  {s.secondary && <span className="shrink-0 tabular-nums text-text-muted">{s.secondary}</span>}
                </li>
              );
            })}
          </ul>
        </div>
      );
  }
}

function Count({ count, type }: { count: number; type: string }) {
  return (
    <div className="flex items-baseline gap-2">
      <span className="text-3xl font-semibold tabular-nums text-text-primary">{count}{count === 8 ? "+" : ""}</span>
      <span className="text-xs text-text-muted">{CHART_TYPE_LABEL[type]}</span>
    </div>
  );
}
