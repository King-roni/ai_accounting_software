"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { Archive, ShieldCheck } from "lucide-react";
import { Badge, Button, EmptyState, ErrorState, Table, useToast, type Column } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import { ARCHIVE_COLUMNS, type ArchivePackageRow } from "./finalization-helpers";
import { periodLabel } from "./run-helpers";

export function ArchivePanel() {
  const { currentBusiness, user } = useShell();
  const { toast } = useToast();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [busyId, setBusyId] = useState<string | null>(null);

  const key = currentBusiness ? ["archive-packages", currentBusiness.id] : null;
  const { data, error, isLoading, mutate } = useSWR<ArchivePackageRow[]>(key, async () => {
    const { data, error } = await supabase.from("archive_packages").select(ARCHIVE_COLUMNS).eq("business_id", currentBusiness!.id).order("period_start", { ascending: false });
    if (error) throw new Error(error.message);
    return (data ?? []) as unknown as ArchivePackageRow[];
  });

  async function verify(p: ArchivePackageRow) {
    setBusyId(p.id);
    const { data: d, error } = await supabase.rpc("verify_archive_package", { p_archive_package_id: p.id, p_actor_user_id: user.id, p_context: {} });
    setBusyId(null);
    if (error) { toast({ variant: "error", title: "Verification failed", description: error.message }); return; }
    // verify_archive_package returns decision PASSED (anchor matches) / FAILED
    // (tamper → opens a blocking issue) / ERROR (e.g. PACKAGE_NOT_FOUND).
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

  const columns: Column<ArchivePackageRow>[] = [
    { id: "period", header: "Period", sortable: true, sortValue: (p) => p.period_start, cell: (p) => <span className="font-medium text-text-primary">{periodLabel(p.period_start)}</span> },
    { id: "kind", header: "Kind", cell: (p) => <Badge variant={p.original_finalization ? "status-info" : "status-neutral"} size="sm">{p.original_finalization ? "Original" : "Adjustment"}</Badge> },
    { id: "stepup", header: "Step-up", cell: (p) => (p.step_up_auth_used ? <Badge variant="status-success" size="sm">Used</Badge> : <span className="text-text-muted">—</span>) },
    { id: "hash", header: "Hash anchor", cell: (p) => <span className="font-mono text-xs text-text-secondary">{p.bundle_hash_anchor ? `${p.bundle_hash_anchor.slice(0, 12)}…` : "—"}</span> },
    { id: "created", header: "Archived", cell: (p) => <span className="tabular-nums text-text-secondary">{new Date(p.created_at).toLocaleDateString("en-GB")}</span> },
    {
      id: "actions", header: "", align: "right",
      cell: (p) => (
        <div className="flex justify-end" onClick={(e) => e.stopPropagation()}>
          <Button variant="secondary" size="sm" leadingIcon={ShieldCheck} loading={busyId === p.id} onClick={() => verify(p)}>Verify integrity</Button>
        </div>
      ),
    },
  ];

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-text-secondary">Locked, tamper-evident packages for finalized periods. Each can be re-verified against its hash anchor.</p>
      {error ? (
        <ErrorState description={error.message} onRetry={() => mutate()} />
      ) : (
        <Table
          columns={columns}
          data={data ?? []}
          rowKey={(p) => p.id}
          loading={isLoading}
          empty={<EmptyState icon={Archive} heading="No archived periods yet" body="When a period is finalized, its locked archive package appears here for verification." />}
        />
      )}
    </div>
  );
}
