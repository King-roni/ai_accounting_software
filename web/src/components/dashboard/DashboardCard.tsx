"use client";
import { useMemo } from "react";
import useSWR from "swr";
import { ArrowRight } from "lucide-react";
import { Badge, Card, CardBody, Skeleton } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import { CHART_TYPE_LABEL, DATA_SOURCE_BADGE, summarizeRow, type CardDef, type DrillResult } from "./dashboard-helpers";

export function DashboardCard({ def, businessIds, onOpen }: { def: CardDef; businessIds: string[]; onOpen: (def: CardDef) => void }) {
  const { user } = useShell();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);

  const { data, isLoading } = useSWR<DrillResult | null>(
    businessIds.length ? ["card", def.card_id, businessIds.join(",")] : null,
    async () => {
      const { data, error } = await supabase.rpc("dashboard_route_drill_down", {
        p_card_id: def.card_id, p_business_ids: businessIds, p_actor_user_id: user.id, p_filters: {}, p_page_size: 6, p_context: {},
      });
      if (error) throw new Error(error.message);
      return data as DrillResult;
    },
  );

  const rows = data?.rows ?? [];
  const count = rows.length;
  const ds = DATA_SOURCE_BADGE[def.data_source];

  return (
    <Card interactive onClick={() => onOpen(def)} className="flex flex-col">
      <CardBody className="flex flex-1 flex-col gap-3 pt-5">
        <div className="flex items-start justify-between gap-2">
          <div className="min-w-0">
            <h3 className="truncate font-semibold text-text-primary">{def.display_name}</h3>
            {def.description && <p className="line-clamp-1 text-xs text-text-muted">{def.description}</p>}
          </div>
          <div className="flex shrink-0 items-center gap-1">
            <Badge variant={ds.variant} size="sm">{ds.label}</Badge>
          </div>
        </div>

        {isLoading ? (
          <div className="flex flex-col gap-2"><Skeleton height={28} className="w-16" /><Skeleton height={14} /><Skeleton height={14} className="w-2/3" /></div>
        ) : (
          <>
            <div className="flex items-baseline gap-2">
              <span className="text-3xl font-semibold tabular-nums text-text-primary">{count}{count === 6 ? "+" : ""}</span>
              <span className="text-xs text-text-muted">{CHART_TYPE_LABEL[def.chart_type]}</span>
            </div>
            {rows.length === 0 ? (
              <p className="text-sm text-text-muted">Nothing to show.</p>
            ) : (
              <ul className="flex flex-col gap-1">
                {rows.slice(0, 4).map((r) => {
                  const s = summarizeRow(r.payload);
                  return (
                    <li key={r.id} className="flex items-center justify-between gap-2 text-sm">
                      <span className="truncate text-text-secondary">{s.primary}</span>
                      {s.secondary && <span className="shrink-0 tabular-nums text-text-muted">{s.secondary}</span>}
                    </li>
                  );
                })}
              </ul>
            )}
          </>
        )}

        <div className="mt-auto flex items-center gap-1 pt-1 text-xs font-medium text-action-primary">
          View details <ArrowRight size={13} aria-hidden="true" />
        </div>
      </CardBody>
    </Card>
  );
}
