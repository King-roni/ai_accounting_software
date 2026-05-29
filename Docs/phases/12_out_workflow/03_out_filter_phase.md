# Block 12 — Phase 03: `OUT_FILTER` Phase

## References

- Block doc: `Docs/blocks/12_out_workflow.md` (Type-Aware Evidence Rules; INTERNAL_TRANSFER routing)
- Block doc: `Docs/blocks/08_transaction_classification_and_tagging.md` (the 12 transaction types — closed taxonomy)
- Decisions log: `Docs/decisions_log.md` (INTERNAL_TRANSFER through both filters with single deduplicated ledger entry)

## Phase Goal

Define the `OUT_FILTER` phase and its single tool: take Block 08's classified transaction set for the period and mark the OUT-relevant subset that downstream OUT phases process. The phase is deterministic — it switches on `transaction.type` only — and produces no side effects beyond a mark on each transaction. After this phase, the EVIDENCE_DISCOVERY / MATCHING / LEDGER_PREPARATION phases have a stable filtered set to operate on.

## Dependencies

- Phase 02 (`OUT_MONTHLY` type registration sequences this phase at position 3)
- Phase 04 (parallel coordination — owns the `INTERNAL_TRANSFER` dedup contract)
- Block 03 Phase 03 (tool registration framework)
- Block 04 Phase 02 (`transactions` — the existing column `out_workflow_in_scope` and `in_workflow_in_scope` markers; these are added in Phase 01 of this block if they don't exist in Block 04 — see "Schema delta" below)
- Block 08 Phase 09 (`CLASSIFICATION` phase produces `transaction_type` for every row)

## Deliverables

- **Schema delta on `transactions`** (added by Phase 01 if not already present in Block 04):
  - `out_workflow_in_scope` (boolean; default `false`) — set by `OUT_FILTER` to `true` when the row is included.
  - `in_workflow_in_scope` (boolean; default `false`) — set by Block 13's `IN_FILTER` to `true` when the row is included.
  - `out_filter_decided_at` (timestamp; nullable) — when `OUT_FILTER` last touched this row.
  - `out_filter_decided_by_run_id` (FK to `workflow_runs`; nullable) — the most-recent `OUT_MONTHLY` run that decided this row's `out_workflow_in_scope` flag. Block 13's `IN_FILTER` provides parallel `in_filter_decided_at` and `in_filter_decided_by_run_id` columns. The split per-direction columns avoid the multi-valued problem; full filter-decision history (across re-runs) is recoverable from the audit trail (`OUT_FILTER_RAN` events).
- **Tool registration** with `engine.registerTool`:
  - **`out_workflow.filter_out_transactions`** — takes `(business_id, period, run_id)` and marks the OUT-relevant subset. Side-effect: `WRITES_RUN_STATE` (writes `out_workflow_in_scope = true` on each in-scope row). AI tier: `NONE` (deterministic — switches on `transaction.type`).
- **Filter rule** (closed; one entry per `(transaction_type, direction)` per the table from Phase 02):
  - **In-scope (set `out_workflow_in_scope = true`):** `OUT_EXPENSE`, `INTERNAL_TRANSFER` (direction-symmetric — also IN-scope), `FX_EXCHANGE`, `BANK_FEE`, `REFUND_OUT`, `PAYROLL_OR_TEAM_PAYMENT`, `TAX_PAYMENT`, `LOAN_OR_SHAREHOLDER_MOVEMENT` **with OUT direction** (outgoing loans, capital returns), `CHARGEBACK`.
  - **Not in OUT scope:** `IN_INCOME`, `REFUND_IN`, `LOAN_OR_SHAREHOLDER_MOVEMENT` **with IN direction** (capital injections, incoming loan disbursements) — all handled by IN_FILTER per the architecture doc's "refund routing is symmetric" rule, extended here to loans/capital. Direction is determined by the bank-statement amount sign (Block 07 Phase 04's normalization step) plus any direction hint in the matched contract.
  - **`UNKNOWN` handling:** treated as in-scope (for surface-and-block) — `out_workflow_in_scope = true` is set but the row is also marked as a blocking issue. The phase raises a `Possible Wrong Match` review issue (severity `HIGH`) per Block 14's bucket map; the user must reclassify before MATCHING produces meaningful results. The exit gate (Phase 05) does not advance until every `UNKNOWN` row is resolved or excluded.
- **`INTERNAL_TRANSFER` routing (cross-block contract):**
  - The architecture doc commits: "INTERNAL_TRANSFER transactions pass through both `OUT_FILTER` and `IN_FILTER`. Block 11's inter-account movement tool emits a single deduplicated ledger entry per transfer regardless of which workflow's filter encountered it first."
  - `OUT_FILTER` sets `out_workflow_in_scope = true` for INTERNAL_TRANSFER rows; Block 13's `IN_FILTER` sets `in_workflow_in_scope = true`. Both flags being true is intentional — the row is in scope of both workflows.
  - **Dedup of the ledger entry** is owned by Block 11 Phase 07's `prepareInternalTransferEntries` path: it produces exactly one PRIMARY ledger entry per `transactions.id` regardless of whether OUT or IN's `LEDGER_PREPARATION` phase invokes the dispatcher first. Idempotency is enforced by the dispatcher's delete-and-replace transaction (Block 11 Phase 07's recompute contract).
  - Phase 04 owns the broader OUT/IN parallel coordination semantics; this phase only enforces the in-scope marking.
- **Idempotency:**
  - Re-running `out_workflow.filter_out_transactions` for the same `(business_id, period, run_id)` produces the same result (deterministic; no clock-dependent inputs).
  - When the tool re-runs after upstream classification changes (Block 08 phase result re-derived), it correctly transitions previously in-scope rows to out-of-scope or vice versa based on the new `transaction.type`. Audit event `OUT_FILTER_SCOPE_TRANSITIONED` records the change.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `OUT_WORKFLOW`):
  - `OUT_FILTER_RAN`
  - `OUT_FILTER_INCLUDED_TRANSACTION` (per row included; payload includes `transaction_type` so per-type counts can be aggregated)
  - `OUT_FILTER_UNKNOWN_BLOCKER_RAISED`
  - `OUT_FILTER_SCOPE_TRANSITIONED` (when re-run flips a row's in-scope flag)

## Definition of Done

- The schema delta exists; both flags default to `false`; an unfilltered transaction has both flags `false`.
- A test classifies 10 transactions of mixed types; running `out_workflow.filter_out_transactions` flips the right rows to `out_workflow_in_scope = true` and leaves IN-only rows alone.
- An `INTERNAL_TRANSFER` row has `out_workflow_in_scope = true` after this phase AND has `in_workflow_in_scope = true` after Block 13's filter runs (verified once Block 13 phase docs are written).
- An `UNKNOWN` row is marked in-scope AND raises a `Possible Wrong Match` HIGH review issue.
- Re-running the filter is idempotent.
- Re-running after a classification change correctly transitions the row's flag and emits `OUT_FILTER_SCOPE_TRANSITIONED`.

## Sub-doc Hooks (Stage 4)

- **Filter rule sub-doc** — the canonical type→scope table; future-type compatibility (closed taxonomy + new-type addition path).
- **`UNKNOWN`-blocker UX sub-doc** — review-issue card layout, recommended actions.
- **`INTERNAL_TRANSFER` cross-workflow contract sub-doc** — the canonical statement of the dedup rule referenced by Block 13 and Block 11 Phase 07.
- **Filter-rerun semantics sub-doc** — when re-runs fire, transition audit shape, downstream impact.
