import type { BadgeVariant } from "@/components/ui";
import { formatMoney } from "@/components/transactions/transaction-helpers";

/** Row from public.dashboard_card_definitions. */
export interface CardDef {
  card_id: string;
  display_name: string;
  description: string | null;
  default_position: number;
  permission_surface: string;
  data_source: "OPERATIONAL" | "ANALYTICS" | "ARCHIVE";
  severity_rule_ref: string | null;
  chart_type: "KPI_NUMBER" | "BAR" | "DONUT" | "LINE" | "LIST" | "TABLE";
}

/** A row from dashboard_route_drill_down. */
export interface DrillRow {
  id: string;
  source: string;
  business_id: string;
  payload: Record<string, unknown>;
}
export interface DrillResult {
  rows: DrillRow[];
  card_id: string;
  decision: string;
  data_source: string;
  accessible_business_ids?: string[];
}

/** Explicit dashboard layout (matches the TimeFuserBooks mockup order + spans),
 *  overriding the DB default_position. */
export const CARD_ORDER: string[] = [
  "monthly_overview",
  "evidence_collection_status",
  "vat_summary",
  "income_overview",
  "expense_overview",
  "unresolved_review_items",
  "client_invoice_aging",
  "subscription_recurring_totals",
  "unmatched_transactions",
  "recent_finalizations",
  "tax_treatment_breakdown",
];
export const CARD_SPAN: Record<string, number> = {
  monthly_overview: 2,
  unresolved_review_items: 2,
  client_invoice_aging: 2,
  subscription_recurring_totals: 2,
};
/** Faint-chart variant for cards whose backend metric isn't computed yet (stub). */
export const STUB_VARIANT: Record<string, "donut" | "bars" | "line" | "ring" | "aging"> = {
  vat_summary: "donut",
  tax_treatment_breakdown: "donut",
  income_overview: "bars",
  expense_overview: "bars",
  subscription_recurring_totals: "line",
  evidence_collection_status: "ring",
  client_invoice_aging: "aging",
};
export const STUB_LABEL: Record<string, string> = {
  vat_summary: "Lights up when the VAT engine is connected",
  income_overview: "Weekly inflow · target view",
  expense_overview: "Weekly outflow · target view",
  subscription_recurring_totals: "MRR trend — lights up when recurring invoices run",
  tax_treatment_breakdown: "VAT treatment mix · target view",
  evidence_collection_status: "Evidence match rate · target view",
  client_invoice_aging: "Receivables aging · target view",
};

export const CHART_TYPE_LABEL: Record<string, string> = {
  KPI_NUMBER: "KPI", BAR: "Bar", DONUT: "Donut", LINE: "Trend", LIST: "List", TABLE: "Table",
};

/** A transaction is "without a confirmed match" while it sits in these states.
 *  The generic operational drill-down RPC does NOT filter on match_status, so
 *  the unmatched card/drawer query `transactions` directly with this filter. */
export const UNMATCHED_STATUSES = ["UNMATCHED", "MATCHED_PROPOSED"] as const;
export const UNMATCHED_COLUMNS =
  "id, transaction_date, amount, currency, counterparty_name, normalized_description, raw_description_masked";
export interface UnmatchedTxn {
  id: string;
  transaction_date: string;
  amount: number;
  currency: string;
  counterparty_name: string | null;
  normalized_description: string | null;
  raw_description_masked: string | null;
}
export function unmatchedLabel(r: UnmatchedTxn): string {
  return r.counterparty_name ?? r.normalized_description ?? r.raw_description_masked ?? "Transaction";
}

export const DATA_SOURCE_BADGE: Record<string, { variant: BadgeVariant; label: string }> = {
  OPERATIONAL: { variant: "status-info", label: "Live" },
  ANALYTICS: { variant: "status-neutral", label: "Analytics" },
  ARCHIVE: { variant: "status-success", label: "Archive" },
};

/** True when the card's rows are backend analytics stubs (real MVs not built yet). */
export function isStubResult(rows: DrillRow[]): boolean {
  return rows.length > 0 && rows.every((r) => r.id == null || typeof r.payload?.stage === "string");
}

function rowValue(p: Record<string, unknown>): number | null {
  for (const k of ["amount", "total_amount", "total", "outstanding_amount", "value", "count"]) {
    if (typeof p[k] === "number") return p[k] as number;
  }
  return null;
}
function rowDate(p: Record<string, unknown>): string | null {
  for (const k of ["transaction_date", "issue_date", "period_start", "created_at"]) {
    if (typeof p[k] === "string") return p[k] as string;
  }
  return null;
}
function rowCategory(p: Record<string, unknown>): string {
  for (const k of ["category", "vat_treatment", "transaction_type", "direction", "severity", "status"]) {
    if (typeof p[k] === "string") return p[k] as string;
  }
  return "Other";
}

/** Numeric series from rows for sparkline (chronological |value|). */
export function valueSeries(rows: DrillRow[]): number[] {
  return rows
    .map((r) => ({ d: rowDate(r.payload), v: rowValue(r.payload) }))
    .filter((x): x is { d: string | null; v: number } => x.v != null)
    .sort((a, b) => (a.d ?? "").localeCompare(b.d ?? ""))
    .map((x) => Math.abs(x.v));
}

/** Category-bucketed series for bar/donut (summed |value| per category). */
export function categorySeries(rows: DrillRow[]): { label: string; value: number }[] {
  const m = new Map<string, number>();
  for (const r of rows) {
    const v = rowValue(r.payload);
    if (v == null) continue;
    const k = rowCategory(r.payload);
    m.set(k, (m.get(k) ?? 0) + Math.abs(v));
  }
  return [...m.entries()].map(([label, value]) => ({ label, value })).sort((a, b) => b.value - a.value);
}

/** A one-line human summary of a drill-down row's payload (shape varies per card). */
export function summarizeRow(p: Record<string, unknown>): { primary: string; secondary?: string } {
  const str = (k: string) => (typeof p[k] === "string" ? (p[k] as string) : undefined);
  const num = (k: string) => (typeof p[k] === "number" ? (p[k] as number) : undefined);

  const title = str("title") ?? str("display_name") ?? str("plain_language_title") ?? str("description") ?? str("client_name") ?? str("counterparty_name");
  const amount = num("amount") ?? num("total_amount") ?? num("total") ?? num("outstanding_amount");
  const currency = str("currency") ?? "EUR";
  const date = str("transaction_date") ?? str("issue_date") ?? str("period_start") ?? str("created_at")?.slice(0, 10);
  const type = str("transaction_type") ?? str("severity") ?? str("status") ?? str("vat_treatment");

  const primary = title ?? (date ? `${date}${type ? ` · ${type}` : ""}` : type ?? "Item");
  const bits: string[] = [];
  if (amount != null) bits.push(formatMoney(amount, currency));
  if (title && date) bits.push(date);
  if (title && type && !date) bits.push(type);
  return { primary, secondary: bits.join(" · ") || undefined };
}
