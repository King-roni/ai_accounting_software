# Tool: in_workflow.create_credit_note

**Block:** in_workflow
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`in_workflow.create_credit_note` creates a credit note record linked to an existing tax invoice.
A credit note is used to reduce or reverse the amount owed on an invoice — for example, to correct
an overcharge, apply a discount after the invoice was sent, or reverse a paid invoice without
voiding it.

This tool creates the credit note in `DRAFT` status. The CN-YYYY-NNNN series number is not
allocated at creation — it is allocated when the credit note is issued via the separate
`in_workflow.issue_credit_note` tool. This mirrors the INV-YYYY-NNNN pattern from
`invoice_sequence_schema.md` and ensures sequence numbers are only consumed for credit notes
that actually leave the system.

PDF generation also occurs at issue time, not at create time.

---

## Tool Signature

```
in_workflow.create_credit_note(
  original_invoice_id  UUID,
  credit_amount        DECIMAL(15,2),
  credit_reason        TEXT,
  credit_lines[]       CreditLine
) -> credit_note_draft
```

### CreditLine Object

```json
{
  "original_line_item_id": "<uuid | null>",
  "description":           "Overcharge on consulting fee — November",
  "quantity":              1,
  "unit_price":            250.00,
  "vat_rate":              0.19,
  "line_total":            250.00
}
```

`original_line_item_id` is optional. If provided, it must reference a line item on the original
invoice. Full or partial credit against a specific line is supported.

### Inputs

| Field | Type | Required | Description |
|---|---|---|---|
| `original_invoice_id` | UUID | Yes | FK to `invoices.id`. The invoice being credited. |
| `credit_amount` | DECIMAL(15,2) | Yes | Total credit amount (sum of `credit_lines[].line_total`). Must match line total sum. |
| `credit_reason` | TEXT | Yes | Reason for the credit. Stored on the record and printed on the credit note PDF at issue time. |
| `credit_lines[]` | CreditLine[] | Yes | One or more line items to credit. At least one line required. |

### Output

```json
{
  "credit_note": {
    "id": "<uuid>",
    "status": "DRAFT",
    "cn_number": null,
    "original_invoice_id": "<uuid>",
    "original_invoice_number": "INV-2025-0042",
    "credit_amount": 250.00,
    "currency": "EUR",
    "credit_reason": "Overcharge on consulting fee.",
    "created_at": "2025-11-05T10:00:00Z"
  }
}
```

`cn_number` is `null` at this stage. It is populated when `in_workflow.issue_credit_note` is
called.

---

## Behaviour

### 1. Pre-condition Checks

**Original invoice guard:**

| Original Invoice Status | Allowed? |
|---|---|
| `DRAFT` | Yes |
| `SENT` | Yes |
| `PARTIALLY_PAID` | Yes |
| `PAID` | Yes |
| `OVERDUE` | Yes |
| `VOID` | No — `ORIGINAL_INVOICE_VOIDED` (409) |

A voided invoice cannot be credited because it has no outstanding or paid value to reverse.
If the original invoice is `VOID`, return `ORIGINAL_INVOICE_VOIDED`.

**Credit amount validation:**

```
sum(credit_lines[].line_total) must equal credit_amount (tolerance: +-0.01 EUR for rounding)
credit_amount must be > 0
credit_amount must not exceed original_invoice.total_amount_eur - existing_credited_amount
```

If the credit would exceed the remaining creditable balance, return `CREDIT_EXCEEDS_BALANCE`.

**Period lock:** Credit notes can be created against invoices in locked periods (the original
invoice is not modified at this stage). The `payment_date` of the credit note is set at issue
time.

### 2. Compute Remaining Creditable Balance

```sql
SELECT
  invoices.total_amount_eur,
  COALESCE(SUM(cn.credit_amount), 0) AS total_credited
FROM invoices
LEFT JOIN credit_notes cn
  ON cn.original_invoice_id = invoices.id
  AND cn.status NOT IN ('VOID')
WHERE invoices.id = :original_invoice_id
GROUP BY invoices.total_amount_eur;

creditable_balance = total_amount_eur - total_credited
```

### 3. Insert Credit Note (DRAFT)

```sql
INSERT INTO credit_notes (
  id, business_id, original_invoice_id, cn_number, status,
  credit_amount, currency, credit_reason, created_by, created_at
) VALUES (
  gen_uuid_v7(),
  :business_id,
  :original_invoice_id,
  NULL,               -- cn_number allocated at ISSUED, not DRAFT
  'DRAFT',
  :credit_amount,
  :currency,
  :credit_reason,
  auth.uid(),
  now()
);
```

### 4. Insert Credit Note Line Items

For each entry in `credit_lines[]`:

