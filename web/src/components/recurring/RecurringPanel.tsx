"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { Pause, Play, Plus, Repeat, Square } from "lucide-react";
import { Badge, Button, EmptyState, ErrorState, Table, useToast, type Column } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import { TemplateCreateDrawer } from "./TemplateCreateDrawer";
import { TEMPLATE_COLUMNS, TEMPLATE_STATUS_BADGE, cadenceLabel, type TemplateRow } from "./recurring-helpers";

type Decision = { decision?: string; reason_code?: string; reason?: string } | null;

export function RecurringPanel() {
  const { currentBusiness, user } = useShell();
  const { toast } = useToast();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [createOpen, setCreateOpen] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);

  const key = currentBusiness ? ["recurring-templates", currentBusiness.id] : null;
  const { data, error, isLoading, mutate } = useSWR<TemplateRow[]>(key, async () => {
    const { data, error } = await supabase
      .from("recurring_invoice_templates").select(TEMPLATE_COLUMNS)
      .eq("business_id", currentBusiness!.id)
      .order("created_at", { ascending: false });
    if (error) throw new Error(error.message);
    return (data ?? []) as unknown as TemplateRow[];
  });

  async function act(t: TemplateRow, fn: string, okMsg: string) {
    setBusyId(t.id);
    const { data: d, error } = await supabase.rpc(fn, { p_actor_user_id: user.id, p_template_id: t.id, p_context: {} });
    setBusyId(null);
    if (error) { toast({ variant: "error", title: "Action failed", description: error.message }); return; }
    const dec = d as Decision;
    if (dec?.decision && dec.decision !== "ALLOW") { toast({ variant: "warning", title: "Not allowed", description: dec.reason_code ?? dec.reason }); return; }
    toast({ variant: "success", title: okMsg });
    mutate();
  }

  const columns: Column<TemplateRow>[] = [
    { id: "name", header: "Template", sortable: true, sortValue: (t) => t.template_name.toLowerCase(), cell: (t) => <span className="font-medium text-text-primary">{t.template_name}</span> },
    { id: "client", header: "Client", cell: (t) => <span className="text-text-primary">{t.client?.display_name ?? "—"}</span> },
    { id: "cadence", header: "Cadence", cell: (t) => <span className="text-text-secondary">{cadenceLabel(t.cadence_kind)}</span> },
    { id: "next", header: "Next due", sortable: true, sortValue: (t) => t.next_due_date, cell: (t) => <span className="tabular-nums">{t.next_due_date}</span> },
    { id: "autosend", header: "Auto-send", cell: (t) => (t.auto_send ? <Badge variant="status-info" size="sm">On</Badge> : <span className="text-text-muted">Off</span>) },
    { id: "status", header: "Status", cell: (t) => { const b = TEMPLATE_STATUS_BADGE[t.status]; return <Badge variant={b.variant} size="sm">{b.label}</Badge>; } },
    {
      id: "actions", header: "", align: "right",
      cell: (t) => (
        <div className="flex justify-end gap-1" onClick={(e) => e.stopPropagation()}>
          {t.status === "ACTIVE" && <Button variant="ghost" size="sm" leadingIcon={Pause} loading={busyId === t.id} onClick={() => act(t, "recurring_template_pause", "Template paused")}>Pause</Button>}
          {t.status === "PAUSED" && <Button variant="ghost" size="sm" leadingIcon={Play} loading={busyId === t.id} onClick={() => act(t, "recurring_template_resume", "Template resumed")}>Resume</Button>}
          {t.status !== "ENDED" && <Button variant="ghost" size="sm" leadingIcon={Square} loading={busyId === t.id} onClick={() => act(t, "recurring_template_end", "Template ended")}>End</Button>}
        </div>
      ),
    },
  ];

  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center justify-between">
        <p className="text-sm text-text-secondary">{(data ?? []).length} template{(data ?? []).length === 1 ? "" : "s"}</p>
        <Button leadingIcon={Plus} size="sm" onClick={() => setCreateOpen(true)}>New template</Button>
      </div>

      {error ? (
        <ErrorState description={error.message} onRetry={() => mutate()} />
      ) : (
        <Table
          columns={columns}
          data={data ?? []}
          rowKey={(t) => t.id}
          loading={isLoading}
          empty={<EmptyState icon={Repeat} heading="No recurring templates" body="Create a template to auto-generate invoices on a schedule." action={<Button leadingIcon={Plus} onClick={() => setCreateOpen(true)}>New template</Button>} />}
        />
      )}

      <TemplateCreateDrawer open={createOpen} onClose={() => setCreateOpen(false)} onCreated={() => mutate()} />
    </div>
  );
}
