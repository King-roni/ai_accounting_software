import type { BadgeVariant } from "@/components/ui";

export interface MatchRow {
  id: string;
  match_level: "EXACT" | "STRONG_PROBABLE" | "WEAK_POSSIBLE";
  match_method: string;
  match_score: number;
  match_signals: Record<string, number> | null;
  match_reason_plain_language: string | null;
  match_status: "MATCHED_CONFIRMED" | "MATCHED_AUTO_HIGH_CONFIDENCE" | "MATCHED_NEEDS_CONFIRMATION" | "POSSIBLE_MATCH" | "NO_MATCH" | "REJECTED_MATCH";
  requires_user_confirmation: boolean;
  document_id: string | null;
  transaction: {
    transaction_date: string;
    amount: number;
    currency: string;
    normalized_description: string | null;
    raw_description: string | null;
    counterparty_name: string | null;
  } | null;
  document: {
    supplier_name: string | null;
    invoice_number: string | null;
    amount_total: number | null;
    currency: string | null;
    document_type: string | null;
  } | null;
}

/** PostgREST select with embedded transaction + document. */
export const MATCH_SELECT =
  "id, match_level, match_method, match_score, match_signals, match_reason_plain_language, match_status, requires_user_confirmation, document_id, " +
  "transaction:transactions(transaction_date, amount, currency, normalized_description, raw_description, counterparty_name), " +
  "document:documents(supplier_name, invoice_number, amount_total, currency, document_type)";

export const LEVEL_BADGE: Record<MatchRow["match_level"], { variant: BadgeVariant; label: string }> = {
  EXACT: { variant: "status-success", label: "Exact" },
  STRONG_PROBABLE: { variant: "status-info", label: "Strong" },
  WEAK_POSSIBLE: { variant: "severity-medium", label: "Weak" },
};

export const STATUS_BADGE: Record<MatchRow["match_status"], { variant: BadgeVariant; label: string }> = {
  MATCHED_CONFIRMED: { variant: "status-success", label: "Confirmed" },
  MATCHED_AUTO_HIGH_CONFIDENCE: { variant: "status-success", label: "Auto-matched" },
  MATCHED_NEEDS_CONFIRMATION: { variant: "severity-medium", label: "Needs confirmation" },
  POSSIBLE_MATCH: { variant: "severity-medium", label: "Possible" },
  NO_MATCH: { variant: "status-neutral", label: "No match" },
  REJECTED_MATCH: { variant: "severity-blocking", label: "Rejected" },
};

export const SIGNAL_LABELS: Record<string, string> = {
  amount_delta: "Amount",
  date_proximity: "Date",
  counterparty_match: "Counterparty",
  reference_string_match: "Reference",
};

export function scoreColor(score: number): string {
  if (score < 0.6) return "var(--color-status-danger)";
  if (score < 0.8) return "var(--color-status-warning)";
  return "var(--color-status-success)";
}

export function money(amount: number | null | undefined, currency: string | null | undefined): string {
  if (amount == null) return "—";
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: (currency || "EUR").trim() }).format(amount);
}
