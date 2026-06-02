"use client";
import { useMemo, useState } from "react";
import useSWR, { mutate as globalMutate } from "swr";
import { BellRing, CheckCircle2, FilePlus2, PlayCircle } from "lucide-react";
import { Badge, Button, Drawer, Textarea, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import {
  GATE_LABEL, PHASE_STATUS_META, RUN_COLUMNS, WORKFLOW_SIDE, WORKFLOW_TYPE_LABEL,
  periodLabel, phaseProgress, runIsActive, runStatusBadge,
  type ApprovalRow, type PhaseDefRow, type PhaseStateRow, type RunRow,
} from "./run-helpers";
import { FinalizationChecklist } from "./FinalizationChecklist";
import { AdjustmentForm } from "./AdjustmentForm";
import { AdjustmentFinalizePanel } from "./AdjustmentFinalizePanel";

type Decision = { decision?: string; reason_code?: string; reason?: string } | null;
function denied(d: Decision): string | null {
  if (d && d.decision && !["ALLOW", "STARTED", "CREATED", "OK", "SUCCESS"].includes(d.decision)) return d.reason_code ?? d.reason ?? d.decision;
  return null;
}

export function RunDetailDrawer({ runId, open, onClose, onChanged }: { runId: string | null; open: boolean; onClose: () => void; onChanged: () => void }) {
  return (
    <Drawer open={open} onClose={onClose} title="Workflow run" width={620}>
      {open && runId && <Body runId={runId} onClose={onClose} onChanged={onChanged} />}
    </Drawer>
  );
}

function Body({ runId, onClose, onChanged }: { runId: string; onClose: () => void; onChanged: () => void }) {
  const { user } = useShell();
  const { toast } = useToast();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [busy, setBusy] = useState<string | null>(null);
  const [approveOpen, setApproveOpen] = useState(false);
  const [adjustOpen, setAdjustOpen] = useState(false);
  const [note, setNote] = useState("");

  const { data: run, mutate: mutateRun } = useSWR<RunRow | null>(["run", runId], async () => {
    const { data, error } = await supabase.from("workflow_runs").select(RUN_COLUMNS).eq("id", runId).single();
    if (error) throw new Error(error.message);
    return data as unknown as RunRow;
  }, {
    // Live-update while the run is still progressing; stop once it's terminal.
    refreshInterval: (latest) => latest && runIsActive(latest.status) ? 5000 : 0,
  });
  const { data: defs } = useSWR<PhaseDefRow[]>(run ? ["phase-defs", run.workflow_type] : null, async ([, wfType]: [string, string]) => {
    const { data, error } = await supabase.from("workflow_phase_definitions").select("phase_order, phase_name, optional, description").eq("workflow_type", wfType).order("phase_order");
    if (error) throw new Error(error.message);
    return (data ?? []) as PhaseDefRow[];
  });
  const { data: states, mutate: mutateStates } = useSWR<PhaseStateRow[]>(["phase-states", runId], async () => {
    const { data, error } = await supabase.from("workflow_phase_states").select("phase_name, phase_order, status, gate_decision, error_summary, started_at, completed_at").eq("workflow_run_id", runId).order("phase_order");
    if (error) throw new Error(error.message);
    return (data ?? []) as PhaseStateRow[];
  }, {
    // Phase states change as the engine advances — poll while the run is active.
    refreshInterval: run && runIsActive(run.status) ? 5000 : 0,
  });
  const { data: approvals, mutate: mutateApprovals } = useSWR<ApprovalRow[]>(["run-approvals", runId], async () => {
    const { data, error } = await supabase.from("workflow_run_approvals").select("id, approved_by, approved_at, approval_method, approval_note, revoked_at").eq("run_id", runId).order("approved_at");
    if (error) throw new Error(error.message);
    return (data ?? []) as ApprovalRow[];
  });
  // Child adjustment runs (only meaningful once this is a finalized monthly run).
  const showChildren = !!run && run.workflow_type.endsWith("MONTHLY") && run.status === "FINALIZED";
  const { data: children, mutate: mutateChildren } = useSWR<RunRow[]>(
    showChildren ? ["child-adjustments", runId] : null,
    async () => {
      const { data, error } = await supabase.from("workflow_runs").select(RUN_COLUMNS).eq("parent_run_id", runId).order("created_at");
      if (error) throw new Error(error.message);
      return (data ?? []) as unknown as RunRow[];
    },
  );

  // Also revalidate the FinalizationChecklist's gate SWR (it owns the
  // ["fin-gates", runId] key) so its "Approval recorded" / step-up items reflect
  // an approval recorded here without a manual page reload.
  function refresh() { mutateRun(); mutateStates(); mutateApprovals(); mutateChildren(); void globalMutate(["fin-gates", runId]); onChanged(); }

  if (!run) return <p className="text-sm text-text-muted">Loading…</p>;
  const side = WORKFLOW_SIDE[run.workflow_type];
  const isAdjustment = run.workflow_type.endsWith("ADJUSTMENT");
  const isFinalizedMonthly = run.workflow_type.endsWith("MONTHLY") && run.status === "FINALIZED";
  const b = runStatusBadge(run.status);
  const stateByName = new Map((states ?? []).map((s) => [s.phase_name, s]));
  const { completed, total } = phaseProgress(defs ?? [], states ?? []);
  const canApprove = ["AWAITING_APPROVAL", "REVIEW_HOLD"].includes(run.status);
  const canClearHold = run.status === "REVIEW_HOLD";
  const canRemind = side === "OUT" && ["RUNNING", "REVIEW_HOLD", "AWAITING_APPROVAL", "PAUSED"].includes(run.status);

  async function call(label: string, args: { fn: string; params: Record<string, unknown> }, okMsg: string) {
    setBusy(label);
    const { data, error } = await supabase.rpc(args.fn, args.params);
    setBusy(null);
    if (error) { toast({ variant: "error", title: "Action failed", description: error.message }); return; }
    const d = denied(data as Decision);
    if (d) { toast({ variant: "warning", title: "Not allowed", description: d }); return; }
    toast({ variant: "success", title: okMsg });
    refresh();
  }

  async function approve() {
    const params = side === "OUT"
      ? { p_organization_id: run!.organization_id, p_business_id: run!.business_id, p_run_id: run!.id, p_approval_method: "STANDARD", p_approval_note: note.trim() || null, p_actor_user_id: user.id, p_context: {} }
      : { p_organization_id: run!.organization_id, p_business_id: run!.business_id, p_run_id: run!.id, p_approval_method: "STANDARD", p_approval_note: note.trim() || null, p_actor_user_id: user.id, p_context: {} };
    await call("approve", { fn: side === "OUT" ? "out_workflow_user_approval" : "in_workflow_user_approval", params }, "Run approved");
    setApproveOpen(false);
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant={b.variant}>{b.label}</Badge>
        <Badge variant={side === "OUT" ? "status-info" : "status-neutral"} size="sm">{side === "OUT" ? "Expenses" : "Income"}</Badge>
        <span className="text-sm text-text-secondary">{WORKFLOW_TYPE_LABEL[run.workflow_type]} · {periodLabel(run.period_start)}</span>
      </div>

      <div className="grid grid-cols-3 gap-3 rounded-md border border-border-subtle p-3 text-sm">
        <Stat label="Phases done" value={`${completed} / ${total}`} />
        <Stat label="Started" value={run.started_at ? new Date(run.started_at).toLocaleString("en-GB") : "Not started"} />
        <Stat label="Trigger" value={run.trigger_kind === "MANUAL" ? "Manual" : "Event"} />
      </div>
      {run.manual_trigger_note && <p className="rounded-sm bg-bg-raised px-3 py-2 text-xs text-text-secondary">Note: {run.manual_trigger_note}</p>}

      <div>
        <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-text-muted">Phases</p>
        <ol className="flex flex-col gap-2">
          {(defs ?? []).map((d) => {
            const st = stateByName.get(d.phase_name);
            const meta = PHASE_STATUS_META[st?.status ?? "PENDING"];
            return (
              <li key={d.phase_name} className="flex items-start gap-3 rounded-md border border-border-subtle p-3">
                <span className="mt-0.5 w-5 shrink-0 text-right text-xs tabular-nums text-text-muted">{d.phase_order}</span>
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-medium text-text-primary">{d.phase_name.replaceAll("_", " ")}</span>
                    {d.optional && <Badge variant="status-neutral" size="sm">Optional</Badge>}
                    <Badge variant={meta.variant} size="sm">{meta.label}</Badge>
                    {st?.gate_decision && <span className="text-xs text-text-muted">Gate: {GATE_LABEL[st.gate_decision] ?? st.gate_decision}</span>}
                  </div>
                  {d.description && <p className="mt-0.5 text-xs text-text-secondary">{d.description}</p>}
                  {st?.error_summary && <p className="mt-1 text-xs" style={{ color: "var(--color-status-danger)" }}>{st.error_summary}</p>}
                </div>
              </li>
            );
          })}
        </ol>
      </div>

      {isAdjustment ? (
        <AdjustmentFinalizePanel run={run} onChanged={refresh} />
      ) : (
        <FinalizationChecklist runId={run.id} runStatus={run.status} side={side} organizationId={run.organization_id} businessId={run.business_id} onChanged={refresh} />
      )}

      {isFinalizedMonthly && (
        <div>
          <div className="mb-2 flex items-center justify-between gap-2">
            <p className="text-xs font-semibold uppercase tracking-wide text-text-muted">Adjustments</p>
            <Button size="sm" variant="secondary" leadingIcon={FilePlus2} onClick={() => setAdjustOpen(true)}>Start an adjustment</Button>
          </div>
          {(children ?? []).length === 0 ? (
            <p className="text-sm text-text-muted">No corrections opened for this period.</p>
          ) : (
            <ul className="flex flex-col gap-1.5">
              {(children ?? []).map((c) => {
                const cb = runStatusBadge(c.status);
                return (
                  <li key={c.id} className="flex items-center gap-2 rounded-md border border-border-subtle px-3 py-2 text-sm">
                    <span className="min-w-0 flex-1 truncate text-text-primary">{WORKFLOW_TYPE_LABEL[c.workflow_type]}</span>
                    <span className="text-xs text-text-muted">{new Date(c.created_at).toLocaleDateString("en-GB")}</span>
                    <Badge variant={cb.variant} size="sm">{cb.label}</Badge>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      )}

      <div>
        <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-text-muted">Approvals</p>
        {(approvals ?? []).length === 0 ? (
          <p className="text-sm text-text-muted">No approvals recorded.</p>
        ) : (
          <ul className="flex flex-col gap-1 text-sm">
            {(approvals ?? []).map((a) => (
              <li key={a.id} className="flex items-center gap-2">
                <CheckCircle2 size={14} className="text-[var(--color-status-success)]" aria-hidden="true" />
                <span className="text-text-primary">{a.approval_method}</span>
                <span className="text-text-muted">{new Date(a.approved_at).toLocaleString("en-GB")}</span>
                {a.revoked_at && <Badge variant="status-neutral" size="sm">Revoked</Badge>}
              </li>
            ))}
          </ul>
        )}
      </div>

      {(canApprove || canRemind) && (
        <div className="flex flex-wrap gap-2 border-t border-border-subtle pt-4">
          {canApprove && <Button size="sm" leadingIcon={CheckCircle2} onClick={() => setApproveOpen((v) => !v)}>Approve run</Button>}
          {canClearHold && (
            <Button size="sm" variant="secondary" leadingIcon={PlayCircle} loading={busy === "clear"} onClick={() => call("clear",
              side === "OUT"
                ? { fn: "out_workflow_clear_human_review_hold", params: { p_organization_id: run.organization_id, p_business_id: run.business_id, p_run_id: run.id, p_actor_user_id: user.id, p_context: {} } }
                : { fn: "in_workflow_clear_human_review_hold", params: { p_run_id: run.id, p_context: {} } },
              "Hold cleared")}>Clear review hold</Button>
          )}
          {canRemind && (
            <Button size="sm" variant="ghost" leadingIcon={BellRing} loading={busy === "remind"} onClick={() => call("remind", { fn: "out_workflow_send_reminder", params: { p_organization_id: run.organization_id, p_business_id: run.business_id, p_run_id: run.id, p_actor_user_id: user.id, p_context: {} } }, "Reminder sent")}>Send reminder</Button>
          )}
        </div>
      )}

      {approveOpen && (
        <div className="flex flex-col gap-2 rounded-md border border-border-subtle p-3">
          <Textarea label="Approval note (optional)" value={note} onChange={(e) => setNote(e.target.value)} rows={2} />
          <div className="flex justify-end">
            <Button size="sm" loading={busy === "approve"} onClick={approve}>Confirm approval</Button>
          </div>
        </div>
      )}

      <div className="sticky bottom-0 -mx-5 -mb-5 mt-1 flex items-center justify-end gap-2 border-t border-border-subtle bg-bg-overlay p-4">
        <Button variant="tertiary" onClick={onClose}>Close</Button>
      </div>

      <Drawer open={adjustOpen} onClose={() => setAdjustOpen(false)} title="Open an adjustment" width={460}>
        {adjustOpen && (
          <AdjustmentForm
            parentRun={run}
            onClose={() => setAdjustOpen(false)}
            onCreated={() => { setAdjustOpen(false); refresh(); }}
          />
        )}
      </Drawer>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return <div><p className="text-xs text-text-muted">{label}</p><p className="text-text-primary">{value}</p></div>;
}
