# in_monthly_phase_sequence

**Category:** Reference data · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

Canonical ordered phase sequence for `IN_MONTHLY` workflow runs. This is the reference record for the 8-position (0-based index 0–7) phase sequence registered at engine boot via `engine.registerWorkflowType({ type: 'IN_MONTHLY', ... })`. The sequence is snapshotted into `workflow_runs.effective_phase_sequence_json` at run creation time; in-flight runs are not affected by subsequent registry changes. Mirror structure of `out_monthly_phase_sequence` but for the incoming invoice side.

Phase indices are 0-based to match `workflow_runs.current_phase_index`. The registration call in `in_monthly_type_definition` uses 1-based position numbering; both forms are included for cross-reference.

---

## Phase sequence table

| Index (0-based) | Index (1-based) | Phase name | Owning block | Side phase? |
| --- | --- | --- | --- | --- |
| 0 | 1 | `INGESTION` | Block 07 | No |
| 1 | 2 | `CLASSIFICATION` | Block 08 | No |
| 2 | 3 | `IN_FILTER` | Block 13 Phase 03 | No |
| 3 | 4 | `INCOME_MATCHING` | Block 10 Phase 08 | No |
| 4 | 5 | `LEDGER_PREPARATION` | Block 11 Phase 09 | No |
| 5 | 6 | `AI_END_SCAN` | Block 06 Phase 11 | No |
| 6 | 7 | `HUMAN_REVIEW_HOLD` | Block 13 Phase 07 | **Yes** |
| 7 | 8 | `FINALIZATION` | Block 15 | No |

**Architecture note:** Block 13's architecture doc lists 9 conceptual phases (`INCOME_LEDGER_PREPARATION` and `VAT_CLASSIFICATION` as separate entries). Block 11 Phase 09 consolidated these into a single `LEDGER_PREPARATION` runtime phase. The 8-position sequence is canonical. Consumers querying phase events must use `LEDGER_PREPARATION` only — there is no `VAT_CLASSIFICATION_PHASE_*` event series. This matches the same consolidation in `out_monthly_phase_sequence` (11-position, Block 12).

**Evidence discovery is absent:** `IN_MONTHLY` does not include `EVIDENCE_DISCOVERY_EMAIL` or `EVIDENCE_DISCOVERY_DRIVE` phases. Income matching operates against structured `Invoice` records from the Invoice Generator, not externally discovered documents. This is a durable cross-block contract per Block 13 Phase 07.

---

## Per-phase detail

### Phase 0 — `INGESTION` (Block 07)

**Description:** Parses the bank statement upload, validates the file format, deduplicates rows against prior uploads for the same account and period, and generates the statement evidence PDF. Shared with `OUT_MONTHLY` for the same paired run; if the OUT run has already completed INGESTION for the period, the IN run's phase short-circuits via `WORKFLOW_TOOL_DEDUP_HIT`.

**Gate function:** `engine.gate_ingestion_complete`

**ADVANCE condition:** Every `bank_statement_rows` row for the period has `status ∈ {NEW, DUPLICATE_EXACT, DUPLICATE_PROBABLE, NEEDS_REVIEW}` and all ambiguous duplicates have review issues raised; OR a `WORKFLOW_TOOL_DEDUP_HIT` indicates the OUT run already completed this phase.

**HOLD condition:** One or more rows remain in `PENDING_DEDUP` or an intermediate processing status.

**FAIL condition:** File format unsupported (`STATEMENT_FORMAT_REJECTED_UNSUPPORTED`); parser encounters an unrecoverable error after bounded retries (`STATEMENT_PARSER_FAILED`).

**Estimated duration:** 5–60 seconds (or near-instant on dedup hit).

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED` (payload: `gate_name`, `outcome`, `run_id`, `phase_name`). On HOLD: `WORKFLOW_GATE_HOLD`.

---

### Phase 1 — `CLASSIFICATION` (Block 08)

**Description:** Runs the three-layer classification pipeline against every unclassified transaction in the period. Shared with `OUT_MONTHLY`; dedup contract from Block 12 Phase 04 applies.

**Gate function:** `engine.gate_classification_complete`

**ADVANCE condition:** Every transaction in the period has a non-null `transaction_type`; OR dedup hit confirms OUT run already completed classification for the period.

**HOLD condition:** One or more transactions still carry `transaction_type = NULL`.

**FAIL condition:** Layer 3 AI escalation fails after bounded retries with no lower-layer fallback.

**Estimated duration:** 10–120 seconds (or near-instant on dedup hit).

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED`. On HOLD: `WORKFLOW_GATE_HOLD`.

