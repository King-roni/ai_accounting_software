import type { BadgeVariant } from "@/components/ui";

/** Row from public.recurring_invoice_templates (RLS-scoped), client name joined. */
export interface TemplateRow {
  id: string;
  business_id: string;
  organization_id: string;
  client_id: string;
  template_name: string;
  invoice_type: "PRO_FORMA" | "TAX";
  currency: string;
  vat_treatment_per_line: boolean;
  default_vat_treatment: string | null;
  payment_terms_days: number;
  lines_payload: unknown;
  cadence_kind: string;
  cadence_anchor_day_of_period: number;
  next_due_date: string;
  start_date: string;
  end_date: string | null;
  auto_send: boolean;
  auto_send_target_email: string | null;
  status: "ACTIVE" | "PAUSED" | "ENDED";
  created_at: string;
  client?: { display_name: string | null } | null;
}

export const TEMPLATE_COLUMNS =
  "id, business_id, organization_id, client_id, template_name, invoice_type, currency, vat_treatment_per_line, default_vat_treatment, payment_terms_days, lines_payload, cadence_kind, cadence_anchor_day_of_period, next_due_date, start_date, end_date, auto_send, auto_send_target_email, status, created_at, client:clients(display_name)";

export const CADENCE_LABEL: Record<string, string> = {
  WEEKLY: "Weekly",
  BIWEEKLY: "Every 2 weeks",
  MONTHLY: "Monthly",
  QUARTERLY: "Quarterly",
  SEMI_ANNUAL: "Every 6 months",
  ANNUAL: "Annually",
};
export const CADENCE_OPTIONS = ["WEEKLY", "BIWEEKLY", "MONTHLY", "QUARTERLY", "SEMI_ANNUAL", "ANNUAL"];

export const TEMPLATE_STATUS_BADGE: Record<string, { variant: BadgeVariant; label: string }> = {
  ACTIVE: { variant: "status-success", label: "Active" },
  PAUSED: { variant: "severity-medium", label: "Paused" },
  ENDED: { variant: "status-neutral", label: "Ended" },
};

export function cadenceLabel(c: string): string {
  return CADENCE_LABEL[c] ?? c;
}
