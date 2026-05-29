import type { BadgeVariant } from "@/components/ui";

/** Row from public.invoices (RLS-scoped), with the client name joined in. */
export interface InvoiceRow {
  id: string;
  organization_id: string;
  business_id: string;
  client_id: string;
  invoice_type: "PRO_FORMA" | "TAX";
  invoice_number: string | null;
  issue_date: string;
  supply_date: string | null;
  due_date: string;
  currency: string;
  subtotal_amount: number;
  vat_amount: number;
  total_amount: number;
  vat_treatment_per_line: boolean;
  default_vat_treatment: string | null;
  lifecycle_status: string;
  converted_from_pro_forma_id: string | null;
  converted_to_tax_invoice_id: string | null;
  pdf_rendered_at: string | null;
  sent_at: string | null;
  written_off_reason: string | null;
  created_at: string;
  client?: { display_name: string | null } | null;
}

export interface InvoiceLineRow {
  id: string;
  invoice_id: string;
  line_number: number;
  description: string;
  quantity: number;
  unit_price: number;
  currency: string;
  subtotal_amount: number;
  vat_treatment: string | null;
  vat_rate_pct: number | null;
  vat_amount: number | null;
  total_amount: number;
}

export const INVOICE_COLUMNS =
  "id, organization_id, business_id, client_id, invoice_type, invoice_number, issue_date, supply_date, due_date, currency, subtotal_amount, vat_amount, total_amount, vat_treatment_per_line, default_vat_treatment, lifecycle_status, converted_from_pro_forma_id, converted_to_tax_invoice_id, pdf_rendered_at, sent_at, written_off_reason, created_at, client:clients(display_name)";

export const INVOICE_TYPE_LABEL: Record<string, string> = { PRO_FORMA: "Pro forma", TAX: "Tax invoice" };

export const LIFECYCLE_BADGE: Record<string, { variant: BadgeVariant; label: string }> = {
  DRAFT: { variant: "status-neutral", label: "Draft" },
  SENT: { variant: "status-info", label: "Sent" },
  PAYMENT_EXPECTED: { variant: "status-info", label: "Payment expected" },
  PARTIALLY_PAID: { variant: "severity-medium", label: "Partially paid" },
  PAID: { variant: "status-success", label: "Paid" },
  OVERPAID: { variant: "severity-medium", label: "Overpaid" },
  REFUNDED: { variant: "status-neutral", label: "Refunded" },
  WRITTEN_OFF: { variant: "status-neutral", label: "Written off" },
  CREDITED: { variant: "status-neutral", label: "Credited" },
  CONVERTED_TO_TAX_INVOICE: { variant: "status-neutral", label: "Converted" },
  FINALIZED: { variant: "status-success", label: "Finalized" },
  EXPIRED_UNCONVERTED: { variant: "status-neutral", label: "Expired" },
};

export function lifecycleBadge(status: string): { variant: BadgeVariant; label: string } {
  return LIFECYCLE_BADGE[status] ?? { variant: "status-neutral", label: status };
}

/** Suggested VAT rate for a treatment (Cyprus). User can override. */
export function defaultRateFor(treatment: string): number {
  switch (treatment) {
    case "DOMESTIC_STANDARD":
    case "DOMESTIC_CYPRUS_VAT":
      return 19;
    case "DOMESTIC_REDUCED":
      return 9;
    default:
      return 0;
  }
}

export function round2(n: number): number {
  return Math.round((n + Number.EPSILON) * 100) / 100;
}
