import type { BadgeVariant } from "@/components/ui";

export interface DocRow {
  id: string;
  source: "EMAIL" | "DRIVE" | "MANUAL" | "INVOICE_GENERATOR";
  source_location: string | null;
  original_filename: string | null;
  document_type: "INVOICE" | "RECEIPT" | "CONTRACT" | "PROOF_OF_PAYMENT" | "BANK_EVIDENCE" | "STUB" | "OTHER";
  supplier_name: string | null;
  supplier_country: string | null;
  supplier_vat_number: string | null;
  invoice_number: string | null;
  invoice_date: string | null;
  due_date: string | null;
  amount_subtotal: number | null;
  amount_total: number | null;
  currency: string | null;
  vat_amount: number | null;
  vat_rate: number | null;
  payment_reference: string | null;
  client_name: string | null;
  line_items: { description?: string; amount?: number }[] | null;
  extraction_status: "DISCOVERED" | "INGESTED" | "EXTRACTED" | "LINKED_CANDIDATE" | "MATCHED" | "DISMISSED";
  extraction_confidence_per_field: Record<string, number> | null;
  extraction_layer_used: string | null;
  discovery_reason: string | null;
  created_at: string;
}

export const DOC_COLUMNS =
  "id, source, source_location, original_filename, document_type, supplier_name, supplier_country, supplier_vat_number, invoice_number, invoice_date, due_date, amount_subtotal, amount_total, currency, vat_amount, vat_rate, payment_reference, client_name, line_items, extraction_status, extraction_confidence_per_field, extraction_layer_used, discovery_reason, created_at";

export const EXTRACTION_BADGE: Record<DocRow["extraction_status"], { variant: BadgeVariant; label: string }> = {
  DISCOVERED: { variant: "status-neutral", label: "Discovered" },
  INGESTED: { variant: "status-info", label: "Ingested" },
  EXTRACTED: { variant: "status-success", label: "Extracted" },
  LINKED_CANDIDATE: { variant: "status-info", label: "Linked candidate" },
  MATCHED: { variant: "status-success", label: "Matched" },
  DISMISSED: { variant: "status-neutral", label: "Dismissed" },
};

export const SOURCE_LABEL: Record<DocRow["source"], string> = {
  EMAIL: "Email", DRIVE: "Drive", MANUAL: "Manual upload", INVOICE_GENERATOR: "Invoice generator",
};

/** Confidence (0–1) → token color, per the app-wide 60/80 thresholds. */
export function confidenceColor(c: number): string {
  if (c < 0.6) return "var(--color-status-danger)";
  if (c < 0.8) return "var(--color-status-warning)";
  return "var(--color-status-success)";
}

export function docTitle(d: DocRow): string {
  return d.supplier_name || d.client_name || d.original_filename || "Untitled document";
}

export function fmtMoney(amount: number | null, currency: string | null): string {
  if (amount == null) return "—";
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: (currency || "EUR").trim() }).format(amount);
}