```sql
INSERT INTO credit_note_lines (
  id, credit_note_id, original_line_item_id, description,
  quantity, unit_price, vat_rate, line_total
) VALUES (...);
```

### 5. Update Original Invoice credited_amount

```sql
UPDATE invoices
SET    credited_amount = credited_amount + :credit_amount
WHERE  id = :original_invoice_id;
```

Note: This is a draft update. If the credit note is subsequently voided, `credited_amount` is
decremented. Full credit (where `credited_amount >= total_amount_eur`) transitions the original
invoice to `VOID` only at issue time, not at draft time.

### 6. Fully Credited Check (at Issue Time)

This tool does not transition the original invoice to `VOID`. That check is performed by
`in_workflow.issue_credit_note` after the CN number is allocated. At that point:

```
IF invoices.credited_amount >= invoices.total_amount_eur
  -> UPDATE invoices SET status = 'VOID'
```

### 7. Audit Emission

```json
{
  "event_type":    "CREDIT_NOTE_CREATED",
  "severity":      "LOW",
  "actor_id":      "<user_id>",
  "business_id":   "<business_id>",
  "resource_type": "credit_note",
  "resource_id":   "<credit_note_id>",
  "payload": {
    "original_invoice_id":     "<uuid>",
    "original_invoice_number": "INV-2025-0042",
    "credit_amount":           250.00,
    "currency":                "EUR",
    "status":                  "DRAFT"
  }
}
```

---

## Write Classification

| Classification | Value |
|---|---|
| WRITES_RUN_STATE | Yes — inserts `credit_notes` and `credit_note_lines`; updates `invoices.credited_amount` |
| WRITES_AUDIT | Yes — emits `CREDIT_NOTE_CREATED` (LOW) |

---

## CN-YYYY-NNNN Series Number

The CN-YYYY-NNNN number is NOT allocated by this tool. It is allocated by
`in_workflow.issue_credit_note` in the same atomic transaction that sets `status = 'ISSUED'`.
This design ensures:

1. Sequence numbers are only consumed for credit notes that clients will receive.
2. Draft credit notes that are discarded (never issued) do not create gaps in the CN series.
3. The CN series is auditable: every number in the range corresponds to an issued document.

The CN sequence is stored in `invoice_sequences` with `type = 'CREDIT_NOTE'` (separate counter
from INV series, same year-keyed structure).

---

## Partial Credit

`credit_lines[]` supports partial credit against specific invoice lines. The accountant may
credit one line in full, another line partially, or add a freeform credit line not tied to the
original invoice. All three patterns are valid as long as the total does not exceed the
creditable balance.

---

## Error Reference

| Code | HTTP | Condition |
|---|---|---|
| `ORIGINAL_INVOICE_NOT_FOUND` | 404 | Original invoice does not exist or belongs to a different business. |
| `ORIGINAL_INVOICE_VOIDED` | 409 | Cannot create a credit note against a voided invoice. |
| `CREDIT_EXCEEDS_BALANCE` | 422 | `credit_amount` exceeds the remaining creditable balance. |
| `CREDIT_AMOUNT_MISMATCH` | 422 | `credit_amount` does not match the sum of `credit_lines[].line_total`. |
| `CREDIT_LINES_EMPTY` | 422 | `credit_lines[]` is empty. |
| `CREDIT_AMOUNT_ZERO` | 422 | `credit_amount` is zero or negative. |

---

## Related Documents

- `credit_note_schema.md` — credit_notes table DDL and status enum
- `invoice_schema.md` — invoices table and credited_amount field
- `invoice_credit_note_link_policy.md` — when to use credit notes vs. void
- `credit_note_allocation_schema.md` — credit application and allocation records
- `invoice_sequence_schema.md` — CN-YYYY-NNNN sequence allocation rules
- `emit_audit_api.md` — audit emission contract

---

## Mobile

`in_workflow.create_credit_note` writes run state and emits an audit event. Mobile clients must
observe the following:

**Allowed on mobile:** Yes. Creating a draft credit note is a low-risk write; the credit note
does not leave the system until it is issued.

**UX requirements:**
- Show the original invoice details (number, client, amount, credited to date) prominently before
  the user enters credit line items.
- Display the remaining creditable balance and update it as the user adds or edits credit lines.
  Prevent submission if total exceeds the creditable balance.
- Each credit line should default to the full original line amount; the user reduces it for
  partial credits.
- On successful creation, navigate to the credit note detail screen. Show a banner:
  "Credit note draft created. Issue it to send to the client."
- The issue action (in_workflow.issue_credit_note) is a separate step, exposed as a prominent
  CTA on the draft credit note detail screen.

**Offline behaviour:** Requires network. Display "Creating credit notes requires a network
connection." Do not allow offline creation as the creditable balance check requires a live read.
