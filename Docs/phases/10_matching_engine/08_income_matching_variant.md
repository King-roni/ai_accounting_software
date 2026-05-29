# Block 10 — Phase 08: Income Matching Variant

## References

- Block doc: `Docs/blocks/10_matching_engine.md` (forward note: variant for IN_MONTHLY)
- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (Income Matching Outcomes section)
- Decisions log: `Docs/decisions_log.md` (Multiple-invoices-one-payment always requires user confirmation; pro-forma cannot match)

## Phase Goal

Build the IN-side matching variant that runs inside `IN_MONTHLY`. Same scoring engine (Phase 02), different candidate set (internal `Invoice` records from Block 13's Invoice Generator instead of externally discovered documents), and different outcomes (the seven IN-specific outcome types from Block 13's contract). After this phase, an incoming bank payment can be matched to one or more invoices, the invoice's lifecycle status (`SENT`, `PARTIALLY_PAID`, `PAID`, `OVERPAID`) is updated correctly, and ambiguous cases route to the review queue.

## Dependencies

- Phase 02 (scoring engine — reused with IN-side candidate set)
- Phase 04 (split-payment combinatorial detection — used for `MULTIPLE_INVOICES_ONE_PAYMENT`)
- Phase 06 (rejection memory — applies to IN-side too)
- Block 04 Phase 02 (`transactions` — IN-side transaction types)
- Block 13 (Invoice Generator — produces the candidate `Invoice` records)

## Deliverables