---

### Phase 2 — `IN_FILTER` (Block 13 Phase 03)

**Description:** Selects transactions in scope for the IN workflow. In-scope types include `IN_INCOME`, `REFUND_IN`, `INTERNAL_TRANSFER` (IN-direction), `FX_EXCHANGE` (IN-direction), `LOAN_OR_SHAREHOLDER_MOVEMENT` (IN-direction), and `CHARGEBACK` (IN-direction). Sets `in_workflow_in_scope` on each transaction row. Emits `IN_FILTER_RAN` as the aggregate event for the filter run.

**Gate function:** `engine.gate_in_filter_complete`

**ADVANCE condition:** Every in-period transaction has `in_workflow_in_scope` set (true or false).

**HOLD condition:** Filter execution has not completed for one or more transactions.

**FAIL condition:** Filter tool encounters an unrecoverable DB error after bounded retries.

**Estimated duration:** 2–10 seconds.

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED`. On HOLD: `WORKFLOW_GATE_HOLD`. `IN_FILTER_RAN` emitted on filter execution.

---

### Phase 3 — `INCOME_MATCHING` (Block 10 Phase 08)

**Description:** Scores and confirms matches between in-scope IN transactions and open `invoices` rows. Proposes multi-invoice allocations where a single bank credit spans multiple invoices. Sets `effective_match_status` on each in-scope transaction. Excludes `PRO_FORMA` invoices from matching candidates.

**Gate function:** `engine.gate_income_matching_complete`

**ADVANCE condition:** Every in-scope IN transaction has `effective_match_status` set; all proposed multi-invoice allocations are either confirmed or rejected.

**HOLD condition (routing to HUMAN_REVIEW_HOLD):** One or more IN transactions remain unmatched without a documented resolution; OR a multi-invoice allocation proposal requires human confirmation. Gate returns `ROUTE_TO_SIDE_PHASE` if blocking review issues are raised.

**FAIL condition:** Matching engine encounters an unrecoverable error after bounded retries.

**Estimated duration:** 10–60 seconds.

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED`. On `ROUTE_TO_SIDE_PHASE`: `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE`. `INCOME_MATCHING_PAIR_SCORED`, `INCOME_MATCHING_OUTCOME_RECORDED` emitted during execution.

---

### Phase 4 — `LEDGER_PREPARATION` (Block 11 Phase 09)

**Description:** Resolves counterparties for in-scope income transactions, decides VAT treatment, prepares `draft_ledger_entries` rows for income entries, and generates invoice lifecycle ledger entries (e.g., bad-debt expense for written-off invoices). Covers income ledger preparation and VAT classification in a single consolidated phase.

**Gate function:** `engine.gate_ledger_preparation_complete`

**ADVANCE condition:** Every in-scope IN transaction has at least one `draft_ledger_entries` row, OR is held with an audit-logged reason. All VAT compliance fields are populated.

**HOLD condition:** One or more transactions await ledger entry creation or VAT resolution; OR a blocking `LEDGER_ACCOUNTANT_REVIEW_FLAGGED` issue is open.

**FAIL condition:** Ledger tool encounters an unrecoverable computation error after bounded retries.

**Estimated duration:** 15–90 seconds.

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED`. On HOLD: `WORKFLOW_GATE_HOLD`. `LEDGER_PHASE_HOLDING` emitted on hold entry.

---

### Phase 5 — `AI_END_SCAN` (Block 06 Phase 11)

**Description:** Runs the Block 06 Phase 11 end-scan over the full in-scope IN transaction set and associated ledger entries and invoice records. Produces review issues in Block 14's buckets with severity `LOW` through `BLOCKING`.

**Gate function:** `engine.gate_ai_end_scan_complete`

**ADVANCE condition:** End-scan completed AND no AI failure is unrecovered AND zero review issues with `severity ∈ {HIGH, BLOCKING}` and `status = OPEN` exist. `MEDIUM` and `LOW` issues do not block.

**HOLD condition (routing to side phase):** End-scan completed AND at least one blocking review issue (`severity ∈ {HIGH, BLOCKING}`, `status = OPEN`) exists. Gate returns `ROUTE_TO_SIDE_PHASE` → `HUMAN_REVIEW_HOLD` (index 6).

**FAIL condition:** End-scan tool fails after bounded retries.

**Estimated duration:** 15–120 seconds.

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED`. On `ROUTE_TO_SIDE_PHASE`: `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE`.

