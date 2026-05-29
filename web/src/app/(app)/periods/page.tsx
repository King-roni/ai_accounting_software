"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { ArrowDownLeft, ArrowUpRight, Building2, CalendarPlus, ChevronRight } from "lucide-react";
import { Badge, Button, Card, CardBody, Drawer, EmptyState, ErrorState, Input, Select, Skeleton, Tabs, Textarea, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import { RunDetailDrawer } from "@/components/runs/RunDetailDrawer";
import { ArchivePanel } from "@/components/runs/ArchivePanel";
import { RUN_COLUMNS, periodLabel, runStatusBadge, type RunRow } from "@/components/runs/run-helpers";

interface PeriodGroup { key: string; periodStart: string; out: RunRow | null; in: RunRow | null }

export default function PeriodsPage() {
  const { currentBusiness, isMultiBusiness } = useShell();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [startOpen, setStartOpen] = useState(false);
  const [detailId, setDetailId] = useState<string | null>(null);
  const [tab, setTab] = useState("periods");

  const key = currentBusiness ? ["runs", currentBusiness.id] : null;
  const { data, error, isLoading, mutate } = useSWR<RunRow[]>(key, async () => {
    const { data, error } = await supabase.from("workflow_runs").select(RUN_COLUMNS).eq("business_id", currentBusiness!.id).order("period_start", { ascending: false });
    if (error) throw new Error(error.message);
    return (data ?? []) as unknown as RunRow[];
  });

  const groups = useMemo<PeriodGroup[]>(() => {
    const m = new Map<string, PeriodGroup>();
    for (const r of data ?? []) {
      const k = r.period_start;
      if (!m.has(k)) m.set(k, { key: k, periodStart: r.period_start, out: null, in: null });
      const g = m.get(k)!;
      if (r.workflow_type.startsWith("OUT")) g.out = r;
      else g.in = r;
    }
    return [...m.values()].sort((a, b) => b.periodStart.localeCompare(a.periodStart));
  }, [data]);

  return (
    <div className="flex flex-col gap-5">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold text-text-primary">Periods</h1>
          <p className="text-sm text-text-secondary">{isMultiBusiness ? "All businesses" : currentBusiness?.display_name ?? "—"} · {groups.length} period{groups.length === 1 ? "" : "s"}</p>
        </div>
        {currentBusiness && !isMultiBusiness && <Button leadingIcon={CalendarPlus} onClick={() => setStartOpen(true)}>Start a period</Button>}
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
                          <div className="grid gap-2 sm:grid-cols-2">
                            <RunRowItem icon={ArrowUpRight} title="Outgoing (expenses)" run={g.out} onOpen={setDetailId} />
                            <RunRowItem icon={ArrowDownLeft} title="Incoming (income)" run={g.in} onOpen={setDetailId} />
                          </div>
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

function RunRowItem({ icon: Icon, title, run, onOpen }: { icon: typeof ArrowUpRight; title: string; run: RunRow | null; onOpen: (id: string) => void }) {
  if (!run) return (
    <div className="flex items-center gap-3 rounded-md border border-dashed border-border-subtle p-3 text-text-muted">
      <Icon size={18} aria-hidden="true" /><span className="text-sm">{title}: not created</span>
    </div>
  );
  const b = runStatusBadge(run.status);
  return (
    <button type="button" onClick={() => onOpen(run.id)} className="flex items-center gap-3 rounded-md border border-border-subtle p-3 text-left hover:bg-bg-raised">
      <Icon size={18} className="shrink-0 text-text-secondary" aria-hidden="true" />
      <div className="min-w-0 flex-1">
        <p className="text-sm font-medium text-text-primary">{title}</p>
        <Badge variant={b.variant} size="sm">{b.label}</Badge>
      </div>
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