- **Candidate set for IN-side matching:**
  - `Invoice` records for the business with status in `{SENT, PAYMENT_EXPECTED, PARTIALLY_PAID, OVERPAID}`.
  - **Status rationale:**
    - `SENT` — issued and dispatched to client; the canonical "awaiting payment" state.
    - `PAYMENT_EXPECTED` — same intent as `SENT` but with an explicit reminder cycle in flight; still awaiting payment, still a candidate.
    - `PARTIALLY_PAID` — already received some payment but not full amount; remaining balance is still expected, so additional incoming payments must be candidates (this drives the `ONE_INVOICE_MULTIPLE_PAYMENTS` outcome).
    - `OVERPAID` — already received more than expected; **kept in the candidate set only** to handle the edge case of a refund-then-repayment cycle where the user reverses the overpayment and a new payment arrives — typically scored low-confidence and routed to review. If Block 13's decomposition decides `OVERPAID` is a terminal-final state, this entry is removed by a follow-up edit; for now, keeping it eligible is the safer Stage 1 default.
  - **Excluded:** `DRAFT` (not issued), `CANCELLED`, `REFUNDED`, `PAID` (fully resolved), and `PRO_FORMA` invoices.
  - Cross-period look-back applies (Phase 02's 1–2 month window) — invoices issued in prior periods can still match incoming payments.
  - **Pro-forma invoices are NOT candidates** (Stage 1) — the scoring engine filters them out before pair evaluation.
  - **Cross-block dependency (durable contract):** this filter relies on Block 13's `Invoice` schema exposing a discriminator field. Block 10 commits to using either `Invoice.invoice_type ∈ {PRO_FORMA, TAX}` (preferred) or a boolean `Invoice.is_pro_forma` — Block 13's decomposition must provide one of these. The Block 11/13 phase decomposition that introduces the `Invoice` table is responsible for honoring this contract; if it lands without the discriminator, this phase's tests fail and Block 13 must add the column before INCOME_MATCHING is wired.
- **IN-side signal weighting** (uses Phase 02's signal computation but with different weights):
  - **Invoice number / payment reference** is the dominant signal — strong weight, often the deciding factor for `FULL_MATCH`.
  - **Client name + amount + currency** is the secondary cluster.
  - **Client bank info** (if known from prior payments) — medium signal.
  - **Date proximity** — uses Phase 02's ±3/±10/±30 day windows, with `invoice_issue_date` and `due_date` as references.
- **`income_match_outcome` computation** — for each `(transaction, invoice)` candidate pair after Phase 02 scoring, derive the IN-specific outcome:
  - **`FULL_MATCH`** — amount matches invoice total exactly within rounding tolerance.
  - **`PARTIAL_PAYMENT`** — amount < invoice total but ≥ a configurable minimum (default `5%` of invoice total, to avoid noise).
  - **`OVERPAYMENT`** — amount > invoice total beyond rounding tolerance.
  - **`MULTIPLE_INVOICES_ONE_PAYMENT`** — Phase 04's combinatorial detection found a combination of unmatched invoices summing to the transaction amount. **Always requires user confirmation** (Stage 1 — never silent allocation).
    - **IN-side candidate set for combinatorial detection:** the same status-filter as the single-pair candidate set above (`{SENT, PAYMENT_EXPECTED, PARTIALLY_PAID, OVERPAID}`, pro-forma excluded), restricted to invoices for the same client when client identity can be derived from the transaction (counterparty name, IBAN, prior-payment correlation); when client identity is uncertain, the candidate set is widened to all eligible invoices for the business and confidence is correspondingly lowered.
    - **Bounds:** the same 20-candidate / 5-constituent bounds from Phase 04 apply. For invoices specifically, narrowing prefers (a) same-client first, (b) same-currency first, (c) within ±60 days of transaction date.
    - **Allocation outcome:** on user-confirm, each constituent invoice gets its own `match_records` row with `split_payment_flag = true` and `split_payment_group_id = group.id`; the per-invoice lifecycle calls (`invoice.markPaid` or `invoice.markPartiallyPaid` per the allocated amount) are issued individually per the Outcome→lifecycle table above.
  - **`ONE_INVOICE_MULTIPLE_PAYMENTS`** — the matched invoice already has prior `PARTIAL_PAYMENT` matches; this transaction adds to the running total.
  - **`NO_MATCH`** — no invoice candidate above threshold.
  - **`POSSIBLE_REFUND_OR_TRANSFER`** — the incoming amount matches a prior outgoing transaction (likely a refund) or matches a known internal-transfer pattern (own-account counterparty); raises a review issue suggesting the user reclassify the transaction type from `IN_INCOME` to `REFUND_IN` or `INTERNAL_TRANSFER`.
- **Auto-confirm rules for IN-side:**
  - **`FULL_MATCH` with invoice-number-or-reference exact match** → auto-confirms; invoice transitions to `PAID` via Block 13's lifecycle.
  - **`FULL_MATCH` without exact reference** → `MATCHED_NEEDS_CONFIRMATION` (the amount matches but the engine wants the user to confirm the right invoice).
  - **`PARTIAL_PAYMENT`** → `MATCHED_NEEDS_CONFIRMATION`; invoice transitions to `PARTIALLY_PAID` only on user confirmation.
  - **`OVERPAYMENT`** → `MATCHED_NEEDS_CONFIRMATION`; invoice transitions to `OVERPAID` on confirmation; review issue prompts whether to issue a credit note for the surplus.
  - **`MULTIPLE_INVOICES_ONE_PAYMENT`** → always `POSSIBLE_MATCH` (review queue) per Stage 1; user confirms the allocation across invoices.
  - **`ONE_INVOICE_MULTIPLE_PAYMENTS`** → auto-confirms when the running total stays under invoice total; transitions invoice to `PAID` only when total reaches invoice amount.
  - **`POSSIBLE_REFUND_OR_TRANSFER`** → `POSSIBLE_MATCH`; the user can either confirm the invoice match (treating it as legitimate income) or reclassify the transaction type.
- **Invoice lifecycle integration:**
  - Block 13's Invoice Generator owns the lifecycle states; this phase **calls into** Block 13's lifecycle-transition function rather than directly updating invoice rows.
  - **Outcome → lifecycle call mapping (durable contract — function names below are the cross-block contract; Block 13's decomposition must register exactly these names):**
    - `FULL_MATCH` (auto-confirmed) → `invoice.markPaid(invoice_id, transaction_id, paid_amount, paid_at)`
    - `FULL_MATCH` (user-confirmed after `MATCHED_NEEDS_CONFIRMATION`) → same `invoice.markPaid`
    - `PARTIAL_PAYMENT` (user-confirmed) → `invoice.markPartiallyPaid(invoice_id, transaction_id, partial_amount, paid_at)`
    - `OVERPAYMENT` (user-confirmed) → `invoice.markOverpaid(invoice_id, transaction_id, overpaid_amount, paid_at)`
    - `MULTIPLE_INVOICES_ONE_PAYMENT` (user-confirmed allocation) → for each constituent invoice, the appropriate `invoice.markPaid` or `invoice.markPartiallyPaid` based on the allocated amount
    - `ONE_INVOICE_MULTIPLE_PAYMENTS` (running total still under invoice total) → `invoice.markPartiallyPaid`; when the cumulative paid reaches invoice total, `invoice.markPaid`
    - `NO_MATCH` → no lifecycle call
    - `POSSIBLE_REFUND_OR_TRANSFER` → no lifecycle call until user resolves; if user confirms the invoice match, falls through to `FULL_MATCH` path
  - Each transition emits `INVOICE_LIFECYCLE_TRANSITIONED` with the new status and the matching transaction id.
  - **Failure mode:** if Block 13's lifecycle function returns an error (e.g., invoice in unexpected state), the matching tool does NOT silently swallow it — it emits `INVOICE_LIFECYCLE_TRANSITION_FAILED` with the error payload and raises a HIGH-severity review issue in `'Possible Wrong Match'`. The `match_records` row is left in `MATCHED_NEEDS_CONFIRMATION` until the user reconciles.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `INCOME_MATCHING` for the IN-side variant):
  - `INCOME_MATCHING_OUTCOME_FULL_MATCH`
  - `INCOME_MATCHING_OUTCOME_PARTIAL_PAYMENT`
  - `INCOME_MATCHING_OUTCOME_OVERPAYMENT`
  - `INCOME_MATCHING_OUTCOME_MULTIPLE_INVOICES_ONE_PAYMENT`
  - `INCOME_MATCHING_OUTCOME_ONE_INVOICE_MULTIPLE_PAYMENTS`
  - `INCOME_MATCHING_OUTCOME_NO_MATCH`
  - `INCOME_MATCHING_OUTCOME_POSSIBLE_REFUND_OR_TRANSFER`
  - `INVOICE_LIFECYCLE_TRANSITIONED` (cross-block; emitted by Block 13's lifecycle function)
  - `INVOICE_LIFECYCLE_TRANSITION_FAILED` (cross-block; emitted on lifecycle call error)

## Definition of Done

- An IN_INCOME transaction with amount matching an outstanding invoice's total exactly (and matching invoice number) auto-confirms; the invoice transitions to `PAID`.
- A partial-amount IN_INCOME transaction routes to `MATCHED_NEEDS_CONFIRMATION`; on user confirm, the invoice goes to `PARTIALLY_PAID`.
- A `MULTIPLE_INVOICES_ONE_PAYMENT` candidate is surfaced to the review queue and never silently allocated (verified by absence of any auto-allocation in the audit trail).
- A pro-forma invoice is correctly filtered out of the candidate set (verified via test).
- A `POSSIBLE_REFUND_OR_TRANSFER` outcome surfaces the right review issue suggesting reclassification.
- Tests cover all seven outcome types plus the pro-forma exclusion.

## Sub-doc Hooks (Stage 4)

- **IN-side signal weighting sub-doc** — exact weights, calibration vs OUT-side weights.
- **Partial-payment minimum threshold sub-doc** — the `5%`-of-total rule, edge cases.
- **Invoice lifecycle integration sub-doc** — the contract between Block 10 Phase 08 and Block 13's lifecycle functions.
- **Refund detection rule sub-doc** — when to suggest reclassification, audit shape.
