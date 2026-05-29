# Block 13 — Phase 10: Income Matching Integration & Multi-Invoice Allocation

## References

- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (Income Matching Outcomes; multi-invoice payment allocation always requires user confirmation; pro-forma cannot match)
- Block doc: `Docs/blocks/10_matching_engine.md` (Phase 08 — IN-side matching variant; the seven outcome types; the candidate-set filter)
- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (Phase 09 — `LEDGER_PREPARATION` consumes match results)
- Decisions log: `Docs/decisions_log.md` (`MULTIPLE_INVOICES_ONE_PAYMENT` always requires user confirmation; pro-forma cannot match; written-off → bad debt expense)

## Phase Goal

Wire Block 10 Phase 08's IN-side matching variant into `IN_MONTHLY` and provide the IN-specific surfaces around it: the candidate-set filter (only `IN_INCOME` and `REFUND_IN`; pro-forma excluded; `INTERNAL_TRANSFER` and `LOAN_OR_SHAREHOLDER_MOVEMENT` skipped), the multi-invoice-allocation user-confirmation flow (the only outcome that always requires user input — Stage 1 explicit decision), and the per-outcome lifecycle calls into Phase 03's named functions. After this phase, `INCOME_MATCHING` is fully integrated into the IN workflow.

## Dependencies

- Phase 01 (`invoices` — the candidate set; `invoice_payment_allocations` table)
- Phase 03 (named lifecycle functions — `invoice.markPaid`, `markPartiallyPaid`, `markOverpaid`, `markRefunded`)
- Phase 06 (pro-forma → tax invoice conversion — surfaces when a pro-forma is the only candidate)
- Phase 07 (`IN_MONTHLY` registration — `INCOME_MATCHING` is sequenced at position 4)
- Phase 08 (`IN_FILTER` produces the in-scope subset)
- Phase 09 (gate functions — `gate.in.income_matching_complete` reads outcomes)
- Block 04 Phase 03 (`match_records` — the matching engine writes there)
- Block 10 Phase 08 (the IN-side variant — produces the seven outcomes)
- Block 14 (review queue — surfaces the multi-invoice-allocation card)

## Deliverables

