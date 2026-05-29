"use client";
import { useMemo, useState } from "react";
import useSWR from "swr";
import { FileText, Hash, Send, FileX, ArrowRightLeft, ReceiptText } from "lucide-react";
import { Badge, Button, Drawer, Input, Textarea, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import { formatMoney } from "@/components/transactions/transaction-helpers";
import { vatTreatmentLabel } from "@/components/clients/client-helpers";
import {
  INVOICE_COLUMNS, INVOICE_TYPE_LABEL, lifecycleBadge, type InvoiceLineRow, type InvoiceRow,
} from "./invoice-helpers";

type Decision = { decision?: string; reason_code?: string; reason?: string } | null;
function denied(d: Decision): string | null {
  if (d && d.decision && d.decision !== "ALLOW") return d.reason_code ?? d.reason ?? "Not allowed.";
  return null;
}

export function InvoiceDetailDrawer({
  invoiceId, open, onClose, onChanged,
}: {
  invoiceId: string | null;
  open: boolean;
  onClose: () => void;
  onChanged: () => void;
}) {
  return (
    <Drawer open={open} onClose={onClose} title="Invoice" width={600}>
      {open && invoiceId && <DetailBody invoiceId={invoiceId} onClose={onClose} onChanged={onChanged} />}
    </Drawer>
  );
}

function DetailBody({ invoiceId, onClose, onChanged }: { invoiceId: string; onClose: () => void; onChanged: () => void }) {
  const { user, currentBusiness } = useShell();
  const { toast } = useToast();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [busy, setBusy] = useState<string | null>(null);
  const [cnOpen, setCnOpen] = useState(false);
  const [cnAmount, setCnAmount] = useState("");
  const [cnReason, setCnReason] = useState("");
  const [woReason, setWoReason] = useState("");
  const [woOpen, setWoOpen] = useState(false);
  const [pdfPayload, setPdfPayload] = useState<unknown>(null);

  const { data: inv, mutate: mutateInv } = useSWR<InvoiceRow | null>(["invoice", invoiceId], async () => {
    const { data, error } = await supabase.from("invoices").select(INVOICE_COLUMNS).eq("id", invoiceId).single();
    if (error) throw new Error(error.message);
    return data as unknown as InvoiceRow;
  });
  const { data: lines } = useSWR<InvoiceLineRow[]>(["invoice-lines", invoiceId], async () => {
    const { data, error } = await supabase.from("invoice_lines").select("*").eq("invoice_id", invoiceId).order("line_number");
    if (error) throw new Error(error.message);
    return (data ?? []) as InvoiceLineRow[];
  });

  function refresh() { mutateInv(); onChanged(); }
  // Supabase's rpc() returns a thenable builder (PromiseLike), not a true Promise.
  async function run(label: string, fn: () => PromiseLike<{ data: unknown; error: { message: string } | null }>, okMsg: string) {
    setBusy(label);
    const { data, error } = await fn();
    setBusy(null);
    if (error) { toast({ variant: "error", title: "Action failed", description: error.message }); return false; }
    const d = denied(data as Decision);
    if (d) { toast({ variant: "warning", title: "Not allowed", description: d }); return false; }
    toast({ variant: "success", title: okMsg });
    refresh();
    return true;
  }

  if (!inv) return <p className="text-sm text-text-muted">Loading…</p>;
  const b = lifecycleBadge(inv.lifecycle_status);
  const cur = inv.currency;
  const isDraft = inv.lifecycle_status === "DRAFT";
  const isProForma = inv.invoice_type === "PRO_FORMA";
  const canCredit = ["SENT", "PAYMENT_EXPECTED", "PARTIALLY_PAID", "PAID", "OVERPAID", "FINALIZED"].includes(inv.lifecycle_status) && !isProForma;

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant={b.variant}>{b.label}</Badge>
        <Badge variant="status-neutral" size="sm">{INVOICE_TYPE_LABEL[inv.invoice_type]}</Badge>
        <span className="font-mono text-sm text-text-primary">{inv.invoice_number ?? "— (no number yet)"}</span>
      </div>

      <div className="grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
        <Field label="Client" value={inv.client?.display_name ?? "—"} />
        <Field label="Issue date" value={inv.issue_date} />
        <Field label="Due date" value={inv.due_date} />
        <Field label="VAT mode" value={inv.vat_treatment_per_line ? "Per line" : vatTreatmentLabel(inv.default_vat_treatment)} />
      </div>

      <div className="overflow-hidden rounded-md border border-border-subtle">
        <table className="w-full text-sm">
          <thead className="bg-bg-raised text-left text-text-secondary">
            <tr><th className="px-3 py-2 font-medium">Description</th><th className="px-3 py-2 text-right font-medium">Qty</th><th className="px-3 py-2 text-right font-medium">Unit</th><th className="px-3 py-2 text-right font-medium">VAT</th><th className="px-3 py-2 text-right font-medium">Total</th></tr>
          </thead>
          <tbody>
            {(lines ?? []).map((l) => (
              <tr key={l.id} className="border-t border-border-subtle">
                <td className="px-3 py-2 text-text-primary">{l.description}{l.vat_treatment && <span className="block text-xs text-text-muted">{vatTreatmentLabel(l.vat_treatment)}</span>}</td>
                <td className="px-3 py-2 text-right tabular-nums">{l.quantity}</td>
                <td className="px-3 py-2 text-right tabular-nums">{formatMoney(l.unit_price, cur)}</td>
                <td className="px-3 py-2 text-right tabular-nums">{formatMoney(l.vat_amount ?? 0, cur)}</td>
                <td className="px-3 py-2 text-right tabular-nums text-text-primary">{formatMoney(l.total_amount, cur)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="flex flex-col gap-1 text-sm">
        <div className="flex justify-between"><span className="text-text-secondary">Subtotal</span><span className="tabular-nums">{formatMoney(inv.subtotal_amount, cur)}</span></div>
        <div className="flex justify-between"><span className="text-text-secondary">VAT</span><span className="tabular-nums">{formatMoney(inv.vat_amount, cur)}</span></div>
        <div className="flex justify-between font-semibold"><span className="text-text-primary">Total</span><span className="tabular-nums text-text-primary">{formatMoney(inv.total_amount, cur)}</span></div>
      </div>

      {inv.written_off_reason && <p className="rounded-sm bg-bg-raised px-3 py-2 text-xs text-text-secondary">Written off: {inv.written_off_reason}</p>}

      {/* Actions */}
      <div className="flex flex-wrap gap-2 border-t border-border-subtle pt-4">
        {isDraft && !inv.invoice_number && (
          <Button size="sm" variant="secondary" leadingIcon={Hash} loading={busy === "num"} onClick={() => run("num", () => supabase.rpc("allocate_invoice_number", { p_invoice_id: inv.id, p_context: {} }), "Invoice number allocated")}>Allocate number</Button>
        )}
        {(isDraft || inv.lifecycle_status === "DRAFT") && (
          <Button size="sm" leadingIcon={Send} loading={busy === "sent"} onClick={() => run("sent", () => supabase.rpc("invoice_mark_sent", { p_actor_user_id: user.id, p_invoice_id: inv.id, p_sent_at: null, p_context: {} }), "Marked as sent")}>Mark sent</Button>
        )}
        {isProForma && (
          <Button size="sm" variant="secondary" leadingIcon={ArrowRightLeft} loading={busy === "conv"} onClick={() => run("conv", () => supabase.rpc("invoice_convert_pro_forma_to_tax_invoice", { p_actor_user_id: user.id, p_pro_forma_invoice_id: inv.id, p_issue_date: null, p_context: {} }), "Converted to tax invoice")}>Convert to tax invoice</Button>
        )}
        <Button size="sm" variant="secondary" leadingIcon={FileText} loading={busy === "pdf"} onClick={async () => {
          setBusy("pdf");
          const { data, error } = await supabase.rpc("invoice_compute_pdf_render_payload", { p_actor_user_id: user.id, p_invoice_id: inv.id, p_render_kind: isDraft ? "DRAFT_PREVIEW" : "FINAL", p_language_code: "en", p_renderer_version: "v1", p_context: {} });
          setBusy(null);
          if (error) { toast({ variant: "error", title: "Couldn’t build PDF data", description: error.message }); return; }
          const d = denied(data as Decision);
          if (d) { toast({ variant: "warning", title: "Not allowed", description: d }); return; }
          setPdfPayload(data);
        }}>Preview PDF data</Button>
        {!isDraft && !["WRITTEN_OFF", "PAID", "CREDITED"].includes(inv.lifecycle_status) && (
          <Button size="sm" variant="ghost" leadingIcon={FileX} onClick={() => setWoOpen((v) => !v)}>Write off</Button>
        )}
        {canCredit && (
          <Button size="sm" variant="ghost" leadingIcon={ReceiptText} onClick={() => { setCnOpen((v) => !v); setCnAmount(String(inv.total_amount)); }}>Issue credit note</Button>
        )}
      </div>

      {woOpen && (
        <div className="flex flex-col gap-2 rounded-md border border-border-subtle p-3">
          <Textarea label="Write-off reason" value={woReason} onChange={(e) => setWoReason(e.target.value)} rows={2} />
          <div className="flex justify-end">
            <Button size="sm" variant="danger" loading={busy === "wo"} disabled={!woReason.trim()} onClick={async () => { if (await run("wo", () => supabase.rpc("invoice_mark_written_off", { p_actor_user_id: user.id, p_invoice_id: inv.id, p_reason: woReason.trim(), p_written_off_at: null, p_context: {} }), "Invoice written off")) setWoOpen(false); }}>Confirm write-off</Button>
          </div>
        </div>
      )}

      {cnOpen && (
        <div className="flex flex-col gap-2 rounded-md border border-border-subtle p-3">
          <div className="grid grid-cols-2 gap-2">
            <Input label={`Amount (${cur})`} type="number" value={cnAmount} onChange={(e) => setCnAmount(e.target.value)} />
          </div>
          <Textarea label="Reason" value={cnReason} onChange={(e) => setCnReason(e.target.value)} rows={2} />
          <div className="flex justify-end">
            <Button size="sm" loading={busy === "cn"} disabled={!cnReason.trim() || !(parseFloat(cnAmount) > 0)} onClick={async () => {
              if (!currentBusiness) return;
              if (await run("cn", () => supabase.rpc("credit_note_issue", { p_organization_id: currentBusiness.organization_id, p_business_id: currentBusiness.id, p_actor_user_id: user.id, p_against_invoice_id: inv.id, p_amount: parseFloat(cnAmount), p_reason: cnReason.trim(), p_issue_date: null, p_context: {} }), "Credit note issued")) setCnOpen(false);
            }}>Issue credit note</Button>
          </div>
        </div>
      )}

      {pdfPayload != null && (
        <div className="flex flex-col gap-1 rounded-md border border-border-subtle p-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-text-muted">PDF render payload</p>
          <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-words text-xs text-text-secondary">{JSON.stringify(pdfPayload, null, 2)}</pre>
        </div>
      )}

      <div className="sticky bottom-0 -mx-5 -mb-5 mt-1 flex items-center justify-end gap-2 border-t border-border-subtle bg-bg-overlay p-4">
        <Button variant="tertiary" onClick={onClose}>Close</Button>
      </div>
    </div>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-xs text-text-muted">{label}</p>
      <p className="text-text-primary">{value}</p>
    </div>
  );
}
