# Tool: in_workflow.apply_credit_note

| Field              | Value       |
|--------------------|-------------|
| Namespace          | in_workflow |
| WRITES_RUN_STATE   | No          |
| WRITES_AUDIT       | Yes         |
| Idempotent         | No          |
| Mobile             | No          |

## Purpose

Applies a credit note to reduce the outstanding balance of an invoice. The operation reduces the `consumed_amount` on the credit note and adjusts the invoice balance accordingly, which may transition the invoice to `PARTIALLY_PAID` or `PAID`. Ledger entries are created to record the application.

This tool does not issue new credit notes. To create a credit note, use `tool_credit_note_create.md`. Partial applications are allowed; a single credit note may be applied across multiple invoices.

---

## Parameters

| Parameter        | Type          | Required | Description                                                                                                               |
|------------------|---------------|----------|---------------------------------------------------------------------------------------------------------------------------|
| `credit_note_id` | uuid          | Yes      | The credit note to apply. Must be in `ISSUED` status.                                                                     |
| `invoice_id`     | uuid          | Yes      | The invoice to reduce. Must be in `SENT`, `PARTIALLY_PAID`, or `OVERDUE` status.                                          |
| `apply_amount`   | numeric(15,2) | Yes      | The amount to apply from the credit note toward the invoice. Must be > 0 and satisfy both balance constraints (see below). |

---

## Pre-conditions

- The caller must hold permission `in_workflow:apply_credit_note` on the business entity.
- Both `credit_note_id` and `invoice_id` must belong to the same `business_entity_id`.
- The current run for the business entity must be in `RUNNING` status. Credit notes cannot be applied during a paused or held run.

---

## Steps

### 1. Load and validate credit note

Fetch the credit note by `credit_note_id`. Confirm:

- `credit_note.status = 'ISSUED'`
- `credit_note.business_entity_id` matches the caller's context
- The credit note is not in a locked period. If `is_locked = true` for the credit note's period, return `CREDIT_NOTE_PERIOD_LOCKED`.

Calculate `remaining_credit = credit_note.credit_amount - credit_note.consumed_amount`.

If `remaining_credit <= 0`, the credit note is fully consumed and cannot be applied. Return `CREDIT_NOTE_FULLY_CONSUMED`.

### 2. Load and validate invoice

Fetch the invoice by `invoice_id`. Confirm:

- `invoice.status` is one of `SENT`, `PARTIALLY_PAID`, `OVERDUE`
- `invoice.business_entity_id` matches the caller's context

Calculate `outstanding_balance = invoice.invoice_total - invoice.paid_amount - invoice.credit_applied_amount`.

If `outstanding_balance <= 0`, return `INVOICE_ALREADY_PAID`.

### 3. Validate apply_amount

- `apply_amount` must be > 0.
- `apply_amount` must be ≤ `remaining_credit` (cannot exceed available credit note balance).
- `apply_amount` must be ≤ `outstanding_balance` (cannot over-apply to the invoice).

If either constraint fails, return `APPLY_AMOUNT_EXCEEDS_LIMIT` with `max_allowed` set to `min(remaining_credit, outstanding_balance)`.

### 4. Execute application in a transaction

All writes below occur inside a single database transaction.

**4a. Update credit note consumed amount:**

```sql
UPDATE credit_notes
SET consumed_amount = consumed_amount + :apply_amount,
    updated_at = now()
WHERE id = :credit_note_id
  AND status = 'ISSUED';
```

**4b. Set credit note status to FULLY_APPLIED if now fully consumed:**

```sql
UPDATE credit_notes
SET status = 'FULLY_APPLIED'
WHERE id = :credit_note_id
  AND consumed_amount >= credit_amount;
```

**4c. Update invoice credit_applied_amount:**

```sql
UPDATE invoices
SET credit_applied_amount = credit_applied_amount + :apply_amount,
    updated_at = now()
WHERE id = :invoice_id;
```

**4d. Transition invoice status if balance now cleared:**

Recalculate `new_outstanding = invoice.invoice_total - invoice.paid_amount - new_credit_applied_amount`.

