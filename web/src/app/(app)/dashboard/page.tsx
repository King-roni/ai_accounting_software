"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { Building2, RefreshCw } from "lucide-react";
import { Button, Card, CardBody, EmptyState, ErrorState, Skeleton, useToast } from "@/components/ui";
import { formatPeriod, useShell } from "@/components/shell/ShellContext";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { DashboardCard } from "@/components/dashboard/DashboardCard";
import { DrillDownDrawer } from "@/components/dashboard/DrillDownDrawer";
import { CARD_ORDER, CARD_SPAN, type CardDef } from "@/components/dashboard/dashboard-helpers";

export default function DashboardPage() {
  const { currentBusiness, businesses, isMultiBusiness, period, user } = useShell();
  const { toast } = useToast();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const heading = isMultiBusiness ? "Multi-business overview" : currentBusiness?.display_name ?? "Dashboard";

  const [drill, setDrill] = useState<CardDef | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  const businessIds = useMemo(
    () => (isMultiBusiness ? businesses.map((b) => b.id) : currentBusiness ? [currentBusiness.id] : []),
    [isMultiBusiness, businesses, currentBusiness],
  );

  const { data: cards, error, isLoading } = useSWR<CardDef[]>(["dashboard-cards"], async () => {
    const { data, error } = await supabase.from("dashboard_card_definitions").select("*").order("default_position");
    if (error) throw new Error(error.message);
    return (data ?? []) as CardDef[];
  });

  async function refresh() {
    if (!currentBusiness) return;
    setRefreshing(true);
    const { error } = await supabase.rpc("dashboard_trigger_manual_refresh", {
      p_business_id: currentBusiness.id, p_organization_id: currentBusiness.organization_id, p_actor_user_id: user.id, p_context: {},
    });
    setRefreshing(false);
    toast(error ? { variant: "error", title: "Refresh failed", description: error.message } : { variant: "success", title: "Dashboard refresh queued" });
  }

  return (
    <div className="flex flex-col gap-5">
      <header className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold text-text-primary">{heading}</h1>
          <p className="text-sm text-text-secondary tabular-nums">{formatPeriod(period)}</p>
        </div>
        {!isMultiBusiness && currentBusiness && (
          <Button variant="secondary" size="sm" leadingIcon={RefreshCw} loading={refreshing} onClick={refresh}>Refresh now</Button>
        )}
      </header>

      {businessIds.length === 0 ? (
        <EmptyState icon={Building2} heading="No businesses yet" body="Once you have access to a business, its dashboard appears here." />
      ) : error ? (
        <ErrorState description={error.message} />
      ) : isLoading ? (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
          {Array.from({ length: 8 }).map((_, i) => <Card key={i}><CardBody className="pt-5"><Skeleton height={110} /></CardBody></Card>)}
        </div>
      ) : (
        <div className="grid grid-cols-1 gap-4 [grid-auto-flow:row_dense] sm:grid-cols-2 xl:grid-cols-4">
          {[...(cards ?? [])]
            .sort((a, b) => {
              const ia = CARD_ORDER.indexOf(a.card_id), ib = CARD_ORDER.indexOf(b.card_id);
              return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib);
            })
            .map((def) => (
              <div key={def.card_id} className={(CARD_SPAN[def.card_id] ?? 1) === 2 ? "sm:col-span-2" : ""}>
                <DashboardCard def={def} businessIds={businessIds} onOpen={setDrill} />
              </div>
            ))}
        </div>
      )}

      <DrillDownDrawer def={drill} businessIds={businessIds} open={!!drill} onClose={() => setDrill(null)} />
    </div>
  );
}
