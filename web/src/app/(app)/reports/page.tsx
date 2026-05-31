"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { Building2, Download, FileSpreadsheet, FileText } from "lucide-react";
import { Badge, Button, EmptyState, ErrorState, Table, Tabs, useToast, type Column } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import { RequestExportDrawer } from "@/components/reports/RequestExportDrawer";
import { getExportDownloadUrl } from "@/lib/exports/actions";
import {
  EXPORT_COLUMNS, EXPORT_STATUS_BADGE, SCOPE_LABEL, kindLabel,
  type ExportCatalogueRow, type ExportRow,
} from "@/components/reports/report-helpers";

export default function ReportsPage() {
  const { currentBusiness, isMultiBusiness } = useShell();
  const { toast } = useToast();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [tab, setTab] = useState("catalogue");
  const [entry, setEntry] = useState<ExportCatalogueRow | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);

  const { data: catalogue } = useSWR<ExportCatalogueRow[]>(["export-catalogue"], async () => {
    const { data, error } = await supabase.from("export_catalogue_definitions").select("*").order("display_name");
    if (error) throw new Error(error.message);
    return (data ?? []) as ExportCatalogueRow[];
  });

  const exKey = currentBusiness ? ["exports", currentBusiness.id] : null;
  const { data: exports, error, isLoading, mutate } = useSWR<ExportRow[]>(exKey, async () => {
    const { data, error } = await supabase.from("exports").select(EXPORT_COLUMNS).eq("business_id", currentBusiness!.id).order("requested_at", { ascending: false });
    if (error) throw new Error(error.message);
    return (data ?? []) as unknown as ExportRow[];
  });

  async function download(e: ExportRow) {
    setBusyId(e.id);
    const res = await getExportDownloadUrl(e.id);
    setBusyId(null);
    if (!res.ok) {
      const msg =
        res.error === "EXPORT_NOT_READY"
          ? "The export file isn’t generated yet."
          : res.error;
      toast({ variant: "error", title: "Download failed", description: msg });
      return;
    }
    window.open(res.url, "_blank", "noopener");
    mutate();
  }

  const catalogueColumns: Column<ExportCatalogueRow>[] = [
    {
      id: "name", header: "Report", cell: (c) => (
        <div className="flex items-center gap-2">
          {c.supported_formats.includes("PDF") ? <FileText size={16} className="text-text-muted" aria-hidden="true" /> : <FileSpreadsheet size={16} className="text-text-muted" aria-hidden="true" />}
          <span className="font-medium text-text-primary">{c.display_name}</span>
        </div>
      ),
    },
    { id: "scope", header: "Scope", cell: (c) => <span className="text-text-secondary">{SCOPE_LABEL[c.scope_kind]}</span> },
    { id: "formats", header: "Formats", cell: (c) => <span className="flex flex-wrap gap-1">{c.supported_formats.map((f) => <Badge key={f} variant="status-neutral" size="sm">{f}</Badge>)}</span> },
    { id: "action", header: "", align: "right", cell: (c) => <Button size="sm" variant="secondary" onClick={() => setEntry(c)}>Generate</Button> },
  ];

  const exportColumns: Column<ExportRow>[] = [
    { id: "kind", header: "Report", cell: (e) => <span className="font-medium text-text-primary">{kindLabel(e.export_kind, catalogue)}</span> },
    { id: "format", header: "Format", cell: (e) => <Badge variant="status-neutral" size="sm">{e.format}</Badge> },
    { id: "period", header: "Period", cell: (e) => <span className="tabular-nums text-text-secondary">{e.period_start ? `${e.period_start} → ${e.period_end}` : "All-time"}</span> },
    { id: "requested", header: "Requested", sortable: true, sortValue: (e) => e.requested_at, cell: (e) => <span className="tabular-nums text-text-secondary">{new Date(e.requested_at).toLocaleString("en-GB")}</span> },
    { id: "status", header: "Status", cell: (e) => { const b = EXPORT_STATUS_BADGE[e.status]; return <Badge variant={b.variant} size="sm">{b.label}</Badge>; } },
    {
      id: "action", header: "", align: "right",
      cell: (e) => (
        <div onClick={(ev) => ev.stopPropagation()}>
          <Button size="sm" variant="tertiary" leadingIcon={Download} loading={busyId === e.id} disabled={e.status !== "COMPLETED"} onClick={() => download(e)}>Download</Button>
        </div>
      ),
    },
  ];

  return (
    <div className="flex flex-col gap-5">
      <header>
        <h1 className="text-2xl font-semibold text-text-primary">Reports &amp; exports</h1>
        <p className="text-sm text-text-secondary">{isMultiBusiness ? "All businesses" : currentBusiness?.display_name ?? "—"}</p>
      </header>

      {!currentBusiness ? (
        <EmptyState icon={Building2} heading="Select a business" body="Choose a business to generate and download reports." />
      ) : isMultiBusiness ? (
        <EmptyState icon={Building2} heading="Pick a single business" body="Reports are generated per-business. Switch from “All businesses” to a specific one." />
      ) : (
        <Tabs
          value={tab}
          onValueChange={setTab}
          tabs={[
            {
              id: "catalogue", label: "Available reports",
              content: (
                <Table columns={catalogueColumns} data={catalogue ?? []} rowKey={(c) => c.export_kind} loading={!catalogue}
                  empty={<EmptyState icon={FileText} heading="No report types" body="The export catalogue is empty." />} />
              ),
            },
            {
              id: "history", label: "Export history",
              content: error ? (
                <ErrorState description={error.message} onRetry={() => mutate()} />
              ) : (
                <Table columns={exportColumns} data={exports ?? []} rowKey={(e) => e.id} loading={isLoading}
                  empty={<EmptyState icon={Download} heading="No exports yet" body="Generate a report from the “Available reports” tab — it’ll appear here." />} />
              ),
            },
          ]}
        />
      )}

      <RequestExportDrawer entry={entry} open={!!entry} onClose={() => setEntry(null)} onRequested={() => { mutate(); setTab("history"); }} />
    </div>
  );
}
