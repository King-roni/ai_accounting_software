"use client";
import { Badge, Drawer } from "@/components/ui";
import { money, STATUS_BADGE, vatTreatment, type LedgerRow } from "./ledger-helpers";

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="grid grid-cols-[9rem_1fr] gap-3 py-1.5">
      <dt className="text-xs font-medium uppercase tracking-wide text-text-muted">{label}</dt>
      <dd className="text-sm text-text-primary">{children}</dd>
    </div>
  );
}
function Flag({ on, label }: { on: boolean; label: string }) {
  return <span className={on ? "rounded-full px-2 py-0.5 text-xs" : "hidden"} style={{ background: "color-mix(in srgb, var(--color-status-warning) 14%, transparent)", color: "var(--color-status-warning)" }}>{label}</span>;
}

export function LedgerDetailDrawer({ row, accountName, open, onClose }: { row: LedgerRow | null; accountName: (code: string | null) => string; open: boolean; onClose: () => void }) {
  return (
    <Drawer open={open} onClose={onClose} title="Ledger entry" width={460}>
      {row && (
        <div className="flex flex-col gap-4">
          <div className="flex flex-wrap items-center gap-2">
            <Badge variant={vatTreatment(row.vat_treatment).variant} size="sm">{vatTreatment(row.vat_treatment).label}</Badge>
            <Badge variant={STATUS_BADGE[row.status].variant} size="sm">{STATUS_BADGE[row.status].label}</Badge>
            <Flag on={row.reverse_charge_relevant} label="Reverse charge" />
            <Flag on={row.vies_relevant} label="VIES" />
            {row.requires_accountant_review && <Flag on label="Needs accountant review" />}
          </div>

          <dl className="flex flex-col divide-y divide-border-subtle border-y border-border-subtle">
            <Row label="Account">{accountName(row.debit_account_code) }</Row>
            <Row label="Amount"><span className="font-mono tabular-nums">{money(row.debit_amount ?? row.credit_amount, row.currency)}</span></Row>
            <Row label="Entry kind">{row.entry_kind}</Row>
            <Row label="Period">{row.entry_period}</Row>
            <Row label="Counterparty">{row.counterparty_country ?? "—"}{row.counterparty_vat_number ? ` · ${row.counterparty_vat_number}` : ""}</Row>
            <Row label="Input VAT">{row.input_vat_reclaimable_flag ? `${money(row.input_vat_reclaimable_amount, row.currency)} reclaimable` : "—"}</Row>
            <Row label="Output VAT">{row.output_vat_due_flag ? `${money(row.output_vat_due_amount, row.currency)} due` : "—"}</Row>
            <Row label="Evidence">{[row.requires_invoice && "invoice", row.requires_receipt && "receipt", row.requires_contract && "contract"].filter(Boolean).join(", ") || "—"}</Row>
          </dl>

          {row.vat_treatment_explanation && (
            <p className="rounded-md bg-bg-raised p-3 text-sm text-text-secondary">{row.vat_treatment_explanation}</p>
          )}
          {row.requires_accountant_review && row.accountant_review_reason && (
            <p className="text-sm" style={{ color: "var(--color-status-warning)" }}>⚑ {row.accountant_review_reason}</p>
          )}
        </div>
      )}
    </Drawer>
  );
}
