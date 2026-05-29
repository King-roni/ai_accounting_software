# Block 13 — Phase 08: `IN_FILTER` Phase

## References

- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (Type Set for IN_FILTER)
- Block doc: `Docs/blocks/12_out_workflow.md` (Phase 03 — symmetric `OUT_FILTER`; INTERNAL_TRANSFER routing)
- Block doc: `Docs/blocks/08_transaction_classification_and_tagging.md` (the 12-type closed taxonomy)
- Decisions log: `Docs/decisions_log.md` (refund routing is symmetric across workflows; UNKNOWN with positive direction is flagged)

## Phase Goal

Define the `IN_FILTER` phase and its single tool: take Block 08's classified transaction set for the period and mark the IN-relevant subset that downstream IN phases process. The phase is deterministic — it switches on `transaction.type` AND direction (for `UNKNOWN` and `LOAN_OR_SHAREHOLDER_MOVEMENT`) — and produces no side effects beyond a mark on each transaction. After this phase, `INCOME_MATCHING` (Block 10 Phase 08) and `LEDGER_PREPARATION` (Block 11 Phase 09) have a stable filtered set to operate on.

## Dependencies

- Phase 07 (`IN_MONTHLY` type registration sequences this phase at position 3)
- Phase 09 (gate-function library — `gate.in.in_filter_complete`)
- Block 03 Phase 03 (tool registration)
- Block 04 Phase 02 (`transactions` — uses the `in_workflow_in_scope` flag declared in Block 12 Phase 03's schema delta)
- Block 08 Phase 09 (`CLASSIFICATION` produces `transaction_type` for every row)
- Block 12 Phase 03 (symmetric `OUT_FILTER`; the schema delta on `transactions` was added there — this phase reuses the columns)

## Deliverables

- **Tool registration** with `engine.registerTool`:
  - **`in_workflow.filter_in_transactions`** — takes `(business_id, period, run_id)` and marks the IN-relevant subset. Side-effect: `WRITES_RUN_STATE` (writes `in_workflow_in_scope = true`, `in_filter_decided_at`, `in_filter_decided_by_run_id` per Block 12 Phase 03's schema). AI tier: `NONE`.
  - The schema columns (`in_workflow_in_scope`, `in_filter_decided_at`, `in_filter_decided_by_run_id`) were added by Block 12 Phase 03's delta — this phase consumes them.
- **Filter rule** (closed; one entry per `(transaction_type, direction)` per the architecture doc's "Type Set for IN_FILTER"):
  - **In-scope (set `in_workflow_in_scope = true`):**
    - `IN_INCOME` — matches against issued tax invoices (Phase 10 wires the matcher).
    - `REFUND_IN` — matches against the original outgoing transaction (Block 10 Phase 08's `POSSIBLE_REFUND_OR_TRANSFER` path applies).
    - `INTERNAL_TRANSFER` (direction-symmetric — also OUT-scope per Block 12 Phase 03; the single-ledger-entry dedup contract from Block 12 Phase 04 applies).
    - `LOAN_OR_SHAREHOLDER_MOVEMENT` **with IN direction** (capital injections, incoming loan disbursements). OUT direction is handled by `OUT_FILTER` per Block 12 Phase 03's per-direction split.
    - `UNKNOWN` **with positive direction** — flagged as a blocking issue per the architecture-doc "UNKNOWN (with positive direction) → flagged; user resolves." The phase raises a `Possible Wrong Match` review issue (severity `HIGH`) — same pattern as Block 12 Phase 03's `UNKNOWN` handling. The exit gate (Phase 09) does not advance until every `UNKNOWN`-with-positive-direction row is resolved or excluded.
    - **Direction determination:** sign of the transaction amount on the bank statement (positive = credit to the business's account = income/positive direction). Block 07 Phase 04's normalization step preserves the sign.
  - **Not in IN scope:**
    - `OUT_EXPENSE`, `FX_EXCHANGE`, `BANK_FEE`, `REFUND_OUT`, `PAYROLL_OR_TEAM_PAYMENT`, `TAX_PAYMENT`, `CHARGEBACK` — all OUT-only per Block 12 Phase 02.
    - `LOAN_OR_SHAREHOLDER_MOVEMENT` **with OUT direction** — handled by `OUT_FILTER`.
    - `UNKNOWN` **with negative direction** — handled by `OUT_FILTER` per Block 12 Phase 03.
- **`INTERNAL_TRANSFER` routing (cross-block contract — restated for clarity):**
  - The architecture doc commits: "INTERNAL_TRANSFER transactions pass through both `OUT_FILTER` and `IN_FILTER`. Block 11's inter-account movement tool emits a single deduplicated ledger entry per transfer regardless of which workflow's filter encountered it first."
  - `IN_FILTER` sets `in_workflow_in_scope = true` for INTERNAL_TRANSFER rows; `OUT_FILTER` sets `out_workflow_in_scope = true`. Both flags being true is intentional.
  - **Dedup of the ledger entry** is owned by Block 11 Phase 07's `prepareInternalTransferEntries` path (one PRIMARY entry per `transactions.id`); Block 12 Phase 04 owns the parallel coordination semantics; this phase only enforces the in-scope marking.
- **Routing nuance** (architecture-doc note: "INTERNAL_TRANSFER and LOAN_OR_SHAREHOLDER_MOVEMENT rows on the IN side are recognized but processed by their type-specific ledger paths in Block 11, not by income matching"):
  - These types are flagged `in_workflow_in_scope = true` but are **excluded from the income-matching candidate input set** Block 10 Phase 08 receives. Phase 10 of this block owns the precise filter (only `IN_INCOME` and `REFUND_IN` rows are passed to the matcher; `INTERNAL_TRANSFER` and `LOAN_OR_SHAREHOLDER_MOVEMENT` rows skip matching entirely and proceed to `LEDGER_PREPARATION`).
- **Idempotency:**
  - Re-running `in_workflow.filter_in_transactions` for the same `(business_id, period, run_id)` produces the same result (deterministic; switches on `transaction.type` + amount sign).
  - Re-running after upstream classification changes correctly transitions previously in-scope rows to out-of-scope or vice versa. Audit event `IN_FILTER_SCOPE_TRANSITIONED`.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `IN_WORKFLOW`):
  - `IN_FILTER_RAN` — emitted once per filter invocation; payload carries per-type counts (e.g., `{ included: { IN_INCOME: 12, REFUND_IN: 1, INTERNAL_TRANSFER: 3, ... }, excluded: { ... } }`). Aggregate emission rather than per-row keeps the audit-log volume bounded for typical periods (1000-row periods produce one event, not a thousand). Mirrors the aggregate-event pattern Block 12 Phase 03's audit list should adopt.
  - `IN_FILTER_UNKNOWN_POSITIVE_BLOCKER_RAISED` — emitted once per `UNKNOWN`-with-positive-direction row that triggers the review issue (low cardinality; per-row emission acceptable here because each is an actionable user issue).
  - `IN_FILTER_SCOPE_TRANSITIONED` — emitted once per filter invocation when at least one row's scope flag flipped on re-run; payload lists the affected `transaction_id`s.

## Definition of Done

- A test classifies 10 transactions of mixed types and directions; running `in_workflow.filter_in_transactions` flips the right rows to `in_workflow_in_scope = true`.
- An `INTERNAL_TRANSFER` row has both `out_workflow_in_scope = true` AND `in_workflow_in_scope = true` (verified jointly with Block 12 Phase 03's filter).
- A `LOAN_OR_SHAREHOLDER_MOVEMENT` with positive direction is in IN scope; same with OUT direction is NOT in IN scope.
- An `UNKNOWN` with positive direction is in IN scope AND raises a HIGH `Possible Wrong Match` review issue.
- An `UNKNOWN` with negative direction is NOT in IN scope (handled by `OUT_FILTER`).
- A `REFUND_IN` row is in IN scope; a `REFUND_OUT` row is NOT in IN scope (Block 12 owns it).
- Re-running the filter is idempotent.
- Re-running after a classification change transitions the row's flag and emits `IN_FILTER_SCOPE_TRANSITIONED`.

## Sub-doc Hooks (Stage 4)

- **Filter rule sub-doc** — the canonical type×direction → scope table; future-type compatibility.
- **Direction-determination sub-doc** — the bank-statement-sign convention; edge cases (zero-amount, fee-only transactions).
- **`INTERNAL_TRANSFER` cross-workflow contract sub-doc** — the canonical statement of the dedup rule (referenced from Block 11 Phase 07, Block 12 Phase 03/04, and this phase).
- **`UNKNOWN`-positive-blocker UX sub-doc** — review-issue card layout, recommended actions (reclassify as IN_INCOME, INTERNAL_TRANSFER, LOAN_OR_SHAREHOLDER_MOVEMENT IN-direction, etc.).
- **Filter-rerun semantics sub-doc** — when re-runs fire, transition audit shape, downstream impact.
