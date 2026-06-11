"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { CheckCircle2, FileStack, Lock, ShieldCheck } from "lucide-react";
import { Badge, Button, Skeleton, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import {
  ADJUSTMENT_RECORD_COLUMNS,
  DELTA_KIND_LABEL,
  type AdjustmentDeltaKind,
  type AdjustmentRecordRow,
} from "./finalization-helpers";
import type { RunRow } from "./run-helpers";

interface GateRes {
  decision?: string;
  payload?: { reason?: string } | null;
}
interface ParentPkg {
  id: string;
  bundle_hash_anchor: string | null;
  latest_version: number | null;
}

/** Re-finalization panel for an OUT_ADJUSTMENT / IN_ADJUSTMENT run. Once the
 *  run reaches AWAITING_APPROVAL and the adjustment preconditions hold, locks a
 *  new manifest version on the parent period's archive package
 *  (execute_adjustment_lock_sequence). */
export function AdjustmentFinalizePanel({ run, onChanged }: { run: RunRow; onChanged: () => void }) {
  const { user } = useShell();
  const { toast } = useToast();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [busy, setBusy] = useState(false);

  // Adjustment record (delta kind + reason).
  const { data: record } = useSWR<AdjustmentRecordRow | null>(["adj-record", run.id], async () => {
    const { data, error } = await supabase
      .from("adjustment_records")
      .select(ADJUSTMENT_RECORD_COLUMNS)
      .eq("run_id", run.id)
      .maybeSingle();
    if (error) throw new Error(error.message);
    return (data ?? null) as unknown as AdjustmentRecordRow | null;
  });

  // Parent archive package for the period.
  const { data: pkg } = useSWR<ParentPkg | null>(
    run.parent_run_id ? ["adj-parent-pkg", run.parent_run_id] : null,
    async () => {
      // BOOK-979: resolve the package via the parent run's archive_package_id, not
      // archive_packages.workflow_run_id. A paired IN run attaches to the OUT run's
      // period package (BOOK-977), so the package row's workflow_run_id names only
      // the side that built it — keying off it returns nothing for an IN parent and
      // the re-finalize button never enables. The run's archive_package_id link is
      // set correctly on both sides (= the shared period package).
      const { data: parent, error: pErr } = await supabase
        .from("workflow_runs")
        .select("archive_package_id")
        .eq("id", run.parent_run_id!)
        .maybeSingle();
      if (pErr) throw new Error(pErr.message);
      const pkgId = (parent as { archive_package_id: string | null } | null)?.archive_package_id;
      if (!pkgId) return null;
      const { data, error } = await supabase
        .from("archive_packages")
        .select("id, bundle_hash_anchor")
        .eq("id", pkgId)
        .maybeSingle();
      if (error) throw new Error(error.message);
      if (!data) return null;
      const { data: latest } = await supabase
        .from("v_archive_package_latest_manifest")
        .select("latest_version")
        .eq("archive_package_id", data.id)
        .maybeSingle();
      return { ...(data as { id: string; bundle_hash_anchor: string | null }), latest_version: latest?.latest_version ?? null };
    },
  );

  // Finalization preconditions for the adjustment.
  const { data: gate, isLoading: gateLoading, mutate: mutateGate } = useSWR<GateRes | null>(
    pkg ? ["adj-gate", run.id, pkg.id] : null,
    async () => {
      const { data, error } = await supabase.rpc("gate_finalization_adjustment_preconditions_satisfied", {
        p_adjustment_run_id: run.id,
        p_parent_archive_package_id: pkg!.id,
      });
      if (error) throw new Error(error.message);
      return (data ?? null) as GateRes | null;
    },
  );

  const ready = gate?.decision === "ADVANCE";
  const awaiting = run.status === "AWAITING_APPROVAL";
  const finalized = run.status === "FINALIZED";
  const nextVersion = (pkg?.latest_version ?? 1) + 1;

  async function refinalize() {
    if (!pkg) return;
    setBusy(true);
    const { data, error } = await supabase.rpc("execute_adjustment_lock_sequence", {
      p_adjustment_run_id: run.id,
      p_parent_archive_package_id: pkg.id,
      p_actor_user_id: user.id,
      p_context: {},
    });
    setBusy(false);
    if (error) {
      toast({ variant: "error", title: "Re-finalization failed", description: error.message });
      return;
    }
    const d = data as { decision?: string; manifest_version_number?: number; reason?: string } | null;
    if (d?.decision === "COMMITTED") {
      toast({
        variant: "success",
        title: `Archive version ${d.manifest_version_number} locked`,
        description: "The correction is now a superseding, tamper-evident manifest version.",
      });
    } else if (d?.decision === "NO_OP") {
      toast({ variant: "info", title: "Already finalized", description: "This adjustment was already locked." });
    } else {
      toast({ variant: "warning", title: "Not re-finalized", description: d?.reason ?? d?.decision ?? "Preconditions not met." });
    }
    mutateGate();
    onChanged();
  }

  return (
    <div className="flex flex-col gap-3 rounded-md border border-border-subtle p-3">
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <FileStack size={16} className="text-text-secondary" aria-hidden="true" />
          <span className="text-sm font-semibold text-text-primary">Adjustment re-finalization</span>
        </div>
        {finalized ? (
          <Badge variant="status-success">Locked</Badge>
        ) : awaiting ? (
          gateLoading ? (
            <Skeleton height={20} className="w-20" />
          ) : ready ? (
            <Badge variant="status-success">Ready</Badge>
          ) : (
            <Badge variant="severity-medium">Blocked</Badge>
          )
        ) : (
          <Badge variant="status-info">Processing</Badge>
        )}
      </div>

      {record && (
        <dl className="grid grid-cols-1 gap-1 text-sm sm:grid-cols-[auto_1fr] sm:gap-x-3">
          <dt className="text-text-muted">Correction</dt>
          <dd className="text-text-primary">{DELTA_KIND_LABEL[record.delta_kind as AdjustmentDeltaKind] ?? record.delta_kind}</dd>
          <dt className="text-text-muted">Reason</dt>
          <dd className="text-text-secondary">{record.reason}</dd>
        </dl>
      )}

      {!finalized && !awaiting && (
        <p className="text-xs text-text-muted">
          The correction run is being processed. Once it reaches approval, you can re-finalize it here into a new
          archive version.
        </p>
      )}

      {awaiting && !ready && !gateLoading && (
        <p className="text-xs" style={{ color: "var(--color-status-danger)" }}>
          {gate?.payload?.reason
            ? gate.payload.reason.replaceAll("_", " ").toLowerCase()
            : "Preconditions for re-finalization are not yet satisfied."}
        </p>
      )}

      {finalized && (
        <p className="flex items-center gap-2 text-xs text-text-secondary">
          <CheckCircle2 size={14} className="text-[var(--color-status-success)]" aria-hidden="true" />
          Locked as a new manifest version on the {pkg ? "period’s" : ""} archive package. Verify it from the Archive tab.
        </p>
      )}

      {awaiting && (
        <div className="flex items-center justify-between gap-2 border-t border-border-subtle pt-3">
          <p className="text-xs text-text-muted">
            {ready
              ? `Locks archive version ${nextVersion}, superseding v${pkg?.latest_version ?? 1}.`
              : "Resolve the blocker above before re-finalizing."}
          </p>
          <Button size="sm" leadingIcon={ShieldCheck} loading={busy} disabled={!ready || !pkg} onClick={refinalize}>
            Re-finalize period
          </Button>
        </div>
      )}

      {!pkg && run.parent_run_id && (
        <p className="flex items-center gap-2 text-xs text-text-muted">
          <Lock size={14} aria-hidden="true" /> Waiting on the parent period’s archive package.
        </p>
      )}
    </div>
  );
}
