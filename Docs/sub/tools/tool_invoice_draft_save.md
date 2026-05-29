# Tool: in_workflow.save_invoice_draft

| Field              | Value                                        |
|--------------------|----------------------------------------------|
| Namespace          | in_workflow                                  |
| WRITES_RUN_STATE   | No                                           |
| WRITES_AUDIT       | Yes                                          |
| Idempotent         | Yes — on same invoice_id                     |
| Mobile             | Yes                                          |

## Purpose

Saves or updates a draft invoice. If `invoice_id` is null, a new invoice record is created with status `DRAFT`. If `invoice_id` is provided, the existing `DRAFT` invoice is updated in place. No invoice series number is assigned at this stage; the number is assigned only when the invoice transitions to `SENT` via `tool_invoice_send`.

This tool is the primary persistence mechanism for in-progress invoice editing. It is safe to call repeatedly as the user modifies the form; each call overwrites the previous draft state.

---

## Parameters

| Parameter            | Type            | Required | Description                                                                                            |
|----------------------|-----------------|----------|--------------------------------------------------------------------------------------------------------|
| `invoice_id`         | uuid \| null    | No       | If null, a new invoice is created. If provided, must reference an existing invoice in `DRAFT` status.  |
| `business_entity_id` | uuid            | Yes      | FK → `business_entities(id)`. The business entity issuing the invoice.                                 |
| `client_id`          | uuid            | Yes      | FK → `clients(id)`. The recipient of the invoice.                                                      |
| `invoice_lines`      | array of object | Yes      | Line items. Each item: `description` (text), `quantity` (numeric), `unit_price` (numeric(12,2)), `vat_rate` (numeric(5,4)), `account_code` (text optional). Minimum 1 line required. |
| `due_date`           | date            | Yes      | Payment due date. Must be on or after today's date.                                                    |
| `notes`              | text            | No       | Freeform notes to appear on the invoice PDF. Maximum 2000 characters. Not shown to VAT authority.      |

---

## Pre-conditions

- The caller must hold permission `in_workflow:write_invoice` on the business entity.
- If `invoice_id` is provided, the invoice must belong to `business_entity_id` and must be in `DRAFT` status.
- A run in `RUNNING` status must exist for the business entity's current open period. Draft invoices are always associated with the current open run.

---

## Steps

### 1. Resolve create vs. update mode

If `invoice_id` is null, enter create mode. If `invoice_id` is provided, fetch the record and confirm status is `DRAFT`. If the status is anything other than `DRAFT` (for example `SENT` or `VOID`), return `INVOICE_NOT_EDITABLE`.

### 2. Validate invoice lines

For each line item:

- `quantity` must be > 0.
- `unit_price` must be >= 0. Zero unit price is allowed for complimentary line items.
- `vat_rate` must be a value present in the system's configured VAT rates for the business entity's jurisdiction (Cyprus: 0.00, 0.05, 0.09, 0.19).
- `account_code`, if provided, must exist in `chart_of_accounts` for the business entity.

Calculate `line_total = quantity * unit_price` for each line. Calculate `subtotal = sum(line_totals)`. Calculate `vat_total = sum(quantity * unit_price * vat_rate)`. Calculate `invoice_total = subtotal + vat_total`. All arithmetic uses `numeric(15,2)` precision. Rounding follows `ledger_rounding_policy.md` (half-up, per-line).

If any line fails validation, return `INVOICE_LINE_VALIDATION_FAILED` with the line index and the specific field that failed.

### 3. Persist invoice record

**Create mode** (invoice_id is null):

Insert a new row into `invoices`:

```sql
INSERT INTO invoices (
  id,
  business_entity_id,
  client_id,
  status,
  due_date,
  notes,
  subtotal,
  vat_total,
  invoice_total,
  created_by,
  run_id,
  created_at,
  updated_at
) VALUES (
  gen_uuid_v7(),
  :business_entity_id,
  :client_id,
  'DRAFT',
  :due_date,
  :notes,
  :subtotal,
  :vat_total,
  :invoice_total,
  :caller_user_id,
  :current_open_run_id,
  now(),
  now()
)
```