---

### Phase 6 — `HUMAN_REVIEW_HOLD` (Block 13 Phase 07) — side phase

**Description:** Entered when `AI_END_SCAN` gate (or `INCOME_MATCHING` gate) routes `ROUTE_TO_SIDE_PHASE`. Run-level state transitions to `AWAITING_APPROVAL`. The user resolves blocking review issues via Block 14 and records explicit approval. The run cannot advance until both conditions are met.

**Gate function:** `engine.gate_human_review_hold_clear`

**ADVANCE condition:** `count(review_issues WHERE severity IN ('HIGH','BLOCKING') AND status = 'OPEN') = 0` AND `EXISTS(SELECT 1 FROM workflow_run_approvals WHERE run_id = $run AND revoked_at IS NULL AND is_stale = false)`.

**HOLD condition:** One or more blocking issues remain open; OR no non-revoked non-stale approval exists.

**FAIL condition:** None — this phase waits indefinitely pending user action.

**Estimated duration:** Variable; minutes to days pending user resolution.

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED`. On HOLD: `WORKFLOW_GATE_HOLD`. `WORKFLOW_APPROVAL_RECORDED` on approval.

---

### Phase 7 — `FINALIZATION` (Block 15)

**Description:** Executes the Block 15 lock sequence: locks the ledger entries and invoice rows for the period, builds the archive bundle, runs the RFC 3161 timestamp anchor, calls `in_workflow.finalize_invoice` on all non-terminal invoices in the period, and enqueues the dashboard refresh. Terminal phase; on success the run transitions to `FINALIZED`.

**Gate function:** `engine.gate_finalization_complete`

**ADVANCE condition (terminal):** Block 15 lock sequence completed successfully and `ARCHIVE_PROMOTION_COMPLETED` emitted. Run transitions to `FINALIZED`.

**HOLD condition:** None — finalization does not hold; it either succeeds or fails.

**FAIL condition:** Lock sequence encounters partial-write failure → run transitions to `COMPENSATING` (Block 15 Phase 09 rollback). On compensation failure → `FAILED`.

**Estimated duration:** 10–60 seconds; up to 5 minutes if the TSA is slow.

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED`. On completion: `FINALIZATION_LOCK_COMMITTED`, `ARCHIVE_PROMOTION_COMPLETED`.

---

## Gate outcome to run-state mapping

| Gate outcome | Run-level state transition | Notes |
| --- | --- | --- |
| `ADVANCE` | `RUNNING` (continues to next phase) | Engine immediately begins next phase |
| `HOLD` | `REVIEW_HOLD` | System-initiated; re-evaluates when unblocking event arrives |
| `ROUTE_TO_SIDE_PHASE` | `AWAITING_APPROVAL` (HUMAN_REVIEW_HOLD) | Side-phase entered; main sequence paused |
| `FAIL` (unrecoverable) | `FAILED` | Terminal after bounded retries exhaust |

---

## Cross-references

- `workflow_state_enum` — canonical 10-value run-state enum; gate-outcome-to-state mapping
- `workflow_run_schema` — `current_phase_index`, `current_phase_name`, `effective_phase_sequence_json` columns
- `gate_function_library_schema` — registered gate functions referenced by name in this sequence
- `out_monthly_phase_sequence` — parallel OUT-side sequence (11 phases); structural mirror for this document
- `in_monthly_type_definition` — `IN_MONTHLY` type registration; phase array; shared-phase dedup contract
- `audit_event_taxonomy` — `WORKFLOW_GATE_EVALUATED`, `WORKFLOW_GATE_HOLD`, `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE`
- `data_layer_conventions_policy` — canonical JSON for `effective_phase_sequence_json`
- Block 13 Phase 07 — `HUMAN_REVIEW_HOLD` phase detail; per-business IN config
- Block 12 Phase 04 — shared INGESTION/CLASSIFICATION dedup contract
- Block 03 Phase 04 — state machine; `transitionRun()` called on every gate outcome
- Block 03 Phase 05 — gate evaluation framework; caching; re-evaluation triggers
- Block 10 Phase 08 — income matching variant; multi-invoice allocation
- Block 11 Phase 09 — LEDGER_PREPARATION consolidation
- Block 15 Phase 04 — `in_workflow.finalize_invoice` called during lock sequence
