# Allocation Policy

**Category:** Policies · Block 13 — IN Workflow + Invoice Generator  
**Owner:** in_workflow  
**Last updated:** 2026-05-16

---

## 1. Purpose

This policy governs how incoming bank transactions are allocated to outstanding invoices once a match is confirmed. It defines the rules for full, partial, and over-allocation, multi-transaction allocation, credit note allocation, allocation reversal, and FX handling.

---

## 2. Allocation Definition

An allocation record is created when `matching.confirm` is called and a bank transaction is confirmed as matching an invoice. The allocation links a specific transaction amount (or portion of it) to an invoice, reducing the invoice's outstanding balance.

Allocation records are stored in the `invoice_payment_allocations` table. Each allocation row references:
- `transaction_id` — the confirmed bank transaction
- `invoice_id` — the invoice being credited
- `allocated_amount` — the amount applied
- `fx_rate` — exchange rate at confirmation time (non-EUR invoices)
- `allocated_at` — timestamp of confirmation

---

## 3. Full Allocation

**Condition:** `transaction.amount = invoice.total_amount ± €0.01 tolerance`

**Outcome:**
- One allocation record is created for the full invoice amount.
- `invoice.status` transitions to `PAID`.
- The `€0.01` tolerance accounts for rounding differences from bank transfers.

**Tolerance note:** For FX invoices, the tolerance is converted to the invoice currency using the `fx_rate` at confirmation time (see section 9).

---

## 4. Partial Allocation

**Condition:** `transaction.amount < invoice.total_amount`

**Outcome:**
- One allocation record is created for `transaction.amount`.
- `invoice.status` transitions to `PARTIALLY_PAID`.
- The unallocated remainder (`invoice.total_amount - sum(allocated_amounts)`) is tracked by the `invoice_payment_allocations` table; no separate "remainder" row is created — the remainder is derived by query.

**Constraint:** Partial allocations remain open until additional transactions or credit notes cover the outstanding balance.

---

## 5. Over-Allocation

**Condition:** `transaction.amount > invoice.total_amount`

**Outcome:**
- `invoice.status` transitions to `PAID`.
- The excess (`transaction.amount - invoice.total_amount`) is flagged as an `OVERPAYMENT` review issue in `review_issues`.
- The allocation record still records `invoice.total_amount` as `allocated_amount`; the excess is captured in `review_issues.excess_amount`.
- The review issue is assigned severity `MEDIUM` and must be resolved before the period can be finalized.

Audit event emitted: `IN_WORKFLOW_OVERPAYMENT_DETECTED` (MEDIUM).

---

## 6. Multi-Transaction Allocation

Multiple transactions may be allocated against a single invoice. Each allocation is a separate row in `invoice_payment_allocations`.

**Sum check:** After each allocation, the engine recomputes `sum(allocated_amount) WHERE invoice_id = ?`. If the sum equals `invoice.total_amount ± tolerance`, `invoice.status` is set to `PAID`. If the sum exceeds `invoice.total_amount`, over-allocation rules (section 5) apply.

**Ordering:** Allocations are applied in `confirmed_at` ascending order. There is no cap on the number of transactions per invoice, subject to the plan's transaction volume limits.

---

## 7. Credit Note Allocation

A credit note (CN series) may be allocated against an invoice to reduce the outstanding balance. The mechanism is:

1. Credit note is in `ISSUED` status.
2. `in_workflow.allocate_credit_note` is called with `(credit_note_id, invoice_id)`.
3. A `credit_note_allocation` record is created (see `credit_note_allocation_schema.md`).
4. `credit_notes.allocated_amount` is updated to reflect the applied amount.
5. The invoice's effective outstanding balance is recalculated as:
   `invoice.total_amount - sum(payment_allocations) - sum(credit_note_allocations)`

**Status resolution:** If the combined payment allocations and credit note allocations cover `invoice.total_amount ± tolerance`, `invoice.status` transitions to `PAID`.

**Partial credit note allocation:** A credit note may be partially allocated. The remainder of the credit note's value is available for allocation against other invoices, subject to `credit_note_cumulative_cap_schema.md`.

---

## 8. Allocation Reversal

If a confirmed match is subsequently rejected (via `matching.reject_confirmed`):

1. The allocation record's `reversed_at` is set to `now()`.
2. `invoice.status` reverts to its pre-allocation status (`SENT`, `PARTIALLY_PAID`, or `OVERDUE` as applicable).
3. If the reversal is for a credit note allocation, the `credit_note_allocation` record is reversed and `credit_notes.allocated_amount` is decremented.
4. Any associated `OVERPAYMENT` review issue is closed automatically.

Audit event emitted: `IN_WORKFLOW_ALLOCATION_REVERSED` (LOW).

**Irreversibility window:** Allocations in a FINALIZED period cannot be reversed. Attempting to reverse a locked-period allocation returns `PERIOD_LOCKED`. Adjustments in locked periods follow `out_adjustment_policies.md`.

---

## 9. FX Invoice Allocation

For invoices denominated in a non-EUR currency:

- The `€0.01` tolerance is converted to the invoice currency using `fx_rate` stored on the allocation record at confirmation time.
- `fx_rate` is pulled from `data.get_fx_rate` at the moment `matching.confirm` is called.
- The converted tolerance is applied for full/partial/over-allocation determination.
- `allocated_amount` on the allocation record is stored in the invoice's original currency.
- A derived `allocated_amount_eur` column stores the EUR equivalent for reporting.

---

## 10. Allocation Record Storage

All allocation records are persisted in the `invoice_payment_allocations` table as defined in `invoice_payment_allocations_schema.md`. The table is append-only for active records; reversals set `reversed_at` rather than deleting rows.

---

## 11. Tools

| Tool | Action |
|------|--------|
| `matching.confirm` | Triggers allocation creation on match confirmation |
| `in_workflow.allocate_credit_note` | Creates a credit note allocation record |
| `in_workflow.reverse_allocation` | Reverses a payment or credit note allocation |
| `data.get_fx_rate` | Retrieves FX rate at confirmation time |

All `in_workflow` WRITE tools: see `mobile_write_rejection_endpoints.md` — write operations are rejected on mobile clients.

---

## 12. Audit Events

| Event | Severity | Trigger |
|-------|----------|---------|
| `IN_WORKFLOW_PAYMENT_ALLOCATED` | LOW | Allocation record created |
| `IN_WORKFLOW_OVERPAYMENT_DETECTED` | MEDIUM | Excess flagged as review issue |
| `IN_WORKFLOW_ALLOCATION_REVERSED` | LOW | Allocation reversed on match rejection |

---

## 13. Cross-References

- `invoice_schema.md`
- `invoice_payment_allocations_schema.md`
- `matching_policy.md`
- `credit_note_allocation_schema.md`
- `split_payment_relationship_schema.md`
- `out_adjustment_policies.md`
- `mobile_write_rejection_endpoints.md`
