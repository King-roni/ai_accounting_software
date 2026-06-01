"use client";
import { useMemo } from "react";
import useSWR from "swr";
import { AlertTriangle, FileSpreadsheet, FileText } from "lucide-react";
import { Badge, type BadgeVariant } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

/**
 * RecentUploads — the parse-results view (R7.2). Statements are parsed
 * asynchronously by the ingestion worker (upload → parse → normalize → dedup →
 * transactions), so this panel shows each recent upload's live status and, once
 * PARSED, how many transactions were imported (and any rows skipped as
 * warnings). It polls while anything is still queued/parsing.
 */
interface UploadRow {
  id: string;
  original_filename: string | null;
  file_format: string;
  upload_status: "UPLOADED" | "PARSING" | "PARSED" | "FAILED" | "ACCEPTED";
  declared_period_start: string | null;
  declared_period_end: string | null;
  parse_warnings: unknown[] | null;
  uploaded_at: string;
}

const STATUS_BADGE: Record<UploadRow["upload_status"], { variant: BadgeVariant; label: string }> = {
  UPLOADED: { variant: "status-neutral", label: "Queued" },
  PARSING: { variant: "status-info", label: "Parsing…" },
  PARSED: { variant: "status-success", label: "Imported" },
  ACCEPTED: { variant: "status-success", label: "Accepted" },
  FAILED: { variant: "severity-blocking", label: "Failed" },
};

/** A still-queued/parsing upload older than this is likely stuck (worker down). */
const STUCK_THRESHOLD_MS = 3 * 60 * 1000;
function isStuck(u: UploadRow): boolean {
  if (u.upload_status !== "UPLOADED" && u.upload_status !== "PARSING") return false;
  const uploadedAt = new Date(u.uploaded_at).getTime();
  return Number.isFinite(uploadedAt) && Date.now() - uploadedAt > STUCK_THRESHOLD_MS;
}

export function RecentUploads({ businessId }: { businessId: string }) {
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);

  const { data: uploads } = useSWR<UploadRow[]>(
    ["stmt-uploads", businessId],
    async () => {
      const { data, error } = await supabase
        .from("statement_uploads")
        .select(
          "id, original_filename, file_format, upload_status, declared_period_start, declared_period_end, parse_warnings, uploaded_at",
        )
        .eq("business_id", businessId)
        .order("uploaded_at", { ascending: false })
        .limit(5);
      if (error) throw new Error(error.message);
      return (data ?? []) as UploadRow[];
    },
    {
      // Poll while anything is still being processed so status flips live.
      refreshInterval: (latest) =>
        (latest ?? []).some((u) => u.upload_status === "UPLOADED" || u.upload_status === "PARSING") ? 5000 : 0,
    },
  );

  const ids = useMemo(() => (uploads ?? []).map((u) => u.id), [uploads]);
  const { data: counts } = useSWR<Record<string, number>>(
    ids.length ? ["stmt-upload-counts", ...ids] : null,
    async () => {
      const { data, error } = await supabase
        .from("transactions")
        .select("statement_upload_id")
        .in("statement_upload_id", ids);
      if (error) throw new Error(error.message);
      const tally: Record<string, number> = {};
      for (const row of data ?? []) {
        const key = (row as { statement_upload_id: string }).statement_upload_id;
        tally[key] = (tally[key] ?? 0) + 1;
      }
      return tally;
    },
  );

  if (!uploads || uploads.length === 0) return null;

  return (
    <section className="rounded-md border border-border-subtle bg-surface-default">
      <header className="border-b border-border-subtle px-4 py-2.5">
        <h2 className="text-sm font-semibold text-text-primary">Recent uploads</h2>
      </header>
      <ul className="divide-y divide-border-subtle">
        {uploads.map((u) => {
          const badge = STATUS_BADGE[u.upload_status];
          const Icon = u.file_format === "PDF" ? FileText : FileSpreadsheet;
          const warnings = Array.isArray(u.parse_warnings) ? u.parse_warnings.length : 0;
          const imported = counts?.[u.id] ?? 0;
          return (
            <li key={u.id} className="flex items-center gap-3 px-4 py-2.5">
              <Icon size={16} className="shrink-0 text-text-muted" aria-hidden="true" />
              <div className="min-w-0 flex-1">
                <div className="truncate text-sm text-text-primary">{u.original_filename ?? "Statement"}</div>
                <div className="text-xs text-text-muted tabular-nums">
                  {u.declared_period_start} → {u.declared_period_end}
                </div>
              </div>
              <div className="flex items-center gap-3 text-xs text-text-secondary">
                {(u.upload_status === "PARSED" || u.upload_status === "ACCEPTED") && (
                  <span className="tabular-nums">
                    {imported} transaction{imported === 1 ? "" : "s"} imported
                  </span>
                )}
                {warnings > 0 && (
                  <span className="inline-flex items-center gap-1 text-text-secondary">
                    <AlertTriangle size={13} aria-hidden="true" style={{ color: "var(--color-status-warning)" }} /> {warnings} skipped
                  </span>
                )}
                {isStuck(u) && (
                  <span className="inline-flex items-center gap-1" style={{ color: "var(--color-status-warning)" }} title="This upload has been queued for a while.">
                    <AlertTriangle size={13} aria-hidden="true" /> Still queued — the processing service may be offline
                  </span>
                )}
                <Badge variant={badge.variant} size="sm">{badge.label}</Badge>
              </div>
            </li>
          );
        })}
      </ul>
    </section>
  );
}
