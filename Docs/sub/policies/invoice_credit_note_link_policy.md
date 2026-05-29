# Invoice Credit Note Link Policy

**Category:** Policies · Block 13 — IN Workflow + Invoice Generator  
**Owner:** in_workflow  
**Last updated:** 2026-05-16

---

## 1. Purpose

This policy governs how credit notes attach to and offset tax invoices. It defines link eligibility, credit amount constraints, status lifecycles, allocation timing, VAT reversal requirements, and void procedures.

---

## 2. Link Definition

A credit note (CN series) is issued against a specific tax invoice. The `credit_notes.linked_invoice_id` foreign key references the invoice the credit note offsets. This link is immutable after the credit note is created — it cannot be repointed to a different invoice.

One invoice may have multiple credit notes linked to it, subject to the cumulative cap in section 4.

---

## 3. Credit Note Eligibility

A credit note may only be issued against an invoice in one of the following statuses:

| Invoice Status | Credit Note Allowed |
|----------------|---------------------|
| `SENT` | Yes |
| `PARTIALLY_PAID` | Yes |
| `PAID` | Yes |
| `DRAFT` | No |
| `VOID` | No |
| `OVERDUE` | Yes (OVERDUE is a derived state of SENT) |

Attempting to issue a credit note against a `DRAFT` or `VOID` invoice returns a `CREDIT_NOTE_INELIGIBLE_INVOICE_STATUS` error.

---

## 4. Partial Credit

A credit note amount may be less than the invoice total. The constraint is:

```
sum(credit_notes.amount WHERE linked_invoice_id = invoice.id AND status != 'VOID')
  <= invoice.total_amount
```

This cumulative cap is defined in `credit_note_cumulative_cap_schema.md` and enforced at write time by a database constraint trigger. Attempting to issue a credit note that would cause the cumulative sum to exceed `invoice.total_amount` returns `CREDIT_NOTE_CAP_EXCEEDED`.

Multiple credit notes may be issued against the same invoice as long as the cumulative constraint is satisfied.

---

## 5. Full Reversal

**Condition:** `credit_note.amount = invoice.total_amount` (and no other credit notes exist against the invoice, or the cumulative reaches the full amount)

**Outcome:**
- The invoice is considered fully reversed.
- `invoice.status` transitions to `VOID`.
- The credit note's status transitions to `APPLIED`.
- The link is recorded as a full reversal in the `credit_note_allocation` record (`is_full_reversal = true`).

A VOID invoice resulting from a full credit note reversal is distinct from a manually voided invoice. The `void_reason` column on the invoice is set to `CREDIT_NOTE_FULL_REVERSAL`.

---

## 6. Credit Note Status Lifecycle

```
DRAFT -> ISSUED -> APPLIED -> (terminal)
          |
          v
         VOID
```

| Status | Description |
|--------|-------------|
| `DRAFT` | Created but not yet issued to the client |
| `ISSUED` | Issued and available for allocation |
| `APPLIED` | Fully allocated against the linked invoice |
| `VOID` | Cancelled; allocation (if any) reversed |

Transitions:
- `DRAFT -> ISSUED`: via `in_workflow.issue_credit_note`; triggers allocation (section 7)
- `ISSUED -> APPLIED`: automatic when allocation fully covers the linked invoice balance
- `ISSUED -> VOID` or `APPLIED -> VOID`: requires OWNER or ADMIN with step-up auth (section 9)

---

## 7. Allocation Timing

The credit note is allocated at `ISSUED` time. When `in_workflow.issue_credit_note` is called:

1. Credit note status transitions from `DRAFT` to `ISSUED`.
2. A `credit_note_allocation` record is created immediately, linking the credit note to the invoice.
3. The invoice's outstanding balance is recalculated.
4. If the balance reaches zero (within `±€0.01` tolerance), `invoice.status` is updated to `PAID` or `VOID` (see section 5).

Audit event emitted: `IN_WORKFLOW_CREDIT_NOTE_APPLIED` (LOW).

Allocation records are persisted in the `credit_note_allocation_schema.md` table. The `allocated_amount` on the credit note is set to the lesser of the credit note amount and the invoice's outstanding balance at allocation time.

---

## 8. VAT Reversal

Issuing a credit note creates a reverse VAT entry of equal and opposite value to the VAT recorded on the original invoice. The reverse VAT entry:

- References the original invoice's `vat_entry_id` via `reverse_of_vat_entry_id`.
- References the credit note via `credit_note_id`.
- Uses the same `vat_rate` and `vat_amount` (negated) as the original invoice VAT entry.
- Is written to `vat_entries` with `entry_type = 'CREDIT_NOTE_REVERSAL'`.

The reverse VAT entry is created atomically within the same transaction as the credit note issuance. If the VAT entry write fails, the entire issuance is rolled back.

For FX invoices, the reverse VAT entry stores amounts in both the original currency and EUR, using the `fx_rate` from the original invoice.

---

## 9. Credit Note Void

A credit note in `ISSUED` or `APPLIED` status may only be voided by a user with the `OWNER` or `ADMIN` role who has completed step-up authentication.

Void procedure:
1. Step-up token with `purpose = WORKFLOW_APPROVAL` is validated.
2. The credit note's `status` is set to `VOID` and `voided_at` is recorded.
3. The `credit_note_allocation` record is reversed (`reversed_at` set).
4. The reverse VAT entry is itself reversed (a new VAT entry with `entry_type = 'CREDIT_NOTE_VOID_REVERSAL'`).
5. `invoice.status` is recalculated based on remaining payment allocations.

Audit event emitted: `IN_WORKFLOW_CREDIT_NOTE_VOIDED` (MEDIUM).

**Period lock constraint:** Credit notes in a FINALIZED period cannot be voided. Attempting this returns `PERIOD_LOCKED`.

---

## 10. Tools

| Tool | Action |
|------|--------|
| `in_workflow.issue_credit_note` | Issues credit note; creates allocation and VAT reversal |
| `in_workflow.void_credit_note` | Voids an ISSUED or APPLIED credit note (requires step-up) |
| `data.get_credit_note` | Retrieves credit note with allocation summary |

All `in_workflow` WRITE tools: see `mobile_write_rejection_endpoints.md` — write operations are rejected on mobile clients.

---

## 11. Audit Events

| Event | Severity | Trigger |
|-------|----------|---------|
| `IN_WORKFLOW_CREDIT_NOTE_LINKED` | LOW | Credit note created with `linked_invoice_id` set |
| `IN_WORKFLOW_CREDIT_NOTE_APPLIED` | LOW | Credit note allocated against invoice at ISSUED time |
| `IN_WORKFLOW_CREDIT_NOTE_VOIDED` | MEDIUM | Credit note voided with allocation reversed |

---

## 12. Cross-References

- `credit_note_schema.md`
- `credit_note_allocation_schema.md`
- `credit_note_cumulative_cap_schema.md`
- `invoice_schema.md`
- `invoice_amendment_policy.md`
- `archive_step_up_policy.md`
- `mobile_write_rejection_endpoints.md`
