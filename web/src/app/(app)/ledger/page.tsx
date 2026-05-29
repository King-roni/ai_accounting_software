"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { AlertTriangle, Building2 } from "lucide-react";
import { Badge, EmptyState, ErrorState, Select, Table, type Column } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { formatPeriod, useShell } from "@/components/shell/ShellContext";
import { LEDGER_COLUMNS, STATUS_BADGE, money, vatTreatment, type LedgerRow } from "@/components/ledger/ledger-helpers";
import { LedgerDetailDrawer } from "@/components/ledger/LedgerDetailDrawer";
import { periodRange } from "@/components/transactions/transaction-helpers";

function Stat({ label, value, tone, hint }: { label: string; value: string; tone?: "in" | "out"; hint?: string }) {
  const color = tone === "in" ? "var(--color-status-success)" : tone === "out" ? "var(--color-status-danger)" : undefined;
  return (
    <div className="rounded-md border border-border-subtle bg-surface-default px-4 py-3">
      <div className="text-xs font-medium uppercase tracking-wide text-text-muted">{label}</div>
      <div className="mt-1 font-mono text-lg font-medium tabular-nums" style={{ color }}>{value}</div>
      {hint && <div className="text-xs text-text-muted">{hint}</div>}
    </div>
  );
}

export default function LedgerPage() {
  const { currentBusiness, isMultiBusiness, period } = useShell();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const { start, end } = periodRange(period);

  const key = currentBusiness ? ["ledger", currentBusiness.id, start, end] : null;
  const { data, error, isLoading, mutate } = useSWR<LedgerRow[]>(key, async () => {
    const res = await supabase.from("draft_ledger_entries").select(LEDGER_COLUMNS)
      .eq("business_id", currentBusiness!.id).gte("entry_period", start).lte("entry_period", end)
      .order("entry_period", { ascending: true });
    if (res.error) throw new Error(res.error.message);
    return (res.data ?? []) as unknown as LedgerRow[];
  });

  // Chart of accounts name map for this business.
  const { data: coa } = useSWR(currentBusiness ? ["coa", currentBusiness.id] : null, async () => {
    const res = await supabase.from("chart_of_accounts").select("code, name").eq("business_id", currentBusiness!.id);
    if (res.error) throw new Error(res.error.message);
    return res.data ?? [];
  });
  const accountName = (code: string | null) => {
    if (!code) return "—";
    const n = (coa ?? []).find((a) => a.code === code)?.name;
    return n ? `${code} · ${n}` : code;
  };

  const [vat, setVat] = useState("ALL");
  const [reviewOnly, setReviewOnly] = useState("ALL");
  const [detail, setDetail] = useState<LedgerRow | null>(null);

  const rows = useMemo(() => (data ?? []).filter((e) => {
    if (vat !== "ALL" && e.vat_treatment !== vat) return false;
    if (reviewOnly === "REVIEW" && !e.requires_accountant_review) return false;
    return true;
  }), [data, vat, reviewOnly]);

  const totalReclaimable = (data ?? []).reduce((s, e) => s + Number(e.input_vat_reclaimable_amount ?? 0), 0);
  const totalDue = (data ?? []).reduce((s, e) => s + Number(e.output_vat_due_amount ?? 0), 0);
  const net = totalDue - totalReclaimable;
  const reviewCount = (data ?? []).filter((e) => e.requires_accountant_review).length;
  const viesCount = (data ?? []).filter((e) => e.vies_relevant).length;

  const columns: Column<LedgerRow>[] = [
    { id: "account", header: "Account", cell: (e) => <span className="text-text-primary">{accountName(e.debit_account_code)}</span> },
    { id: "amount", header: "Amount", numeric: true, width: 130, sortable: true, sortValue: (e) => Number(e.debit_amount ?? e.credit_amount ?? 0), cell: (e) => <span className="text-text-primary">{money(e.debit_amount ?? e.credit_amount, e.currency)}</span> },
    { id: "vat", header: "VAT treatment", width: 150, cell: (e) => <Badge variant={vatTreatment(e.vat_treatment).variant} size="sm">{vatTreatment(e.vat_treatment).label}</Badge> },
    {
      id: "flags", header: "Flags", width: 130,
      cell: (e) => (
        <div className="flex items-center gap-1.5 text-text-muted">
          {e.reverse_charge_relevant && <span className="text-xs" title="Reverse charge">RC</span>}
          {e.vies_relevant && <span className="text-xs" title="VIES relevant">VIES</span>}
          {e.requires_accountant_review && <AlertTriangle size={14} strokeWidth={1.5} style={{ color: "var(--color-status-warning)" }} aria-label="Needs accountant review" />}
        </div>
      ),
    },
    { id: "status", header: "Status", width: 110, cell: (e) => <Badge variant={STATUS_BADGE[e.status].variant} size="sm">{STATUS_BADGE[e.status].label}</Badge> },
  ];

  return (
    <div className="flex flex-col gap-5">
      <header>
        <h1 className="text-2xl font-semibold text-text-primary">Ledger</h1>
        <p className="text-sm text-text-secondary tabular-nums">{isMultiBusiness ? "All businesses" : currentBusiness?.display_name ?? "—"} · {formatPeriod(period)}</p>
      </header>

      {currentBusiness && (
        <>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <Stat label="Input VAT (reclaimable)" value={money(totalReclaimable)} tone="in" />
            <Stat label="Output VAT (due)" value={money(totalDue)} tone="out" />
            <Stat label="Net VAT position" value={money(net)} hint={net >= 0 ? "payable" : "refund"} />
            <Stat label="Needs review" value={String(reviewCount)} hint={`${viesCount} VIES-relevant`} />
          </div>

          <div className="flex flex-wrap items-end gap-3">
            <Select containerClassName="w-52" aria-label="VAT treatment" value={vat} onChange={(e) => setVat(e.target.value)}>
              <option value="ALL">All VAT treatments</option>
              <option value="DOMESTIC_STANDARD">Domestic standard</option>
              <option value="EU_REVERSE_CHARGE">Reverse charge</option>
              <option value="EXEMPT">Exempt</option>
              <option value="NO_VAT">No VAT</option>
              <option value="OUTSIDE_SCOPE">Outside scope</option>
            </Select>
            <Select containerClassName="w-52" aria-label="Review filter" value={reviewOnly} onChange={(e) => setReviewOnly(e.target.value)}>
              <option value="ALL">All entries</option>
              <option value="REVIEW">Needs accountant review</option>
            </Select>
          </div>
        </>
      )}

      {!currentBusiness ? (
        <EmptyState icon={Building2} heading="Select a business" body="Choose a business to see its draft ledger." />
      ) : error ? (
        <ErrorState description={error.message} onRetry={() => mutate()} />
      ) : (
        <Table
          columns={columns}
          data={rows}
          rowKey={(e) => e.id}
          loading={isLoading}
          density="comfortable"
          onRowClick={setDetail}
          empty={<EmptyState heading="No ledger entries this period" body="Ledger entries are prepared from matched transactions during the bookkeeping run." />}
        />
      )}

      <LedgerDetailDrawer row={detail} accountName={accountName} open={!!detail} onClose={() => setDetail(null)} />
    </div>
  );
}
