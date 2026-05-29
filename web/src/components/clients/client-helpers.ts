import type { BadgeVariant } from "@/components/ui";

/** Row shape returned by public.client_list / client_get (the clients table). */
export interface ClientRow {
  id: string;
  organization_id: string;
  business_id: string;
  display_name: string;
  legal_name: string | null;
  country: string | null;
  vat_number: string | null;
  vat_number_format_valid: boolean;
  billing_address_line_1: string | null;
  billing_address_line_2: string | null;
  billing_city: string | null;
  billing_postal_code: string | null;
  billing_country: string | null;
  billing_email: string | null;
  default_currency: string;
  default_payment_terms_days: number;
  default_reverse_charge_applicable: boolean;
  default_vat_treatment: string | null;
  disabled_at: string | null;
  disabled_by: string | null;
  last_seen_at: string | null;
  created_at: string;
  updated_at: string;
}

/** vat_treatment_enum — labels for the subset users pick when creating clients/invoices. */
export const VAT_TREATMENT_LABEL: Record<string, string> = {
  DOMESTIC_STANDARD: "Domestic — standard rate (19%)",
  DOMESTIC_REDUCED: "Domestic — reduced rate (9% / 5%)",
  DOMESTIC_ZERO: "Domestic — zero-rated",
  DOMESTIC_CYPRUS_VAT: "Domestic — Cyprus VAT",
  EU_REVERSE_CHARGE: "EU reverse charge",
  IMPORT_OR_ACQUISITION: "Import / acquisition",
  NON_EU_SERVICE: "Non-EU service",
  OUTSIDE_SCOPE: "Outside scope of VAT",
  EXEMPT: "Exempt",
  NO_VAT: "No VAT",
  UNKNOWN: "Unknown",
};

/** Options offered in the client/invoice VAT-treatment selects, in a sensible order. */
export const VAT_TREATMENT_OPTIONS: string[] = [
  "DOMESTIC_STANDARD",
  "DOMESTIC_REDUCED",
  "DOMESTIC_ZERO",
  "EU_REVERSE_CHARGE",
  "NON_EU_SERVICE",
  "IMPORT_OR_ACQUISITION",
  "EXEMPT",
  "OUTSIDE_SCOPE",
  "NO_VAT",
];

export function vatTreatmentLabel(t: string | null | undefined): string {
  if (!t) return "—";
  return VAT_TREATMENT_LABEL[t] ?? t;
}

/** Country flag emoji from an ISO 3166-1 alpha-2 code (regional indicators). */
export function flagEmoji(code: string | null | undefined): string {
  if (!code || code.length !== 2) return "";
  const cc = code.toUpperCase();
  if (!/^[A-Z]{2}$/.test(cc)) return "";
  return String.fromCodePoint(...[...cc].map((c) => 0x1f1e6 + c.charCodeAt(0) - 65));
}

export interface ClientStatusBadge {
  variant: BadgeVariant;
  label: string;
}
export function clientStatusBadge(c: ClientRow): ClientStatusBadge {
  return c.disabled_at
    ? { variant: "status-neutral", label: "Inactive" }
    : { variant: "status-success", label: "Active" };
}

/** VAT-format badge (we validate format, not VIES — VIES check is deferred to R4). */
export function vatFormatBadge(c: ClientRow): ClientStatusBadge | null {
  if (!c.vat_number) return null;
  return c.vat_number_format_valid
    ? { variant: "status-success", label: "Valid format" }
    : { variant: "severity-medium", label: "Check format" };
}
