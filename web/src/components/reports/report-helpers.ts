import type { BadgeVariant } from "@/components/ui";

/** Row from public.export_catalogue_definitions. */
export interface ExportCatalogueRow {
  export_kind: string;
  display_name: string;
  supported_formats: string[];
  permission_surface: string;
  scope_kind: "period" | "range" | "all-time" | "multi-period";
  default_retention_days: number;
}

/** Row from public.exports. */
export interface ExportRow {
  id: string;
  export_kind: string;
  format: string;
  period_start: string | null;
  period_end: string | null;
  status: "PENDING" | "RUNNING" | "COMPLETED" | "FAILED";
  requested_at: string;
  completed_at: string | null;
  byte_size: number | null;
  download_count: number;
  failure_message: string | null;
  signed_url_expires_at: string | null;
  storage_object_id: string | null;
}

export const EXPORT_COLUMNS =
  "id, export_kind, format, period_start, period_end, status, requested_at, completed_at, byte_size, download_count, failure_message, signed_url_expires_at, storage_object_id";

export const EXPORT_STATUS_BADGE: Record<string, { variant: BadgeVariant; label: string }> = {
  PENDING: { variant: "status-neutral", label: "Queued" },
  RUNNING: { variant: "status-info", label: "Generating" },
  COMPLETED: { variant: "status-success", label: "Ready" },
  FAILED: { variant: "severity-blocking", label: "Failed" },
};

export const SCOPE_LABEL: Record<string, string> = {
  period: "Single period", range: "Date range", "all-time": "All-time", "multi-period": "Multi-period",
};

/** Whether the export kind needs a period_start/period_end. */
export function scopeNeedsDates(scope: string): boolean {
  return scope !== "all-time";
}

/** Catalogue display name lookup for the exports history list. */
export function kindLabel(kind: string, catalogue: ExportCatalogueRow[] | undefined): string {
  return catalogue?.find((c) => c.export_kind === kind)?.display_name ?? kind;
}
