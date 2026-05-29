# Block 12 — Phase 05: Gate-Function Library

## References

- Block doc: `Docs/blocks/12_out_workflow.md` (Gate Conditions per phase exit)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 05 — gate evaluation framework)
- Decisions log: `Docs/decisions_log.md` (gates as registered functions per phase)

## Phase Goal

Implement and register one gate function per OUT phase, encoding the per-phase exit conditions from the architecture doc. Each gate is deterministic, takes the run's current state as input, and returns one of `ADVANCE` / `HOLD` / `ROUTE_TO_SIDE_PHASE` per Block 03 Phase 05's contract. After this phase, Phase 02's type registration can resolve every `gateFunctionRef` against this library and the engine has the decision logic it needs to drive `OUT_MONTHLY` runs forward.

## Dependencies

- Phase 02 (`OUT_MONTHLY` type registration consumes these references)
- Phase 03 (`OUT_FILTER` produces the in-scope marking the gates check)
- Phase 06 (`MANUAL_UPLOAD_HOLD` — destination of the routing decision from MATCHING's gate)
- Phase 07 (`HUMAN_REVIEW_HOLD` — destination of the routing decision from AI_END_SCAN's gate)
- Block 03 Phase 05 (gate evaluation framework — return-type contract)
- Block 04 Phase 04 (`review_issues` — gates query for blocking issues)
- Blocks 06–11 (each owns the data the gate function inspects)

## Deliverables

- **Gate-return type** (per Block 03 Phase 05; restated for clarity):
  - `ADVANCE` — proceed to the next sequenced phase.
  - `HOLD` — stop here; the run-level state goes to `REVIEW_HOLD`; engine waits for an unblocking event (user action, retry, etc.).
  - `ROUTE_TO_SIDE_PHASE` — explicitly route to a named side phase before the next sequenced phase. Used by `MATCHING` (→ `MANUAL_UPLOAD_HOLD`) and `AI_END_SCAN` (→ `HUMAN_REVIEW_HOLD`).
- **Gate functions registered into Block 03 Phase 05's library** (one per OUT phase; each takes `(run, period, business_id) → GateResult`):
  - **`gate.out.ingestion_complete`** — `ADVANCE` when every Block 07 `bank_statement_rows` row for the period has `status ∈ {NEW, DUPLICATE_EXACT, DUPLICATE_POSSIBLE, NEEDS_REVIEW}` AND ambiguous duplicates have review issues raised. `HOLD` if any row is mid-processing (e.g., `PENDING_DEDUP`).
  - **`gate.out.classification_complete`** — `ADVANCE` when every transaction in the period has a non-null `transaction_type`; `UNKNOWN`-type rows are present (this gate doesn't block them — Phase 03's filter and the `OUT_FILTER` gate handle them) but have at least been classified as `UNKNOWN`. `HOLD` if any row is still `null`.
  - **`gate.out.out_filter_complete`** — `ADVANCE` when every in-period transaction has `out_workflow_in_scope` set (true or false), AND no `UNKNOWN`-type row marked `out_workflow_in_scope = true` is unresolved (the `OUT_FILTER_UNKNOWN_BLOCKER_RAISED` issue must be resolved or the row reclassified). `HOLD` otherwise.
  - **`gate.out.evidence_discovery_email_complete`** — `ADVANCE` when every OUT_EXPENSE row has had its email candidate-search executed (zero candidates is allowed; absence of search execution is not). When `evidence_discovery_email_enabled = false` (Phase 01), the gate returns `ADVANCE` immediately and Phase 02's short-circuit emits `OUT_WORKFLOW_PHASE_SKIPPED_BY_CONFIG`.
  - **`gate.out.evidence_discovery_drive_complete`** — same shape as the email gate, against Drive candidates.
  - **`gate.out.matching_complete`** — `ADVANCE` when every in-scope OUT transaction has `transactions.effective_match_status` set (one of the seven values: the six Block 04 per-pair statuses, plus `EXCEPTION_DOCUMENTED` from Phase 06). `ROUTE_TO_SIDE_PHASE` (→ `MANUAL_UPLOAD_HOLD`) when at least one OUT_EXPENSE row has `effective_match_status = NO_MATCH`. Reading `effective_match_status` is the single mechanism — exceptions flip the column to `EXCEPTION_DOCUMENTED` and the gate sees the same. Other transaction types whose evidence requirement is met by `INTERNAL_TRANSFER` / `BANK_FEE` / `FX_EXCHANGE` etc. don't trigger the side-phase routing.
    > **2026-05-24 post-build amendment (audit M6)**: in the as-built DB the column is `transactions.match_status` (not `effective_match_status`). Spec terminology is preserved here as the conceptual intent; map `effective_match_status` → `match_status` in the implementation. Enum is `transaction_match_status_enum` with values `UNMATCHED`, `MATCHED_PROPOSED`, `MATCHED_CONFIRMED`, `MATCHED_AUTO_CONFIRMED`, `MATCHED_AUTO_HIGH_CONFIDENCE` (added per audit H1), `NO_MATCH_REQUIRED`, `EXCEPTION_DOCUMENTED`. The "NO_MATCH" status the gate routes on corresponds to `UNMATCHED` in DB enum.
  - **`gate.out.manual_upload_hold_clear`** — only evaluated when `MANUAL_UPLOAD_HOLD` is the current phase. `ADVANCE` when every OUT_EXPENSE row has matched evidence OR a documented exception OR a transaction type that doesn't need evidence. `HOLD` otherwise. (No timeout enforcement here — Phase 06's reminder cadence is its own concern.)
  - **`gate.out.ledger_preparation_complete`** — `ADVANCE` when every in-scope OUT transaction has at least one `draft_ledger_entries` row OR is held with an audit-logged reason (per Block 11 Phase 09's exit gate). The architecture-doc's separate `VAT_CLASSIFICATION` gate is folded into this one because Block 11 Phase 09 consolidated the phases (per Phase 02's mapping note); the gate checks all VAT compliance fields are populated per Block 11's exit-gate clause.
  - **`gate.out.ai_end_scan_complete`** — `ADVANCE` when Block 06 Phase 11's end-scan has run AND no AI failure is unrecovered AND `ROUTE_TO_SIDE_PHASE` (→ `HUMAN_REVIEW_HOLD`) when at least one blocking review issue is open in any of Block 14's six buckets. "Blocking" = `severity ∈ {HIGH, BLOCKING}` AND `status = OPEN`. `MEDIUM`/`LOW` issues don't block.
  - **`gate.out.human_review_hold_clear`** — only evaluated when `HUMAN_REVIEW_HOLD` is the current phase. `ADVANCE` when zero blocking issues remain open AND the run carries a recorded user-approval action (per Phase 07). `HOLD` otherwise.
  - **`gate.out.finalization_complete`** — `ADVANCE` when Block 15's `FINALIZATION` phase has produced an archive package AND the dashboard refresh is enqueued. (This is the run's terminal `ADVANCE`; the engine transitions to `FINALIZED` per Block 03 Phase 04.)
- **Gate determinism contract:**
  - Every gate is pure with respect to its inputs (`run`, `period`, `business_id`, plus deterministic queries against the operational DB). No clock-dependent branches inside gate logic — the 7-day reminder in `MANUAL_UPLOAD_HOLD` is owned by Phase 06's reminder scheduler, NOT the gate.
  - **Exception** for `gate.out.manual_upload_hold_clear` and `gate.out.human_review_hold_clear`: these may be re-evaluated when an event arrives (user uploads an invoice, user clicks Approve). The re-evaluation is triggered by Block 03's event mechanism; the gate function itself remains pure.
- **Gate-input shape** (sub-doc finalizes; representative):
  - Each gate receives `{ run_id, business_id, period_start, period_end, transactions_in_scope: Transaction[], current_phase: PhaseName }`.
  - Gates may execute SQL queries; Block 03 Phase 05's framework batches these for performance.
- **Gate caching:**
  - Within one engine tick, identical gate inputs return cached results (Block 03 Phase 05's framework owns the cache). Across ticks, no caching — new state may have arrived.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `OUT_WORKFLOW`):
  - `OUT_GATE_EVALUATED` (per gate call; payload includes gate name, return value, and the salient inputs)
  - `OUT_GATE_ROUTED_TO_SIDE_PHASE` (when `ROUTE_TO_SIDE_PHASE` returns)

## Definition of Done

- All 11 gate functions register at engine boot and are referenceable by name from Phase 02's type registration.
- A test runs `OUT_MONTHLY` end-to-end on a clean fixture; every gate returns `ADVANCE` in sequence and the run finalizes.
- A test injects an unmatched OUT_EXPENSE; `gate.out.matching_complete` returns `ROUTE_TO_SIDE_PHASE` and the engine enters `MANUAL_UPLOAD_HOLD`.
- A test injects a blocking HIGH review issue; `gate.out.ai_end_scan_complete` returns `ROUTE_TO_SIDE_PHASE` and the engine enters `HUMAN_REVIEW_HOLD`.
- Disabling `evidence_discovery_email_enabled` causes `gate.out.evidence_discovery_email_complete` to return `ADVANCE` immediately with the right config-skip audit event.
- Each gate is idempotent on re-evaluation with the same inputs.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Gate-input schema sub-doc** — exact JSON / TypeScript shape of `GateInput`.
- **Per-gate SQL plan sub-doc** — query plans for the heavy gates (matching, AI_END_SCAN).
- **Gate-cache key sub-doc** — what's hashed, eviction rules.
- **Side-phase routing precedence sub-doc** — what happens if both routing conditions could fire (Stage 1: only one ever can per phase).
