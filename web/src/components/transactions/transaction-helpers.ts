import type { BadgeVariant } from "@/components/ui";
import type { Period } from "@/components/shell/ShellContext";

/** Row shape selected from public.transactions (RLS-filtered). */
export interface TxnRow {
  id: string;
  transaction_date: string;
  amount: number;
  currency: string;
  direction: "IN" | "OUT" | "BOTH";
  transaction_type: string;
  normalized_description: string | null;
  raw_description: string | null;
  raw_description_masked: string | null;
  counterparty_name: string | null;
  reference: string | null;
  classification_status: "PENDING" | "NEEDS_CONFIRMATION" | "CONFIRMED" | "FAILED";
  dedup_status: "NEW" | "DUPLICATE_EXACT" | "DUPLICATE_PROBABLE" | "NEEDS_REVIEW";
  match_status: string;
  review_status: string;
  system_tag: string | null;
  user_tag: string | null;
  source_row_index: number;
  transaction_fingerprint: string;
}

export const TXN_COLUMNS =
  "id, transaction_date, amount, currency, direction, transaction_type, normalized_description, raw_description, raw_description_masked, counterparty_name, reference, classification_status, dedup_status, match_status, review_status, system_tag, user_tag, source_row_index, transaction_fingerprint";

/** Inclusive [start, end] date strings for a period's month. */
export function periodRange(p: Period): { start: string; end: string } {
  const mm = String(p.month).padStart(2, "0");
  const lastDay = new Date(p.year, p.month, 0).getDate();
  return { start: `${p.year}-${mm}-01`, end: `${p.year}-${mm}-${String(lastDay).padStart(2, "0")}` };
}

export function formatMoney(amount: number, currency: string): string {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: (currency || "EUR").trim() }).format(amount);
}

export const CLASSIFICATION_BADGE: Record<TxnRow["classification_status"], { variant: BadgeVariant; label: string }> = {
  PENDING: { variant: "status-neutral", label: "Unclassified" },
  NEEDS_CONFIRMATION: { variant: "severity-medium", label: "Needs review" },
  CONFIRMED: { variant: "status-success", label: "Classified" },
  FAILED: { variant: "severity-blocking", label: "Failed" },
};

/** Non-NEW dedup states get a badge; NEW is the normal case (no badge). */
export const DEDUP_BADGE: Partial<Record<TxnRow["dedup_status"], { variant: BadgeVariant; label: string }>> = {
  DUPLICATE_EXACT: { variant: "severity-blocking", label: "Duplicate" },
  DUPLICATE_PROBABLE: { variant: "severity-medium", label: "Possible dup" },
  NEEDS_REVIEW: { variant: "severity-high", label: "Review dup" },
};

/** Display label for a transaction (normalized → masked → raw → fallback). */
export function txnDescription(t: TxnRow): string {
  return t.normalized_description || t.raw_description_masked || t.raw_description || "—";
}

/** The winning tag for display, if any. */
export function txnTag(t: TxnRow): string | null {
  return t.user_tag || t.system_tag || null;
}
