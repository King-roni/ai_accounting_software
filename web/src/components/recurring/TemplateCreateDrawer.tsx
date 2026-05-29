"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { Plus, Trash2 } from "lucide-react";
import { Button, Drawer, Input, Select, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import { formatMoney } from "@/components/transactions/transaction-helpers";
import { VAT_TREATMENT_LABEL, VAT_TREATMENT_OPTIONS, type ClientRow } from "@/components/clients/client-helpers";
import { defaultRateFor, round2 } from "@/components/invoices/invoice-helpers";
import { CADENCE_LABEL, CADENCE_OPTIONS } from "./recurring-helpers";

interface LineDraft { description: string; quantity: string; unit_price: string; }
const todayISO = () => new Date().toISOString().slice(0, 10);
const emptyLine = (): LineDraft => ({ description: "", quantity: "1", unit_price: "0" });

export function TemplateCreateDrawer({ open, onClose, onCreated }: { open: boolean; onClose: () => void; onCreated: () => void }) {
  return (
    <Drawer open={open} onClose={onClose} title="New recurring template" width={600}>
      {open && <Form onClose={onClose} onCreated={onCreated} />}
    </Drawer>
  );
}

function Form({ onClose, onCreated }: { onClose: () => void; onCreated: () => void }) {
  const { user, currentBusiness } = useShell();
  const { toast } = useToast();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);

  const { data: clients } = useSWR<ClientRow[]>(
    currentBusiness ? ["clients-for-template", currentBusiness.id] : null,
    async () => {
      const { data, error } = await supabase.rpc("client_list", { p_business_id: currentBusiness!.id, p_include_disabled: false, p_limit: 200, p_offset: 0 });
      if (error) throw new Error(error.message);
      return ((data as { clients?: ClientRow[] })?.clients ?? []) as ClientRow[];
    },
  );

  const [name, setName] = useState("");
  const [clientId, setClientId] = useState("");
  const [invoiceType, setInvoiceType] = useState<"TAX" | "PRO_FORMA">("TAX");
  const [currency, setCurrency] = useState("EUR");
  const [treatment, setTreatment] = useState("DOMESTIC_STANDARD");
  const [rate, setRate] = useState("19");
  const [terms, setTerms] = useState("30");
  const [cadence, setCadence] = useState("MONTHLY");
  const [anchorDay, setAnchorDay] = useState("1");
  const [startDate, setStartDate] = useState(todayISO);
  const [endDate, setEndDate] = useState("");
  const [autoSend, setAutoSend] = useState(false);
  const [autoSendEmail, setAutoSendEmail] = useState("");
  const [lines, setLines] = useState<LineDraft[]>([emptyLine()]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const setLine = (i: number, patch: Partial<LineDraft>) => setLines((ls) => ls.map((l, idx) => (idx === i ? { ...l, ...patch } : l)));

  function chooseClient(id: string) {
    setClientId(id);
    const c = clients?.find((x) => x.id === id);
    if (!c) return;
    setCurrency(c.default_currency || "EUR");
    setTerms(String(c.default_payment_terms_days ?? 30));
    if (c.default_vat_treatment) { setTreatment(c.default_vat_treatment); setRate(String(defaultRateFor(c.default_vat_treatment))); }
    if (c.billing_email) setAutoSendEmail(c.billing_email);
  }

  const computed = useMemo(() => {
    const r = parseFloat(rate) || 0;
    const rows = lines.map((l) => {
      const sub = round2((parseFloat(l.quantity) || 0) * (parseFloat(l.unit_price) || 0));
      const vat = round2(sub * r / 100);
      return { sub, vat, total: round2(sub + vat) };
    });
    const subtotal = round2(rows.reduce((a, x) => a + x.sub, 0));
    const vat = round2(rows.reduce((a, x) => a + x.vat, 0));
    return { rows, subtotal, vat, total: round2(subtotal + vat) };
  }, [lines, rate]);

  async function submit() {
    if (!currentBusiness) return;
    if (!name.trim()) { setErr("Template name is required."); return; }
    if (!clientId) { setErr("Pick a client."); return; }
    if (lines.every((l) => l.description.trim() === "")) { setErr("Add at least one line."); return; }
    setBusy(true); setErr(null);
    const r = parseFloat(rate) || 0;
    const linesPayload = lines.map((l, i) => ({
      description: l.description.trim() || `Line ${i + 1}`,
      quantity: parseFloat(l.quantity) || 0,
      unit_price: parseFloat(l.unit_price) || 0,
      currency,
      vat_treatment: null,
      vat_rate_pct: r,
      vat_amount: computed.rows[i].vat,
    }));

    const { data, error } = await supabase.rpc("recurring_template_create", {
      p_actor_user_id: user.id,
      p_organization_id: currentBusiness.organization_id,
      p_business_id: currentBusiness.id,
      p_client_id: clientId,
      p_template_name: name.trim(),
      p_invoice_type: invoiceType,
      p_currency: currency,
      p_vat_treatment_per_line: false,
      p_default_vat_treatment: treatment,
      p_payment_terms_days: parseInt(terms, 10) || 30,
      p_lines_payload: linesPayload,
      p_cadence_kind: cadence,
      p_cadence_anchor_day_of_period: parseInt(anchorDay, 10) || 1,
      p_start_date: startDate,
      p_end_date: endDate || null,
      p_auto_send: autoSend,
      p_auto_send_target_email: autoSend ? (autoSendEmail || null) : null,
      p_pro_forma_expiry_days: 30,
      p_context: {},
    });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    const d = data as { decision?: string; reason_code?: string } | null;
    if (d?.decision && d.decision !== "ALLOW") { setErr(`Couldn’t create template: ${d.reason_code ?? "denied"}`); return; }
    toast({ variant: "success", title: "Recurring template created" });
    onCreated();
    onClose();
  }

  return (
    <div className="flex flex-col gap-4">
      {err && <p className="rounded-sm border border-[var(--color-status-danger)] px-3 py-2 text-xs" style={{ color: "var(--color-status-danger)" }}>{err}</p>}

      <Input label="Template name" required value={name} onChange={(e) => setName(e.target.value)} placeholder="Monthly retainer" />
      <Select label="Client" required value={clientId} onChange={(e) => chooseClient(e.target.value)}>
        <option value="">Select a client…</option>
        {(clients ?? []).map((c) => <option key={c.id} value={c.id}>{c.display_name}</option>)}
      </Select>

      <div className="grid grid-cols-3 gap-3">
        <Select label="Type" value={invoiceType} onChange={(e) => setInvoiceType(e.target.value as "TAX" | "PRO_FORMA")}>
          <option value="TAX">Tax invoice</option>
          <option value="PRO_FORMA">Pro forma</option>
        </Select>
        <Input label="Currency" value={currency} onChange={(e) => setCurrency(e.target.value.toUpperCase())} maxLength={3} />
        <Input label="Terms (days)" type="number" value={terms} onChange={(e) => setTerms(e.target.value)} />
      </div>

      <div className="grid grid-cols-[1fr_auto] gap-3">
        <Select label="VAT treatment" value={treatment} onChange={(e) => { setTreatment(e.target.value); setRate(String(defaultRateFor(e.target.value))); }}>
          {VAT_TREATMENT_OPTIONS.map((v) => <option key={v} value={v}>{VAT_TREATMENT_LABEL[v]}</option>)}
        </Select>
        <Input label="Rate %" type="number" value={rate} onChange={(e) => setRate(e.target.value)} containerClassName="w-24" />
      </div>

      <div className="grid grid-cols-2 gap-3">
        <Select label="Cadence" value={cadence} onChange={(e) => setCadence(e.target.value)}>
          {CADENCE_OPTIONS.map((c) => <option key={c} value={c}>{CADENCE_LABEL[c]}</option>)}
        </Select>
        <Input label="Anchor day of period" type="number" value={anchorDay} onChange={(e) => setAnchorDay(e.target.value)} helperText="e.g. 1 = first of the period" />
      </div>

      <div className="grid grid-cols-2 gap-3">
        <Input label="Start date" type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)} />
        <Input label="End date (optional)" type="date" value={endDate} onChange={(e) => setEndDate(e.target.value)} />
      </div>

      <label className="flex cursor-pointer items-center gap-2 text-sm text-text-primary">
        <input type="checkbox" checked={autoSend} onChange={(e) => setAutoSend(e.target.checked)} className="accent-[var(--color-action-primary)]" />
        Auto-send each generated invoice
      </label>
      {autoSend && <Input label="Send to email" type="email" value={autoSendEmail} onChange={(e) => setAutoSendEmail(e.target.value)} placeholder="billing@example.com" />}

      <div className="flex flex-col gap-3 border-t border-border-subtle pt-3">
        <div className="flex items-center justify-between">
          <p className="text-xs font-semibold uppercase tracking-wide text-text-muted">Lines</p>
          <Button variant="tertiary" size="sm" leadingIcon={Plus} onClick={() => setLines((ls) => [...ls, emptyLine()])}>Add line</Button>
        </div>
        {lines.map((l, i) => (
          <div key={i} className="rounded-md border border-border-subtle p-3">
            <div className="flex items-start gap-2">
              <Input containerClassName="flex-1" label={`Description ${i + 1}`} value={l.description} onChange={(e) => setLine(i, { description: e.target.value })} placeholder="Monthly retainer fee" />
              {lines.length > 1 && <Button variant="ghost" size="sm" leadingIcon={Trash2} aria-label="Remove line" className="mt-6" onClick={() => setLines((ls) => ls.filter((_, idx) => idx !== i))} />}
            </div>
            <div className="mt-2 grid grid-cols-3 gap-2">
              <Input label="Qty" type="number" value={l.quantity} onChange={(e) => setLine(i, { quantity: e.target.value })} />
              <Input label="Unit price" type="number" value={l.unit_price} onChange={(e) => setLine(i, { unit_price: e.target.value })} />
              <div className="flex flex-col justify-end pb-2 text-right text-sm">
                <span className="text-xs text-text-muted">Line total</span>
                <span className="tabular-nums text-text-primary">{formatMoney(computed.rows[i]?.total ?? 0, currency)}</span>
              </div>
            </div>
          </div>
        ))}
      </div>

      <div className="flex justify-between border-t border-border-subtle pt-3 text-sm font-semibold">
        <span className="text-text-primary">Per-invoice total</span>
        <span className="tabular-nums text-text-primary">{formatMoney(computed.total, currency)}</span>
      </div>

      <div className="sticky bottom-0 -mx-5 -mb-5 mt-1 flex items-center justify-end gap-2 border-t border-border-subtle bg-bg-overlay p-4">
        <Button variant="tertiary" onClick={onClose} disabled={busy}>Cancel</Button>
        <Button onClick={submit} loading={busy}>Create template</Button>
      </div>
    </div>
  );
}
