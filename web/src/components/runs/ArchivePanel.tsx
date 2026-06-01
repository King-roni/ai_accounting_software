"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { Archive, FileStack, ShieldCheck } from "lucide-react";
import { Badge, Button, EmptyState, ErrorState, Skeleton, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import {
  ADJUSTMENT_RECORD_COLUMNS,
  ARCHIVE_COLUMNS,
  DELTA_KIND_LABEL,
  MANIFEST_COLUMNS,
  type AdjustmentDeltaKind,
  type AdjustmentRecordRow,
  type ArchivePackageRow,
  type ManifestVersionRow,
} from "./finalization-helpers";
import { periodLabel } from "./run-helpers";

interface ArchiveData {
  packages: ArchivePackageRow[];
  manifestsByPackage: Map<string, ManifestVersionRow[]>;
  recordByRun: Map<string, AdjustmentRecordRow>;
}

export function ArchivePanel() {
  const { currentBusiness, user } = useShell();
  const { toast } = useToast();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [busyId, setBusyId] = useState<string | null>(null);

  const key = currentBusiness ? ["archive-packages", currentBusiness.id] : null;
  const { data, error, isLoading, mutate } = useSWR<ArchiveData>(key, async () => {
    const biz = currentBusiness!.id;
    const [pkgRes, manRes, adjRes] = await Promise.all([
      supabase.from("archive_packages").select(ARCHIVE_COLUMNS).eq("business_id", biz).order("period_start", { ascending: false }),
      supabase.from("archive_manifests").select(MANIFEST_COLUMNS).eq("business_id", biz).order("manifest_version_number", { ascending: true }),
      supabase.from("adjustment_records").select(ADJUSTMENT_RECORD_COLUMNS).eq("business_id", biz),
    ]);
    if (pkgRes.error) throw new Error(pkgRes.error.message);
    if (manRes.error) throw new Error(manRes.error.message);
    if (adjRes.error) throw new Error(adjRes.error.message);
    const manifestsByPackage = new Map<string, ManifestVersionRow[]>();
    for (const m of (manRes.data ?? []) as unknown as ManifestVersionRow[]) {
      const list = manifestsByPackage.get(m.archive_package_id) ?? [];
      list.push(m);
      manifestsByPackage.set(m.archive_package_id, list);
    }
    const recordByRun = new Map<string, AdjustmentRecordRow>();
    for (const r of (adjRes.data ?? []) as unknown as AdjustmentRecordRow[]) recordByRun.set(r.run_id, r);
    return {
      packages: (pkgRes.data ?? []) as unknown as ArchivePackageRow[],
      manifestsByPackage,
      recordByRun,
    };
  });

  async function verify(p: ArchivePackageRow) {
    setBusyId(p.id);
    const { data: d, error } = await supabase.rpc("verify_archive_package", { p_archive_package_id: p.id, p_actor_user_id: user.id, p_context: {} });
    setBusyId(null);
    if (error) { toast({ variant: "error", title: "Verification failed", description: error.message }); return; }
    const res = d as { decision?: string; reason?: string } | null;
    if (res?.decision === "PASSED") {
      toast({ variant: "success", title: "Archive integrity verified", description: "Recomputed file hashes match the sealed anchor." });
    } else if (res?.decision === "FAILED") {
      toast({ variant: "error", title: "Tamper detected", description: "Recomputed inventory doesn’t match the sealed hash — a blocking review issue was opened." });
    } else {
      toast({ variant: "error", title: "Verification error", description: res?.reason ?? res?.decision ?? "Unknown error" });
    }
    mutate();
  }

  if (error) return <ErrorState description={error.message} onRetry={() => mutate()} />;

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-text-secondary">
        Locked, tamper-evident packages for finalized periods. Adjustments add a superseding manifest version; each
        package can be re-verified against its hash anchor.
      </p>

      {isLoading ? (
        <div className="flex flex-col gap-3">{[0, 1].map((i) => <div key={i} className="rounded-xl border border-border-subtle bg-surface-default p-4 shadow-1"><Skeleton height={72} /></div>)}</div>
      ) : (data?.packages ?? []).length === 0 ? (
        <EmptyState icon={Archive} heading="No archived periods yet" body="When a period is finalized, its locked archive package appears here for verification." />
      ) : (
        <div className="flex flex-col gap-3">
          {(data?.packages ?? []).map((p) => (
            <ArchiveCard
              key={p.id}
              pkg={p}
              manifests={data!.manifestsByPackage.get(p.id) ?? []}
              recordByRun={data!.recordByRun}
              verifying={busyId === p.id}
              onVerify={() => verify(p)}
            />
          ))}
        </div>
      )}
    </div>
  );
}

function ArchiveCard({
  pkg,
  manifests,
  recordByRun,
  verifying,
  onVerify,
}: {
  pkg: ArchivePackageRow;
  manifests: ManifestVersionRow[];
  recordByRun: Map<string, AdjustmentRecordRow>;
  verifying: boolean;
  onVerify: () => void;
}) {
  const latest = manifests.length ? manifests[manifests.length - 1].manifest_version_number : 1;
  const adjusted = latest > 1;
  return (
    <div className="rounded-xl border border-border-subtle bg-surface-default p-4 shadow-1">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap items-center gap-2">
          <span className="font-semibold text-text-primary">{periodLabel(pkg.period_start)}</span>
          <Badge variant={adjusted ? "severity-medium" : "status-info"} size="sm">{adjusted ? "Adjusted" : "Original"}</Badge>
          <Badge variant="status-neutral" size="sm">Version {latest}</Badge>
          {pkg.step_up_auth_used && <Badge variant="status-success" size="sm">Step-up</Badge>}
        </div>
        <Button variant="secondary" size="sm" leadingIcon={ShieldCheck} loading={verifying} onClick={onVerify}>Verify integrity</Button>
      </div>

      <ol className="mt-3 flex flex-col gap-2 border-t border-border-subtle pt-3">
        {manifests.length === 0 ? (
          <li className="text-xs text-text-muted">No manifest versions recorded.</li>
        ) : (
          manifests.map((m) => {
            const rec = m.produced_by_run_id ? recordByRun.get(m.produced_by_run_id) : undefined;
            const isOriginal = m.manifest_version_number === 1 || !rec;
            return (
              <li key={m.id} className="flex items-start gap-3 text-sm">
                <span className="mt-0.5 flex h-5 w-9 shrink-0 items-center justify-center rounded-md bg-bg-raised font-mono text-[11px] font-bold text-text-secondary">v{m.manifest_version_number}</span>
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    {isOriginal ? (
                      <span className="font-medium text-text-primary">Original finalization</span>
                    ) : (
                      <>
                        <FileStack size={14} className="text-text-muted" aria-hidden="true" />
                        <span className="font-medium text-text-primary">{DELTA_KIND_LABEL[rec!.delta_kind as AdjustmentDeltaKind] ?? rec!.delta_kind}</span>
                      </>
                    )}
                    <span className="text-xs text-text-muted">{new Date(m.produced_at).toLocaleDateString("en-GB")}</span>
                  </div>
                  {rec && !isOriginal && <p className="mt-0.5 text-xs text-text-secondary">{rec.reason}</p>}
                  {m.manifest_hash && <p className="mt-0.5 font-mono text-[11px] text-text-muted">{m.manifest_hash.slice(0, 16)}…</p>}
                </div>
              </li>
            );
          })
        )}
      </ol>
    </div>
  );
}
