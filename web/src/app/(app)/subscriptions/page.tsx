"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import Link from "next/link";
import { Building2, Receipt, RefreshCw, Search } from "lucide-react";
import { Badge, EmptyState, ErrorState, Input, Select, Table, Drawer, type Column } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import { formatMoney } from "@/components/transactions/transaction-helpers";
import {
  rollupVendors, subscriptionStats, vendorColor, vendorInitials,
  type SpendTxn, type Vendor, type VendorMemoryRow,
} from "@/components/subscriptions/subscription-helpers";

const EXPENSE = "var(--color-status-danger-text)";

function Stat({ label, value, sub, tone }: { label: string; value: string | number; sub?: string; tone?: boolean }) {
  return (
    <div className="rounded-xl border border-border-subtle bg-surface-default px-4 py-3 shadow-1">
      <div className="text-[11px] font-semibold uppercase tracking-[0.06em] text-text-muted">{label}</div>
      <div className="mt-1.5 font-mono text-xl font-semibold tabular-nums" style={tone ? { color: EXPENSE } : undefined}>{value}</div>
      {sub && <div className="mt-0.5 text-xs text-text-muted">{sub}</div>}
    </div>
  );
}

function Avatar({ name, signature, size = 36 }: { name: string; signature: string; size?: number }) {
  return (
    <span
      aria-hidden="true"
      className="grid shrink-0 place-items-center rounded-[9px] font-bold text-white"
      style={{ width: size, height: size, background: vendorColor(signature), fontSize: size > 36 ? 14 : 12 }}
    >
      {vendorInitials(name)}
    </span>
  );
}

function CadenceCell({ v }: { v: Vendor }) {
  if (!v.cadence) return <span className="text-text-muted">—</span>;
  return (
    <span className="text-text-secondary">
      {v.cadence.label}
      {v.cadence.estimated && <span className="ml-1 text-text-muted" title="Estimated — confirms after the next charge">~</span>}
    </span>
  );
}

