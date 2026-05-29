# Block 13 — Phase 03: Invoice Composition & Lifecycle State Machine

## References

- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (Capabilities — Invoice composition; Invoice Lifecycle; Multi-Currency Invoicing)
- Block doc: `Docs/blocks/10_matching_engine.md` (Phase 08 — `invoice.markPaid` / `invoice.markPartiallyPaid` / `invoice.markOverpaid` named lifecycle functions)
- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (Phase 07 — IN_INCOME ledger path consumes the invoice's lifecycle status)
- Decisions log: `Docs/decisions_log.md` (multi-currency invoices locked at issued currency)

## Phase Goal

Implement invoice composition (line items, totals, currency lock) and the full lifecycle state machine: every transition the architecture doc allows, the named lifecycle functions Block 10 Phase 08 commits to consuming, and the rules that protect immutability after `FINALIZED`. After this phase, the Invoice Generator is functionally complete for tax-invoice happy paths; Phases 04–06 add PDF rendering, recurring templates, pro-forma conversion, credit notes, and write-off.

## Dependencies

- Phase 01 (`invoices`, `invoice_lines`)
- Phase 02 (`clients` for default pull-through)
- Block 02 Phase 04 (permission matrix — composition is `INVOICE_MANAGE` surface, Owner / Admin / Bookkeeper)
- Block 03 Phase 04 (state-machine pattern — invoices have their own lifecycle state machine, distinct from `workflow_runs`)
- Block 05 Phase 02 (audit log — every transition emits an audit event per the architecture doc's "every invoice transition still emits an audit event")
- Block 11 Phase 09 (consumer — `LEDGER_PREPARATION` reads `lifecycle_status`)

## Deliverables

- **Composition API:**
  - `invoice.create({ business_id, client_id, invoice_type, currency, issue_date, supply_date?, due_date, vat_treatment_per_line }) → invoice` — creates a `DRAFT` invoice. `currency` defaults to `clients.default_currency`; `due_date` defaults to `issue_date + clients.default_payment_terms_days`.
  - `invoice.addLine({ invoice_id, description, quantity, unit_price, vat_treatment?, vat_rate_pct? }) → invoice_line` — appends a line; `currency` inherited from invoice; line totals computed.
  - `invoice.removeLine({ invoice_line_id })` — only allowed while invoice is `DRAFT`.
  - `invoice.recomputeTotals({ invoice_id }) → invoice` — re-derives `subtotal_amount`, `vat_amount`, `total_amount` from the current line set; called automatically on line add / remove / update; can be called manually after a bulk edit.
  - **`DRAFT`-only edits:** all composition mutations require `lifecycle_status = DRAFT`. Once an invoice transitions out of `DRAFT`, the composition is immutable except for explicit lifecycle transitions (e.g., `markWrittenOff`).
- **Multi-currency lock rule:**
  - `invoices.currency` is set at `create` time and is **immutable** through the entire lifecycle. There is no API to change an invoice's currency post-`DRAFT`. Sub-doc tracks the rare case of a currency-change request; Stage 1 default: void via credit note + issue a fresh invoice in the new currency.
  - `invoice_lines.currency` must equal `invoices.currency`; mismatched lines are rejected at insert.
  - When a payment arrives in a different currency, FX is handled at Block 10 Phase 02's matching engine using the bank-recorded rate (per the Stage 1 FX decision); the invoice itself is never repriced.
- **Lifecycle state machine** (canonical transitions; one transition function per arrow; each emits an audit event):

  ```
  DRAFT
    │  (invoice.send / mark sent)
    ▼
  SENT
    │  (auto-progression after send)
    ▼
  PAYMENT_EXPECTED ──────► WRITTEN_OFF (user-initiated; bad-debt-expense routing)
    │  (matching outcomes)
    ├──► PARTIALLY_PAID ──► PAID
    ├──► PAID
    ├──► OVERPAID
    ├──► REFUNDED            (refund matching)
    │
    └──► CREDITED            (credit note issued — Phase 06)
                              │
                              ▼
                            FINALIZED (period locks; terminal)
  ```

  - **Transitions and named lifecycle functions** (the contracts Block 10 Phase 08 calls into):
    - **`invoice.markSent({ invoice_id, sent_by, sent_at })`** — `DRAFT → SENT`. Allocates the `INV-YYYY-NNNN` number atomically (via Phase 01's allocator) if not already allocated. Sets `lifecycle_status = SENT`. Optional: triggers `invoice.send_email` (out of MVP scope; sub-doc).
    - **`invoice.markPaymentExpected({ invoice_id })`** — `SENT → PAYMENT_EXPECTED`. Auto-fired by a daily background job when an invoice's `sent_at + 1 day` arrives (sub-doc owns the timing); user-callable as well.
    - **`invoice.markPaid({ invoice_id, transaction_id, paid_amount, paid_at })`** — moves to `PAID`. Called by Block 10 Phase 08's IN-side matcher (the canonical contract). Validates `paid_amount` matches `total_amount` within rounding tolerance (per Block 11 Phase 08's rounding rule); a mismatch routes through `markPartiallyPaid` or `markOverpaid` instead.
    - **`invoice.markPartiallyPaid({ invoice_id, transaction_id, partial_amount, paid_at })`** — moves to `PARTIALLY_PAID`. Tracks the running total via `invoice_payment_allocations` (declared below). When the cumulative paid reaches `total_amount`, an internal `invoice.markPaid` is called automatically.
    - **`invoice.markOverpaid({ invoice_id, transaction_id, overpaid_amount, paid_at })`** — moves to `OVERPAID`. The `overpaid_amount` is the surplus over `total_amount`. Phase 08 of Block 10 raises a review issue suggesting a credit note for the surplus.
    - **Exits from `OVERPAID`:** the state has two valid exits:
      - `OVERPAID → REFUNDED` via `invoice.markRefunded` when the user issues a refund for the surplus and a `REFUND_OUT` transaction matches the refund payment.
      - `OVERPAID → CREDITED` via `invoice.markCredited` when the user issues a credit note for the surplus amount instead of refunding (Phase 06's `creditNote.issue` against the OVERPAID invoice for `surplus = paid_amount - total_amount`); the source invoice transitions to `CREDITED` when the credit note's amount equals the unrefunded surplus.
      - Without an explicit refund or credit note, the OVERPAID invoice eventually transitions to `FINALIZED` via Block 15's lock when the period closes — the surplus carries forward as a customer credit balance (sub-doc tracks the customer-credit-tracking pattern; Stage 1 default: surface as a `Possible Tax/VAT Issue` until resolved before finalization).
    - **`invoice.markRefunded({ invoice_id, refund_transaction_id, refunded_at })`** — moves to `REFUNDED`. Called when a `REFUND_OUT` transaction (handled by OUT_FILTER per Block 12) is matched as a refund of this invoice.
    - **`invoice.markWrittenOff({ invoice_id, written_off_by, written_off_at, reason })`** — moves to `WRITTEN_OFF`. **User-initiated only** (no automatic trigger). Routes through Block 11 Phase 07's bad-debt-expense ledger path.
    - **`invoice.markCredited({ invoice_id, credit_note_id, credited_at })`** — moves to `CREDITED`. Called by Phase 06's credit-note issuance. The full-amount credit note voids the invoice; a partial credit note returns the invoice to its pre-credit lifecycle status (sub-doc owns the partial-credit semantics).
    - **`invoice.markFinalized({ invoice_id, finalized_in_run_id, finalized_at })`** — moves to `FINALIZED`. Called by Block 15's `FINALIZATION` phase when the `IN_MONTHLY` period containing this invoice locks. Terminal — no further transitions allowed.
    - **`invoice.markConvertedToTaxInvoice({ pro_forma_invoice_id, tax_invoice_id, converted_by, converted_at })`** — moves the source pro-forma to `CONVERTED_TO_TAX_INVOICE` (terminal pro-forma state). Called by Phase 06's conversion path. The source pro-forma is no longer eligible for any further transitions; the new tax invoice (created by Phase 06) follows the standard tax-invoice sub-machine.
- **`invoice_payment_allocations` table** (declared here; consumed by Block 10 Phase 08):
  - `id` (UUID v7), `organization_id`, `business_id`
  - `invoice_id` (FK to `invoices`)
  - `transaction_id` (FK to `transactions`)
  - `match_record_id` (FK to `match_records`; nullable for pre-match allocations)
  - `allocated_amount` (numeric; in invoice currency)
  - `allocated_at` (timestamp), `allocated_by` (FK to `users` — system or user)
  - `allocation_kind` (enum: `FULL`, `PARTIAL`, `OVERPAYMENT_PRIMARY`, `OVERPAYMENT_SURPLUS`, `REFUND`, `MULTI_INVOICE_USER_CONFIRMED`):
    - **`FULL`** — single payment fully covers the invoice's `total_amount`; one row.
    - **`PARTIAL`** — single payment is less than the invoice's residual unpaid; one row.
    - **`OVERPAYMENT_PRIMARY`** — the portion of an overpayment equal to the invoice's `total_amount`; paired with an `OVERPAYMENT_SURPLUS` row.
    - **`OVERPAYMENT_SURPLUS`** — the surplus portion of an overpayment (`paid_amount - total_amount`); paired with `OVERPAYMENT_PRIMARY`. Two rows are created in the same transaction so reports can disambiguate the legitimate-payment portion from the surplus.
    - **`REFUND`** — a `REFUND_OUT` transaction matched against this invoice; the row's `allocated_amount` is negative or recorded as a separate refund-direction marker (sub-doc tracks the convention).
    - **`MULTI_INVOICE_USER_CONFIRMED`** — one of multiple rows produced by Phase 10's `confirm_multi_invoice_allocation`; each invoice gets one row of this kind, all sharing the same `transaction_id` and `match_record_id`.
  - **Indexes:** `(invoice_id)`, `(transaction_id)`.
  - **RLS** per Block 02 Phase 05.
- **Transition guards (no illegal transitions allowed; runtime-enforced):**
  - `DRAFT` is the only mutable composition state; transitions out of `DRAFT` lock the line items.
  - `FINALIZED` is terminal; the only path back is an `IN_ADJUSTMENT` run (Phase 11), which produces additive adjustment records but never modifies the locked invoice.
  - `WRITTEN_OFF`, `REFUNDED`, `CREDITED` are non-payable terminal states (modulo `FINALIZED`); the matcher (Block 10 Phase 08) skips invoices in these states.
- **Pro-forma lifecycle restriction:**
  - Pro-forma invoices follow a restricted sub-machine: `DRAFT → SENT → CONVERTED_TO_TAX_INVOICE` (a new state; Phase 06 owns the conversion). Pro-formas can NEVER reach `PAID`, `PARTIALLY_PAID`, etc. — they are not match candidates per Block 10 Phase 08. Phase 06 owns the conversion contract.
- **Re-derivation safety on user edits:**
  - Editing an `invoice_line` while `DRAFT` triggers `recomputeTotals`. After exit from `DRAFT`, line edits are blocked entirely; the user must void via credit note or, if still pre-send, transition back to `DRAFT` is **not allowed** (Stage 1 — a sent invoice cannot return to draft; sub-doc tracks the edge case for invoices accidentally sent).
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `INVOICE`):
  - `INVOICE_LINE_ADDED`, `INVOICE_LINE_UPDATED`, `INVOICE_LINE_REMOVED`
  - `INVOICE_TOTALS_RECOMPUTED`
  - **One audit event per lifecycle transition** (matches the architecture doc's "every invoice transition still emits an audit event"):
    - `INVOICE_SENT`, `INVOICE_PAYMENT_EXPECTED`, `INVOICE_MARKED_PAID`, `INVOICE_MARKED_PARTIALLY_PAID`, `INVOICE_MARKED_OVERPAID`, `INVOICE_MARKED_REFUNDED`, `INVOICE_MARKED_WRITTEN_OFF`, `INVOICE_MARKED_CREDITED`, `INVOICE_FINALIZED`, `INVOICE_PRO_FORMA_CONVERTED_TO_TAX` (Phase 06; renamed from the prior `INVOICE_CONVERTED_TO_TAX_INVOICE` to disambiguate from the lifecycle-status value `CONVERTED_TO_TAX_INVOICE`)
  - `INVOICE_LIFECYCLE_TRANSITION_FAILED` (Block 10 Phase 08's contract; emitted when a lifecycle function rejects a transition — e.g., trying to `markPaid` an already-`PAID` invoice)
  - `INVOICE_PAYMENT_ALLOCATION_CREATED` (per row added to `invoice_payment_allocations`)

## Definition of Done

- A user composes a `DRAFT` invoice with three lines; totals re-compute correctly on each edit.
- Currency is set at creation; attempting to change currency post-creation is rejected.
- Calling `invoice.markSent` allocates the `INV` number atomically and emits the right audit event.
- Block 10 Phase 08's IN-side matcher calls `invoice.markPaid` for a clean payment match → `lifecycle_status = PAID`; calls `invoice.markPartiallyPaid` → `PARTIALLY_PAID` with an `invoice_payment_allocations` row; cumulative partial payments reaching `total_amount` auto-transition to `PAID`.
- Calling a transition function from an illegal source state returns `INVOICE_LIFECYCLE_TRANSITION_FAILED` (e.g., `markPaid` on a `WRITTEN_OFF` invoice).
- A `FINALIZED` invoice rejects every transition; the only path back is via `IN_ADJUSTMENT`.
- Pro-forma invoices cannot reach `PAID` / `PARTIALLY_PAID` / etc.; only the restricted sub-machine transitions are allowed.
- Every transition emits the right audit event with the user / system actor recorded.
- Tests cover every transition arrow + the pro-forma restriction + the multi-currency lock + the `DRAFT`-only mutability rule.

## Sub-doc Hooks (Stage 4)

- **Lifecycle state-machine sub-doc** — the formal transition table; per-transition guards; rejection error messages.
- **`invoice_payment_allocations` sub-doc** — the running-total calculation; reconciliation when an allocation is corrected.
- **Partial-credit-note semantics sub-doc** — what happens to lifecycle when a credit note covers part (not all) of an invoice.
- **`SENT → PAYMENT_EXPECTED` auto-trigger sub-doc** — exact timing, daily-job integration.
- **Recompute-on-edit performance sub-doc** — bulk-edit pattern, transactionality of total recomputation.
- **Currency-change voiding sub-doc** — the canonical flow for a wrong-currency invoice (void via credit note, reissue).