- If `new_outstanding = 0` → set `invoice.status = 'PAID'`, set `invoice.paid_at = now()`.
- If `new_outstanding > 0` and `new_outstanding < invoice.invoice_total` → set `invoice.status = 'PARTIALLY_PAID'`.
- Otherwise (first partial application, status was `SENT` or `OVERDUE`) → set `invoice.status = 'PARTIALLY_PAID'`.

**4e. Create credit note allocation record:**

Insert a row in `credit_note_allocations`:

```sql
INSERT INTO credit_note_allocations (id, credit_note_id, invoice_id, applied_amount, applied_at, applied_by)
VALUES (gen_uuid_v7(), :credit_note_id, :invoice_id, :apply_amount, now(), :caller_user_id);
```

**4f. Create ledger entries:**

Create two ledger entries via `tool_ledger_post`:

1. Debit `Accounts Receivable` for `apply_amount` (reduces the receivable balance).
2. Credit `Credit Notes Liability` account for `apply_amount` (extinguishes the credit note liability).

The `ledger_account_mapping` for credit note application must be configured in `chart_of_accounts` under the business entity. If the mapping is missing, return `LEDGER_MAPPING_NOT_FOUND` and roll back the transaction.

### 5. Emit audit event

After successful commit, emit `IN_WORKFLOW_CREDIT_NOTE_APPLIED`:

```json
{
  "credit_note_id": "<uuid>",
  "invoice_id": "<uuid>",
  "apply_amount": "<numeric>",
  "applied_by": "<uuid>",
  "business_entity_id": "<uuid>",
  "credit_note_remaining": "<numeric>",
  "invoice_new_status": "<status>",
  "applied_at": "<iso8601>"
}
```

---

## Error Reference

| Error Code                    | HTTP | Description                                                                                          |
|-------------------------------|------|------------------------------------------------------------------------------------------------------|
| `CREDIT_NOTE_NOT_FOUND`       | 404  | Credit note does not exist for this business entity.                                                 |
| `INVOICE_NOT_FOUND`           | 404  | Invoice does not exist for this business entity.                                                     |
| `CREDIT_NOTE_NOT_ISSUED`      | 409  | Credit note is not in `ISSUED` status. Current status returned in detail.                            |
| `CREDIT_NOTE_PERIOD_LOCKED`   | 409  | The credit note belongs to a locked period and cannot be modified.                                   |
| `CREDIT_NOTE_FULLY_CONSUMED`  | 409  | Credit note has no remaining balance to apply.                                                       |
| `INVOICE_ALREADY_PAID`        | 409  | Invoice outstanding balance is zero; no application needed.                                          |
| `INVOICE_STATUS_INVALID`      | 409  | Invoice is not in `SENT`, `PARTIALLY_PAID`, or `OVERDUE`.                                            |
| `APPLY_AMOUNT_EXCEEDS_LIMIT`  | 422  | `apply_amount` exceeds either remaining credit or outstanding invoice balance. `max_allowed` given.  |
| `LEDGER_MAPPING_NOT_FOUND`    | 422  | Chart of accounts does not have a configured mapping for credit note application.                    |
| `RUN_NOT_IN_RUNNING_STATE`    | 409  | Current run is not in `RUNNING` status. Credit note application is blocked.                          |
| `TRANSACTION_FAILED`          | 500  | Database transaction failed. Safe to retry; no partial writes will have been committed.              |

---

## Mobile

This tool is not available on mobile. Credit note application involves ledger writes and requires desktop confirmation. The mobile view shows credit note status as read-only.

---

## Audit Taxonomy Note

`IN_WORKFLOW_CREDIT_NOTE_APPLIED` should be verified in the audit taxonomy. If not present, add it with domain `IN_WORKFLOW`, entity `CREDIT_NOTE`, verb `APPLIED`.

---

## Related Documents

- `tools/tool_credit_note_create.md` — Prerequisite: creates the credit note before it can be applied.
- `tools/tool_ledger_post.md` — Used internally to create the double-entry ledger records.
- `schemas/credit_note_schema.md` — Credit note record definition including status transitions.
- `schemas/credit_note_allocation_schema.md` — Allocation record written by this tool.
- `policies/credit_note_policy.md` — Rules for when credit notes can be created and applied.
- `policies/invoice_credit_note_link_policy.md` — Invoice linkage and period constraints.
