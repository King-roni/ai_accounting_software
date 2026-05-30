"use client";
import { useMemo } from "react";
import useSWR from "swr";
import { Badge, Drawer, EmptyState, Skeleton } from "@/components/ui";
import { Inbox } from "lucide-react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import { CHART_TYPE_LABEL, DATA_SOURCE_BADGE, isStubResult, summarizeRow, type CardDef, type DrillResult } from "./dashboard-helpers";

export function DrillDownDrawer({ def, businessIds, open, onClose }: { def: CardDef | null; businessIds: string[]; open: boolean; onClose: () => void }) {
  return (
    <Drawer open={open} onClose={onClose} title={def?.display_name ?? "Details"} width={560}>
      {open && def && <Body def={def} businessIds={businessIds} />}
    </Drawer>
  );
}

function Body({ def, businessIds }: { def: CardDef; businessIds: string[] }) {
  const { user } = useShell();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const { data, isLoading, error } = useSWR<DrillResult | null>(["drill", def.card_id, businessIds.join(",")], async () => {
    const { data, error } = await supabase.rpc("dashboard_route_drill_down", {
      p_card_id: def.card_id, p_business_ids: businessIds, p_actor_user_id: user.id, p_filters: {}, p_page_size: 50, p_context: {},
    });
    if (error) throw new Error(error.message);
    return data as DrillResult;
  });
  const rows = data?.rows ?? [];
  const ds = DATA_SOURCE_BADGE[def.data_source];

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant={ds.variant} size="sm">{ds.label}</Badge>
        <span className="text-xs text-text-muted">{CHART_TYPE_LABEL[def.chart_type]}</span>
        {def.description && <span className="text-sm text-text-secondary">{def.description}</span>}
      </div>

      {isLoading ? (
        <div className="flex flex-col gap-2">{[0, 1, 2, 3, 4].map((i) => <Skeleton key={i} height={20} />)}</div>
      ) : error ? (
        <p className="text-sm" style={{ color: "var(--color-status-danger)" }}>{error.message}</p>
      ) : isStubResult(rows) ? (
        <EmptyState icon={Inbox} heading="Awaiting aggregated data" body="This analytics card will list records once the period’s data is aggregated." />
      ) : rows.length === 0 ? (
        <EmptyState icon={Inbox} heading="Nothing here" body="This card has no records for the current selection." />
      ) : (
        <>
          <p className="text-sm text-text-muted">{rows.length}{rows.length === 50 ? "+" : ""} record{rows.length === 1 ? "" : "s"}</p>
          <ul className="flex flex-col divide-y divide-border-subtle rounded-md border border-border-subtle">
            {rows.map((r) => {
              const s = summarizeRow(r.payload);
              return (
                <li key={r.id} className="flex items-center justify-between gap-3 px-3 py-2 text-sm">
                  <span className="min-w-0 truncate text-text-primary">{s.primary}</span>
                  {s.secondary && <span className="shrink-0 tabular-nums text-text-secondary">{s.secondary}</span>}
                </li>
              );
            })}
          </ul>
        </>
      )}
    </div>
  );
}
