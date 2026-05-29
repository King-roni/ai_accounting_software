"use client";
import { useState } from "react";
import { Button, Drawer, Input, Select, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import { periodRange } from "@/components/transactions/transaction-helpers";
import { SCOPE_LABEL, scopeNeedsDates, type ExportCatalogueRow } from "./report-helpers";

export function RequestExportDrawer({ entry, open, onClose, onRequested }: { entry: ExportCatalogueRow | null; open: boolean; onClose: () => void; onRequested: () => void }) {
  return (
    <Drawer open={open} onClose={onClose} title={entry ? `Generate — ${entry.display_name}` : "Generate export"} width={460}>
      {open && entry && <Form entry={entry} onClose={onClose} onRequested={onRequested} />}
    </Drawer>
  );
}

function Form({ entry, onClose, onRequested }: { entry: ExportCatalogueRow; onClose: () => void; onRequested: () => void }) {
  const { user, currentBusiness, period } = useShell();
  const { toast } = useToast();
  const init = periodRange(period);
  const [format, setFormat] = useState(entry.supported_formats[0] ?? "PDF");
  const [start, setStart] = useState(init.start);
  const [end, setEnd] = useState(init.end);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const needsDates = scopeNeedsDates(entry.scope_kind);

  async function submit() {
    if (!currentBusiness) return;
    setBusy(true); setErr(null);
    const supabase = createSupabaseBrowserClient();

    // Accountant pack has a pre-flight validation gate.
    if (entry.export_kind === "accountant_export_pack") {
      const v = await supabase.rpc("validate_accountant_pack_request", {
        p_business_id: currentBusiness.id, p_organization_id: currentBusiness.organization_id,
        p_period_start: start, p_period_end: end, p_actor_user_id: user.id, p_context: {},
      });
      const vd = v.data as { decision?: string; reason?: string; reason_code?: string } | null;
      if (v.error) { setBusy(false); setErr(v.error.message); return; }
      if (vd?.decision && !["ALLOW", "OK", "VALID"].includes(vd.decision)) { setBusy(false); setErr(`Validation: ${vd.reason ?? vd.reason_code ?? vd.decision}`); return; }
    }

    const { data, error } = await supabase.rpc("request_export", {
      p_business_id: currentBusiness.id, p_organization_id: currentBusiness.organization_id,
      p_export_kind: entry.export_kind, p_format: format,
      p_period_start: needsDates ? start : null, p_period_end: needsDates ? end : null,
      p_workflow_run_id: null, p_actor_user_id: user.id, p_source_data_hash: null, p_force_regenerate: false, p_context: {},
    });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    const d = data as { decision?: string; status?: string; reason?: string; reason_code?: string } | null;
    if (d?.decision && !["QUEUED", "ALLOW", "OK", "ACCEPTED"].includes(d.decision)) { setErr(`Couldn’t queue: ${d.reason ?? d.reason_code ?? d.decision}`); return; }
    toast({ variant: "success", title: "Export queued", description: `${entry.display_name} (${format})` });
    onRequested();
    onClose();
  }

  return (
    <div className="flex flex-col gap-4">
      {err && <p className="rounded-sm border border-[var(--color-status-danger)] px-3 py-2 text-xs" style={{ color: "var(--color-status-danger)" }}>{err}</p>}
      <p className="text-sm text-text-secondary">{SCOPE_LABEL[entry.scope_kind]} export. Retention: {entry.default_retention_days === 0 ? "permanent" : `${entry.default_retention_days} days`}.</p>

      <Select label="Format" value={format} onChange={(e) => setFormat(e.target.value)}>
        {entry.supported_formats.map((f) => <option key={f} value={f}>{f}</option>)}
      </Select>

      {needsDates && (
        <div className="grid grid-cols-2 gap-3">
          <Input label="Period start" type="date" value={start} onChange={(e) => setStart(e.target.value)} />
          <Input label="Period end" type="date" value={end} onChange={(e) => setEnd(e.target.value)} />
        </div>
      )}

      <div className="sticky bottom-0 -mx-5 -mb-5 mt-1 flex items-center justify-end gap-2 border-t border-border-subtle bg-bg-overlay p-4">
        <Button variant="tertiary" onClick={onClose} disabled={busy}>Cancel</Button>
        <Button onClick={submit} loading={busy}>Generate</Button>
      </div>
    </div>
  );
}
