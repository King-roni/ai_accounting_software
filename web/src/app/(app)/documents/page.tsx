"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { Building2, Plus, Search } from "lucide-react";
import { Badge, Button, EmptyState, ErrorState, Input, Select, Table, type Column } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import {
  DOC_COLUMNS, EXTRACTION_BADGE, SOURCE_LABEL, docTitle, fmtMoney, type DocRow,
} from "@/components/documents/document-helpers";
import { DocumentDetailDrawer } from "@/components/documents/DocumentDetailDrawer";
import { UploadDocumentDrawer } from "@/components/documents/UploadDocumentDrawer";

export default function DocumentsPage() {
  const { currentBusiness, isMultiBusiness } = useShell();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);

  const key = currentBusiness ? ["docs", currentBusiness.id] : null;
  const { data, error, isLoading, mutate } = useSWR<DocRow[]>(key, async () => {
    const res = await supabase
      .from("documents")
      .select(DOC_COLUMNS)
      .eq("business_id", currentBusiness!.id)
      .order("created_at", { ascending: false });
    if (res.error) throw new Error(res.error.message);
    return (res.data ?? []) as unknown as DocRow[];
  });

  const [search, setSearch] = useState("");
  const [type, setType] = useState("ALL");
  const [status, setStatus] = useState("ALL");
  const [detail, setDetail] = useState<DocRow | null>(null);
  const [uploadOpen, setUploadOpen] = useState(false);

  const rows = useMemo(() => {
    const q = search.trim().toLowerCase();
    return (data ?? []).filter((d) => {
      if (type !== "ALL" && d.document_type !== type) return false;
      if (status !== "ALL" && d.extraction_status !== status) return false;
      if (q) {
        const hay = `${docTitle(d)} ${d.invoice_number ?? ""} ${d.original_filename ?? ""}`.toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });
  }, [data, type, status, search]);

  const columns: Column<DocRow>[] = [
    { id: "type", header: "Type", width: 96, cell: (d) => <span className="text-xs font-medium text-text-secondary">{d.document_type}</span> },
    {
      id: "doc", header: "Document",
      cell: (d) => (
        <div className="min-w-0">
          <div className="truncate text-text-primary">{docTitle(d)}</div>
          <div className="truncate text-xs text-text-muted">{d.invoice_number ?? d.original_filename ?? "—"}</div>
        </div>
      ),
    },
    { id: "date", header: "Date", width: 110, sortable: true, sortValue: (d) => d.invoice_date ?? "", cell: (d) => <span className="tabular-nums text-text-secondary">{d.invoice_date ?? "—"}</span> },
    { id: "amount", header: "Amount", numeric: true, width: 130, sortable: true, sortValue: (d) => Number(d.amount_total ?? 0), cell: (d) => <span className="text-text-primary">{fmtMoney(d.amount_total, d.currency)}</span> },
    { id: "source", header: "Source", width: 130, cell: (d) => <span className="text-text-secondary">{SOURCE_LABEL[d.source]}</span> },
    { id: "status", header: "Status", width: 150, cell: (d) => <Badge variant={EXTRACTION_BADGE[d.extraction_status].variant} size="sm">{EXTRACTION_BADGE[d.extraction_status].label}</Badge> },
  ];

  return (
    <div className="flex flex-col gap-5">
      <header className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold text-text-primary">Documents</h1>
          <p className="text-sm text-text-secondary">{isMultiBusiness ? "All businesses" : currentBusiness?.display_name ?? "—"}</p>
        </div>
        <Button leadingIcon={Plus} disabled={!currentBusiness} onClick={() => setUploadOpen(true)}>Upload document</Button>
      </header>

      {currentBusiness && (
        <div className="flex flex-wrap items-end gap-3">
          <Input containerClassName="w-64" placeholder="Search supplier, invoice no…" leadingIcon={Search} value={search} onChange={(e) => setSearch(e.target.value)} />
          <Select containerClassName="w-44" aria-label="Type" value={type} onChange={(e) => setType(e.target.value)}>
            <option value="ALL">All types</option>
            <option value="INVOICE">Invoice</option>
            <option value="RECEIPT">Receipt</option>
            <option value="CONTRACT">Contract</option>
            <option value="PROOF_OF_PAYMENT">Proof of payment</option>
            <option value="BANK_EVIDENCE">Bank evidence</option>
            <option value="OTHER">Other</option>
          </Select>
          <Select containerClassName="w-48" aria-label="Status" value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="ALL">All statuses</option>
            <option value="DISCOVERED">Discovered</option>
            <option value="INGESTED">Ingested</option>
            <option value="EXTRACTED">Extracted</option>
            <option value="LINKED_CANDIDATE">Linked candidate</option>
            <option value="MATCHED">Matched</option>
            <option value="DISMISSED">Dismissed</option>
          </Select>
        </div>
      )}

      {!currentBusiness ? (
        <EmptyState icon={Building2} heading="Select a business" body="Choose a business to see its documents." />
      ) : error ? (
        <ErrorState description={error.message} onRetry={() => mutate()} />
      ) : (
        <Table
          columns={columns}
          data={rows}
          rowKey={(d) => d.id}
          loading={isLoading}
          density="comfortable"
          onRowClick={setDetail}
          empty={
            <EmptyState
              heading="No documents yet"
              body="Upload an invoice or receipt, or let the email/Drive finders discover them."
              action={<Button size="sm" leadingIcon={Plus} onClick={() => setUploadOpen(true)}>Upload document</Button>}
            />
          }
        />
      )}

      <DocumentDetailDrawer row={detail} open={!!detail} onClose={() => setDetail(null)} />
      <UploadDocumentDrawer open={uploadOpen} onClose={() => setUploadOpen(false)} />
    </div>
  );
}
