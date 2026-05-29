"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { Building2, Contact, Plus, Search, UserX } from "lucide-react";
import { Badge, Button, EmptyState, ErrorState, Input, Table, useToast, type Column } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import { ClientFormDrawer } from "@/components/clients/ClientFormDrawer";
import {
  clientStatusBadge, flagEmoji, vatFormatBadge, vatTreatmentLabel, type ClientRow,
} from "@/components/clients/client-helpers";

export default function ClientsPage() {
  const { currentBusiness, isMultiBusiness, user } = useShell();
  const { toast } = useToast();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);

  const [showInactive, setShowInactive] = useState(false);
  const [q, setQ] = useState("");
  const [editing, setEditing] = useState<ClientRow | null>(null);
  const [formOpen, setFormOpen] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);

  const key = currentBusiness ? ["clients", currentBusiness.id, showInactive] : null;
  const { data, error, isLoading, mutate } = useSWR<ClientRow[]>(key, async () => {
    const { data, error } = await supabase.rpc("client_list", {
      p_business_id: currentBusiness!.id, p_include_disabled: showInactive, p_limit: 200, p_offset: 0,
    });
    if (error) throw new Error(error.message);
    return ((data as { clients?: ClientRow[] })?.clients ?? []) as ClientRow[];
  });

  const rows = useMemo(() => {
    const needle = q.trim().toLowerCase();
    const list = data ?? [];
    if (!needle) return list;
    return list.filter((c) =>
      [c.display_name, c.legal_name, c.billing_email, c.vat_number]
        .some((v) => v?.toLowerCase().includes(needle)),
    );
  }, [data, q]);

  async function disable(c: ClientRow) {
    setBusyId(c.id);
    const { data: d, error } = await supabase.rpc("client_disable", { p_actor_user_id: user.id, p_client_id: c.id, p_context: {} });
    setBusyId(null);
    if (error) { toast({ variant: "error", title: "Couldn’t disable client", description: error.message }); return; }
    const dec = d as { decision?: string; reason?: string } | null;
    if (dec?.decision && dec.decision !== "ALLOW") { toast({ variant: "warning", title: "Not allowed", description: dec.reason }); return; }
    toast({ variant: "success", title: "Client disabled" });
    mutate();
  }

  const columns: Column<ClientRow>[] = [
    {
      id: "name", header: "Name", sortable: true, sortValue: (c) => c.display_name.toLowerCase(),
      cell: (c) => (
        <div className="min-w-0">
          <p className="truncate font-medium text-text-primary">{c.display_name}</p>
          {c.legal_name && c.legal_name !== c.display_name && <p className="truncate text-xs italic text-text-muted">{c.legal_name}</p>}
        </div>
      ),
    },
    {
      id: "country", header: "Country",
      cell: (c) => (c.country ? <span className="tabular-nums">{flagEmoji(c.country)} {c.country}</span> : <span className="text-text-muted">—</span>),
    },
    {
      id: "vat", header: "VAT number",
      cell: (c) => {
        const b = vatFormatBadge(c);
        return c.vat_number ? (
          <span className="inline-flex items-center gap-2">
            <span className="tabular-nums">{c.vat_number}</span>
            {b && <Badge variant={b.variant} size="sm">{b.label}</Badge>}
          </span>
        ) : <span className="text-text-muted">—</span>;
      },
    },
    { id: "vat_treatment", header: "Default VAT", cell: (c) => <span className="text-text-secondary">{vatTreatmentLabel(c.default_vat_treatment)}</span> },
    { id: "terms", header: "Terms", numeric: true, cell: (c) => <span>{c.default_payment_terms_days}d</span> },
    {
      id: "status", header: "Status",
      cell: (c) => { const b = clientStatusBadge(c); return <Badge variant={b.variant} size="sm">{b.label}</Badge>; },
    },
    {
      id: "actions", header: "", align: "right",
      cell: (c) => (
        <div className="flex justify-end gap-1" onClick={(e) => e.stopPropagation()}>
          <Button variant="tertiary" size="sm" onClick={() => { setEditing(c); setFormOpen(true); }}>Edit</Button>
          {!c.disabled_at && (
            <Button variant="ghost" size="sm" leadingIcon={UserX} loading={busyId === c.id} onClick={() => disable(c)}>Disable</Button>
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="flex flex-col gap-5">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold text-text-primary">Clients</h1>
          <p className="text-sm text-text-secondary">
            {isMultiBusiness ? "All businesses" : currentBusiness?.display_name ?? "—"} · {(data ?? []).length} {showInactive ? "total" : "active"}
          </p>
        </div>
        {currentBusiness && !isMultiBusiness && (
          <Button leadingIcon={Plus} onClick={() => { setEditing(null); setFormOpen(true); }}>New client</Button>
        )}
      </header>

      {currentBusiness && !isMultiBusiness && (
        <div className="flex flex-wrap items-center gap-3">
          <Input
            containerClassName="min-w-64 flex-1"
            leadingIcon={Search}
            placeholder="Search by name, email, or VAT number"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            aria-label="Search clients"
          />
          <label className="flex cursor-pointer items-center gap-2 text-sm text-text-secondary">
            <input type="checkbox" checked={showInactive} onChange={(e) => setShowInactive(e.target.checked)} className="accent-[var(--color-action-primary)]" />
            Show inactive
          </label>
        </div>
      )}

      {!currentBusiness ? (
        <EmptyState icon={Building2} heading="Select a business" body="Choose a business to manage its clients." />
      ) : isMultiBusiness ? (
        <EmptyState icon={Building2} heading="Pick a single business" body="Client management is per-business. Switch from “All businesses” to a specific one." />
      ) : error ? (
        <ErrorState description={error.message} onRetry={() => mutate()} />
      ) : (
        <Table
          columns={columns}
          data={rows}
          rowKey={(c) => c.id}
          loading={isLoading}
          onRowClick={(c) => { setEditing(c); setFormOpen(true); }}
          empty={
            q.trim()
              ? <EmptyState icon={Search} heading="No clients match your search" body="Try a different name, email, or VAT number." />
              : <EmptyState icon={Contact} heading="No clients yet" body="Add your first client to start creating invoices." action={<Button leadingIcon={Plus} onClick={() => { setEditing(null); setFormOpen(true); }}>New client</Button>} />
          }
        />
      )}

      <ClientFormDrawer open={formOpen} client={editing} onClose={() => setFormOpen(false)} onSaved={() => mutate()} />
    </div>
  );
}
