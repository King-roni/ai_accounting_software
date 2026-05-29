# tool_invoice_create

**Category:** Tools — Block 13: IN Workflow + Invoice Generator
**Tool name:** `in_workflow.invoice_create`
**Side effect class:** `WRITES_RUN_STATE | WRITES_AUDIT`
**Mobile rejection:** YES — mobile clients cannot call `in_workflow.invoice_create`. See `mobile_write_rejection_endpoints.md`.

---

## Purpose

Creates a new tax invoice or pro-forma invoice within an IN workflow run. The invoice
is always created in `DRAFT` status. Sequence number allocation is deferred to the
transition from `DRAFT` to `SENT` (for TAX invoices) or `DRAFT` to `ISSUED`
(for PRO_FORMA invoices) — it is not allocated at creation time.

---

## Input Schema

```json
{
  "run_id":           "uuid",
  "client_id":        "uuid",
  "invoice_type":     "TAX | PRO_FORMA",
  "line_items": [
    {
      "description": "text",
      "quantity":    "numeric",
      "unit_price":  "numeric",
      "vat_rate":    "numeric"
    }
  ],
  "currency":         "char(3)",
  "issue_date":       "date",
  "due_date":         "date | null",
  "notes":            "text | null",
  "idempotency_key":  "string"
}
```

All fields except `due_date` and `notes` are required.

---

## Output Schema

```json
{
  "invoice_id":     "uuid",
  "invoice_status": "DRAFT",
  "invoice_type":   "text"
}
```

---

## Validation Rules

1. **client_id** must exist in the business's `clients` table and must be associated
   with the same `business_id` as the workflow run.
2. **invoice_type** must be one of `TAX` or `PRO_FORMA`. Any other value returns a
   `400 INVALID_INVOICE_TYPE` error.
3. **vat_rate** for each line item must match a valid Cyprus VAT rate as defined in
   `cyprus_vat_rule_catalog.md`. Invalid rates return `400 INVALID_VAT_RATE`.
4. **currency** must be an ISO 4217 code. For Cyprus-domiciled entities, `EUR` is
   required unless the invoice is explicitly marked as foreign-currency.
5. **due_date**, when provided, must be >= `issue_date`.
6. **line_items** array must contain at least one item. Zero-item invoices are rejected
   with `400 EMPTY_LINE_ITEMS`.

---

## Sequence Number Allocation

Sequence numbers are NOT allocated at creation time. The invoice is created in `DRAFT`
and held without a sequence number.

| Invoice type | Allocates sequence at         | Series |
|---|---|---|
| TAX          | `DRAFT` → `SENT` transition   | `INV`  |
| PRO_FORMA    | `DRAFT` → `ISSUED` transition | `PRO`  |

The sequence is drawn from the `invoice_sequences` table. Allocation is atomic with the
status transition: if the sequence allocation fails, the transition is rolled back and
the invoice remains in `DRAFT`. See `invoice_numbering_sequence_policy.md` for
gap-prevention rules and locking strategy.

---

## VAT Calculation

For each line item:

```
vat_amount = unit_price * quantity * vat_rate
line_total  = (unit_price * quantity) + vat_amount
```

Invoice-level totals are computed by summing all line items:

```
invoice_subtotal  = SUM(unit_price * quantity)
invoice_vat_total = SUM(vat_amount)
invoice_total     = invoice_subtotal + invoice_vat_total
```

All monetary values are stored with 4 decimal places internally. Rounding to 2 decimal
places occurs only at the presentation layer.

---

## Line Item Storage

Line items are persisted to the `invoice_lines` table immediately on creation. The
payload structure follows `invoice_lines_payload_schema.md`. Each row references the
parent `invoice_id` via a non-nullable foreign key.

---

## Initial Status

All invoices — regardless of `invoice_type` — are created with `invoice_status = DRAFT`.
No downstream transitions are triggered by this tool. Transitions are handled by
`in_workflow.invoice_send` (for TAX) and `in_workflow.invoice_issue` (for PRO_FORMA).

---

## Idempotency

If `idempotency_key` matches an existing record for the same `run_id`:

- The original `invoice_id` and `invoice_status` are returned unchanged.
- No new invoice, no new line items, and no new audit event are written.
- The response is identical to the original successful call.

Idempotency keys expire after 24 hours. After expiry, reuse of a key is treated as a
new invocation.

---

## Primary Key

Invoice rows use `gen_uuid_v7()` as the PK. See `invoice_schema.md` for the full DDL.

---

## Audit Events

| Event                          | Severity | Trigger                        |
|---|---|---|
| `IN_WORKFLOW_INVOICE_CREATED`  | LOW      | Invoice row successfully written |

The audit event is written to `audit_log` with `entity_type = 'invoice'`,
`entity_id = invoice_id`, and `run_id` as a correlated reference.

---

## Error Codes

| Code                        | HTTP | Meaning                                      |
|---|---|---|
| `INVALID_INVOICE_TYPE`      | 400  | invoice_type not in allowed enum             |
| `INVALID_VAT_RATE`          | 400  | vat_rate not in cyprus_vat_rule_catalog      |
| `CLIENT_NOT_FOUND`          | 404  | client_id does not exist for this business   |
| `EMPTY_LINE_ITEMS`          | 400  | line_items array is empty                    |
| `RUN_NOT_FOUND`             | 404  | run_id does not exist                        |
| `RUN_STATUS_INCOMPATIBLE`   | 409  | run is not in a state that accepts invoices  |
| `DUPLICATE_SEQUENCE_ERROR`  | 409  | sequence allocation collision (rare)         |

---

## Cross-References

- `invoice_schema.md` — full DDL for the `invoices` table
- `invoice_lines_payload_schema.md` — line item payload and DDL
- `invoice_numbering_sequence_policy.md` — sequence allocation, gap prevention, locking
- `cyprus_vat_rule_catalog.md` — valid VAT rates and applicability rules
- `mobile_write_rejection_endpoints.md` — mobile rejection policy and error format

## Mobile

All write operations in this tool are rejected on mobile clients. Mobile apps receive `HTTP 405 Method Not Allowed` with error code `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full endpoint rejection list.