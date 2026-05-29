# Block 13 — Phase 09: IN Gate-Function Library + `HUMAN_REVIEW_HOLD` for IN

## References

- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (Gate Conditions per phase exit; HUMAN_REVIEW_HOLD)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 04 — state machine, `AWAITING_APPROVAL`; Phase 05 — gate evaluation)
- Block doc: `Docs/blocks/12_out_workflow.md` (Phase 05 — symmetric OUT gate library; Phase 07 — symmetric OUT HUMAN_REVIEW_HOLD)
- Block doc: `Docs/blocks/14_review_queue.md` (six review-issue buckets; severity)

## Phase Goal

Implement and register one gate function per IN phase, encoding the per-phase exit conditions from the architecture doc. Plus the IN-side `HUMAN_REVIEW_HOLD` side phase: entered after `AI_END_SCAN` produces blocking issues; exited only when zero blocking issues remain AND user approval is recorded. Symmetric with Block 12 Phases 05 + 07; reuses the same `workflow_run_approvals` table (Block 12 Phase 01) and the same `WORKFLOW_APPROVE` permission surface (Block 02 Phase 04).

## Dependencies

- Phase 07 (`IN_MONTHLY` type registration consumes these gate references)
- Phase 08 (`IN_FILTER` produces the in-scope marking)
- Phase 10 (income matching integration — `gate.in.income_matching_complete` reads its outputs)
- Block 03 Phase 05 (gate evaluation framework)
- Block 03 Phase 04 (state machine — `AWAITING_APPROVAL` for IN HUMAN_REVIEW_HOLD)
- Block 04 Phase 04 (`review_issues` — gates query for blocking issues)
- Block 06 Phase 11 (`AI_END_SCAN`)
- Block 11 Phase 09 (`LEDGER_PREPARATION` exit-gate — gate.in reuses the same Block 11 contract)
- Block 12 Phase 01 (`workflow_run_approvals` table)
- Block 12 Phase 07 (the symmetric OUT-side `HUMAN_REVIEW_HOLD` design — same `WORKFLOW_APPROVE` surface; same approval-staleness rule; same MEDIUM/LOW non-blocking semantics)

## Deliverables

