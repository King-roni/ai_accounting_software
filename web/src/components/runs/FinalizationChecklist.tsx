"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { CheckCircle2, CircleDashed, Lock, ShieldCheck, XCircle } from "lucide-react";
import { Badge, Button, Skeleton, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import { FINALIZATION_GATES, gatePassed, gateReason, type GateResult } from "./finalization-helpers";

interface MasterResult { decision?: string; failing_gate?: string; failure_payload?: Record<string, unknown> | null }

export function FinalizationChecklist({
  runId, runStatus, side, organizationId, businessId, onChanged,
}: {
  runId: string;
  runStatus: string;
  side: "OUT" | "IN";
  organizationId: string;
  businessId: string;
  onChanged: () => void;
}) {
  const { user } = useShell();
  const { toast } = useToast();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [busy, setBusy] = useState(false);

  const { data, isLoading, mutate } = useSWR(["fin-gates", runId], async () => {
    const [master, ...gates] = await Promise.all([
      supabase.rpc("gate_finalization_preconditions_satisfied", { p_run_id: runId, p_context: {} }),
      ...FINALIZATION_GATES.map((g) => supabase.rpc(g.fn, { p_run_id: runId })),
    ]);
    return {
      master: (master.data ?? null) as MasterResult | null,
      results: FINALIZATION_GATES.map((g, i) => ({ key: g.key, label: g.label, result: (gates[i].data ?? null) as GateResult | null })),
    };
  });

  const master = data?.master;
  const ready = master?.decision === "ADVANCE";
  const canFinalize = ["AWAITING_APPROVAL", "REVIEW_HOLD"].includes(runStatus);

  async function approveWithStepUp() {
    setBusy(true);
    // 1. Mint a step-up token for the FINALIZATION surface.
    const tokenRes = await supabase.rpc("issue_step_up_token", { p_business_id: businessId, p_surface: "FINALIZATION" });
    if (tokenRes.error) { setBusy(false); toast({ variant: "error", title: "Step-up failed", description: tokenRes.error.message }); return; }
    const td = tokenRes.data as { token_id?: string; id?: string; decision?: string; reason?: string } | string | null;
    const tokenId = typeof td === "string" ? td : (td?.token_id ?? td?.id ?? null);
    if (!tokenId) { setBusy(false); toast({ variant: "warning", title: "Couldn’t mint step-up token", description: (typeof td === "object" && td?.reason) || "Step-up may require re-authentication." }); return; }
    // 2. Approve with STEP_UP method, which lets the engine advance the FINALIZATION gate.
    const fn = side === "OUT" ? "out_workflow_user_approval" : "in_workflow_user_approval";
    const res = await supabase.rpc(fn, {
      p_organization_id: organizationId, p_business_id: businessId, p_run_id: runId,
      p_approval_method: "STEP_UP", p_approval_note: "Finalize period", p_actor_user_id: user.id,
      p_context: {}, p_step_up_token_id: tokenId,
    });
    if (res.error) { setBusy(false); toast({ variant: "error", title: "Approval failed", description: res.error.message }); return; }
    const d = res.data as { decision?: string; reason?: string; reason_code?: string } | null;
    if (d?.decision && !["ALLOW", "APPROVED", "OK"].includes(d.decision)) { setBusy(false); toast({ variant: "warning", title: "Not allowed", description: d.reason ?? d.reason_code ?? d.decision }); return; }
    // 3. Approval landed — drive the FINALIZATION gate by running the lock
    //    sequence (lock period → build & anchor the archive package). Mirrors
    //    AdjustmentFinalizePanel.refinalize's result handling.
    const { data: lockData, error: lockErr } = await supabase.rpc("execute_lock_sequence", {
      p_run_id: runId,
      p_actor_user_id: user.id,
      p_context: {},
    });
    setBusy(false);
    if (lockErr) { toast({ variant: "error", title: "Finalization failed", description: lockErr.message }); return; }
    const lock = lockData as { decision?: string; reason?: string; review_issue_id?: string; last_error?: string } | null;
    switch (lock?.decision) {
      case "COMMITTED":
        toast({ variant: "success", title: "Period finalized", description: "Archive package created." });
        break;
      case "NO_OP":
        toast({ variant: "success", title: "Already finalized", description: "This period was already locked." });
        break;
      case "BLOCKED":
        toast({ variant: "error", title: "Finalization blocked", description: lock.reason ?? lock.review_issue_id ?? "A precondition is no longer satisfied." });
        break;
      case "FAILED":
        toast({ variant: "error", title: "Finalization failed", description: lock.reason ?? lock.last_error ?? "The lock sequence did not complete." });
        break;
      default:
        toast({ variant: "warning", title: "Not finalized", description: lock?.reason ?? lock?.decision ?? "The lock sequence returned an unexpected result." });
    }
    mutate(); onChanged();
  }

  return (
    <div className="flex flex-col gap-3 rounded-md border border-border-subtle p-3">
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <Lock size={16} className="text-text-secondary" aria-hidden="true" />
          <span className="text-sm font-semibold text-text-primary">Finalization readiness</span>
        </div>
        {isLoading ? <Skeleton height={20} className="w-24" /> : ready
          ? <Badge variant="status-success">Ready</Badge>
          : <Badge variant="severity-medium">{master?.failing_gate ? `Blocked: ${master.failing_gate.replace("gate_finalization_", "").replaceAll("_", " ")}` : "Not ready"}</Badge>}
      </div>

      {isLoading ? (
        <div className="flex flex-col gap-2">{[0, 1, 2, 3].map((i) => <Skeleton key={i} height={16} />)}</div>
      ) : (
        <ul className="flex flex-col gap-1.5">
          {(data?.results ?? []).map(({ key, label, result }) => {
            const pass = gatePassed(result);
            const reason = gateReason(result);
            return (
              <li key={key} className="flex items-start gap-2 text-sm">
                {pass ? <CheckCircle2 size={16} className="mt-0.5 shrink-0 text-[var(--color-status-success)]" aria-hidden="true" />
                  : result ? <XCircle size={16} className="mt-0.5 shrink-0" style={{ color: "var(--color-status-danger)" }} aria-hidden="true" />
                  : <CircleDashed size={16} className="mt-0.5 shrink-0 text-text-muted" aria-hidden="true" />}
                <div className="min-w-0">
                  <span className={pass ? "text-text-secondary" : "text-text-primary"}>{label}</span>
                  {!pass && reason && <span className="ml-1 text-xs text-text-muted">— {reason}</span>}
                </div>
              </li>
            );
          })}
        </ul>
      )}

      {canFinalize && (
        <div className="flex items-center justify-between gap-2 border-t border-border-subtle pt-3">
          <p className="text-xs text-text-muted">{ready ? "All preconditions met. Approve with step-up to lock & archive." : "Resolve the blockers above before finalizing."}</p>
          <Button size="sm" leadingIcon={ShieldCheck} loading={busy} disabled={!ready} onClick={approveWithStepUp}>Approve &amp; finalize</Button>
        </div>
      )}
    </div>
  );
}
