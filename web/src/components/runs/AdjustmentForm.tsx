"use client";
import { useMemo, useState } from "react";
import { Button, Select, Textarea, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import {
  DELTA_KIND_LABEL,
  deltaKindsForSide,
  type AdjustmentDeltaKind,
} from "./finalization-helpers";
import { periodLabel, WORKFLOW_SIDE, type RunRow } from "./run-helpers";

/** Open an adjustment (OUT_ADJUSTMENT / IN_ADJUSTMENT) against a finalized
 *  monthly run. Calls the side's intake RPC; on success a correction run is
 *  created in CREATED and the worker drives it to AWAITING_APPROVAL, where it
 *  can be re-finalized into a new manifest version on the parent's archive. */
export function AdjustmentForm({
  parentRun,
  onClose,
  onCreated,
}: {
  parentRun: RunRow;
  onClose: () => void;
  onCreated: (adjustmentRunId: string) => void;
}) {
  const { user } = useShell();
  const { toast } = useToast();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const side = WORKFLOW_SIDE[parentRun.workflow_type];
  const kinds = useMemo(() => deltaKindsForSide(side), [side]);
  const [deltaKind, setDeltaKind] = useState<AdjustmentDeltaKind>(kinds[0]);
  const [reason, setReason] = useState("");
  const [detail, setDetail] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const reasonOk = reason.trim().length >= 10;

  async function submit() {
    if (!reasonOk) {
      setErr("A reason of at least 10 characters is required.");
      return;
    }
    setBusy(true);
    setErr(null);
    // delta_payload must be a non-empty JSON object (the IN RPC checks the type).
    const deltaPayload: Record<string, unknown> = { note: detail.trim() || reason.trim() };
    const fn =
      side === "OUT" ? "out_workflow_adjustment_intake" : "in_workflow_adjustment_intake";
    const params =
      side === "OUT"
        ? {
            p_organization_id: parentRun.organization_id,
            p_business_id: parentRun.business_id,
            p_parent_run_id: parentRun.id,
            p_reason: reason.trim(),
            p_delta_kind: deltaKind,
            p_delta_payload: deltaPayload,
            p_requesting_user_id: user.id,
            p_context: {},
          }
        : {
            p_actor_user_id: user.id,
            p_organization_id: parentRun.organization_id,
            p_business_id: parentRun.business_id,
            p_parent_run_id: parentRun.id,
            p_reason: reason.trim(),
            p_delta_kind: deltaKind,
            p_delta_payload: deltaPayload,
            p_context: {},
          };
    const { data, error } = await supabase.rpc(fn, params);
    setBusy(false);
    if (error) {
      setErr(error.message);
      return;
    }
    // OUT returns {decision:'CREATED', run_id}; IN returns {decision:'ALLOW', adjustment_run_id}.
    const d = data as
      | { decision?: string; run_id?: string; adjustment_run_id?: string; reason?: string; reason_code?: string }
      | null;
    const ok = d?.decision === "CREATED" || d?.decision === "ALLOW";
    if (!ok) {
      setErr(`Couldn’t open the adjustment: ${d?.reason ?? d?.reason_code ?? d?.decision ?? "unknown error"}`);
      return;
    }
    toast({
      variant: "success",
      title: "Adjustment opened",
      description: "A correction run was created. It will be processed, then you can re-finalize.",
    });
    onCreated(d?.run_id ?? d?.adjustment_run_id ?? "");
  }

  return (
    <div className="flex flex-col gap-4">
      {err && (
        <p
          className="rounded-sm border px-3 py-2 text-xs"
          style={{ borderColor: "var(--color-status-danger)", color: "var(--color-status-danger)" }}
        >
          {err}
        </p>
      )}
      <p className="text-sm text-text-secondary">
        Correcting <strong>{side === "OUT" ? "expenses" : "income"}</strong> for{" "}
        <strong>{periodLabel(parentRun.period_start)}</strong>. The period stays locked — this opens a
        tracked correction run that re-finalizes into a new, superseding archive version.
      </p>

      <Select label="What are you correcting?" value={deltaKind} onChange={(e) => setDeltaKind(e.target.value as AdjustmentDeltaKind)}>
        {kinds.map((k) => (
          <option key={k} value={k}>
            {DELTA_KIND_LABEL[k]}
          </option>
        ))}
      </Select>

      <div>
        <Textarea
          label="Reason"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          rows={2}
          placeholder="Why is this correction needed? (recorded in the audit trail)"
        />
        <p className={`mt-1 text-xs ${reasonOk ? "text-text-muted" : "text-text-secondary"}`}>
          {reason.trim().length}/10 characters minimum
        </p>
      </div>

      <Textarea
        label="Details (optional)"
        value={detail}
        onChange={(e) => setDetail(e.target.value)}
        rows={3}
        placeholder="What specifically changes — transaction, amount, VAT treatment, evidence…"
      />

      <div className="sticky bottom-0 -mx-5 -mb-5 mt-1 flex items-center justify-end gap-2 border-t border-border-subtle bg-bg-overlay p-4">
        <Button variant="tertiary" onClick={onClose} disabled={busy}>
          Cancel
        </Button>
        <Button onClick={submit} loading={busy} disabled={!reasonOk}>
          Open adjustment
        </Button>
      </div>
    </div>
  );
}
