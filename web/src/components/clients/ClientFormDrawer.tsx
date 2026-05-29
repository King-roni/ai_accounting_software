"use client";
import { useState } from "react";
import { Button, Drawer, Input, Select, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import { VAT_TREATMENT_LABEL, VAT_TREATMENT_OPTIONS, type ClientRow } from "./client-helpers";

interface FormState {
  display_name: string;
  legal_name: string;
  country: string;
  vat_number: string;
  billing_address_line_1: string;
  billing_address_line_2: string;
  billing_city: string;
  billing_postal_code: string;
  billing_country: string;
  billing_email: string;
  default_currency: string;
  default_payment_terms_days: string;
  default_reverse_charge_applicable: boolean;
  default_vat_treatment: string;
}

function initialState(c: ClientRow | null): FormState {
  if (!c) {
    return {
      display_name: "", legal_name: "", country: "", vat_number: "",
      billing_address_line_1: "", billing_address_line_2: "", billing_city: "",
      billing_postal_code: "", billing_country: "", billing_email: "",
      default_currency: "EUR", default_payment_terms_days: "30",
      default_reverse_charge_applicable: false, default_vat_treatment: "DOMESTIC_STANDARD",
    };
  }
  return {
    display_name: c.display_name ?? "", legal_name: c.legal_name ?? "",
    country: c.country ?? "", vat_number: c.vat_number ?? "",
    billing_address_line_1: c.billing_address_line_1 ?? "", billing_address_line_2: c.billing_address_line_2 ?? "",
    billing_city: c.billing_city ?? "", billing_postal_code: c.billing_postal_code ?? "",
    billing_country: c.billing_country ?? "", billing_email: c.billing_email ?? "",
    default_currency: c.default_currency ?? "EUR",
    default_payment_terms_days: String(c.default_payment_terms_days ?? 30),
    default_reverse_charge_applicable: c.default_reverse_charge_applicable ?? false,
    default_vat_treatment: c.default_vat_treatment ?? "DOMESTIC_STANDARD",
  };
}

const nz = (s: string) => (s.trim() === "" ? null : s.trim());

/** Thin controller: mounts the form fresh on each open so state inits from props (no effect). */
export function ClientFormDrawer({
  open, client, onClose, onSaved,
}: {
  open: boolean;
  client: ClientRow | null;
  onClose: () => void;
  onSaved: () => void;
}) {
  return (
    <Drawer open={open} onClose={onClose} title={client ? "Edit client" : "New client"} width={520}>
      {open && <ClientForm key={client?.id ?? "new"} client={client} onClose={onClose} onSaved={onSaved} />}
    </Drawer>
  );
}

function ClientForm({ client, onClose, onSaved }: { client: ClientRow | null; onClose: () => void; onSaved: () => void }) {
  const { user, currentBusiness } = useShell();
  const { toast } = useToast();
  const [form, setForm] = useState<FormState>(() => initialState(client));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const isEdit = !!client;

  const set = <K extends keyof FormState>(k: K, v: FormState[K]) => setForm((f) => ({ ...f, [k]: v }));

  async function save() {
    if (!currentBusiness) return;
    if (form.display_name.trim() === "") { setErr("Display name is required."); return; }
    const supabase = createSupabaseBrowserClient();
    setBusy(true); setErr(null);
    const terms = parseInt(form.default_payment_terms_days, 10);

    const res = isEdit
      ? await supabase.rpc("client_update", {
          p_actor_user_id: user.id,
          p_client_id: client!.id,
          p_display_name: nz(form.display_name),
          p_legal_name: nz(form.legal_name),
          p_country: nz(form.country),
          p_vat_number_raw: nz(form.vat_number),
          p_billing_address_line_1: nz(form.billing_address_line_1),
          p_billing_address_line_2: nz(form.billing_address_line_2),
          p_billing_city: nz(form.billing_city),
          p_billing_postal_code: nz(form.billing_postal_code),
          p_billing_country: nz(form.billing_country),
          p_billing_email: nz(form.billing_email),
          p_default_currency: nz(form.default_currency),
          p_default_payment_terms_days: Number.isFinite(terms) ? terms : null,
          p_default_reverse_charge_applicable: form.default_reverse_charge_applicable,
          p_default_vat_treatment: form.default_vat_treatment || null,
          p_clear_country: form.country.trim() === "",
          p_clear_vat_number: form.vat_number.trim() === "",
          p_context: {},
        })
      : await supabase.rpc("client_create", {
          p_organization_id: currentBusiness.organization_id,
          p_business_id: currentBusiness.id,
          p_actor_user_id: user.id,
          p_display_name: form.display_name.trim(),
          p_legal_name: nz(form.legal_name),
          p_country: nz(form.country),
          p_vat_number_raw: nz(form.vat_number),
          p_billing_address_line_1: nz(form.billing_address_line_1),
          p_billing_address_line_2: nz(form.billing_address_line_2),
          p_billing_city: nz(form.billing_city),
          p_billing_postal_code: nz(form.billing_postal_code),
          p_billing_country: nz(form.billing_country),
          p_billing_email: nz(form.billing_email),
          p_default_currency: form.default_currency.trim() || "EUR",
          p_default_payment_terms_days: Number.isFinite(terms) ? terms : 30,
          p_default_reverse_charge_applicable: form.default_reverse_charge_applicable,
          p_default_vat_treatment: form.default_vat_treatment || null,
          p_context: {},
        });

    setBusy(false);
    if (res.error) { setErr(res.error.message); return; }
    const d = res.data as { decision?: string; reason?: string } | null;
    if (d?.decision && d.decision !== "ALLOW") { setErr(d.reason ?? "This action isn't allowed."); return; }
    toast({ variant: "success", title: isEdit ? "Client updated" : "Client created" });
    onSaved();
    onClose();
  }

  return (
    <div className="flex flex-col gap-4">
      {err && <p className="rounded-sm border border-[var(--color-status-danger)] px-3 py-2 text-xs" style={{ color: "var(--color-status-danger)" }}>{err}</p>}

      <Input label="Display name" required value={form.display_name} onChange={(e) => set("display_name", e.target.value)} placeholder="Aphrodite Holdings Ltd" />
      <Input label="Legal name" value={form.legal_name} onChange={(e) => set("legal_name", e.target.value)} helperText="Shown on invoices if different from the display name." />

      <div className="grid grid-cols-2 gap-3">
        <Input label="Country" value={form.country} onChange={(e) => set("country", e.target.value.toUpperCase())} maxLength={2} placeholder="CY" helperText="ISO code" />
        <Input label="VAT number" value={form.vat_number} onChange={(e) => set("vat_number", e.target.value)} placeholder="CY10259033X" />
      </div>

      <Select label="Default VAT treatment" value={form.default_vat_treatment} onChange={(e) => set("default_vat_treatment", e.target.value)}>
        {VAT_TREATMENT_OPTIONS.map((v) => <option key={v} value={v}>{VAT_TREATMENT_LABEL[v]}</option>)}
      </Select>

      <label className="flex cursor-pointer items-center gap-2 text-sm text-text-primary">
        <input type="checkbox" checked={form.default_reverse_charge_applicable} onChange={(e) => set("default_reverse_charge_applicable", e.target.checked)} className="accent-[var(--color-action-primary)]" />
        Reverse charge applies by default
      </label>

      <div className="border-t border-border-subtle pt-3">
        <p className="mb-3 text-xs font-semibold uppercase tracking-wide text-text-muted">Billing</p>
        <div className="flex flex-col gap-3">
          <Input label="Email" type="email" value={form.billing_email} onChange={(e) => set("billing_email", e.target.value)} placeholder="billing@example.com" />
          <Input label="Address line 1" value={form.billing_address_line_1} onChange={(e) => set("billing_address_line_1", e.target.value)} />
          <Input label="Address line 2" value={form.billing_address_line_2} onChange={(e) => set("billing_address_line_2", e.target.value)} />
          <div className="grid grid-cols-3 gap-3">
            <Input label="City" value={form.billing_city} onChange={(e) => set("billing_city", e.target.value)} />
            <Input label="Postal code" value={form.billing_postal_code} onChange={(e) => set("billing_postal_code", e.target.value)} />
            <Input label="Country" value={form.billing_country} onChange={(e) => set("billing_country", e.target.value.toUpperCase())} maxLength={2} placeholder="CY" />
          </div>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <Input label="Currency" value={form.default_currency} onChange={(e) => set("default_currency", e.target.value.toUpperCase())} maxLength={3} placeholder="EUR" />
        <Input label="Payment terms (days)" type="number" value={form.default_payment_terms_days} onChange={(e) => set("default_payment_terms_days", e.target.value)} />
      </div>

      <div className="sticky bottom-0 -mx-5 -mb-5 mt-1 flex items-center justify-end gap-2 border-t border-border-subtle bg-bg-overlay p-4">
        <Button variant="tertiary" onClick={onClose} disabled={busy}>Cancel</Button>
        <Button onClick={save} loading={busy}>{isEdit ? "Save changes" : "Create client"}</Button>
      </div>
    </div>
  );
}
