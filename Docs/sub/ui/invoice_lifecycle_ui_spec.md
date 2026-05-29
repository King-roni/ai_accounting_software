# Invoice Lifecycle UI Spec

**Category:** UI · **Owning block:** 13 — IN Workflow + Invoice Generator · **Block reference:** Block 13 § Phase 04 (Invoice Generator), Phase 06 (Income Matching) · **Stage:** 4 sub-doc (Layer 2 UI spec)

**Purpose:** Defines the visual state machine, allocation panel, credit note flow, amendment wizard, and mobile constraints for the invoice lifecycle UI. This spec is the binding reference for front-end implementation. It covers the accountant-facing surfaces only; client-facing invoice PDFs are governed by a separate spec.

---

## State machine display

Invoice status is shown as a horizontal stepper with three primary states:

```
DRAFT  ──────►  SENT  ──────►  PAID
```

Each step is a labelled node. The active state has a filled indicator; past states have a check mark; future states are outlined. The stepper is read-only — status transitions are triggered by action buttons, not by clicking the stepper.

### Off-path states

Two states are off the primary path and are displayed as side-labels, not stepper nodes:

| State | Display location | Visual treatment |
| --- | --- | --- |
| `VOID` | Below the stepper, between SENT and PAID | Red label "Voided" with a strikethrough on the SENT → PAID edge |
| `OVERDUE` | As an overlay badge on the SENT node | Amber badge "Overdue" shown when `due_date < today` and `status = SENT` |

`OVERDUE` is a derived display state, not a database status value. The database `status` remains `SENT`; the UI computes overdue display from `due_date`. The `OVERDUE` badge is removed as soon as a payment is recorded or the invoice is voided.

### Credit note display

Credit notes are displayed as a linked sub-item directly below the parent invoice in the invoice list and in the invoice detail view. Layout:

```
INV-2026-0042    €1,450.00    PAID    [action buttons]
  └─ CN-2026-0003   -€450.00   ISSUED  [view credit note]
```

The credit note row is indented and prefixed with a "└─" visual indicator. Clicking the credit note row navigates to the credit note detail view. If multiple credit notes exist for the same parent invoice, they are each shown as separate indented rows.

---

## Multi-invoice allocation UX

When a payment transaction matches multiple invoices (detected by the income matching engine and signalled by `IN_MULTI_INVOICE_ALLOCATION_PROPOSED`), the payment record displays an allocation panel instead of a single match confirmation.

### Allocation panel

The allocation panel is a table with one row per matched invoice:

| Column | Content |
| --- | --- |
| Invoice number | Clickable link to invoice detail |
| Client | Client canonical name |
| Invoice total | Total invoice amount (EUR) |
| Outstanding | Pre-allocation outstanding balance |
| Allocated amount | Editable numeric input (EUR, two decimal places) |

**Invariants enforced by the UI:**

- The sum of all `allocated_amount` values must equal the transaction amount. A running total is shown at the bottom of the table: "Total allocated: €X.XX / €Y.YY (transaction amount)".
- If the total does not equal the transaction amount, a validation error is shown inline and the confirm button is disabled. The allowed tolerance is ±0.01 EUR (to accommodate rounding in multi-currency scenarios). If the discrepancy exceeds ±0.01 EUR, the accountant must adjust the allocation before confirming.
- No individual `allocated_amount` may exceed the invoice's `outstanding_balance`. If it does, the cell shows a red border and a tooltip "Cannot exceed outstanding balance of €X.XX".

**Allocation actions:**

- **Confirm:** Executes the allocation. Emits `IN_MULTI_INVOICE_ALLOCATION_CONFIRMED`. Disabled until the ±0.01 EUR tolerance is satisfied.
- **Edit and confirm:** Available after a prior `CONFIRMED` allocation — re-opens the allocation table for adjustment. Emits `IN_MULTI_INVOICE_ALLOCATION_EDITED_AND_CONFIRMED`.
- **Reject allocation:** Rejects the proposed split. Emits `IN_MULTI_INVOICE_ALLOCATION_REJECTED`. The payment record reverts to unmatched.

If the invariant check fails server-side (e.g., concurrent invoice payment between proposal and confirmation), `IN_ALLOCATION_INVARIANT_VIOLATION_REJECTED` is returned and displayed as an inline error: "Allocation rejected: invoice balance changed. Please refresh and resubmit."

---

## Credit note flow

The "Issue Credit Note" action is available on invoices in `SENT` or `PARTIALLY_PAID` status. It opens a right-anchored side-panel (not a modal).

### Side-panel contents

