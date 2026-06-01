"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { Building2, CalendarPlus, ChevronRight } from "lucide-react";
import { Badge, Button, Card, CardBody, Drawer, EmptyState, ErrorState, Input, Select, Skeleton, Tabs, Textarea, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import { useIsMobile } from "@/components/shell/use-is-mobile";
import { RunDetailDrawer } from "@/components/runs/RunDetailDrawer";
import { ArchivePanel } from "@/components/runs/ArchivePanel";
import { RUN_COLUMNS, WORKFLOW_TYPE_LABEL, periodLabel, phaseProgress, runIsActive, runStatusBadge, type RunRow } from "@/components/runs/run-helpers";

interface PeriodGroup { key: string; periodStart: string; out: RunRow | null; in: RunRow | null; adjustments: RunRow[] }

export default function PeriodsPage() {
  const { currentBusiness, isMultiBusiness } = useShell();
  const isMobile = useIsMobile();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [startOpen, setStartOpen] = useState(false);
  const [detailId, setDetailId] = useState<string | null>(null);
  const [tab, setTab] = useState("periods");

  const key = currentBusiness ? ["runs", currentBusiness.id] : null;
  const { data, error, isLoading, mutate } = useSWR<RunRow[]>(key, async () => {
    const { data, error } = await supabase.from("workflow_runs").select(RUN_COLUMNS).eq("business_id", currentBusiness!.id).order("period_start", { ascending: false });
    if (error) throw new Error(error.message);
    return (data ?? []) as unknown as RunRow[];
  }, {
    // Poll only while a run is still in-flight so finished periods don't refetch.
    refreshInterval: (latest) => (latest ?? []).some((r) => runIsActive(r.status)) ? 8000 : 0,
  });

  const groups = useMemo<PeriodGroup[]>(() => {
    const m = new Map<string, PeriodGroup>();
    for (const r of data ?? []) {
      const k = r.period_start;
      if (!m.has(k)) m.set(k, { key: k, periodStart: r.period_start, out: null, in: null, adjustments: [] });
      const g = m.get(k)!;
      if (r.workflow_type === "OUT_MONTHLY") g.out = r;
      else if (r.workflow_type === "IN_MONTHLY") g.in = r;
      else g.adjustments.push(r); // OUT_ADJUSTMENT / IN_ADJUSTMENT
    }
    for (const g of m.values()) g.adjustments.sort((a, b) => a.created_at.localeCompare(b.created_at));
    return [...m.values()].sort((a, b) => b.periodStart.localeCompare(a.periodStart));
  }, [data]);

  return (
    <div className="flex flex-col gap-5">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold text-text-primary">Periods</h1>
          <p className="text-sm text-text-secondary">{isMultiBusiness ? "All businesses" : currentBusiness?.display_name ?? "—"} · {groups.length} period{groups.length === 1 ? "" : "s"}</p>
        </div>
        {currentBusiness && !isMultiBusiness && !isMobile && <Button leadingIcon={CalendarPlus} onClick={() => setStartOpen(true)}>Start a period</Button>}
      </header>

      {!currentBusiness ? (
        <EmptyState icon={Building2} heading="Select a business" body="Choose a business to see its monthly workflow runs." />
      ) : isMultiBusiness ? (
        <EmptyState icon={Building2} heading="Pick a single business" body="Workflow runs are per-business. Switch from “All businesses” to a specific one." />
      ) : (
        <Tabs
          value={tab}
          onValueChange={setTab}
          tabs={[
            {
              id: "periods", label: "Periods", content: (
                error ? (
                  <ErrorState description={error.message} onRetry={() => mutate()} />
                ) : isLoading ? (
                  <div className="flex flex-col gap-3">{[0, 1].map((i) => <Card key={i}><CardBody className="pt-5"><Skeleton height={64} /></CardBody></Card>)}</div>
                ) : groups.length === 0 ? (
                  <EmptyState icon={CalendarPlus} heading="No periods run yet" body="Start a monthly period to run the outgoing (expenses) and incoming (income) workflows." action={<Button leadingIcon={CalendarPlus} onClick={() => setStartOpen(true)}>Start a period</Button>} />
                ) : (
                  <div className="flex flex-col gap-3">
                    {groups.map((g) => (
                      <Card key={g.key}>
                        <CardBody className="flex flex-col gap-3 pt-5">
                          <h2 className="text-lg font-semibold text-text-primary">{periodLabel(g.periodStart)}</h2>
                          <div className="flex flex-col gap-2">
                            <RunRowItem side="OUT" title="Outgoing — expenses" descriptor="Expenses & payables" run={g.out} onOpen={setDetailId} />
                            <RunRowItem side="IN" title="Incoming — income" descriptor="Income & receivables" run={g.in} onOpen={setDetailId} />
                          </div>
                          {g.adjustments.length > 0 && (
                            <div className="flex flex-col gap-1.5 border-t border-border-subtle pt-3">
                              <p className="text-xs font-semibold uppercase tracking-wide text-text-muted">Adjustments</p>
                              {g.adjustments.map((a) => <AdjustmentRowItem key={a.id} run={a} onOpen={setDetailId} />)}
                            </div>
                          )}
                        </CardBody>
                      </Card>
                    ))}
                  </div>
                )
              ),
            },
            { id: "archive", label: "Archive", content: <ArchivePanel /> },
          ]}
        />
      )}

      <StartPeriodDrawer open={startOpen} onClose={() => setStartOpen(false)} onStarted={() => mutate()} />
      <RunDetailDrawer runId={detailId} open={!!detailId} onClose={() => setDetailId(null)} onChanged={() => mutate()} />
    </div>
  );
}

function RunRowItem({ side, title, descriptor, run, onOpen }: { side: "OUT" | "IN"; title: string; descriptor: string; run: RunRow | null; onOpen: (id: string) => void }) {
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  // Compute progress against required phases — identical math to the run drawer
  // (phaseProgress) so the same run never shows two different totals.
  const { data: prog } = useSWR(run ? ["run-phase-progress", run.id, run.workflow_type] : null, async () => {
    const [defsRes, statesRes] = await Promise.all([
      supabase.from("workflow_phase_definitions").select("phase_name, optional").eq("workflow_type", run!.workflow_type),
      supabase.from("workflow_phase_states").select("phase_name, status").eq("workflow_run_id", run!.id),
    ]);
    return phaseProgress(defsRes.data ?? [], statesRes.data ?? []);
  });

  const tag = (
    <span
      className="flex h-6 shrink-0 items-center rounded-md px-2 text-[11px] font-bold"
      style={side === "OUT"
        ? { background: "color-mix(in srgb, var(--color-status-danger) 12%, transparent)", color: "var(--color-status-danger-text)" }
        : { background: "color-mix(in srgb, var(--color-status-success) 12%, transparent)", color: "var(--color-status-success-text)" }}
    >{side}</span>
  );

  if (!run) return (
    <div className="flex items-center gap-3 rounded-lg border border-dashed border-border-default p-3 text-text-muted">
      {tag}<span className="text-sm">{title}: not created</span>
    </div>
  );

  const b = runStatusBadge(run.status);
  const done = prog?.completed ?? 0;
  const total = prog?.total ?? 0;
  const pct = prog?.pct ?? 0;

  return (
    <button type="button" onClick={() => onOpen(run.id)} className="flex items-center gap-3 rounded-lg border border-border-subtle bg-surface-default p-3 text-left transition-colors hover:border-border-default hover:bg-bg-raised">
      {tag}
      <div className="min-w-0 flex-1">
        <p className="text-sm font-semibold text-text-primary">{title}</p>
        <p className="mt-0.5 text-xs text-text-muted">{descriptor}</p>
      </div>
      <div className="hidden w-28 shrink-0 sm:block">
        <div className="h-1.5 overflow-hidden rounded-full bg-border-subtle"><span className="block h-full rounded-full bg-action-primary transition-[width]" style={{ width: `${pct}%` }} /></div>
        <p className="mt-1 text-right font-mono text-[10.5px] text-text-muted">{prog ? `${done}/${total} phases` : "…"}</p>
      </div>
      <Badge variant={b.variant} size="sm">{b.label}</Badge>
      <ChevronRight size={16} className="shrink-0 text-text-muted" aria-hidden="true" />
    </button>
  );
}

function AdjustmentRowItem({ run, onOpen }: { run: RunRow; onOpen: (id: string) => void }) {
  const b = runStatusBadge(run.status);
  const side = run.workflow_type.startsWith("OUT") ? "OUT" : "IN";
  return (
    <button type="button" onClick={() => onOpen(run.id)} className="flex items-center gap-3 rounded-lg border border-border-subtle bg-surface-default px-3 py-2 text-left transition-colors hover:border-border-default hover:bg-bg-raised">
      <span className="flex h-5 shrink-0 items-center rounded-md bg-bg-raised px-1.5 text-[10px] font-bold text-text-muted">{side}</span>
      <span className="min-w-0 flex-1 truncate text-sm text-text-primary">{WORKFLOW_TYPE_LABEL[run.workflow_type]}</span>
      <span className="hidden text-xs text-text-muted sm:block">{new Date(run.created_at).toLocaleDateString("en-GB")}</span>
      <Badge variant={b.variant} size="sm">{b.label}</Badge>
      <ChevronRight size={16} className="shrink-0 text-text-muted" aria-hidden="true" />
    </button>
  );
}

function StartPeriodDrawer({ open, onClose, onStarted }: { open: boolean; onClose: () => void; onStarted: () => void }) {
  const { period } = useShell();
  return (
    <Drawer open={open} onClose={onClose} title="Start a period" width={460}>
      {open && <StartForm initialYear={period.year} initialMonth={period.month} onClose={onClose} onStarted={onStarted} />}
    </Drawer>
  );
}

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

function StartForm({ initialYear, initialMonth, onClose, onStarted }: { initialYear: number; initialMonth: number; onClose: () => void; onStarted: () => void }) {
  const { user, currentBusiness } = useShell();
  const { toast } = useToast();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [year, setYear] = useState(String(initialYear));
  const [month, setMonth] = useState(String(initialMonth));
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function submit() {
    if (!currentBusiness) return;
    const y = parseInt(year, 10), m = parseInt(month, 10);
    const lastDay = new Date(Date.UTC(y, m, 0)).getUTCDate();
    const periodStart = `${y}-${String(m).padStart(2, "0")}-01T00:00:00Z`;
    const periodEnd = `${y}-${String(m).padStart(2, "0")}-${String(lastDay).padStart(2, "0")}T23:59:59Z`;
    setBusy(true); setErr(null);
    const { data, error } = await supabase.rpc("out_workflow_start_run_manually", {
      p_organization_id: currentBusiness.organization_id,
      p_business_id: currentBusiness.id,
      p_period_start: periodStart,
      p_period_end: periodEnd,
      p_started_by: user.id,
      p_manual_trigger_note: note.trim() || null,
      p_context: {},
    });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    const d = data as { decision?: string; reason?: string; reason_code?: string } | null;
    if (d?.decision && d.decision !== "STARTED") { setErr(`Couldn’t start: ${d.reason ?? d.reason_code ?? d.decision}`); return; }
    toast({ variant: "success", title: "Period started", description: "Outgoing + incoming runs created." });
    onStarted();
    onClose();
  }

  return (
    <div className="flex flex-col gap-4">
      {err && <p className="rounded-sm border border-[var(--color-status-danger)] px-3 py-2 text-xs" style={{ color: "var(--color-status-danger)" }}>{err}</p>}
      <p className="text-sm text-text-secondary">Starting a period creates the paired <strong>outgoing</strong> (expenses) and <strong>incoming</strong> (income) monthly workflow runs.</p>
      <div className="grid grid-cols-2 gap-3">
        <Select label="Month" value={month} onChange={(e) => setMonth(e.target.value)}>
          {MONTHS.map((name, i) => <option key={name} value={i + 1}>{name}</option>)}
        </Select>
        <Input label="Year" type="number" value={year} onChange={(e) => setYear(e.target.value)} />
      </div>
      <Textarea label="Trigger note (optional)" value={note} onChange={(e) => setNote(e.target.value)} rows={2} placeholder="Why are you starting this period manually?" />
      <div className="sticky bottom-0 -mx-5 -mb-5 mt-1 flex items-center justify-end gap-2 border-t border-border-subtle bg-bg-overlay p-4">
        <Button variant="tertiary" onClick={onClose} disabled={busy}>Cancel</Button>
        <Button onClick={submit} loading={busy}>Start period</Button>
      </div>
    </div>
  );
}
