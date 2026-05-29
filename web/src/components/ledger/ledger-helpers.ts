import type { BadgeVariant } from "@/components/ui";

export interface LedgerRow {
  id: string;
  parent_transaction_id: string | null;
  entry_kind: string;
  debit_account_code: string | null;
  credit_account_code: string | null;
  debit_amount: number | null;
  credit_amount: number | null;
  currency: string;
  entry_period: string;
  counterparty_country: string | null;
  counterparty_vat_number: string | null;
  vat_treatment: string;
  input_vat_reclaimable_flag: boolean;
  input_vat_reclaimable_amount: number | null;
  output_vat_due_flag: boolean;
  output_vat_due_amount: number | null;
  reverse_charge_relevant: boolean;
  vies_relevant: boolean;
  requires_invoice: boolean;
  requires_receipt: boolean;
  requires_contract: boolean;
  requires_accountant_review: boolean;
  accountant_review_reason: string | null;
  status: "DRAFT" | "READY_FOR_FINALIZATION" | "LOCKED";
  vat_treatment_explanation: string | null;
}

export const LEDGER_COLUMNS =
  "id, parent_transaction_id, entry_kind, debit_account_code, credit_account_code, debit_amount, credit_amount, currency, entry_period, counterparty_country, counterparty_vat_number, vat_treatment, input_vat_reclaimable_flag, input_vat_reclaimable_amount, output_vat_due_flag, output_vat_due_amount, reverse_charge_relevant, vies_relevant, requires_invoice, requires_receipt, requires_contract, requires_accountant_review, accountant_review_reason, status, vat_treatment_explanation";

/** vat_treatment → friendly label + badge variant. */
export const VAT_TREATMENT: Record<string, { label: string; variant: BadgeVariant }> = {
  DOMESTIC_STANDARD: { label: "Domestic standard", variant: "status-info" },
  DOMESTIC_REDUCED: { label: "Domestic reduced", variant: "status-info" },
  DOMESTIC_CYPRUS_VAT: { label: "Cyprus VAT", variant: "status-info" },
  DOMESTIC_ZERO: { label: "Zero-rated", variant: "status-neutral" },
  EU_REVERSE_CHARGE: { label: "Reverse charge", variant: "severity-medium" },
  IMPORT_OR_ACQUISITION: { label: "Import / acquisition", variant: "severity-medium" },
  NON_EU_SERVICE: { label: "Non-EU service", variant: "severity-medium" },
  OUTSIDE_SCOPE: { label: "Outside scope", variant: "status-neutral" },
  EXEMPT: { label: "Exempt", variant: "status-neutral" },
  NO_VAT: { label: "No VAT", variant: "status-neutral" },
  UNKNOWN: { label: "Unknown", variant: "severity-high" },
};

export const STATUS_BADGE: Record<LedgerRow["status"], { label: string; variant: BadgeVariant }> = {
  DRAFT: { label: "Draft", variant: "status-neutral" },
  READY_FOR_FINALIZATION: { label: "Ready", variant: "status-success" },
  LOCKED: { label: "Locked", variant: "status-info" },
};

export function vatTreatment(t: string) {
  return VAT_TREATMENT[t] ?? { label: t, variant: "status-neutral" as BadgeVariant };
}

export function money(amount: number | null | undefined, currency = "EUR"): string {
  if (amount == null) return "—";
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: currency.trim() }).format(amount);
}
