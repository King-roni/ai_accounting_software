# out_monthly_phase_sequence

**Category:** Reference data · **Owning block:** 12 — OUT Workflow · **Stage:** 4 sub-doc (Layer 2)

Canonical ordered phase sequence for `OUT_MONTHLY` workflow runs. This is the reference record for the 11-position (0-based index 0–10) phase sequence registered at engine boot via `engine.registerWorkflowType({ type: 'OUT_MONTHLY', ... })`. The sequence is snapshotted into `workflow_runs.effective_phase_sequence_json` at run creation time; in-flight runs are not affected by subsequent registry changes.

Phase indices below are 0-based to match `workflow_runs.current_phase_index`. The registration call in Block 12 Phase 02 uses 1-based numbering; both forms are included for cross-reference.

---

## Phase sequence table

| Index (0-based) | Index (1-based) | Phase name | Owning block | Side phase? |
| --- | --- | --- | --- | --- |
| 0 | 1 | `INGESTION` | Block 07 | No |
| 1 | 2 | `CLASSIFICATION` | Block 08 | No |
| 2 | 3 | `OUT_FILTER` | Block 12 Phase 03 | No |
| 3 | 4 | `EVIDENCE_DISCOVERY_EMAIL` | Block 09 | No |
| 4 | 5 | `EVIDENCE_DISCOVERY_DRIVE` | Block 09 | No |
| 5 | 6 | `MATCHING` | Block 10 | No |
| 6 | 7 | `MANUAL_UPLOAD_HOLD` | Block 12 Phase 06 | **Yes** |
| 7 | 8 | `LEDGER_PREPARATION` | Block 11 | No |
| 8 | 9 | `AI_END_SCAN` | Block 06 | No |
| 9 | 10 | `HUMAN_REVIEW_HOLD` | Block 12 Phase 07 | **Yes** |
| 10 | 11 | `FINALIZATION` | Block 15 | No |

**Phase mapping note:** The architecture doc lists 12 conceptual phases (`LEDGER_PREPARATION` and `VAT_CLASSIFICATION` as separate positions). Block 11 Phase 09 consolidated these into a single `LEDGER_PREPARATION` phase. The runtime sequence has 11 positions. Consumers querying phase events must use `LEDGER_PREPARATION` only — there is no `VAT_CLASSIFICATION_PHASE_*` event series.

---

## Per-phase detail

### Phase 0 — `INGESTION` (Block 07)

**Description:** Parses the bank statement upload, validates the file format, deduplicates rows against prior uploads for the same account and period, and generates the statement evidence PDF. Produces `bank_statement_rows` records for the period.

**Gate function:** `engine.gate_ingestion_complete`

**ADVANCE condition:** Every `bank_statement_rows` row for the period has `status ∈ {NEW, DUPLICATE_EXACT, DUPLICATE_PROBABLE, NEEDS_REVIEW}` and all ambiguous duplicates have review issues raised.

**HOLD condition:** One or more rows remain in `PENDING_DEDUP` or an intermediate processing status (file parsing not yet complete).

**FAIL condition:** File format is unsupported (emits `STATEMENT_FORMAT_REJECTED_UNSUPPORTED`); parser encounters an unrecoverable error after bounded retries (emits `STATEMENT_PARSER_FAILED`).

**Estimated duration:** 5–60 seconds depending on file size and dedup volume.

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED` (payload: `gate_name`, `outcome`, `run_id`, `phase_name`). On HOLD: `WORKFLOW_GATE_HOLD`.

---

### Phase 1 — `CLASSIFICATION` (Block 08)

**Description:** Runs the three-layer classification pipeline (rule-based Layer 1, ML Layer 2, LLM Layer 3 escalation) against every unclassified transaction in the period. Writes `transaction_type` on each `transactions` row and optionally increments vendor memory.

**Gate function:** `engine.gate_classification_complete`

**ADVANCE condition:** Every transaction in the period has a non-null `transaction_type` (including `UNKNOWN`; the filter phase handles `UNKNOWN` blocking, not this gate).

**HOLD condition:** One or more transactions still carry `transaction_type = NULL` (classification not yet completed for those rows).

**FAIL condition:** Layer 3 (AI) escalation fails after bounded retries and no lower-layer fallback applies; emits `CLASSIFICATION_LAYER_3_DECIDED` with failure payload. Engine transitions to `FAILED`.

**Estimated duration:** 10–120 seconds depending on transaction count and AI escalation rate.

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED`. On HOLD: `WORKFLOW_GATE_HOLD`.