- **Gate functions registered into Block 03 Phase 05's library** (one per IN phase; each takes `(run, period, business_id) → GateResult` returning `ADVANCE` / `HOLD` / `ROUTE_TO_SIDE_PHASE`):
  - **`gate.in.ingestion_complete`** — same shape as `gate.out.ingestion_complete` (Block 12 Phase 05). Shared phase; the gate is shared too — both workflows reuse the OUT-side definition rather than duplicate it. Phase 07's registration references `gate.out.ingestion_complete` directly (no separate IN-side gate; sub-doc tracks whether to alias or reuse).
  - **`gate.in.classification_complete`** — same; reuses `gate.out.classification_complete`.
  - **`gate.in.in_filter_complete`** — `ADVANCE` when every in-period transaction has `in_workflow_in_scope` set (true or false), AND no `UNKNOWN`-with-positive-direction row marked `in_workflow_in_scope = true` is unresolved (the `IN_FILTER_UNKNOWN_POSITIVE_BLOCKER_RAISED` issue must be resolved or the row reclassified). `HOLD` otherwise.
  - **`gate.in.income_matching_complete`** — reads `match_records.income_outcome` (per the schema migration Phase 01 declares — the seven-value enum from Block 10 Phase 08). `ADVANCE` when every in-scope IN transaction (`IN_INCOME`, `REFUND_IN`) has `income_outcome` set AND the gate-blocking outcomes below are all resolved. `HOLD` when at least one of:
    - **`MULTIPLE_INVOICES_ONE_PAYMENT`** has not yet been resolved by user-confirmed allocation (Phase 10 enforces mandatory user-confirmation per Stage 1).
    - **`POSSIBLE_REFUND_OR_TRANSFER`** has not yet been resolved by user action (either confirm-as-income → re-runs matching with the row treated as IN_INCOME, or reclassify-transaction-type → routes the row out of IN scope via Block 12 Phase 03's filter or routes it to its OUT-side counterpart). The Stage 1 default holds the gate rather than advancing — silently advancing would let misclassified income flow into the ledger; the user must explicitly resolve.
    - **`NO_MATCH`** raises a HIGH `Missing Documents` review issue (income received without an invoice) but does NOT hold the gate — the run can advance with NO_MATCH rows; the HUMAN_REVIEW_HOLD gate then catches the unresolved review issue. Sub-doc tracks the trade-off; Stage 1 default: NO_MATCH advances (HIGH issue holds at HUMAN_REVIEW_HOLD).
  - Other outcomes (`FULL_MATCH`, `PARTIAL_PAYMENT`, `OVERPAYMENT`, `ONE_INVOICE_MULTIPLE_PAYMENTS`) advance the gate; their per-outcome handling is owned by Phase 10.
  - **`gate.in.ledger_preparation_complete`** — `ADVANCE` when every in-scope IN transaction has at least one `draft_ledger_entries` row OR is held with an audit-logged reason. Reuses Block 11 Phase 09's exit-gate contract (the architecture doc lists `INCOME_LEDGER_PREPARATION` and `VAT_CLASSIFICATION` as separate phases; the consolidation Block 11 Phase 09 made applies here too — see Phase 07's "Phase mapping note").
  - **`gate.in.ai_end_scan_complete`** — `ADVANCE` when Block 06 Phase 11's end-scan has run AND no AI failure is unrecovered. `ROUTE_TO_SIDE_PHASE` (→ `HUMAN_REVIEW_HOLD`) when at least one blocking review issue is open. "Blocking" = `severity ∈ {HIGH, BLOCKING}` AND `status = OPEN`. Same threshold as Block 12 Phase 05's symmetric gate.
  - **`gate.in.human_review_hold_clear`** — only evaluated when `HUMAN_REVIEW_HOLD` is the current phase. `ADVANCE` when zero blocking issues remain open AND a non-revoked `workflow_run_approvals` row exists for this run. `HOLD` otherwise.
  - **`gate.in.finalization_complete`** — `ADVANCE` when Block 15's `FINALIZATION` phase has produced an archive package AND the dashboard refresh is enqueued AND every invoice affected by this period has transitioned to `FINALIZED` (per Phase 03's `markFinalized`). The architecture doc adds the invoice-finalization condition specifically to the IN-side; OUT has no equivalent invoice-finalization step. `HOLD` if any invoice transition fails.
  - **Invoice finalization tool — `in_workflow.finalize_period_invoices`** — fires near the end of `FINALIZATION` (before the gate evaluates) and bulk-calls `invoice.markFinalized` for every invoice referenced by the period's locked ledger entries. Side-effect: `WRITES_RUN_STATE`. AI tier: `NONE`. Block 15's `FINALIZATION` phase invokes this tool as part of its lock sequence; Block 13 owns the registration so the IN-specific contract is colocated with the gate that depends on it. Without this tool, the gate would never clear (Block 15 alone does not fire `markFinalized` per its current architecture-doc lock-sequence).
- **Gate determinism contract:**
  - Every gate is pure with respect to its inputs (no clock-dependent branches). `gate.in.human_review_hold_clear` is re-evaluated on event arrival (issue-status change, approval recorded / revoked) per Block 03 Phase 05's framework.
