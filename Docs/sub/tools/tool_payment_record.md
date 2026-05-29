# Tool: in_workflow.record_payment

**Block:** in_workflow
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`in_workflow.record_payment` records a payment received against an open invoice. It creates a
payment record in the `payments` table, updates the invoice status based on whether the payment
satisfies the remaining balance, and posts the corresponding double-entry ledger transaction
(DEBIT bank account, CREDIT accounts receivable).

The tool handles three payment outcome cases: full payment (`PAID`), partial payment
(`PARTIALLY_PAID`), and overpayment (handled per `invoice_overpayment_policy.md`).

Stripe payments processed via the payment link flow are recorded automatically by the Stripe
webhook handler. This tool is used for manual recording of bank transfers, cash, cheques, and
other out-of-band payments.

---

## Tool Signature

```
in_workflow.record_payment(
  invoice_id      UUID,
  amount          DECIMAL(15,2),
  currency        CHAR(3),
  payment_date    DATE,
  payment_method  'BANK_TRANSFER' | 'STRIPE' | 'CASH' | 'CHEQUE' | 'OTHER',
  reference       TEXT DEFAULT NULL,
  notes           TEXT DEFAULT NULL
) -> payment_result
```

### Inputs

| Field | Type | Required | Description |
|---|---|---|---|
| `invoice_id` | UUID | Yes | FK to `invoices.id`. Must belong to the calling business. |
| `amount` | DECIMAL(15,2) | Yes | Payment amount in the specified `currency`. Must be > 0. |
| `currency` | CHAR(3) | Yes | ISO 4217 currency code. If not EUR, FX conversion is applied via `tool_fx_convert.md` to populate `amount_eur`. |
| `payment_date` | DATE | Yes | Date the payment was received (not the recording date). Cannot be in a locked period. |
| `payment_method` | ENUM | Yes | Channel through which the payment was received. |
| `reference` | TEXT | No | Bank reference, cheque number, or transaction ID. Stored for reconciliation. |
| `notes` | TEXT | No | Free-text notes for the accountant. Not visible to the client. |

### Output

```json
{
  "payment": {
    "id": "<uuid>",
    "invoice_id": "<uuid>",
    "amount": 1250.00,
    "currency": "EUR",
    "amount_eur": 1250.00,
    "fx_rate": 1.00000000,
    "payment_date": "2025-11-10",
    "payment_method": "BANK_TRANSFER",
    "reference": "REF-20251110-001",
    "created_at": "2025-11-10T14:22:00Z",
    "ledger_entry_id": "<uuid>"
  },
  "invoice": {
    "id": "<uuid>",
    "invoice_number": "INV-2025-0042",
    "status": "PAID",
    "amount_due": 1250.00,
    "amount_paid": 1250.00,
    "remaining_balance": 0.00
  }
}
```

---

## Behaviour

### 1. Pre-condition Checks

**Invoice status guard:**

| Invoice Status | Allowed? |
|---|---|
| `SENT` | Yes |
| `PARTIALLY_PAID` | Yes |
| `OVERDUE` | Yes |
| `DRAFT` | No — `INVOICE_NOT_PAYABLE` (409) |
| `PAID` | No — `INVOICE_ALREADY_PAID` (409) |
| `VOID` | No — `INVOICE_VOIDED` (409) |

**Amount guard:** `amount` must be greater than 0. Zero-amount payments are rejected.

**Period lock guard:** `payment_date` must not fall within a locked period. Use
`engine.gate_period_locked` evaluated against the payment date.

**Currency guard:** If `currency` is not `EUR`, fetch the ECB rate for `payment_date` via
`tool_fx_convert.md` and populate `amount_eur` and `fx_rate`. If the ECB rate for the date is
unavailable, follow `ecb_rate_freshness_policy.md` (fallback to most recent available rate and
flag as `RATE_ESTIMATED`).

### 2. Compute Remaining Balance

```sql
SELECT
  invoices.total_amount_eur,
  COALESCE(SUM(payments.amount_eur), 0) AS paid_to_date
FROM invoices
LEFT JOIN payments ON payments.invoice_id = invoices.id
WHERE invoices.id = :invoice_id
GROUP BY invoices.total_amount_eur;

remaining_balance = total_amount_eur - paid_to_date
```

### 3. Outcome Routing

```
IF amount_eur = remaining_balance  -> new_status = 'PAID'
IF amount_eur < remaining_balance  -> new_status = 'PARTIALLY_PAID'
IF amount_eur > remaining_balance  -> OVERPAYMENT: see below
```

**Overpayment handling** (per `invoice_overpayment_policy.md`):
- Record the payment at full `amount_eur`.
- Set invoice status to `PAID`.
- Create a `credit_balance_entries` record for the excess amount.
- Create a review queue issue of type `OVERPAYMENT_REVIEW` so the accountant can decide whether
  to refund, apply to a future invoice, or write off.
- Emit `PAYMENT_RECEIVED` audit event with `overpayment: true` in payload.

### 4. Create Payment Record