---

### Phase 2 — `OUT_FILTER` (Block 12 Phase 03)

**Description:** Applies the type-aware evidence rules table to mark each transaction `out_workflow_in_scope = true/false`. `UNKNOWN`-type transactions that are in-scope raise a `BLOCKING` review issue (`OUT_FILTER_UNKNOWN_BLOCKER_RAISED`). Only in-scope transactions proceed through subsequent phases.

**Gate function:** `engine.gate_out_filter_complete`

**ADVANCE condition:** Every in-period transaction has `out_workflow_in_scope` set, AND no `UNKNOWN`-type row marked in-scope is unresolved (either the issue is resolved or the row has been reclassified).

**HOLD condition:** Any in-scope `UNKNOWN` row has an open `BLOCKING` review issue that has not been resolved or reclassified.

**FAIL condition:** Filter tool encounters an unrecoverable DB error after bounded retries.

**Estimated duration:** 2–10 seconds (lightweight predicate evaluation; no external calls).

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED`. On HOLD: `WORKFLOW_GATE_HOLD`. `OUT_FILTER_RAN` is the aggregate event for the filter execution itself.

---

### Phase 3 — `EVIDENCE_DISCOVERY_EMAIL` (Block 09)

**Description:** Searches the business's connected email inbox for documents matching in-scope `OUT_EXPENSE` transactions. Candidate documents are linked but not yet confirmed as matched evidence.

**Gate function:** `engine.gate_evidence_discovery_email_complete`

**ADVANCE condition:** Every `OUT_EXPENSE` row has had its email candidate-search executed (zero candidates is acceptable; absence of search execution is not). If `evidence_discovery_email_enabled = false` in `out_workflow_configs`, the gate returns `ADVANCE` immediately and `OUT_WORKFLOW_PHASE_SKIPPED_BY_CONFIG` is emitted.

**HOLD condition:** Search execution has not completed for one or more `OUT_EXPENSE` rows.

**FAIL condition:** Email integration token is revoked or permanently unreachable after retries (emits `INTEGRATION_REFRESH_FAILED`). Engine transitions to `FAILED`.

**Estimated duration:** 5–30 seconds for businesses with small inboxes; up to 5 minutes for high-volume mailboxes.

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED`. On HOLD: `WORKFLOW_GATE_HOLD`.

---

### Phase 4 — `EVIDENCE_DISCOVERY_DRIVE` (Block 09)

**Description:** Searches the business's connected Google Drive for documents matching in-scope `OUT_EXPENSE` transactions. Symmetric with email discovery.

**Gate function:** `engine.gate_evidence_discovery_drive_complete`

**ADVANCE condition:** Every `OUT_EXPENSE` row has had its Drive candidate-search executed. If `evidence_discovery_drive_enabled = false`, gate returns `ADVANCE` immediately with `OUT_WORKFLOW_PHASE_SKIPPED_BY_CONFIG`.

**HOLD condition:** Search execution has not completed for one or more `OUT_EXPENSE` rows.

**FAIL condition:** Drive integration token revoked or permanently unreachable after retries.

**Estimated duration:** 5–60 seconds.

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED`. On HOLD: `WORKFLOW_GATE_HOLD`.

---

### Phase 5 — `MATCHING` (Block 10)

**Description:** Scores and confirms matches between in-scope OUT transactions and their candidate evidence documents. Sets `transactions.effective_match_status` for every in-scope row.

**Gate function:** `engine.gate_matching_complete`

**ADVANCE condition:** Every in-scope OUT transaction has `effective_match_status` set to one of the seven values (six Block 04 per-pair statuses plus `EXCEPTION_DOCUMENTED`).

**HOLD condition (routing to side phase):** At least one `OUT_EXPENSE` row has `effective_match_status = NO_MATCH`. Gate returns `ROUTE_TO_SIDE_PHASE` → `MANUAL_UPLOAD_HOLD` (index 6). Other transaction types whose evidence requirement is met by classification type (e.g., `INTERNAL_TRANSFER`, `BANK_FEE`) do not trigger side-phase routing.

**FAIL condition:** Matching engine encounters an unrecoverable error after bounded retries.

**Estimated duration:** 10–60 seconds.

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED`. On `ROUTE_TO_SIDE_PHASE`: `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE`.

