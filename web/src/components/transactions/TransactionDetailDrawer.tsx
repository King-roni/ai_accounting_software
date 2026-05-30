"use client";
import { Badge, Drawer } from "@/components/ui";
import { CLASSIFICATION_BADGE, DEDUP_BADGE, formatMoney, txnDescription, txnTag, type TxnRow } from "./transaction-helpers";

function Row({ label, children, mono }: { label: string; children: React.ReactNode; mono?: boolean }) {
  return (
    <div className="grid grid-cols-[8rem_1fr] gap-3 py-1.5">
      <dt className="text-xs font-medium uppercase tracking-wide text-text-muted">{label}</dt>
      <dd className={mono ? "break-all font-mono text-xs text-text-primary" : "text-sm text-text-primary"}>{children}</dd>
    </div>
  );
}

export function TransactionDetailDrawer({ row, open, onClose }: { row: TxnRow | null; open: boolean; onClose: () => void }) {
  return (
    <Drawer open={open} onClose={onClose} title="Transaction detail" width={440}>
      {row && (
        <dl className="flex flex-col divide-y divide-border-subtle">
          <Row label="Amount">
            <span
              className="font-mono font-medium tabular-nums"
              style={{ color: row.amount < 0 ? "var(--color-status-danger-text)" : "var(--color-status-success-text)" }}
            >
              {formatMoney(row.amount, row.currency)}
            </span>
          </Row>
          <Row label="Date">{row.transaction_date}</Row>
          <Row label="Direction">{row.direction}</Row>
          <Row label="Type">{row.transaction_type}</Row>
          <Row label="Description">{txnDescription(row)}</Row>
          <Row label="Counterparty">{row.counterparty_name ?? "—"}</Row>
          <Row label="Reference">{row.reference ?? "—"}</Row>
          <Row label="Tag">{txnTag(row) ?? "—"}</Row>
          <Row label="Classification">
            <Badge variant={CLASSIFICATION_BADGE[row.classification_status].variant} size="sm">
              {CLASSIFICATION_BADGE[row.classification_status].label}
            </Badge>
          </Row>
          <Row label="Dedup">
            {DEDUP_BADGE[row.dedup_status] ? (
              <Badge variant={DEDUP_BADGE[row.dedup_status]!.variant} size="sm">{DEDUP_BADGE[row.dedup_status]!.label}</Badge>
            ) : (
              <span className="text-sm text-text-secondary">New</span>
            )}
          </Row>
          <Row label="Match">{row.match_status}</Row>
          <Row label="Review">{row.review_status}</Row>
          <Row label="Fingerprint" mono>{row.transaction_fingerprint.slice(0, 32)}…</Row>
          <Row label="Row index">{row.source_row_index}</Row>
        </dl>
      )}
    </Drawer>
  );
}