```sql
INSERT INTO payments (
  id, invoice_id, business_id, amount, currency, amount_eur, fx_rate,
  payment_date, payment_method, reference, notes, recorded_by, created_at
) VALUES (
  gen_uuid_v7(), :invoice_id, :business_id, :amount, :currency, :amount_eur, :fx_rate,
  :payment_date, :payment_method, :reference, :notes, auth.uid(), now()
);
```

### 5. Post Ledger Entry

Call `tool_ledger_post.md` with:

```json
{
  "business_id": "<business_id>",
  "entry_date":  "<payment_date>",
  "description": "Payment received: INV-2025-0042",
  "lines": [
    {
      "account_code": "<bank_account_from_business_settings>",
      "account_type": "ASSET",
      "debit":        1250.00,
      "credit":       0
    },
    {
      "account_code": "1100",
      "account_type": "ASSET",
      "debit":        0,
      "credit":       1250.00,
      "description":  "Accounts receivable — INV-2025-0042"
    }
  ]
}
```

The returned `ledger_entry_id` is stored on the payment record.

### 6. Update Invoice Status

```sql
UPDATE invoices
SET    status           = :new_status,
       amount_paid      = amount_paid + :amount_eur,
       remaining_balance = total_amount_eur - (amount_paid + :amount_eur),
       paid_at          = CASE WHEN :new_status = 'PAID' THEN now() ELSE NULL END
WHERE  id = :invoice_id;
```

### 7. Audit Emission

```json
{
  "event_type":    "PAYMENT_RECEIVED",
  "severity":      "LOW",
  "actor_id":      "<user_id>",
  "business_id":   "<business_id>",
  "resource_type": "payment",
  "resource_id":   "<payment_id>",
  "payload": {
    "invoice_id":      "<uuid>",
    "invoice_number":  "INV-2025-0042",
    "amount":          1250.00,
    "currency":        "EUR",
    "payment_method":  "BANK_TRANSFER",
    "new_invoice_status": "PAID",
    "overpayment":     false
  }
}
```

---

## Write Classification

| Classification | Value |
|---|---|
| WRITES_RUN_STATE | Yes — inserts `payments` record; updates `invoices.status`, `amount_paid`, `remaining_balance` |
| WRITES_AUDIT | Yes — emits `PAYMENT_RECEIVED` (LOW) |

---

## Reconciliation

Payments recorded via this tool are initially in an `UNRECONCILED` state. Bank reconciliation
(matching payments to bank statement rows) is handled by `tool_ledger_reconcile.md`. When a
payment is reconciled, a `PAYMENT_RECONCILED` audit event (LOW) is emitted and
`payments.ledger_entry_id` is updated.

---

## Error Reference

| Code | HTTP | Condition |
|---|---|---|
| `INVOICE_NOT_FOUND` | 404 | `invoice_id` does not exist or belongs to a different business. |
| `INVOICE_NOT_PAYABLE` | 409 | Invoice is in `DRAFT` status. |
| `INVOICE_ALREADY_PAID` | 409 | Invoice is fully `PAID`. |
| `INVOICE_VOIDED` | 409 | Invoice has been voided. |
| `AMOUNT_INVALID` | 422 | `amount` is zero or negative. |
| `CURRENCY_INVALID` | 422 | `currency` is not a valid ISO 4217 code. |
| `PERIOD_LOCKED` | 409 | `payment_date` falls in a locked period. |
| `FX_RATE_UNAVAILABLE` | 202 | ECB rate unavailable; estimated rate used; `RATE_ESTIMATED` flag set. |
| `LEDGER_POST_FAILED` | 500 | Double-entry post failed; payment record rolled back. |

---

## Related Documents

- `payment_schema.md` — payments table DDL
- `invoice_schema.md` — invoice status machine
- `invoice_overpayment_policy.md` — overpayment routing rules
- `tool_ledger_post.md` — ledger entry creation
- `tool_fx_convert.md` — FX conversion and ECB rate lookup
- `ecb_rate_freshness_policy.md` — rate staleness handling
- `emit_audit_api.md` — audit emission contract
- `tool_ledger_reconcile.md` — bank reconciliation flow

---

## Mobile

`in_workflow.record_payment` writes run state and emits an audit event. Mobile clients must
observe the following:

**Allowed on mobile:** Yes. Recording a bank transfer or cash payment from the mobile app is a
common accountant workflow.

**UX requirements:**
- Pre-populate `payment_date` with today's date; allow the user to change it. Clearly indicate
  if the selected date falls in a locked period before the user submits.
- Show a currency selector; default to the invoice currency. If a non-EUR currency is selected,
  display the estimated EUR equivalent using the last known ECB rate before submission.
- After submitting, show the updated invoice status prominently (PAID / PARTIALLY_PAID) and the
  remaining balance if partially paid.
- For overpayment scenarios, display a banner: "Overpayment recorded — review required in the
  review queue."
- `STRIPE` payment method should only be selectable if `invoices.stripe_checkout_session_id` is
  set; otherwise hide it from the picker to avoid confusion with manual Stripe entries.

**Offline behaviour:** Requires network. Do not allow offline payment recording as the ledger
post requires a live database write. Display "Recording payments requires a network connection."
