"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { Building2, CheckCircle2, Clock, UserPlus } from "lucide-react";
import { Badge, Button, Card, CardBody, EmptyState, ErrorState, useToast } from "@/components/ui";
import { SeverityIcon } from "@/theme/icons";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import Link from "next/link";
import {
  GROUPS, GROUP_LABEL, ISSUE_COLUMNS, SEVERITY_BADGE, SEVERITY_RANK, resolutionRoute, type IssueRow, type IssueGroup,
} from "@/components/reviews/review-helpers";
import { ReviewDetailDrawer } from "@/components/reviews/ReviewDetailDrawer";
import type { CardAccent } from "@/components/ui";

const ACCENT: Record<string, CardAccent> = { BLOCKING: "severity-blocking", HIGH: "severity-high", MEDIUM: "severity-medium", LOW: "severity-low" };

export default function ReviewsPage() {
  const { currentBusiness, isMultiBusiness, user } = useShell();
  const { toast } = useToast();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);

  const key = currentBusiness ? ["issues", currentBusiness.id] : null;
  const { data, error, isLoading, mutate } = useSWR<IssueRow[]>(key, async () => {
    const res = await supabase.from("review_issues").select(ISSUE_COLUMNS).eq("business_id", currentBusiness!.id).eq("status", "OPEN");
    if (res.error) throw new Error(res.error.message);
    return (res.data ?? []) as unknown as IssueRow[];
  });

  const [group, setGroup] = useState<IssueGroup | "ALL">("ALL");
  const [detail, setDetail] = useState<IssueRow | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);

  const counts = useMemo(() => {
    const m = new Map<string, number>();
    (data ?? []).forEach((i) => m.set(i.issue_group, (m.get(i.issue_group) ?? 0) + 1));
    return m;
  }, [data]);

  const rows = useMemo(() => {
    const list = (data ?? []).filter((i) => group === "ALL" || i.issue_group === group);
    return [...list].sort((a, b) => SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity] || a.created_at.localeCompare(b.created_at));
  }, [data, group]);

  // The B14 RPCs return a { decision, status_after, reason } payload rather than
  // throwing on denial (e.g. a BLOCKING issue can't be snoozed).
  type Decision = { decision?: string; reason?: string; message?: string } | null;
  function denied(res: Decision): string | null {
    if (res && res.decision && res.decision !== "ALLOW") return res.reason ?? res.message ?? "This action isn't allowed for this issue.";
    return null;
  }

  async function snooze(r: IssueRow) {
    setBusyId(r.id);
    const { data, error: e } = await supabase.rpc("snooze_apply", { p_actor_user_id: user.id, p_issue_id: r.id, p_snooze_reason: "Snoozed from review queue", p_context: {} });
    setBusyId(null);
    if (e) { toast({ variant: "error", title: "Snooze failed", description: e.message }); return; }
    const d = denied(data as Decision);
    if (d) { toast({ variant: "warning", title: "Can’t snooze this issue", description: d }); return; }
    toast({ variant: "success", title: "Issue snoozed" });
    setDetail(null); mutate();
  }
  async function assign(r: IssueRow) {
    setBusyId(r.id);
    const { data, error: e } = await supabase.rpc("review_queue_assign", { p_actor_user_id: user.id, p_issue_id: r.id, p_assignee_user_id: user.id, p_context: {} });
    setBusyId(null);
    if (e) { toast({ variant: "error", title: "Assign failed", description: e.message }); return; }
    const d = denied(data as Decision);
    if (d) { toast({ variant: "warning", title: "Can’t assign this issue", description: d }); return; }
    toast({ variant: "success", title: "Assigned to you" });
    mutate();
  }

  return (
    <div className="flex flex-col gap-5">
      <header>
        <h1 className="text-2xl font-semibold text-text-primary">Review queue</h1>
        <p className="text-sm text-text-secondary">{isMultiBusiness ? "All businesses" : currentBusiness?.display_name ?? "—"} · {(data ?? []).length} open</p>
      </header>

      {currentBusiness && (
        <div className="flex flex-wrap gap-2">
          <button type="button" onClick={() => setGroup("ALL")} className={`rounded-md border px-3 py-2 text-sm ${group === "ALL" ? "border-action-primary bg-[color-mix(in_srgb,var(--color-action-primary)_8%,transparent)] text-text-primary" : "border-border-subtle text-text-secondary hover:text-text-primary"}`}>
            All <span className="tabular-nums">({(data ?? []).length})</span>
          </button>
          {GROUPS.map((g) => (
            <button key={g.id} type="button" onClick={() => setGroup(g.id)} className={`rounded-md border px-3 py-2 text-sm ${group === g.id ? "border-action-primary bg-[color-mix(in_srgb,var(--color-action-primary)_8%,transparent)] text-text-primary" : "border-border-subtle text-text-secondary hover:text-text-primary"}`}>
              {g.label} <span className="tabular-nums text-text-muted">({counts.get(g.id) ?? 0})</span>
            </button>
          ))}
        </div>
      )}

      {!currentBusiness ? (
        <EmptyState icon={Building2} heading="Select a business" body="Choose a business to see its review queue." />
      ) : error ? (
        <ErrorState description={error.message} onRetry={() => mutate()} />
      ) : isLoading ? (
        <div className="flex flex-col gap-3">{[0, 1, 2].map((i) => <Card key={i}><CardBody><div className="h-16" /></CardBody></Card>)}</div>
      ) : rows.length === 0 ? (
        <EmptyState icon={CheckCircle2} heading="Inbox zero" body="No open issues in this bucket. Nice work." />
      ) : (
        <div className="flex flex-col gap-3">
          {rows.map((r) => {
            const route = resolutionRoute(r.recommended_action);
            return (
              <Card key={r.id} accent={ACCENT[r.severity]} interactive onClick={() => setDetail(r)}>
                <CardBody className="flex flex-col gap-2 pt-4">
                  <div className="flex flex-wrap items-center gap-2">
                    <Badge variant={SEVERITY_BADGE[r.severity].variant} size="sm">{r.severity}</Badge>
                    <span className="text-xs text-text-muted">{GROUP_LABEL[r.issue_group]}</span>
                  </div>
                  <div className="flex items-start gap-2">
                    <SeverityIcon severity={r.severity} size={18} className="mt-0.5 shrink-0" />
                    <div className="min-w-0">
                      <p className="font-medium text-text-primary">{r.plain_language_title}</p>
                      {r.plain_language_description && <p className="line-clamp-2 text-sm text-text-secondary">{r.plain_language_description}</p>}
                    </div>
                  </div>
                  <div className="flex flex-wrap items-center gap-2 pt-1" onClick={(e) => e.stopPropagation()}>
                    {route && (
                      <Link href={route.href} className="inline-flex h-8 items-center rounded-md bg-action-primary px-3 text-sm font-medium text-text-on-primary hover:bg-action-hover">{route.label}</Link>
                    )}
                    <Button variant="secondary" size="sm" leadingIcon={UserPlus} loading={busyId === r.id} onClick={() => assign(r)}>Assign to me</Button>
                    <Button variant="tertiary" size="sm" leadingIcon={Clock} loading={busyId === r.id} onClick={() => snooze(r)}>Snooze</Button>
                  </div>
                </CardBody>
              </Card>
            );
          })}
        </div>
      )}

      <ReviewDetailDrawer row={detail} open={!!detail} onClose={() => setDetail(null)} onSnooze={snooze} onAssign={assign} busy={busyId === detail?.id} />
    </div>
  );
}
