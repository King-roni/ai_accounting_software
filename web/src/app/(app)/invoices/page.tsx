"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { Building2, Plus, Receipt, Search } from "lucide-react";
import { Badge, Button, EmptyState, ErrorState, Input, Table, Tabs, type Column } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import { useIsMobile } from "@/components/shell/use-is-mobile";
import { formatMoney } from "@/components/transactions/transaction-helpers";
import { InvoiceCreateDrawer } from "@/components/invoices/InvoiceCreateDrawer";
import { InvoiceDetailDrawer } from "@/components/invoices/InvoiceDetailDrawer";
import { INVOICE_COLUMNS, INVOICE_TYPE_LABEL, lifecycleBadge, type InvoiceRow } from "@/components/invoices/invoice-helpers";
import { RecurringPanel } from "@/components/recurring/RecurringPanel";

const STATUS_FILTERS: { id: string; label: string; match: (s: string) => boolean }[] = [
  { id: "ALL", label: "All", match: () => true },
  { id: "DRAFT", label: "Drafts", match: (s) => s === "DRAFT" },
  { id: "OPEN", label: "Awaiting payment", match: (s) => ["SENT", "PAYMENT_EXPECTED", "PARTIALLY_PAID"].includes(s) },
  { id: "PAID", label: "Settled", match: (s) => ["PAID", "OVERPAID", "REFUNDED", "FINALIZED"].includes(s) },
  { id: "CLOSED", label: "Closed", match: (s) => ["WRITTEN_OFF", "CREDITED", "CONVERTED_TO_TAX_INVOICE", "EXPIRED_UNCONVERTED"].includes(s) },
];

export default function InvoicesPage() {
  const { currentBusiness, isMultiBusiness } = useShell();
  const isMobile = useIsMobile();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);

  const [tab, setTab] = useState("invoices");
  const [filter, setFilter] = useState("ALL");
  const [q, setQ] = useState("");
  const [createOpen, setCreateOpen] = useState(false);
  const [detailId, setDetailId] = useState<string | null>(null);

  const key = currentBusiness ? ["invoices", currentBusiness.id] : null;
  const { data, error, isLoading, mutate } = useSWR<InvoiceRow[]>(key, async () => {
    const { data, error } = await supabase
      .from("invoices").select(INVOICE_COLUMNS)
      .eq("business_id", currentBusiness!.id)
      .order("created_at", { ascending: false });
    if (error) throw new Error(error.message);
    return (data ?? []) as unknown as InvoiceRow[];
  });

  const rows = useMemo(() => {
    const f = STATUS_FILTERS.find((x) => x.id === filter)!;
    const needle = q.trim().toLowerCase();
    return (data ?? []).filter((i) =>
      f.match(i.lifecycle_status) &&
      (!needle || (i.invoice_number?.toLowerCase().includes(needle) || i.client?.display_name?.toLowerCase().includes(needle))),
    );
  }, [data, filter, q]);

  const counts = useMemo(() => {
    const m = new Map<string, number>();
    STATUS_FILTERS.forEach((f) => m.set(f.id, (data ?? []).filter((i) => f.match(i.lifecycle_status)).length));
    return m;
  }, [data]);

  const columns: Column<InvoiceRow>[] = [
    { id: "number", header: "Number", cell: (i) => <span className="font-mono text-text-primary">{i.invoice_number ?? <span className="text-text-muted">Draft</span>}</span> },
    { id: "client", header: "Client", cell: (i) => <span className="text-text-primary">{i.client?.display_name ?? "—"}</span> },
    { id: "type", header: "Type", cell: (i) => <span className="text-text-secondary">{INVOICE_TYPE_LABEL[i.invoice_type]}</span> },
    { id: "issue", header: "Issued", sortable: true, sortValue: (i) => i.issue_date, cell: (i) => <span className="tabular-nums">{i.issue_date}</span> },
    { id: "due", header: "Due", cell: (i) => <span className="tabular-nums">{i.due_date}</span> },
    { id: "total", header: "Total", numeric: true, sortable: true, sortValue: (i) => i.total_amount, cell: (i) => <span className="tabular-nums text-text-primary">{formatMoney(i.total_amount, i.currency)}</span> },
    { id: "status", header: "Status", cell: (i) => { const b = lifecycleBadge(i.lifecycle_status); return <Badge variant={b.variant} size="sm">{b.label}</Badge>; } },
  ];

  const invoicesPanel = (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-2">
        {STATUS_FILTERS.map((f) => (
          <button key={f.id} type="button" onClick={() => setFilter(f.id)} className={`rounded-md border px-3 py-2 text-sm ${filter === f.id ? "border-action-primary bg-[color-mix(in_srgb,var(--color-action-primary)_8%,transparent)] text-text-primary" : "border-border-subtle text-text-secondary hover:text-text-primary"}`}>
            {f.label} <span className="tabular-nums text-text-muted">({counts.get(f.id) ?? 0})</span>
          </button>
        ))}
        <Input containerClassName="ml-auto min-w-56" leadingIcon={Search} placeholder="Search number or client" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search invoices" />
        {!isMobile && <Button leadingIcon={Plus} onClick={() => setCreateOpen(true)}>New invoice</Button>}
      </div>
      {error ? (
        <ErrorState description={error.message} onRetry={() => mutate()} />
      ) : (
        <Table
          columns={columns}
          data={rows}
          rowKey={(i) => i.id}
          loading={isLoading}
          onRowClick={(i) => setDetailId(i.id)}
          empty={
            q.trim() || filter !== "ALL"
              ? <EmptyState icon={Search} heading="No invoices match" body="Try another filter or search term." />
              : <EmptyState icon={Receipt} heading="No invoices yet" body="Create your first invoice for a client." action={<Button leadingIcon={Plus} onClick={() => setCreateOpen(true)}>New invoice</Button>} />
          }
        />
      )}
    </div>
  );

  return (
    <div className="flex flex-col gap-5">
      <header>
        <h1 className="text-2xl font-semibold text-text-primary">Invoices</h1>
        <p className="text-sm text-text-secondary">{isMultiBusiness ? "All businesses" : currentBusiness?.display_name ?? "—"} · {(data ?? []).length} total</p>
      </header>

      {!currentBusiness ? (
        <EmptyState icon={Building2} heading="Select a business" body="Choose a business to see its invoices." />
      ) : isMultiBusiness ? (
        <EmptyState icon={Building2} heading="Pick a single business" body="Invoicing is per-business. Switch from “All businesses” to a specific one." />
      ) : (
        <Tabs
          value={tab}
          onValueChange={setTab}
          tabs={[
            { id: "invoices", label: "Invoices", content: invoicesPanel },
            { id: "recurring", label: "Recurring", content: <RecurringPanel /> },
          ]}
        />
      )}

      <InvoiceCreateDrawer open={createOpen} onClose={() => setCreateOpen(false)} onCreated={() => mutate()} />
      <InvoiceDetailDrawer invoiceId={detailId} open={!!detailId} onClose={() => setDetailId(null)} onChanged={() => mutate()} />
    </div>
  );
}