No `invoice_number` is assigned. The `invoice_number` column remains null until `tool_invoice_send` fires.

**Update mode** (invoice_id is provided):

```sql
UPDATE invoices
SET client_id       = :client_id,
    due_date        = :due_date,
    notes           = :notes,
    subtotal        = :subtotal,
    vat_total       = :vat_total,
    invoice_total   = :invoice_total,
    updated_at      = now()
WHERE id = :invoice_id
  AND status = 'DRAFT'
  AND business_entity_id = :business_entity_id;
```

### 4. Save invoice lines

Delete all existing `invoice_line_items` for the invoice, then insert the provided lines:

```sql
DELETE FROM invoice_line_items WHERE invoice_id = :invoice_id;

INSERT INTO invoice_line_items (id, invoice_id, description, quantity, unit_price, vat_rate, line_total, sort_order)
VALUES ...
```

This replace-all approach is intentional. Draft editing does not version line items.

### 5. Emit audit event

Emit `INVOICE_DRAFT_SAVED` with payload:

```json
{
  "invoice_id": "<uuid>",
  "business_entity_id": "<uuid>",
  "client_id": "<uuid>",
  "action": "CREATE" | "UPDATE",
  "invoice_total": "<numeric>",
  "line_count": <int>,
  "saved_by": "<uuid>"
}
```

---

## Idempotency

Calling this tool multiple times with the same `invoice_id` and identical parameters is safe and will produce no visible state change beyond updating `updated_at`. Multiple calls with evolving line items will converge to the last provided line set.

---

## Error Reference

| Error Code                       | HTTP | Description                                                                                    |
|----------------------------------|------|------------------------------------------------------------------------------------------------|
| `INVOICE_NOT_FOUND`              | 404  | `invoice_id` provided but no matching invoice exists for this business entity.                 |
| `INVOICE_NOT_EDITABLE`           | 409  | Invoice is not in `DRAFT` status and cannot be modified via this tool.                         |
| `INVOICE_LINE_VALIDATION_FAILED` | 422  | One or more line items failed validation. `line_index` and `field` are included in the detail. |
| `NO_OPEN_RUN`                    | 422  | No run in `RUNNING` status exists for the current period. Draft cannot be associated.          |
| `CLIENT_NOT_FOUND`               | 422  | `client_id` does not exist or does not belong to this business entity.                         |
| `DUE_DATE_IN_PAST`               | 422  | `due_date` is before today's date.                                                             |
| `NOTES_TOO_LONG`                 | 422  | `notes` exceeds 2000 characters.                                                               |

---

## Mobile

This tool is available on mobile. The mobile UI presents a simplified line-item form. Complex multi-line invoices with many account codes are better handled on desktop. Auto-save triggers this tool on field blur.

---

## Audit Taxonomy Note

`INVOICE_DRAFT_SAVED` should be verified in the audit taxonomy. If not present, add it with domain `INVOICE`, entity `DRAFT`, verb `SAVED`. The `action` field distinguishes create from update.

---

## Related Documents

- `tools/tool_invoice_create.md` — Legacy create path; this tool supersedes it for draft workflows.
- `tools/tool_invoice_send.md` — Transitions invoice from `DRAFT` to `SENT` and assigns the series number.
- `tools/tool_invoice_void.md` — Void a `DRAFT` or `SENT` invoice.
- `schemas/invoice_schema.md` — Full invoice record definition.
- `schemas/invoice_line_item_schema.md` — Line item column definitions.
- `policies/invoice_numbering_policy.md` — When and how invoice numbers are assigned.
- `policies/invoice_draft_stale_policy.md` — Staleness rules for invoices left in `DRAFT`.
