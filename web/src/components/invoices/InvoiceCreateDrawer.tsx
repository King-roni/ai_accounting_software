"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { Plus, Trash2 } from "lucide-react";
import { Button, Drawer, Input, Select, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import { formatMoney } from "@/components/transactions/transaction-helpers";
import { VAT_TREATMENT_LABEL, VAT_TREATMENT_OPTIONS, type ClientRow } from "@/components/clients/client-helpers";
import { defaultRateFor, round2 } from "./invoice-helpers";

interface LineDraft {
  description: string;
  quantity: string;
  unit_price: string;
  vat_treatment: string;
  vat_rate_pct: string;
}

const todayISO = () => new Date().toISOString().slice(0, 10);
function addDaysISO(base: string, days: number): string {
  const d = new Date(base + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}
const emptyLine = (treatment = "DOMESTIC_STANDARD"): LineDraft => ({
  description: "", quantity: "1", unit_price: "0", vat_treatment: treatment, vat_rate_pct: String(defaultRateFor(treatment)),
});

export function InvoiceCreateDrawer({
  open, onClose, onCreated,
}: {
  open: boolean;
  onClose: () => void;
  onCreated: () => void;
}) {
  return (
    <Drawer open={open} onClose={onClose} title="New invoice" width={620}>
      {open && <CreateForm onClose={onClose} onCreated={onCreated} />}
    </Drawer>
  );
}

function CreateForm({ onClose, onCreated }: { onClose: () => void; onCreated: () => void }) {
  const { user, currentBusiness } = useShell();
  const { toast } = useToast();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);

  const { data: clients } = useSWR<ClientRow[]>(
    currentBusiness ? ["clients-for-invoice", currentBusiness.id] : null,
    async () => {
      const { data, error } = await supabase.rpc("client_list", { p_business_id: currentBusiness!.id, p_include_disabled: false, p_limit: 200, p_offset: 0 });
      if (error) throw new Error(error.message);
      return ((data as { clients?: ClientRow[] })?.clients ?? []) as ClientRow[];
    },
  );

  const [clientId, setClientId] = useState("");
  const [invoiceType, setInvoiceType] = useState<"TAX" | "PRO_FORMA">("TAX");
  const [issueDate, setIssueDate] = useState(todayISO);
  const [dueDate, setDueDate] = useState(() => addDaysISO(todayISO(), 30));
  const [currency, setCurrency] = useState("EUR");
  const [perLine, setPerLine] = useState(false);
  const [defaultTreatment, setDefaultTreatment] = useState("DOMESTIC_STANDARD");
  const [defaultRate, setDefaultRate] = useState("19");
  const [lines, setLines] = useState<LineDraft[]>([emptyLine()]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  // When a client is chosen, adopt its currency + payment terms + default treatment.
  function chooseClient(id: string) {
    setClientId(id);
    const c = clients?.find((x) => x.id === id);
    if (!c) return;
    setCurrency(c.default_currency || "EUR");
    setDueDate(addDaysISO(issueDate, c.default_payment_terms_days ?? 30));
    if (c.default_vat_treatment) { setDefaultTreatment(c.default_vat_treatment); setDefaultRate(String(defaultRateFor(c.default_vat_treatment))); }
  }

  const setLine = (i: number, patch: Partial<LineDraft>) =>
    setLines((ls) => ls.map((l, idx) => (idx === i ? { ...l, ...patch } : l)));

  const computed = useMemo(() => {
    const rows = lines.map((l) => {
      const qty = parseFloat(l.quantity) || 0;
      const price = parseFloat(l.unit_price) || 0;
      const rate = perLine ? parseFloat(l.vat_rate_pct) || 0 : parseFloat(defaultRate) || 0;
      const sub = round2(qty * price);
      const lineVat = round2(sub * rate / 100);
      return { sub, vat: lineVat, total: round2(sub + lineVat), rate };
    });
    const subtotal = round2(rows.reduce((a, r) => a + r.sub, 0));
    const vat = round2(rows.reduce((a, r) => a + r.vat, 0));
    return { rows, subtotal, vat, total: round2(subtotal + vat) };
  }, [lines, perLine, defaultRate]);

  async function submit() {
    if (!currentBusiness) return;
    if (!clientId) { setErr("Pick a client."); return; }
    if (lines.length === 0 || lines.every((l) => l.description.trim() === "")) { setErr("Add at least one line with a description."); return; }
    setBusy(true); setErr(null);

    const linesPayload = lines.map((l, i) => ({
      description: l.description.trim() || `Line ${i + 1}`,
      quantity: parseFloat(l.quantity) || 0,
      unit_price: parseFloat(l.unit_price) || 0,
      currency,
      vat_treatment: perLine ? l.vat_treatment : null,
      vat_rate_pct: computed.rows[i].rate,
      vat_amount: computed.rows[i].vat,
    }));

    const { data, error } = await supabase.rpc("invoice_create_draft", {
      p_organization_id: currentBusiness.organization_id,
      p_business_id: currentBusiness.id,
      p_actor_user_id: user.id,
      p_client_id: clientId,
      p_invoice_type: invoiceType,
      p_issue_date: issueDate,
      p_supply_date: null,
      p_due_date: dueDate,
      p_currency: currency,
      p_vat_treatment_per_line: perLine,
      p_default_vat_treatment: perLine ? null : defaultTreatment,
      p_lines: linesPayload,
      p_context: {},
    });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    const d = data as { decision?: string; reason_code?: string } | null;
    if (d?.decision && d.decision !== "ALLOW") { setErr(`Couldn’t create draft: ${d.reason_code ?? "denied"}`); return; }
    toast({ variant: "success", title: "Draft invoice created" });
    onCreated();
    onClose();
  }

  return (
    <div className="flex flex-col gap-4">
      {err && <p className="rounded-sm border border-[var(--color-status-danger)] px-3 py-2 text-xs" style={{ color: "var(--color-status-danger)" }}>{err}</p>}

      <Select label="Client" required value={clientId} onChange={(e) => chooseClient(e.target.value)}>
        <option value="">Select a client…</option>
        {(clients ?? []).map((c) => <option key={c.id} value={c.id}>{c.display_name}</option>)}
      </Select>

      <div className="grid grid-cols-2 gap-3">
        <Select label="Type" value={invoiceType} onChange={(e) => setInvoiceType(e.target.value as "TAX" | "PRO_FORMA")}>
          <option value="TAX">Tax invoice</option>
          <option value="PRO_FORMA">Pro forma</option>
        </Select>
        <Input label="Currency" value={currency} onChange={(e) => setCurrency(e.target.value.toUpperCase())} maxLength={3} />
      </div>

      <div className="grid grid-cols-2 gap-3">
        <Input label="Issue date" type="date" value={issueDate} onChange={(e) => setIssueDate(e.target.value)} />
        <Input label="Due date" type="date" value={dueDate} onChange={(e) => setDueDate(e.target.value)} />
      </div>

      <label className="flex cursor-pointer items-center gap-2 text-sm text-text-primary">
        <input type="checkbox" checked={perLine} onChange={(e) => setPerLine(e.target.checked)} className="accent-[var(--color-action-primary)]" />
        Different VAT treatment per line
      </label>

      {!perLine && (
        <div className="grid grid-cols-[1fr_auto] gap-3">
          <Select label="VAT treatment" value={defaultTreatment} onChange={(e) => { setDefaultTreatment(e.target.value); setDefaultRate(String(defaultRateFor(e.target.value))); }}>
            {VAT_TREATMENT_OPTIONS.map((v) => <option key={v} value={v}>{VAT_TREATMENT_LABEL[v]}</option>)}
          </Select>
          <Input label="Rate %" type="number" value={defaultRate} onChange={(e) => setDefaultRate(e.target.value)} containerClassName="w-24" />
        </div>
      )}

      <div className="flex flex-col gap-3 border-t border-border-subtle pt-3">
        <div className="flex items-center justify-between">
          <p className="text-xs font-semibold uppercase tracking-wide text-text-muted">Lines</p>
          <Button variant="tertiary" size="sm" leadingIcon={Plus} onClick={() => setLines((ls) => [...ls, emptyLine(defaultTreatment)])}>Add line</Button>
        </div>
        {lines.map((l, i) => (
          <div key={i} className="rounded-md border border-border-subtle p-3">
            <div className="flex items-start gap-2">
              <Input containerClassName="flex-1" label={`Description ${i + 1}`} value={l.description} onChange={(e) => setLine(i, { description: e.target.value })} placeholder="Consulting services" />
              {lines.length > 1 && (
                <Button variant="ghost" size="sm" leadingIcon={Trash2} aria-label="Remove line" className="mt-6" onClick={() => setLines((ls) => ls.filter((_, idx) => idx !== i))} />
              )}
            </div>
            <div className="mt-2 grid grid-cols-3 gap-2">
              <Input label="Qty" type="number" value={l.quantity} onChange={(e) => setLine(i, { quantity: e.target.value })} />
              <Input label="Unit price" type="number" value={l.unit_price} onChange={(e) => setLine(i, { unit_price: e.target.value })} />
              {perLine ? (
                <Input label="Rate %" type="number" value={l.vat_rate_pct} onChange={(e) => setLine(i, { vat_rate_pct: e.target.value })} />
              ) : (
                <div className="flex flex-col justify-end pb-2 text-right text-sm">
                  <span className="text-xs text-text-muted">Line total</span>
                  <span className="tabular-nums text-text-primary">{formatMoney(computed.rows[i]?.total ?? 0, currency)}</span>
                </div>
              )}
            </div>
            {perLine && (
              <div className="mt-2 grid grid-cols-[1fr_auto] gap-2">
                <Select label="VAT treatment" value={l.vat_treatment} onChange={(e) => setLine(i, { vat_treatment: e.target.value, vat_rate_pct: String(defaultRateFor(e.target.value)) })}>
                  {VAT_TREATMENT_OPTIONS.map((v) => <option key={v} value={v}>{VAT_TREATMENT_LABEL[v]}</option>)}
                </Select>
                <div className="flex flex-col justify-end pb-2 text-right text-sm">
                  <span className="text-xs text-text-muted">Line total</span>
                  <span className="tabular-nums text-text-primary">{formatMoney(computed.rows[i]?.total ?? 0, currency)}</span>
                </div>
              </div>
            )}
          </div>
        ))}
      </div>

      <div className="flex flex-col gap-1 border-t border-border-subtle pt-3 text-sm">
        <div className="flex justify-between"><span className="text-text-secondary">Subtotal</span><span className="tabular-nums text-text-primary">{formatMoney(computed.subtotal, currency)}</span></div>
        <div className="flex justify-between"><span className="text-text-secondary">VAT</span><span className="tabular-nums text-text-primary">{formatMoney(computed.vat, currency)}</span></div>
        <div className="flex justify-between font-semibold"><span className="text-text-primary">Total</span><span className="tabular-nums text-text-primary">{formatMoney(computed.total, currency)}</span></div>
      </div>

      <div className="sticky bottom-0 -mx-5 -mb-5 mt-1 flex items-center justify-end gap-2 border-t border-border-subtle bg-bg-overlay p-4">
        <Button variant="tertiary" onClick={onClose} disabled={busy}>Cancel</Button>
        <Button onClick={submit} loading={busy}>Create draft</Button>
      </div>
    </div>
  );
}