- **`HUMAN_REVIEW_HOLD` for IN side** — symmetric with Block 12 Phase 07:
  - **Phase entry condition** (driven by `gate.in.ai_end_scan_complete` returning `ROUTE_TO_SIDE_PHASE`): at least one `review_issues` row in any of Block 14's six buckets has `severity ∈ {HIGH, BLOCKING}` AND `status = OPEN`. On entry, run-level state transitions to `AWAITING_APPROVAL` (Block 03 Phase 04).
  - **Tool registrations** with `engine.registerTool`:
    - **`in_workflow.user_approval`** — symmetric with `out_workflow.user_approval`. Side-effect: `WRITES_RUN_STATE` (writes a `workflow_run_approvals` row — same table, declared by Block 12 Phase 01; both OUT and IN use it). AI tier: `NONE`.
    - **`in_workflow.user_revoke_approval`** — symmetric with the OUT-side. Side-effect: `WRITES_RUN_STATE` (marks the prior approval row as revoked). AI tier: `NONE`.
  - **Permission gate:** `WORKFLOW_APPROVE` surface (Block 02 Phase 04 — same as Block 12 Phase 07; the role-to-surface mapping lives in the matrix).
  - **Phase exit condition** (driven by `gate.in.human_review_hold_clear`): zero blocking issues open AND a non-revoked approval row exists. Approval is **required even when no blocking issues are present** (parallel to Block 12 Phase 07).
  - **Approval-staleness rule** (parallel to Block 12 Phase 07): if a re-run of `AI_END_SCAN` produces a new blocking issue post-approval, the gate flips back to `HOLD`; the prior approval row stays in audit but is no longer counted; emits `IN_HUMAN_REVIEW_APPROVAL_STALENESS_DETECTED`.
  - **MEDIUM / LOW issues do not block** — they remain visible in the review queue and the run can finalize with them open. Carry-forward to next monthly run when explicitly snoozed (parallel to Block 12 Phase 07's L5 fix); Block 14's snooze contract owns the boundary.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `IN_WORKFLOW`):
  - `IN_GATE_EVALUATED` (per gate call; payload includes gate name, return value, salient inputs)
  - `IN_GATE_ROUTED_TO_SIDE_PHASE` (when `ROUTE_TO_SIDE_PHASE` returns)
  - `IN_HUMAN_REVIEW_HOLD_ENTERED`
  - `IN_HUMAN_REVIEW_APPROVAL_RECORDED`
  - `IN_HUMAN_REVIEW_APPROVAL_REVOKED`
  - `IN_HUMAN_REVIEW_HOLD_CLEARED`
  - `IN_HUMAN_REVIEW_APPROVAL_STALENESS_DETECTED`

## Definition of Done

- All 8 gate functions register at engine boot and are referenceable by name from Phase 07's type registration. (`gate.in.ingestion_complete` and `gate.in.classification_complete` may alias the OUT-side gates; sub-doc owns the choice.)
- A test runs `IN_MONTHLY` end-to-end on a clean fixture; every gate returns `ADVANCE` in sequence and the run finalizes.
- A test injects a `MULTIPLE_INVOICES_ONE_PAYMENT` outcome; `gate.in.income_matching_complete` returns `HOLD` until user confirmation arrives via Phase 10's surface.
- A test injects a blocking HIGH review issue at end-scan; `gate.in.ai_end_scan_complete` returns `ROUTE_TO_SIDE_PHASE` and the engine enters `HUMAN_REVIEW_HOLD`.
- A user records approval via `in_workflow.user_approval`; the gate clears; `FINALIZATION` starts.
- A `gate.in.human_review_hold_clear` evaluation with zero blocking issues but no approval row returns `HOLD` (approval required even with zero issues).
- An approval revocation flips the gate back to `HOLD`.
- A new blocking issue post-approval emits the staleness event and flips the gate back.
- An Accountant attempting approval is denied per the `WORKFLOW_APPROVE` permission gate.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Gate-aliasing sub-doc** — Stage 1 choice for `INGESTION` and `CLASSIFICATION` gates: alias OUT-side or duplicate.
- **`POSSIBLE_REFUND_OR_TRANSFER` gate-hold rule sub-doc** — Stage 1 default and Stage 2+ tunable.
- **Gate-input schema sub-doc** — same shape as Block 12 Phase 05.
- **Approval-staleness UX sub-doc** — symmetric with Block 12 Phase 07.
- **Step-up auth for IN approval sub-doc** — when a business should require step-up (e.g., high-revenue period); same threshold rules as OUT.
