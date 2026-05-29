"use client";
import { Badge, Drawer } from "@/components/ui";
import { confidenceColor, docTitle, EXTRACTION_BADGE, fmtMoney, SOURCE_LABEL, type DocRow } from "./document-helpers";

function Field({ label, value, conf }: { label: string; value: React.ReactNode; conf?: number | null }) {
  return (
    <div className="grid grid-cols-[9rem_1fr] items-center gap-3 py-1.5">
      <dt className="text-xs font-medium uppercase tracking-wide text-text-muted">{label}</dt>
      <dd className="flex items-center gap-2 text-sm text-text-primary">
        <span className="flex-1">{value ?? "—"}</span>
        {conf != null && (
          <span className="flex items-center gap-1 text-xs text-text-muted tabular-nums" title={`Extraction confidence ${(conf * 100).toFixed(0)}%`}>
            <span className="inline-block h-2 w-2 rounded-full" style={{ background: confidenceColor(conf) }} aria-hidden="true" />
            {(conf * 100).toFixed(0)}%
          </span>
        )}
      </dd>
    </div>
  );
}

export function DocumentDetailDrawer({ row, open, onClose }: { row: DocRow | null; open: boolean; onClose: () => void }) {
  const c = row?.extraction_confidence_per_field ?? {};
  return (
    <Drawer open={open} onClose={onClose} title="Document & extraction" width={460}>
      {row && (
        <div className="flex flex-col gap-4">
          <div className="flex flex-wrap items-center gap-2">
            <Badge variant={EXTRACTION_BADGE[row.extraction_status].variant} size="sm">{EXTRACTION_BADGE[row.extraction_status].label}</Badge>
            <span className="rounded-full border border-border-subtle bg-bg-raised px-2 py-0.5 text-xs text-text-secondary">{row.document_type}</span>
            <span className="rounded-full border border-border-subtle bg-bg-raised px-2 py-0.5 text-xs text-text-secondary">{SOURCE_LABEL[row.source]}</span>
            {row.extraction_layer_used && <span className="rounded-full border border-border-subtle bg-bg-raised px-2 py-0.5 text-xs text-text-secondary">{row.extraction_layer_used}</span>}
          </div>

          <div>
            <h3 className="text-base font-semibold text-text-primary">{docTitle(row)}</h3>
            <p className="break-all text-xs text-text-muted">{row.original_filename ?? row.source_location ?? "—"}</p>
          </div>

          <dl className="flex flex-col divide-y divide-border-subtle border-y border-border-subtle">
            <Field label="Supplier" value={row.supplier_name} />
            <Field label="Supplier VAT" value={row.supplier_vat_number} conf={c.supplier_vat_number} />
            <Field label="Country" value={row.supplier_country} />
            <Field label="Invoice no." value={row.invoice_number} conf={c.invoice_number} />
            <Field label="Invoice date" value={row.invoice_date} conf={c.invoice_date} />
            <Field label="Due date" value={row.due_date} />
            <Field label="Subtotal" value={fmtMoney(row.amount_subtotal, row.currency)} />
            <Field label="VAT" value={`${fmtMoney(row.vat_amount, row.currency)}${row.vat_rate != null ? ` (${row.vat_rate}%)` : ""}`} />
            <Field label="Total" value={fmtMoney(row.amount_total, row.currency)} conf={c.amount_total} />
            <Field label="Payment ref" value={row.payment_reference} />
          </dl>

          {row.line_items && row.line_items.length > 0 && (
            <div>
              <p className="mb-1 text-xs font-medium uppercase tracking-wide text-text-muted">Line items</p>
              <ul className="rounded-md border border-border-subtle">
                {row.line_items.map((li, i) => (
                  <li key={i} className="flex items-center justify-between border-b border-border-subtle px-3 py-2 text-sm last:border-0">
                    <span className="text-text-primary">{li.description ?? "—"}</span>
                    <span className="font-mono tabular-nums text-text-secondary">{fmtMoney(li.amount ?? null, row.currency)}</span>
                  </li>
                ))}
              </ul>
            </div>
          )}

          {row.discovery_reason && (
            <p className="text-xs text-text-muted"><span className="font-medium">Discovery:</span> {row.discovery_reason}</p>
          )}
        </div>
      )}
    </Drawer>
  );
}