---

### Phase 6 — `MANUAL_UPLOAD_HOLD` (Block 12 Phase 06) — side phase

**Description:** Pauses the run awaiting manual evidence uploads for unmatched `OUT_EXPENSE` transactions. Entered conditionally when `engine.gate_matching_complete` returns `ROUTE_TO_SIDE_PHASE`. During this phase, run-level state is `REVIEW_HOLD` and `phase_state.status = HOLDING`. Reminder notifications fire after `manual_upload_hold_reminder_days` days (per `out_workflow_configs`).

**Gate function:** `engine.gate_manual_upload_hold_clear`

**ADVANCE condition:** Every `OUT_EXPENSE` row has matched evidence, OR a documented exception (status `EXCEPTION_DOCUMENTED`), OR a transaction type that does not require evidence.

**HOLD condition:** One or more `OUT_EXPENSE` rows remain at `NO_MATCH` without a documented exception.

**FAIL condition:** None — this phase waits indefinitely; there is no timeout auto-fail (only reminder cadence, not auto-cancellation).

**Estimated duration:** Variable; hours to days pending user action.

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED`. On HOLD: `WORKFLOW_GATE_HOLD`.

---

### Phase 7 — `LEDGER_PREPARATION` (Block 11)

**Description:** Resolves counterparties, decides VAT treatment (including reverse-charge and VIES period assignment), computes reverse-charge amounts, prepares `draft_ledger_entries` rows, flags any unresolvable entries for review, and generates VAT explanation outputs. Covers both ledger preparation and VAT classification in a single consolidated phase (Block 11 Phase 09 consolidation).

**Gate function:** `engine.gate_ledger_preparation_complete`

**ADVANCE condition:** Every in-scope OUT transaction has at least one `draft_ledger_entries` row, OR is held with an audit-logged reason. All VAT compliance fields are populated.

**HOLD condition:** One or more transactions are still awaiting ledger entry creation or VAT resolution; or a blocking `LEDGER_ACCOUNTANT_REVIEW_FLAGGED` issue is open.

**FAIL condition:** Ledger tool encounters an unrecoverable computation error after bounded retries (e.g., missing chart-of-accounts mapping with no fallback).

**Estimated duration:** 15–90 seconds.

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED`. On HOLD: `WORKFLOW_GATE_HOLD`. `LEDGER_PHASE_HOLDING` is emitted by Block 11 on hold entry.

---

### Phase 8 — `AI_END_SCAN` (Block 06)

**Description:** Runs the Block 06 Phase 11 end-scan over the full in-scope transaction set and associated ledger entries. Produces review issues in Block 14's six buckets with severity `LOW` through `BLOCKING`.

**Gate function:** `engine.gate_ai_end_scan_complete`

**ADVANCE condition:** End-scan has completed AND no AI failure is unrecovered AND zero review issues with `severity ∈ {HIGH, BLOCKING}` and `status = OPEN` exist across any Block 14 bucket. `MEDIUM` and `LOW` issues do not block.

**HOLD condition (routing to side phase):** End-scan completed AND at least one blocking review issue (`severity ∈ {HIGH, BLOCKING}`, `status = OPEN`) exists. Gate returns `ROUTE_TO_SIDE_PHASE` → `HUMAN_REVIEW_HOLD` (index 9).

**FAIL condition:** End-scan tool fails after bounded retries (emits `END_SCAN_FINDING_RAISED` with failure payload). Engine transitions to `FAILED`.

