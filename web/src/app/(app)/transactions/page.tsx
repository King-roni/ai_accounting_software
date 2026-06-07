"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { Building2, Plus, Search } from "lucide-react";
import { Badge, Button, EmptyState, ErrorState, Input, Select, Table, type Column } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { formatPeriod, useShell } from "@/components/shell/ShellContext";
import {
  CLASSIFICATION_BADGE, DEDUP_BADGE, formatMoney, periodRange, TXN_COLUMNS,
  txnDescription, txnTag, type TxnRow,
} from "@/components/transactions/transaction-helpers";
import { TransactionDetailDrawer } from "@/components/transactions/TransactionDetailDrawer";
import { UploadStatementDrawer } from "@/components/transactions/UploadStatementDrawer";
import { RecentUploads } from "@/components/transactions/RecentUploads";

function Stat({ label, value, tone }: { label: string; value: string | number; tone?: "in" | "out" }) {
  const color = tone === "in" ? "var(--color-status-success-text)" : tone === "out" ? "var(--color-status-danger-text)" : undefined;
  return (
    <div className="rounded-md border border-border-subtle bg-surface-default px-4 py-3">
      <div className="text-xs font-medium uppercase tracking-wide text-text-muted">{label}</div>
      <div className="mt-1 font-mono text-lg font-medium tabular-nums" style={{ color }}>{value}</div>
    </div>
  );
}

