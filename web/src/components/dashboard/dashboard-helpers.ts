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

export const CHART_TYPE_LABEL: Record<string, string> = {
  KPI_NUMBER: "KPI", BAR: "Bar", DONUT: "Donut", LINE: "Trend", LIST: "List", TABLE: "Table",
};

export const DATA_SOURCE_BADGE: Record<string, { variant: BadgeVariant; label: string }> = {
  OPERATIONAL: { variant: "status-info", label: "Live" },
  ANALYTICS: { variant: "status-neutral", label: "Analytics" },
  ARCHIVE: { variant: "status-success", label: "Archive" },
};

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