**Estimated duration:** 15–120 seconds depending on AI model response time.

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED`. On `ROUTE_TO_SIDE_PHASE`: `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE`.

---

### Phase 9 — `HUMAN_REVIEW_HOLD` (Block 12 Phase 07) — side phase

**Description:** Entered when `AI_END_SCAN` gate routes `ROUTE_TO_SIDE_PHASE`. Run-level state transitions to `AWAITING_APPROVAL`. The user resolves blocking review issues via the Block 14 review queue and explicitly records approval via `out_workflow.user_approval`. The run cannot proceed until both conditions are met.

**Gate function:** `engine.gate_human_review_hold_clear`

**ADVANCE condition:** `count(review_issues WHERE severity IN ('HIGH','BLOCKING') AND status = 'OPEN') = 0` AND `EXISTS(SELECT 1 FROM workflow_run_approvals WHERE run_id = $run AND revoked_at IS NULL AND is_stale = false)`.

**HOLD condition:** One or more blocking issues remain open, OR no non-revoked non-stale approval row exists for the run.

**FAIL condition:** None — this phase waits indefinitely pending user action.

**Estimated duration:** Variable; minutes to days pending user resolution and approval.

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED`. On HOLD: `WORKFLOW_GATE_HOLD`.

---

### Phase 10 — `FINALIZATION` (Block 15)

**Description:** Executes the Block 15 lock sequence: locks the ledger, builds the archive bundle (canonical JSON manifest, Object-Locked storage), runs the RFC 3161 timestamp anchor, and enqueues the dashboard refresh. This is the terminal phase. On success, run transitions to `FINALIZED`.

**Gate function:** `engine.gate_finalization_complete`

**ADVANCE condition (terminal):** Block 15 lock sequence completed successfully and `ARCHIVE_PROMOTION_COMPLETED` emitted. The engine transitions the run to `FINALIZED`.

**HOLD condition:** None — finalization does not hold; it either succeeds or fails.

**FAIL condition:** Lock sequence encounters a partial-write failure → run transitions to `COMPENSATING` (Block 15 Phase 09 rollback). On compensation failure → `FAILED`.

**Estimated duration:** 10–60 seconds under normal conditions; up to 5 minutes if the TSA is slow.

**Audit events on gate evaluation:** `WORKFLOW_GATE_EVALUATED`. On completion: `FINALIZATION_LOCK_COMMITTED`, `ARCHIVE_PROMOTION_COMPLETED`.

---

## Gate outcome to run-state mapping

| Gate outcome | Run-level state transition | Notes |
| --- | --- | --- |
| `ADVANCE` | `RUNNING` (continues to next phase) | Engine immediately begins next phase |
| `HOLD` | `REVIEW_HOLD` | System-initiated; re-evaluates when unblocking event arrives |
| `ROUTE_TO_SIDE_PHASE` | `REVIEW_HOLD` (MANUAL_UPLOAD_HOLD) or `AWAITING_APPROVAL` (HUMAN_REVIEW_HOLD) | Side-phase entered; non-side phases skipped until side-phase clears |
| `FAIL` (unrecoverable error) | `FAILED` | Terminal; no automatic retry after bounded retries exhaust |

---

## Cross-references

- `workflow_state_enum` — canonical 10-value run-state enum; gate-outcome-to-state mapping binds to this
- `workflow_run_schema` — `current_phase_index`, `current_phase_name`, `effective_phase_sequence_json` columns
- `gate_function_library_schema` — registered gate functions referenced by name in this sequence
- `out_config_schema` — `enabled_phases`, `manual_upload_hold_reminder_days`, `evidence_discovery_*_enabled` toggles
- `data_layer_conventions_policy` — UUID v7 for run IDs; canonical JSON for `effective_phase_sequence_json`
- `audit_event_taxonomy` — `WORKFLOW_GATE_EVALUATED`, `WORKFLOW_GATE_HOLD`, `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE`
- Block 12 Phase 02 — `OUT_MONTHLY` type registration (authoritative source for this sequence)
- Block 12 Phase 05 — gate-function library (authoritative source for gate logic)
- Block 12 Phase 06 — `MANUAL_UPLOAD_HOLD` phase detail
- Block 12 Phase 07 — `HUMAN_REVIEW_HOLD` phase detail
- Block 03 Phase 04 — state machine; `transitionRun()` called on every gate outcome
- Block 03 Phase 05 — gate evaluation framework; caching; re-evaluation triggers
