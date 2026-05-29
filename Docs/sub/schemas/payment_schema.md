# Schema: payments

**Block:** in_workflow
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

The `payments` table records all payment transactions received against invoices. Each row
represents a single payment event — whether a full settlement, a partial payment, an automatic
Stripe payment, or a manually recorded bank transfer, cash, or cheque payment.

Payments are the source of truth for invoice settlement status. The invoice `amount_paid` and
`remaining_balance` columns are derived from the sum of associated payment records; the
canonical balance check always queries `payments` rather than trusting the invoice aggregate
columns alone.

A payment is linked to a double-entry ledger entry via `ledger_entry_id`. The ledger entry posts
DEBIT to the bank account and CREDIT to accounts receivable (account 1100). Reconciliation of
payments against bank statement rows is tracked in the ledger reconciliation flow.

---

## DDL

```sql
-- -------------------------------------------------------------------------
-- payments
-- -------------------------------------------------------------------------

CREATE TABLE payments (
  id                        UUID          NOT NULL DEFAULT gen_uuid_v7(),
  invoice_id                UUID          NOT NULL,
  business_id               UUID          NOT NULL,

  -- Amount in the received currency
  amount                    DECIMAL(15,2) NOT NULL CHECK (amount > 0),
  currency                  CHAR(3)       NOT NULL,  -- ISO 4217

  -- EUR equivalent (= amount if currency = 'EUR')
  amount_eur                DECIMAL(15,2) NOT NULL CHECK (amount_eur > 0),

  -- ECB rate used for FX conversion; 1.00000000 if currency = 'EUR'
  fx_rate                   DECIMAL(18,8) NOT NULL DEFAULT 1.00000000,

  -- Date the payment was received (not the recording date)
  payment_date              DATE          NOT NULL,

  -- Channel through which the payment was received
  payment_method            TEXT          NOT NULL,

  -- Stripe payment intent ID; populated for Stripe-originated payments only
  stripe_payment_intent_id  TEXT          UNIQUE,

  -- Bank reference, cheque number, or other external identifier
  reference                 TEXT,

  -- Accountant notes; not visible to the client
  notes                     TEXT,

  -- User who recorded this payment
  recorded_by               UUID          NOT NULL,

  -- Ledger entry created for this payment (DEBIT bank / CREDIT AR)
  ledger_entry_id           UUID,

  created_at                TIMESTAMPTZ   NOT NULL DEFAULT now(),

  PRIMARY KEY (id),

  FOREIGN KEY (invoice_id)
    REFERENCES invoices(id)
    ON DELETE RESTRICT,

  FOREIGN KEY (business_id)
    REFERENCES business_entities(id)
    ON DELETE RESTRICT,

  FOREIGN KEY (recorded_by)
    REFERENCES auth.users(id),

  FOREIGN KEY (ledger_entry_id)
    REFERENCES ledger_entries(id)
);

-- payment_method enum values (enforced at application layer):
--   'BANK_TRANSFER', 'STRIPE', 'CASH', 'CHEQUE', 'OTHER'

COMMENT ON TABLE payments IS
  'Records payment events received against invoices. '
  'Each row is one payment. Stripe payments are created by webhook handler; '
  'all other methods are created via in_workflow.record_payment.';

COMMENT ON COLUMN payments.amount_eur IS
  'EUR equivalent of amount, computed using ECB rate at payment_date. '
  'Equal to amount when currency = EUR.';

COMMENT ON COLUMN payments.fx_rate IS
  'ECB exchange rate used: amount * fx_rate = amount_eur. '
  'Stored for auditability. 1.00000000 for EUR payments.';

COMMENT ON COLUMN payments.stripe_payment_intent_id IS
  'Populated only for payments originating from Stripe. '
  'Used to prevent duplicate webhook processing (UNIQUE constraint).';

COMMENT ON COLUMN payments.ledger_entry_id IS
  'FK to the double-entry ledger post for this payment. '
  'NULL briefly during payment creation; set in the same transaction as INSERT.';
```

---

## Indexes

