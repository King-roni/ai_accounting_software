"use client";
import useSWR from "swr";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

/**
 * PersonalAuditFeed (R7.4) — a 30-day timeline of the signed-in user's own
 * actions from the append-only hash-chain audit log, via list_my_audit_events
 * (RLS-scoped to the actor; returns action/subject/timestamp/reason only).
 */
interface AuditRow {
  occurred_at: string;
  action: string;
  subject_type: string;
  subject_id: string | null;
  business_id: string | null;
  reason: string | null;
}

function humanizeAction(action: string): string {
  const t = action.replace(/_/g, " ").toLowerCase();
  return t.charAt(0).toUpperCase() + t.slice(1);
}

function humanizeSubject(subjectType: string): string {
  return subjectType.replace(/_/g, " ").toLowerCase();
}

export default function PersonalAuditFeed() {
  const { data, error, isLoading } = useSWR<AuditRow[]>("my-audit-feed", async () => {
    const supabase = createSupabaseBrowserClient();
    const { data, error } = await supabase.rpc("list_my_audit_events", { p_limit: 50 });
    if (error) throw new Error(error.message);
    return (data ?? []) as AuditRow[];
  });

  if (isLoading) {
    return <p className="text-sm text-text-muted">Loading your recent activity…</p>;
  }
  if (error) {
    return (
      <p className="text-sm" style={{ color: "var(--color-status-danger)" }}>
        Couldn’t load your activity: {error.message}
      </p>
    );
  }
  if (!data || data.length === 0) {
    return <p className="text-sm text-text-muted">No account activity in the last 30 days.</p>;
  }

  return (
    <ol className="divide-y divide-border-subtle">
      {data.map((row, i) => (
        <li key={`${row.occurred_at}-${i}`} className="flex items-start justify-between gap-4 py-2.5">
          <div className="min-w-0">
            <p className="truncate text-sm font-medium text-text-primary">{humanizeAction(row.action)}</p>
            <p className="truncate text-xs text-text-muted">
              {humanizeSubject(row.subject_type)}
              {row.reason ? ` · ${row.reason}` : ""}
            </p>
          </div>
          <time
            dateTime={row.occurred_at}
            className="shrink-0 whitespace-nowrap text-xs tabular-nums text-text-muted"
          >
            {new Date(row.occurred_at).toLocaleString("en-GB", {
              day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit",
            })}
          </time>
        </li>
      ))}
    </ol>
  );
}