1. **Header:** "Issue Credit Note for [invoice_number]"
2. **Original invoice summary:** Invoice number, client, total amount, outstanding balance.
3. **Line items table:** Pre-filled with the original invoice's line items. Each row is editable:
   - Description (text, read-only — cannot be changed on a credit note)
   - Quantity (numeric input, defaults to original quantity, max = original quantity)
   - Unit price (numeric input, defaults to original unit price, read-only on credit notes — the quantity field is the adjustment lever)
   - Line total (computed: quantity × unit price, read-only)
4. **Credit note total:** Computed sum of all line totals. Shown as a negative amount (e.g., "-€450.00").
5. **Reason field:** Text area, required, max 500 characters. The reason is stored on the credit note row and is included in the credit note PDF.
6. **Submit button:** "Issue Credit Note". Disabled until reason is non-empty and at least one line item has quantity > 0.
7. **Cancel button:** Closes the panel without action.

### After submission

- A `CN-YYYY-NNNN` sequence number is allocated and the credit note is created in `ISSUED` status.
- `CREDIT_NOTE_ISSUED` is emitted.
- The parent invoice's `outstanding_balance` updates immediately in the UI (optimistic update, confirmed on server response).
- The credit note appears as a linked sub-item below the parent invoice (see "State machine display" above).

---

## Amendment flow

Amending a `SENT` invoice is not an in-place edit. The amendment flow voids the original invoice, issues a credit note, and creates a replacement draft — all presented as a guided 3-step wizard.

### Step 1 — Review original

- Displays the original invoice in read-only form.
- Shows a yellow info banner: "Amending a sent invoice will void the original and issue a credit note. A replacement invoice will be created in draft."
- Action: "Proceed to credit note" or "Cancel".

### Step 2 — Issue credit note

- Same side-panel UI as the credit note flow above, but the reason field is pre-filled with "Amendment of [invoice_number]" and is editable.
- The credit note covers the full original invoice amount (all lines at original quantity). The accountant cannot partially adjust the credit note in the amendment flow — the amendment is always a full void-and-replace.
- Submitting this step: voids the original invoice (emits `INVOICE_VOIDED`), issues the credit note (emits `CREDIT_NOTE_ISSUED`).
- Advancing to Step 3 is blocked until the credit note is successfully issued.

### Step 3 — Create replacement

- Displays a new invoice form pre-filled with the original invoice's line items, client, and due date.
- The accountant adjusts the line items as needed and submits.
- The replacement invoice is created in `DRAFT` status (emits `INVOICE_CREATED`).
- The original invoice's ID is stored on the replacement as `amended_from_invoice_id`.
- The wizard closes after successful creation. The replacement invoice appears in the invoice list in `DRAFT` status.

### Amendment audit trail

The combination of `INVOICE_VOIDED` → `CREDIT_NOTE_ISSUED` → `INVOICE_CREATED` (on the replacement) forms the audit trail. The wizard does not emit a separate `INVOICE_AMENDED` event (that event is reserved for DRAFT invoice edits per `audit_event_taxonomy`).

---

## Mobile behaviour

When `client_form_factor = MOBILE`:

1. **Invoice list:** Read-only. Accountant can view invoice statuses, amounts, and follow links to detail views.
2. **Invoice detail:** Read-only. State machine stepper, credit note sub-items, and allocation panel summary are visible.
3. **Issue, void, and amendment actions:** Blocked. The action buttons are replaced with a soft-prompt banner:

   > "To issue, void, or amend invoices, open this page on a desktop browser."

4. **Allocation panel:** Visible in read-only mode on mobile. The editable amount inputs are replaced with read-only displays. The confirm button is hidden.

Per `mobile_write_rejection_endpoints.md`, the server-side endpoints for issue, void, amendment, and allocation confirm actions return `403 MOBILE_WRITE_REJECTED` for mobile clients.

---

## Cross-references

- `invoice_lifecycle_integration.md` — server-side state machine transitions, eligibility rules per status
- `credit_note_schema.md` — `credit_notes` table structure, `CN-YYYY-NNNN` sequence allocation
- `invoice_amendment_policy.md` — voiding rules, amendment eligibility, amendment audit trail
- `invoice_lines_payload_schema.md` — line item field definitions, quantity/unit-price constraints
- `invoice_sequence_schema.md` — sequence counter table, `INV`, `PRO`, `CN` series allocation rules
- `mobile_write_rejection_endpoints.md` — server-side mobile write blocking
- `audit_event_taxonomy` — `INVOICE_VOIDED`, `CREDIT_NOTE_ISSUED`, `INVOICE_CREATED`, `IN_MULTI_INVOICE_ALLOCATION_CONFIRMED`, `IN_MULTI_INVOICE_ALLOCATION_REJECTED`, `IN_ALLOCATION_INVARIANT_VIOLATION_REJECTED`
- `in_monthly_phase_sequence.md` — which phases drive invoice lifecycle transitions