```sql
-- Fast lookup of all payments on a given invoice
CREATE INDEX idx_payments_invoice_id
  ON payments(invoice_id);

-- Business-scoped payment queries filtered by date (common in reconciliation and reporting)
CREATE INDEX idx_payments_business_id_payment_date
  ON payments(business_id, payment_date);

-- Deduplication guard for Stripe webhook replays
CREATE UNIQUE INDEX idx_payments_stripe_payment_intent_id
  ON payments(stripe_payment_intent_id)
  WHERE stripe_payment_intent_id IS NOT NULL;
```

---

## Row-Level Security

```sql
-- Business members can read their own payments
CREATE POLICY payments_select_business_members
  ON payments FOR SELECT
  USING (
    business_id IN (
      SELECT business_id
      FROM org_members
      WHERE user_id = auth.uid()
        AND status = 'ACTIVE'
    )
  );

-- Only service role and accountants with WRITE permission can insert payments
CREATE POLICY payments_insert_service_or_accountant
  ON payments FOR INSERT
  WITH CHECK (
    auth.role() = 'service_role'
    OR (
      business_id IN (
        SELECT business_id
        FROM org_members
        WHERE user_id = auth.uid()
          AND role IN ('ACCOUNTANT', 'ADMIN')
          AND status = 'ACTIVE'
      )
    )
  );

-- Payments are immutable once created — no UPDATE or DELETE via RLS
-- Corrections are handled via credit notes or reversal entries, not row edits.
CREATE POLICY payments_no_update ON payments FOR UPDATE USING (false);
CREATE POLICY payments_no_delete ON payments FOR DELETE USING (false);

ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
```

---

## Data Zone

**Zone:** Operational

**Retention:** 7 years from `created_at` per `data_retention_policy.md` and Cyprus legal
requirements for accounting records (Article 141 of the Companies Law Cap. 113).

Payments are never physically deleted within the retention window. After 7 years, records are
eligible for archival per `zone_promotion_policy.md`.

---

## Immutability

Payment records are append-only. Once created, a payment row must not be updated or deleted.
This ensures the ledger's double-entry integrity is not retroactively altered. If a payment was
recorded in error:

1. Post a reversal ledger entry via `tool_ledger_post.md`.
2. Create a new correct payment record.
3. Void or adjust the invoice as necessary.

Do not use `UPDATE` or `DELETE` on the payments table outside of a controlled migration with
explicit audit trail.

---

## FX Handling

If `currency != 'EUR'`, `amount_eur` is computed using the ECB rate for `payment_date` via
`tool_fx_convert.md`. The rate used is stored in `fx_rate` for auditability. If the ECB rate
is unavailable for the exact date (weekend, bank holiday), the most recent available rate is
used and the payment is flagged with `notes` value `RATE_ESTIMATED` per
`ecb_rate_freshness_policy.md`.

---

## Overpayment

If `amount_eur` exceeds the invoice's remaining balance, the payment is recorded in full and the
excess is handled per `invoice_overpayment_policy.md`. A `credit_balance_entries` record is
created for the overpaid amount, and a review queue issue of type `OVERPAYMENT_REVIEW` is raised.

---

## Audit Events

| Event | Severity | When |
|---|---|---|
| `PAYMENT_RECEIVED` | LOW | Payment record created (via `in_workflow.record_payment`). |
| `PAYMENT_RECONCILED` | LOW | Payment matched to a bank statement row during reconciliation. |
| `PAYMENT_REFUND_INITIATED` | MEDIUM | Refund process started (via Stripe or manual reversal entry). |

All events are emitted via `emit_audit_api.md` and reference `resource_type = 'payment'` with
`resource_id = payments.id`.

---

## Related Documents

- `invoice_schema.md` — parent invoice table and status machine
- `ledger_entry_schema.md` — double-entry ledger entries
- `invoice_overpayment_policy.md` — overpayment routing and credit balance handling
- `tool_payment_record.md` — tool that inserts into this table
- `tool_ledger_post.md` — double-entry post called by record_payment
- `tool_fx_convert.md` — FX conversion and ECB rate lookup
- `ecb_rate_freshness_policy.md` — rate staleness and estimation rules
- `data_retention_policy.md` — 7-year retention, zone assignments
- `emit_audit_api.md` — audit event emission contract
- `stripe_payment_dispute_runbook.md` — handling Stripe dispute events