export default function TransactionsPage() {
  const { currentBusiness, isMultiBusiness, period } = useShell();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const { start, end } = periodRange(period);

  const key = currentBusiness ? ["txns", currentBusiness.id, start, end] : null;
  const { data, error, isLoading, mutate } = useSWR<TxnRow[]>(key, async () => {
    const res = await supabase
      .from("transactions")
      .select(TXN_COLUMNS)
      .eq("business_id", currentBusiness!.id)
      .gte("transaction_date", start)
      .lte("transaction_date", end)
      .order("transaction_date", { ascending: true });
    if (res.error) throw new Error(res.error.message);
    return (res.data ?? []) as unknown as TxnRow[];
  });

  const [search, setSearch] = useState("");
  const [dir, setDir] = useState("ALL");
  const [cls, setCls] = useState("ALL");
  const [detail, setDetail] = useState<TxnRow | null>(null);
  const [uploadOpen, setUploadOpen] = useState(false);

  const rows = useMemo(() => {
    const q = search.trim().toLowerCase();
    return (data ?? []).filter((t) => {
      if (dir !== "ALL" && t.direction !== dir) return false;
      if (cls !== "ALL" && t.classification_status !== cls) return false;
      if (q) {
        const hay = `${txnDescription(t)} ${t.counterparty_name ?? ""} ${t.reference ?? ""}`.toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });
  }, [data, dir, cls, search]);

  const totalIn = rows.reduce((s, r) => (Number(r.amount) > 0 ? s + Number(r.amount) : s), 0);
  const totalOut = rows.reduce((s, r) => (Number(r.amount) < 0 ? s + Number(r.amount) : s), 0);

  const columns: Column<TxnRow>[] = [
    { id: "date", header: "Date", width: 104, sortable: true, sortValue: (r) => r.transaction_date, cell: (r) => <span className="whitespace-nowrap font-mono text-xs tabular-nums text-text-secondary">{r.transaction_date}</span> },
    {
      id: "desc", header: "Description",
      cell: (r) => (
        <div className="min-w-0">
          <div className="truncate text-text-primary">{txnDescription(r)}</div>
          {r.counterparty_name && <div className="truncate text-xs text-text-muted">{r.counterparty_name}</div>}
        </div>
      ),
    },
    {
      id: "amount", header: "Amount", numeric: true, width: 140, sortable: true, sortValue: (r) => Number(r.amount),
      cell: (r) => <span style={{ color: Number(r.amount) < 0 ? "var(--color-status-danger-text)" : "var(--color-status-success-text)" }}>{formatMoney(Number(r.amount), r.currency)}</span>,
    },
    {
      id: "class", header: "Classification", width: 180,
      cell: (r) => {
        const tag = txnTag(r);
        // BOOK-970: only a CONFIRMED classification reads as confident (green).
        // An unconfirmed suggestion (e.g. the no-AI fallback) shows the status
        // badge ("Needs review") with the proposed tag muted alongside, so it
        // never looks like a settled category.
        if (tag && r.classification_status === "CONFIRMED") {
          return <Badge variant="status-success" size="sm">{tag}</Badge>;
        }
        const b = CLASSIFICATION_BADGE[r.classification_status];
        return (
          <span className="inline-flex items-center gap-1.5">
            <Badge variant={b.variant} size="sm">{b.label}</Badge>
            {tag && (
              <span className="truncate text-xs text-text-muted" title={tag}>{tag}</span>
            )}
          </span>
        );
      },
    },
    {
      id: "flags", header: "", width: 120,
      cell: (r) => { const d = DEDUP_BADGE[r.dedup_status]; return d ? <Badge variant={d.variant} size="sm">{d.label}</Badge> : null; },
    },
  ];

  return (
    <div className="flex flex-col gap-5">
      <header className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold text-text-primary">Transactions</h1>
          <p className="text-sm text-text-secondary tabular-nums">
            {isMultiBusiness ? "All businesses" : currentBusiness?.display_name ?? "—"} · {formatPeriod(period)}
          </p>
        </div>
        <Button leadingIcon={Plus} disabled={!currentBusiness} onClick={() => setUploadOpen(true)}>Upload statement</Button>
      </header>

      {currentBusiness && (
        <>
          <div className="grid grid-cols-3 gap-3 sm:max-w-xl">
            <Stat label="Transactions" value={rows.length} />
            <Stat label="Money in" value={formatMoney(totalIn, currentBusiness ? "EUR" : "EUR")} tone="in" />
            <Stat label="Money out" value={formatMoney(totalOut, "EUR")} tone="out" />
          </div>

          <div className="flex flex-wrap items-end gap-3">
            <Input containerClassName="w-64" placeholder="Search description, counterparty…" leadingIcon={Search} value={search} onChange={(e) => setSearch(e.target.value)} />
            <Select containerClassName="w-44" label="" aria-label="Direction" value={dir} onChange={(e) => setDir(e.target.value)}>
              <option value="ALL">All directions</option>
              <option value="IN">Money in</option>
              <option value="OUT">Money out</option>
            </Select>
            <Select containerClassName="w-52" aria-label="Classification" value={cls} onChange={(e) => setCls(e.target.value)}>
              <option value="ALL">All classifications</option>
              <option value="PENDING">Unclassified</option>
              <option value="NEEDS_CONFIRMATION">Needs review</option>
              <option value="CONFIRMED">Classified</option>
              <option value="FAILED">Failed</option>
            </Select>
          </div>
        </>
      )}

      {currentBusiness && !isMultiBusiness && <RecentUploads businessId={currentBusiness.id} />}

      {!currentBusiness ? (
        <EmptyState icon={Building2} heading="Select a business" body="Choose a business from the switcher to see its transactions." />
      ) : error ? (
        <ErrorState description={error.message} onRetry={() => mutate()} />
      ) : (
        <Table
          columns={columns}
          data={rows}
          rowKey={(r) => r.id}
          loading={isLoading}
          density="compact"
          onRowClick={setDetail}
          empty={
            <EmptyState
              heading="No transactions this period"
              body="Upload a bank statement to import transactions for this period."
              action={<Button size="sm" leadingIcon={Plus} onClick={() => setUploadOpen(true)}>Upload statement</Button>}
            />
          }
        />
      )}

      <TransactionDetailDrawer row={detail} open={!!detail} onClose={() => setDetail(null)} />
      <UploadStatementDrawer open={uploadOpen} onClose={() => setUploadOpen(false)} />
    </div>
  );
}