export default function SubscriptionsPage() {
  const { currentBusiness } = useShell();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);

  const key = currentBusiness ? ["subscriptions", currentBusiness.id] : null;
  const { data, error, isLoading, mutate } = useSWRSubs(key, currentBusiness?.id, supabase);

  const vendors = useMemo(() => (data ? rollupVendors(data.txns, data.memory) : []), [data]);
  const stats = useMemo(() => subscriptionStats(vendors), [vendors]);
  const tags = useMemo(() => [...new Set(vendors.map((v) => v.tag).filter(Boolean) as string[])].sort(), [vendors]);

  const [search, setSearch] = useState("");
  const [tag, setTag] = useState("ALL");
  const [detail, setDetail] = useState<Vendor | null>(null);

  const rows = useMemo(() => {
    const q = search.trim().toLowerCase();
    return vendors.filter((v) => (tag === "ALL" || v.tag === tag) && (!q || v.name.toLowerCase().includes(q)));
  }, [vendors, search, tag]);

  const columns: Column<Vendor>[] = [
    {
      id: "vendor", header: "Vendor",
      cell: (v) => (
        <div className="flex min-w-0 items-center gap-3">
          <Avatar name={v.name} signature={v.signature} />
          <div className="min-w-0">
            <div className="truncate font-medium text-text-primary">{v.name}</div>
            {v.tag && <div className="truncate text-xs text-text-muted">{v.tag}</div>}
          </div>
        </div>
      ),
    },
    {
      id: "amount", header: "Amount", numeric: true, width: 130, sortable: true, sortValue: (v) => v.amount,
      cell: (v) => <span style={{ color: EXPENSE }}>{formatMoney(v.amount, v.currency)}</span>,
    },
    { id: "cadence", header: "Billing", width: 120, cell: (v) => <CadenceCell v={v} /> },
    {
      id: "next", header: "Next charge", width: 130, sortable: true, sortValue: (v) => v.nextCharge ?? "9999",
      cell: (v) => <span className="font-mono text-xs tabular-nums text-text-secondary">{v.nextCharge ?? "—"}</span>,
    },
    {
      id: "status", header: "Status", width: 130,
      cell: (v) => v.tracked
        ? <Badge variant="status-success" size="sm">Tracked</Badge>
        : <Badge variant="status-info" size="sm">Recurring</Badge>,
    },
  ];

  return (
    <div className="flex flex-col gap-5">
      <header>
        <h1 className="text-2xl font-semibold text-text-primary">Subscriptions</h1>
        <p className="text-sm text-text-secondary">{currentBusiness?.display_name ?? "—"} · recurring spend</p>
      </header>

      {!currentBusiness ? (
        <EmptyState icon={Building2} heading="Select a business" body="Choose a single business from the switcher to see its recurring vendor spend." />
      ) : error ? (
        <ErrorState description={error.message} onRetry={() => mutate()} />
      ) : (
        <>
          <div className="inline-flex items-center gap-2 self-start rounded-full border border-[color-mix(in_srgb,var(--color-brand-500)_16%,transparent)] bg-brand-50 px-3 py-1.5 text-xs text-text-secondary">
            <RefreshCw size={13} className="text-action-primary" aria-hidden="true" />
            Auto-detected from your bank transactions · cadence &amp; next-charge are estimates that sharpen as more statements arrive
          </div>

          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4 sm:max-w-3xl">
            <Stat label="Recurring vendors" value={stats.count} sub={tags.length ? `${tags.length} categor${tags.length === 1 ? "y" : "ies"}` : "tracked + detected"} />
            <Stat label="Est. monthly" value={formatMoney(stats.monthly, "EUR")} sub="normalised per month" tone />
            <Stat label="Annualised" value={formatMoney(stats.annual, "EUR")} sub="projected yearly" />
            <Stat label="Spend to date" value={formatMoney(stats.spendToDate, "EUR")} sub="across all charges" />
          </div>

          <div className="flex flex-wrap items-end gap-3">
            <Input containerClassName="w-64" placeholder="Search vendors…" leadingIcon={Search} value={search} onChange={(e) => setSearch(e.target.value)} />
            <Select containerClassName="w-52" aria-label="Category" value={tag} onChange={(e) => setTag(e.target.value)}>
              <option value="ALL">All categories</option>
              {tags.map((t) => <option key={t} value={t}>{t}</option>)}
            </Select>
          </div>

          <Table
            columns={columns}
            data={rows}
            rowKey={(v) => v.signature}
            loading={isLoading}
            density="compact"
            onRowClick={setDetail}
            empty={
              <EmptyState
                icon={RefreshCw}
                heading="No recurring vendors yet"
                body="As the same vendor appears across multiple statements, TimeFuserBooks learns to track it here as recurring spend."
              />
            }
          />
        </>
      )}

      <Drawer
        open={!!detail}
        onClose={() => setDetail(null)}
        width={460}
        title={detail ? (
          <span className="flex items-center gap-3">
            <Avatar name={detail.name} signature={detail.signature} size={40} />
            <span className="min-w-0">
              <span className="block truncate">{detail.name}</span>
              <span className="block text-xs font-normal text-text-muted">{detail.tag ?? "Uncategorised"}{detail.tracked ? " · Tracked" : ""}</span>
            </span>
          </span>
        ) : ""}
        footer={detail && (
          <Link href="/transactions" className="text-sm font-medium text-action-primary hover:underline">View in transactions →</Link>
        )}
      >
        {detail && <VendorDetail v={detail} />}
      </Drawer>
    </div>
  );
}