- **`effective_match_status` IN-side scope (alignment with Block 12 Phase 06):**
  - The `transactions.effective_match_status` column added by Block 12 Phase 06 is **OUT-only** in Stage 1. The IN side does NOT read or write this column. The IN-side gate (`gate.in.income_matching_complete`, Phase 09) reads `match_records.income_outcome` (per Phase 01's schema migration); the OUT-side gate reads `transactions.effective_match_status`. The two columns serve different dimensions and the two workflows do not share the gate logic.
  - Sub-doc tracks the Stage 2+ unification (a single denormalized status column covering both sides) — out of MVP scope.
- **Candidate-set filter for the IN-side matcher** (passed into Block 10 Phase 08's invocation):
  - **Eligible transactions:** rows with `in_workflow_in_scope = true` AND `transaction_type ∈ {IN_INCOME, REFUND_IN}`. Rows of type `INTERNAL_TRANSFER` or `LOAN_OR_SHAREHOLDER_MOVEMENT` (IN direction) are **excluded** from the matcher input — they skip matching entirely and proceed directly to `LEDGER_PREPARATION` per Phase 08's note.
  - **Eligible invoice candidates:** `invoices` rows for the same `business_id` with `invoice_type = TAX` AND `lifecycle_status ∈ {SENT, PAYMENT_EXPECTED, PARTIALLY_PAID, OVERPAID}`. Pro-formas (`invoice_type = PRO_FORMA`) are **excluded** per Phase 01's discriminator. `WRITTEN_OFF`, `REFUNDED`, `CREDITED`, `PAID` (fully resolved), `FINALIZED` (terminal) invoices are excluded. Cross-period look-back applies per Block 10 Phase 02's 1–2 month window.
- **Tool registration** with `engine.registerTool`:
  - **`in_workflow.income_match_outcome`** — wraps Block 10 Phase 08's `matching.income_match_outcome` for `IN_MONTHLY`'s phase sequence. Side-effect: `WRITES_RUN_STATE` (writes `match_records` rows AND triggers invoice lifecycle transitions per the outcome). AI tier: `NONE` (deterministic; Phase 07 of Block 10 handles AI separately for explanations). Idempotent — Block 10 Phase 06's rejection-memory + the unique constraint on `(transaction_id, document_id)` ensure re-runs produce identical match records.
  - **`in_workflow.confirm_multi_invoice_allocation`** — user-driven action: user confirms which invoices a single payment covers and the allocation amounts. Side-effect: `WRITES_RUN_STATE` (creates `invoice_payment_allocations` rows; triggers per-invoice lifecycle calls based on the allocated amount per invoice; transitions the `match_records` row's status from `POSSIBLE_MATCH` to `MATCHED_CONFIRMED`). AI tier: `NONE`.
- **Per-outcome handling** (consumes Block 10 Phase 08's outcomes; calls Phase 03's named lifecycle functions per the Phase 08 → lifecycle table):

  | Outcome | Auto-applied? | Lifecycle call | Review issue raised? |
  | --- | --- | --- | --- |
  | `FULL_MATCH` (with exact invoice-number reference) | Yes — auto-confirms | `invoice.markPaid` | None |
  | `FULL_MATCH` (without exact reference) | No — `MATCHED_NEEDS_CONFIRMATION` | None until user confirms; on confirm, `invoice.markPaid` | `Needs Confirmation` MEDIUM |
  | `PARTIAL_PAYMENT` | No — `MATCHED_NEEDS_CONFIRMATION`; on confirm, `invoice.markPartiallyPaid` | `Needs Confirmation` MEDIUM |
  | `OVERPAYMENT` | No — `MATCHED_NEEDS_CONFIRMATION`; on confirm, `invoice.markOverpaid` | `Needs Confirmation` MEDIUM + a follow-up `Possible Tax/VAT Issue` prompting credit-note for the surplus |
  | `MULTIPLE_INVOICES_ONE_PAYMENT` | **Always requires user confirmation** (Stage 1 — never silent allocation) | None until user confirms via `in_workflow.confirm_multi_invoice_allocation`; per allocated invoice, `invoice.markPaid` or `markPartiallyPaid` per the user's allocation | `Possible Wrong Match` MEDIUM with the proposed allocations |
  | `ONE_INVOICE_MULTIPLE_PAYMENTS` | Yes — auto-confirms (running-total accumulation) | `invoice.markPartiallyPaid` per payment; when cumulative reaches `total_amount`, automatic `invoice.markPaid` | None (informational events only) |
  | `NO_MATCH` | N/A | None | `Missing Documents` HIGH (income received without an invoice — user creates one or marks as non-invoice income) |
  | `POSSIBLE_REFUND_OR_TRANSFER` | No — surfaces as review | None until user resolves | `Possible Wrong Match` MEDIUM with reclassification suggestion (`REFUND_IN` or `INTERNAL_TRANSFER`) |

- **Multi-invoice allocation user-confirmation flow** (Stage 1's explicit decision: never silently allocate):
  - When Block 10 Phase 08 produces `MULTIPLE_INVOICES_ONE_PAYMENT`, the matcher creates a `match_records` row with status `POSSIBLE_MATCH` and writes a proposed-allocation payload (per Block 10 Phase 04's split-payment combinatorial output) to the review issue.
  - The review issue's recommended-action set includes:
    - **`Confirm proposed allocation`** — applies the engine's proposed allocation across invoices; `in_workflow.confirm_multi_invoice_allocation` runs.
    - **`Edit allocation`** — opens a UI dialog letting the user adjust the allocation amounts per invoice; the user submits and `in_workflow.confirm_multi_invoice_allocation` runs with the user's allocation.
    - **`Reject — none of these invoices`** — the proposal is rejected; the `match_records` row transitions to `REJECTED_MATCH`; the rejection feeds into Block 10 Phase 06's rejection-memory (the (transaction, candidate-invoices) pair is remembered as a rejection); the transaction reverts to `NO_MATCH` and surfaces the standard NO_MATCH issue.
  - **Allocation invariants enforced by `confirm_multi_invoice_allocation`** (last line of defense; the candidate-set filter at the top is the first line):
    - Sum of allocated amounts equals the transaction's amount (within Block 11 Phase 08's rounding tolerance — `±0.02`).
    - Each invoice's allocated amount does not exceed its `total_amount` minus any already-allocated cumulative.
    - All target invoices are in the eligible candidate set (still in lifecycle `SENT` / `PAYMENT_EXPECTED` / `PARTIALLY_PAID` / `OVERPAID`).
    - **Every allocation target invoice has `invoice_type = TAX`** — pro-forma invoices are rejected at the allocation layer (in addition to the candidate-set filter); a malicious or buggy client passing a `PRO_FORMA` invoice ID directly is stopped here. Pro-formas remain non-matchable per Stage 1 (Block 10 Phase 08 + Phase 06 conversion path).
    - Violations are rejected with structured error messages.
  - **Per-invoice lifecycle:** for each allocated invoice, the appropriate Phase 03 transition fires:
    - Allocated amount equals `invoice.total_amount` minus prior allocations → `invoice.markPaid`.
    - Allocated amount is less than that → `invoice.markPartiallyPaid`.
    - Allocated amount exceeds the remaining (rare, would mean engine math error) → rejected before the call.
- **Pro-forma exclusion guard** (cross-block contract reinforcement):
  - The candidate-set filter explicitly excludes `invoice_type = PRO_FORMA` rows. If a payment arrives that obviously matches a pro-forma (e.g., the `payment_reference` carries the pro-forma's `PRO-YYYY-NNNN` number), Block 10 Phase 08 does NOT match it; the outcome is `NO_MATCH` and the review issue includes a recommended-action `Convert pro-forma to tax invoice and re-match` that opens Phase 06's conversion flow. After conversion, a re-run of `INCOME_MATCHING` finds the new tax invoice in the candidate set and produces a `FULL_MATCH`.
- **Outcome → lifecycle audit chain:**
  - Each outcome that triggers a lifecycle call emits Block 10 Phase 08's `INCOME_MATCHING_OUTCOME_*` event AND Phase 03's `INVOICE_MARKED_*` event AND Block 11 Phase 09's downstream ledger event chain. The chain is captured by the run's audit trail and remains queryable post-finalization.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `IN_WORKFLOW`):
  - `IN_INCOME_MATCHING_INVOKED` (with candidate counts)
  - `IN_MULTI_INVOICE_ALLOCATION_PROPOSED` (when `MULTIPLE_INVOICES_ONE_PAYMENT` outcome surfaces)
  - `IN_MULTI_INVOICE_ALLOCATION_CONFIRMED` (with the user's allocation payload)
  - `IN_MULTI_INVOICE_ALLOCATION_EDITED_AND_CONFIRMED`
  - `IN_MULTI_INVOICE_ALLOCATION_REJECTED`
  - `IN_PRO_FORMA_PAYMENT_DETECTED` (when a `NO_MATCH` correlates with a pro-forma reference; review issue surfaces conversion action)

## Definition of Done

- A simple `IN_INCOME` payment matches a single sent tax invoice → `invoice.markPaid` fires; `lifecycle_status = PAID`; no review issue.
- A partial payment routes to `MATCHED_NEEDS_CONFIRMATION`; on user confirm, `invoice.markPartiallyPaid` fires; `invoice_payment_allocations` row is created.
- An overpayment routes to `MATCHED_NEEDS_CONFIRMATION` + a `Possible Tax/VAT Issue` review prompting credit-note creation; on confirm, `invoice.markOverpaid` fires.
- A `MULTIPLE_INVOICES_ONE_PAYMENT` payment surfaces as `Possible Wrong Match` MEDIUM review issue; never auto-applied; user confirms allocation; per-invoice lifecycle transitions fire.
- The allocation invariants are enforced — a user-edited allocation that exceeds an invoice's remaining total is rejected with a clear error.
- A `ONE_INVOICE_MULTIPLE_PAYMENTS` flow accumulates running totals correctly; when cumulative reaches `total_amount`, automatic transition from `PARTIALLY_PAID` to `PAID`.
- A `NO_MATCH` payment with a `PRO-YYYY-NNNN` reference in the descriptor surfaces the convert-pro-forma-and-re-match recommended action; after conversion, re-run produces a clean `FULL_MATCH`.
- Pro-forma invoices are NEVER candidates — verified by inspecting the matcher's input.
- Written-off invoices are NEVER candidates — verified by the lifecycle filter.
- All audit events fire with the right payloads.
- Tests cover all seven outcomes + the pro-forma path + the written-off exclusion + the rejection feeding into Block 10 Phase 06's rejection memory.

## Sub-doc Hooks (Stage 4)

- **Multi-invoice allocation UX sub-doc** — dialog layout, edit UI, validation feedback.
- **Allocation-invariant SQL sub-doc** — exact constraint checks; rejection error shapes.
- **Pro-forma → tax invoice conversion bridge sub-doc** — UX for the recommended action; auto-link of the resulting tax invoice into the unmatched payment.
- **Per-outcome severity calibration sub-doc** — Stage 1 defaults; Stage 2+ tunable.
- **Recovery-from-rejection sub-doc** — when the user rejects all proposed invoices and later realizes one was correct; how rejection memory's privileged-override path applies.
