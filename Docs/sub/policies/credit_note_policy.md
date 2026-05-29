# Policy: Credit Note Creation and Application

## Scope

This policy governs when credit notes may be created, how they are numbered, how they may be applied to invoices, and how period locking interacts with credit note operations.

---

## 1. When Credit Notes May Be Created

A credit note may only be created against an invoice in one of the following statuses:

- `SENT`
- `PARTIALLY_PAID`
- `PAID`
- `OVERDUE`

Credit notes may **not** be created against invoices in `DRAFT` or `VOID` status.

- A `DRAFT` invoice has not been sent and can be edited directly. If lines need removal the draft should be modified, not credited.
- A `VOID` invoice has been cancelled and carries no balance. There is nothing to credit.

Attempting to create a credit note against a `DRAFT` or `VOID` invoice returns error `INVALID_INVOICE_STATUS_FOR_CREDIT_NOTE`.

The credit note creation request must include: the source invoice ID, a reason code, a credit amount, and the user ID of the creating accountant.

---

## 2. Credit Note Series and Number Assignment

Credit notes are assigned a series number in the format `CN-YYYY-NNNN` where:

- `YYYY` is the calendar year of issuance.
- `NNNN` is a zero-padded sequential integer, reset to `0001` at the start of each calendar year.

The series number is assigned **at the moment the credit note status transitions to `ISSUED`**. A credit note in a pre-issue state has no series number (`credit_note_number = null`).

Series numbers are assigned via the `credit_note_sequence` table which uses a row-level lock to prevent gaps or duplicates. The sequence is per-business-entity, not global. Two business entities on the same platform will each maintain their own `CN-` sequence independently.

Once assigned, a series number is immutable. Voiding a credit note does not reclaim the number; the gap is documented in the sequence table with a `VOID` reason.

---

## 3. Maximum Credit Note Value

A credit note cannot exceed the net value of the original invoice it references.

- `credit_note.credit_amount` must be ≤ `source_invoice.invoice_total`
- This constraint is enforced at creation time and cannot be overridden by any role.
- If multiple credit notes are raised against the same invoice (permitted — see section 4), the **cumulative** credit note value across all non-void credit notes for that invoice must not exceed `invoice.invoice_total`.

The enforcement SQL check:

```sql
SELECT COALESCE(SUM(credit_amount), 0)
FROM credit_notes
WHERE source_invoice_id = :invoice_id
  AND status NOT IN ('VOID');
-- result + :new_credit_amount must be <= source_invoice.invoice_total
```

Exceeding the cap returns `CREDIT_NOTE_WOULD_EXCEED_INVOICE_VALUE`.

---

## 4. Partial Credit Notes

Partial credit notes — where `credit_amount < source_invoice.invoice_total` — are permitted.

Use cases include:
- Crediting a single incorrectly priced line item while other lines remain valid.
- Issuing a goodwill credit for part of a service fee.
- Partial dispute resolution.

There is no minimum credit note value other than `> 0.00`.

---

## 5. Applying Credit Notes to Multiple Invoices

A single credit note may be applied to more than one invoice, provided:

- The total applied amount across all applications does not exceed `credit_note.credit_amount`.
- Each application is recorded as a separate row in `credit_note_allocations`.
- Each target invoice belongs to the same `business_entity_id` as the credit note.
- Each target invoice is in an eligible status for application (`SENT`, `PARTIALLY_PAID`, `OVERDUE`).

There is no restriction on the number of invoices a credit note may be applied to. However, applications to invoices in different VAT periods should be reviewed by the accountant for VAT implications.

When the cumulative `consumed_amount` reaches `credit_amount`, the credit note status transitions to `FULLY_APPLIED` automatically. No further applications can be made.

---

## 6. FULLY_APPLIED Status

When `credit_note.consumed_amount >= credit_note.credit_amount`, the credit note status transitions to `FULLY_APPLIED`. This transition is performed atomically within the same transaction as the final application.

A `FULLY_APPLIED` credit note:
- Cannot receive further applications.
- Remains visible in the credit note register for audit purposes.
- Contributes to VAT reporting for the period in which it was issued.

---

## 7. Period Lock Interaction

Credit notes in a locked period are immutable. The following operations are blocked when the credit note's issuance period is locked:

- Modifying credit note metadata (reason, amount).
- Voiding the credit note.
- Reversing an existing allocation.

Creating a **new** credit note referencing an invoice from a locked period is permitted, provided the credit note's own issuance period is unlocked. The credit note will have its own issuance date and will be attributed to the current open period.

Applying a credit note to an invoice in a **locked period** is blocked. The application would modify the invoice balance, which is a write to a locked period record.

---

## 8. Voiding a Credit Note

A credit note in `ISSUED` status with `consumed_amount = 0` may be voided. The status transitions to `VOID`. A void reason is required.

A credit note that has been partially or fully applied (`consumed_amount > 0`) cannot be voided. The accountant must first reverse or remove the allocations before voiding.

## 9. VAT Treatment

For Cyprus VAT purposes, a credit note reduces the taxable value of the original supply in the period it is issued. The VAT component of the credit note (`credit_vat_amount = credit_net_amount * vat_rate`) is deducted from the output VAT liability in the issuing period.

The `vat_rate` on the credit note must match the `vat_rate` of the original invoice line items being credited. If a credit note spans multiple VAT rates (for example, crediting lines at both 9% and 19%), the credit note must record separate `credit_note_lines` with the corresponding rates. The system will allocate VAT treatment per line during VAT period reporting.

---

## Related Documents

- `tools/tool_credit_note_create.md` — Tool that creates and issues credit notes.
- `tools/tool_credit_note_apply.md` — Tool that applies credit notes to invoices.
- `schemas/credit_note_schema.md` — Column definitions and status enum for credit notes.
- `schemas/credit_note_allocation_schema.md` — Allocation records linking credit notes to invoices.
- `schemas/credit_note_cumulative_cap_schema.md` — Cumulative cap enforcement schema.
- `policies/invoice_credit_note_link_policy.md` — Invoice-side rules for credit note eligibility.
- `policies/period_lock_policy.md` — Period lock rules that constrain credit note modifications.
- `policies/invoice_lifecycle_policy.md` — Full invoice status lifecycle including credit note effects.