function VendorDetail({ v }: { v: Vendor }) {
  const kv: { k: string; val: string; tone?: boolean }[] = [
    { k: "Recurring amount", val: formatMoney(v.amount, v.currency), tone: true },
    { k: "Billing cycle", val: v.cadence ? `${v.cadence.label}${v.cadence.estimated ? " (estimated)" : ""}` : "—" },
    { k: "Next charge", val: v.nextCharge ? `${v.nextCharge} (est.)` : "—" },
    { k: "Monthly equivalent", val: v.monthlyEquivalent ? formatMoney(v.monthlyEquivalent, v.currency) : "—" },
    { k: "Annualised", val: v.monthlyEquivalent ? formatMoney(v.monthlyEquivalent * 12, v.currency) : "—" },
    { k: "Spend to date", val: formatMoney(v.total, v.currency) },
    { k: "First seen", val: v.firstSeen ?? "—" },
    { k: "Charges observed", val: String(v.occurrences) },
    ...(v.tracked ? [{ k: "Confirmations", val: `${v.confirmations} match${v.confirmations === 1 ? "" : "es"}` }] : []),
    ...(v.country ? [{ k: "Country", val: v.country }] : []),
  ];

  return (
    <div className="flex flex-col gap-6">
      {v.cadence?.estimated && (
        <div className="flex gap-2.5 rounded-lg border border-border-subtle bg-bg-raised px-3.5 py-3 text-xs leading-relaxed text-text-secondary">
          <RefreshCw size={14} className="mt-0.5 shrink-0 text-text-muted" aria-hidden="true" />
          <span>Cadence is estimated as monthly from a single charge so far. It confirms automatically once a second charge lands.</span>
        </div>
      )}

      <dl className="grid grid-cols-2 gap-x-5 gap-y-4">
        {kv.map(({ k, val, tone }) => (
          <div key={k}>
            <dt className="text-[11px] font-semibold uppercase tracking-[0.04em] text-text-muted">{k}</dt>
            <dd className="mt-1 font-mono text-sm tabular-nums text-text-primary" style={tone ? { color: EXPENSE } : undefined}>{val}</dd>
          </div>
        ))}
      </dl>

      {v.charges.length > 0 && (
        <div>
          <h4 className="mb-2 text-[11px] font-bold uppercase tracking-[0.06em] text-text-secondary">Recent charges</h4>
          <ul>
            {v.charges.slice(0, 6).map((c, i) => (
              <li key={i} className="flex items-center justify-between border-b border-border-subtle py-2.5 text-sm last:border-0">
                <span className="flex items-center gap-2 font-mono text-xs text-text-secondary"><Receipt size={13} className="text-text-muted" aria-hidden="true" />{c.date}</span>
                <span className="font-mono tabular-nums" style={{ color: EXPENSE }}>{formatMoney(c.amount, v.currency)}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}

// --- data ---
type SupabaseClient = ReturnType<typeof createSupabaseBrowserClient>;
function useSWRSubs(key: (string | undefined)[] | null, businessId: string | undefined, supabase: SupabaseClient) {
  return useSWR<{ txns: SpendTxn[]; memory: VendorMemoryRow[] }>(key, async () => {
    const [txnRes, memRes] = await Promise.all([
      supabase
        .from("transactions")
        .select("id, counterparty_name, counterparty_country, amount, currency, transaction_date, system_tag, user_tag")
        .eq("business_id", businessId!).eq("direction", "OUT")
        .order("transaction_date", { ascending: true }),
      supabase
        .from("recurring_vendor_memory")
        .select("id, counterparty_signature, suggested_type, suggested_tag, confirmations_count, first_seen_at, last_confirmation_at, counterparty_country, counterparty_vat_number")
        .eq("business_id", businessId!).eq("status", "ACTIVE"),
    ]);
    if (txnRes.error) throw new Error(txnRes.error.message);
    return {
      txns: (txnRes.data ?? []) as unknown as SpendTxn[],
      // Vendor-memory is best-effort: if RLS or a column hiccup blocks it, the
      // page still works off the ledger's recurring patterns.
      memory: (memRes.error ? [] : (memRes.data ?? [])) as unknown as VendorMemoryRow[],
    };
  });
}
