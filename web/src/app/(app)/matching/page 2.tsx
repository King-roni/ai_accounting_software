"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { ArrowRight, Building2, Check, X } from "lucide-react";
import { Badge, Button, Card, CardBody, EmptyState, ErrorState, Select } from "@/components/ui";
import { useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import {
  LEVEL_BADGE, MATCH_SELECT, money, scoreColor, SIGNAL_LABELS, STATUS_BADGE, type MatchRow,
} from "@/components/matching/match-helpers";

function SignalBars({ signals }: { signals: Record<string, number> | null }) {
  if (!signals) return null;
  const keys = Object.keys(SIGNAL_LABELS).filter((k) => k in signals);
  if (!keys.length) return null;
  return (
    <div className="grid grid-cols-2 gap-x-6 gap-y-1.5 sm:grid-cols-4">
      {keys.map((k) => {
        const v = signals[k];
        return (
          <div key={k}>
            <div className="flex justify-between text-xs text-text-muted">
              <span>{SIGNAL_LABELS[k]}</span>
              <span className="tabular-nums">{Math.round(v * 100)}%</span>
            </div>
            <div className="mt-1 h-1.5 overflow-hidden rounded-full bg-bg-raised">
              <div className="h-full rounded-full" style={{ width: `${Math.round(v * 100)}%`, background: scoreColor(v) }} />
            </div>
          </div>
        );
      })}
    </div>
  );
}

function Side({ label, title, sub, amount, tone }: { label: string; title: string; sub?: string | null; amount: string; tone?: "in" | "out" }) {
  return (
    <div className="min-w-0 rounded-md border border-border-subtle bg-bg-base p-3">
      <div className="text-xs font-medium uppercase tracking-wide text-text-muted">{label}</div>
      <div className="mt-0.5 truncate text-sm font-medium text-text-primary">{title}</div>
      {sub && <div className="truncate text-xs text-text-muted">{sub}</div>}
      <div className="mt-1 font-mono text-sm tabular-nums" style={{ color: tone === "out" ? "var(--color-status-danger-text)" : tone === "in" ? "var(--color-status-success-text)" : undefined }}>{amount}</div>
    </div>
  );
}

export default function MatchingPage() {
  const { currentBusiness, isMultiBusiness, user } = useShell();
  const { toast } = useToast();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);

  const key = currentBusiness ? ["matches", currentBusiness.id] : null;
  const { data, error, isLoading, mutate } = useSWR<MatchRow[]>(key, async () => {
    const res = await supabase.from("match_records").select(MATCH_SELECT).eq("business_id", currentBusiness!.id).order("match_score", { ascending: false });
    if (res.error) throw new Error(res.error.message);
    return (res.data ?? []) as unknown as MatchRow[];
  });

  const [filter, setFilter] = useState("NEEDS");
  const [busyId, setBusyId] = useState<string | null>(null);

  const rows = useMemo(() => {
    return (data ?? []).filter((m) => {
      if (filter === "NEEDS") return m.requires_user_confirmation;
      if (filter === "CONFIRMED") return m.match_status === "MATCHED_CONFIRMED" || m.match_status === "MATCHED_AUTO_HIGH_CONFIDENCE";
      return true;
    });
  }, [data, filter]);

  const needsCount = (data ?? []).filter((m) => m.requires_user_confirmation).length;

  async function act(m: MatchRow, kind: "confirm" | "reject") {
    setBusyId(m.id);
    const fn = kind === "confirm" ? "user_confirm_match" : "user_reject_match";
    const args = kind === "confirm"
      ? { p_match_record_id: m.id, p_actor_user_id: user.id, p_counterparty_signature: null, p_context: {} }
      : { p_match_record_id: m.id, p_actor_user_id: user.id, p_rejection_reason: "Rejected from matching review", p_context: {} };
    const { error: rpcErr } = await supabase.rpc(fn, args);
    setBusyId(null);
    if (rpcErr) { toast({ variant: "error", title: kind === "confirm" ? "Confirm failed" : "Reject failed", description: rpcErr.message }); return; }
    toast({ variant: "success", title: kind === "confirm" ? "Match confirmed" : "Match rejected" });
    mutate();
  }

  return (
    <div className="flex flex-col gap-5">
      <header className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold text-text-primary">Matching</h1>
          <p className="text-sm text-text-secondary">
            {isMultiBusiness ? "All businesses" : currentBusiness?.display_name ?? "—"}
            {needsCount > 0 && <> · <span style={{ color: "var(--color-status-warning)" }}>{needsCount} need confirmation</span></>}
          </p>
        </div>
        {currentBusiness && (
          <Select containerClassName="w-52" aria-label="Filter" value={filter} onChange={(e) => setFilter(e.target.value)}>
            <option value="NEEDS">Needs confirmation</option>
            <option value="CONFIRMED">Confirmed</option>
            <option value="ALL">All matches</option>
          </Select>
        )}
      </header>

      {!currentBusiness ? (
        <EmptyState icon={Building2} heading="Select a business" body="Choose a business to review its transaction↔document matches." />
      ) : error ? (
        <ErrorState description={error.message} onRetry={() => mutate()} />
      ) : isLoading ? (
        <div className="flex flex-col gap-3">{[0, 1, 2].map((i) => <Card key={i}><CardBody><div className="h-24" /></CardBody></Card>)}</div>
      ) : rows.length === 0 ? (
        <EmptyState heading="Nothing to review" body={filter === "NEEDS" ? "No matches are waiting for confirmation." : "No matches found for this business."} />
      ) : (
        <div className="flex flex-col gap-3">
          {rows.map((m) => {
            const t = m.transaction;
            const d = m.document;
            return (
              <Card key={m.id}>
                <CardBody className="flex flex-col gap-4 pt-5">
                  <div className="flex flex-wrap items-center gap-2">
                    <Badge variant={LEVEL_BADGE[m.match_level].variant} size="sm">{LEVEL_BADGE[m.match_level].label} match</Badge>
                    <span className="font-mono text-sm font-medium tabular-nums" style={{ color: scoreColor(m.match_score) }}>{Math.round(m.match_score * 100)}%</span>
                    <Badge variant={STATUS_BADGE[m.match_status].variant} size="sm">{STATUS_BADGE[m.match_status].label}</Badge>
                  </div>

                  <div className="grid grid-cols-1 items-stretch gap-3 sm:grid-cols-[1fr_auto_1fr]">
                    <Side label="Transaction" title={t?.normalized_description || t?.raw_description || "—"} sub={`${t?.transaction_date ?? ""}${t?.counterparty_name ? " · " + t.counterparty_name : ""}`} amount={money(t?.amount, t?.currency)} tone={(t?.amount ?? 0) < 0 ? "out" : "in"} />
                    <div className="hidden items-center justify-center sm:flex"><ArrowRight size={18} strokeWidth={1.5} className="text-text-muted" aria-hidden="true" /></div>
                    <Side label="Document" title={d?.supplier_name || d?.document_type || "—"} sub={d?.invoice_number} amount={money(d?.amount_total, d?.currency)} />
                  </div>

                  {m.match_reason_plain_language && <p className="text-sm text-text-secondary">{m.match_reason_plain_language}</p>}
                  <SignalBars signals={m.match_signals} />

                  {m.requires_user_confirmation && (
                    <div className="flex justify-end gap-2 border-t border-border-subtle pt-3">
                      <Button variant="secondary" size="sm" leadingIcon={X} loading={busyId === m.id} onClick={() => act(m, "reject")}>Reject</Button>
                      <Button size="sm" leadingIcon={Check} loading={busyId === m.id} onClick={() => act(m, "confirm")}>Confirm match</Button>
                    </div>
                  )}
                </CardBody>
              </Card>
            );
          })}
        </div>
      )}
    </div>
  );
}
