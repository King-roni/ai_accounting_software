# Run Phase Enum

**Block:** 03 — Workflow Engine  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This document defines the `run_phase_enum` type and documents the semantics of each phase in the workflow run lifecycle. Phases are the sequential processing stages a workflow run passes through from document intake to finalized output. Each phase has defined entry and exit conditions, a gate check that guards the transition to the next phase, and a set of tools that execute within it. Phase ordering is fixed and non-negotiable; no phase may be skipped.

---

## 1. Enum Definition

```sql
CREATE TYPE run_phase_enum AS ENUM (
    'INTAKE',
    'CLASSIFICATION',
    'MATCHING',
    'LEDGER_POST',
    'VAT_CALC',
    'REVIEW',
    'APPROVAL',
    'FINALIZATION'
);
```

Phases are ordered by their enum position. The workflow engine always advances phases in declaration order. The `workflow_phase_states` table stores one row per `(workflow_run_id, phase)` pair, tracking the status of each phase independently.

---

## 2. Phase Definitions

### 2.1 INTAKE

**Description:** Documents and bank statements are ingested, validated, deduplicated, and parsed into structured records. Raw files are stored in the Processing zone (7-day TTL post-run). Intake is the entry point for all financial data entering the system.

**Entry condition:** `workflow_runs.run_status = CREATED`. The INTAKE phase begins immediately after run creation.

**Exit condition:** All uploaded files have been parsed, deduplicated, and their `bank_upload` or `document` rows are in a non-`PROCESSING` terminal state. The deduplication fingerprint for each record has been computed and stored.

**Gate check:** `engine.gate_intake_complete` — verifies that no `bank_upload` or `document` rows for this run remain in `PROCESSING` status, and that at least one parseable record exists. If the run has zero parseable records, the gate holds with a `WORKFLOW_GATE_HOLD` event and routes to a `REVIEW_HOLD` for operator intervention.

**Tools executing in this phase:**
- `intake.parse_bank_statement`
- `intake.parse_document`
- `intake.validate_file_format`
- `intake.dedup_check`
- `intake.extract_line_items`

**Associated run_status values:** `RUNNING` (throughout), `REVIEW_HOLD` (if gate holds due to zero parseable records or a file validation error requiring human intervention).

**Failure behaviour:** If a file fails to parse due to a format error, the specific file's `bank_upload` or `document` row is marked `FAILED`. The run continues with the remaining parseable files. If all files fail, `engine.gate_intake_complete` holds the run.

**Compensation path:** If INTAKE fails entirely (e.g., all uploaded objects are corrupt), the run transitions to `FAILED`. No compensation is needed as no downstream data has been written.

---

### 2.2 CLASSIFICATION

**Description:** Parsed transactions and document line items are classified against the chart of accounts using AI-assisted classification rules. Each transaction receives a classification result including account code, confidence score, and match level. Results below the business's `classification_confidence_threshold` are flagged for review.

**Entry condition:** INTAKE phase has exited successfully (gate passed).

**Exit condition:** Every parsed transaction row has a classification result (even if that result is `NO_MATCH`). No transaction may remain in an `UNCLASSIFIED` state at exit.

**Gate check:** `engine.gate_classification_complete` — verifies that all transaction rows for the run have a `classification_output` row with a non-null `match_level`. Routes low-confidence results to the review queue (does not hold the run; adds REVIEW issues). Holds if any transaction remains fully unprocessed.

**Tools executing in this phase:**
- `classification.apply_rules`
- `classification.invoke_ai_classifier`
- `classification.validate_output`
- `ai.classify_transaction`

**Associated run_status values:** `RUNNING`, `REVIEW_HOLD` (if AI tier escalation is required and awaits operator action).

**Failure behaviour:** If the AI classifier fails for a specific transaction, the classification falls back to rule-based classification only. If rule-based also fails, the transaction receives `match_level = NO_MATCH` and is routed to the review queue. The run does not fail due to individual classification failures.

**Compensation path:** If the phase fails globally (e.g., AI gateway unreachable for all transactions), the classification output rows are deleted and the phase is retried from the beginning per `retry_policy.md`.

**Why CLASSIFICATION must follow INTAKE:** Classification operates on parsed transaction records. Until INTAKE is complete, the record set is not stable (deduplication may still be running).

---

### 2.3 MATCHING

**Description:** Classified transactions are matched against invoices, credit notes, and bank statement rows to identify which financial events correspond to each other. Match results include a `match_level` (`EXACT`, `STRONG_PROBABLE`, `WEAK_POSSIBLE`, `NO_MATCH`) and an evidence payload.

**Entry condition:** CLASSIFICATION phase has exited successfully (gate passed).

**Exit condition:** Every classified transaction has been evaluated for matching. All `EXACT` and `STRONG_PROBABLE` matches are confirmed. `WEAK_POSSIBLE` and `NO_MATCH` results have been routed to the review queue.

**Gate check:** `engine.gate_matching_complete` — verifies that all transactions have a `match_record` row, that no match scoring is in progress, and that the match signal evidence payload is populated. Routes unresolved `WEAK_POSSIBLE` and `NO_MATCH` records to the review queue. Does not hold the run for unresolved matches (the review queue handles those).

**Tools executing in this phase:**
- `matching.score_transaction`
- `matching.resolve_counterparty`
- `matching.apply_split_payment_detection`
- `matching.apply_income_matching`

**Associated run_status values:** `RUNNING`, `REVIEW_HOLD` (if unresolved matches exceed the configured threshold for auto-advance).

**Failure behaviour:** Individual match scoring failures are retried per `retry_policy.md`. Persistent failures result in `match_level = NO_MATCH` for the affected transaction. The run proceeds.

**Compensation path:** If the phase fails globally, match record rows for the run are deleted and the phase is retried.

**Why MATCHING must follow CLASSIFICATION:** Matching uses the account code and classification confidence to weight match signals. Unclassified transactions cannot be reliably matched.

---

### 2.4 LEDGER_POST

**Description:** Confirmed match results are posted as double-entry ledger entries to the `ledger_entries` table. Each posting produces a pair of debit and credit entries. The ledger is the authoritative record of accounting entries for the period.

**Entry condition:** MATCHING phase has exited successfully (gate passed).

**Exit condition:** All confirmed matches (`EXACT` and `STRONG_PROBABLE`) have corresponding `ledger_entries` rows. The trial balance check passes (total debits equal total credits within floating-point tolerance).

**Gate check:** `engine.gate_ledger_balanced` — verifies that the sum of all debit entries equals the sum of all credit entries for the run, within a tolerance of 0.01 in the default currency. Holds if imbalanced.

**Tools executing in this phase:**
- `ledger.post_entry`
- `ledger.validate_double_entry`
- `ledger.apply_fx_conversion`

**Associated run_status values:** `RUNNING`, `REVIEW_HOLD` (if trial balance fails and requires human correction).

**Failure behaviour:** If a specific ledger posting fails (e.g., invalid account code), the transaction is flagged in the review queue and the posting is skipped. The run continues with the remaining transactions.

**Compensation path:** If the phase fails globally, all `ledger_entries` rows for the run are deleted and the phase is retried. Ledger posting is idempotent via the `dedup_key` column.

**Why LEDGER_POST must follow MATCHING:** Ledger entries represent confirmed economic events. Posting unconfirmed or speculative matches would produce an unreliable trial balance.

---

### 2.5 VAT_CALC

**Description:** VAT amounts are calculated for each ledger entry based on the Cyprus VAT rule catalog, the business's VAT scheme, and the classification of each transaction. VAT entries are written to the `vat_entries` table and aggregated into `vat_period_summaries`.

**Entry condition:** LEDGER_POST phase has exited successfully (gate passed).

**Exit condition:** All ledger entries with a VAT-applicable account code have a corresponding `vat_entries` row. The VAT period summary for the run's period has been computed.

**Gate check:** `engine.gate_vat_calc_complete` — verifies that all VAT-applicable ledger entries have `vat_entries` rows, and that the VAT period summary net VAT figure matches the sum of individual `vat_entries` rows.

**Tools executing in this phase:**
- `ledger.calculate_vat`
- `ledger.apply_vat_rules`
- `ledger.aggregate_vat_period`

**Associated run_status values:** `RUNNING`, `REVIEW_HOLD` (if a VAT treatment cannot be determined for a transaction and requires human classification).

**Failure behaviour:** Transactions where VAT treatment is ambiguous are flagged in the review queue with an `AMBIGUOUS_VAT_TREATMENT` issue. VAT calculation continues for unambiguous transactions.

**Compensation path:** All `vat_entries` rows for the run are deleted and the phase is retried if the phase fails globally.

**Why VAT_CALC must follow LEDGER_POST:** VAT is calculated on the basis of posted ledger entries, not raw transactions. Calculating VAT before ledger posting would produce figures that do not match the posted accounts.

---

### 2.6 REVIEW

**Description:** All review queue issues accumulated during prior phases (low-confidence classifications, unmatched transactions, ambiguous VAT treatments, trial balance anomalies) are presented to the accountant for resolution. The run is in `REVIEW_HOLD` status until all BLOCKING issues are resolved.

**Entry condition:** VAT_CALC phase has exited successfully (gate passed).

**Exit condition:** No BLOCKING review issues remain open for the run. MEDIUM and LOW issues may be snoozed or carried forward.

**Gate check:** `engine.gate_review_clear` — verifies that `review_issues` for the run with `severity = BLOCKING` and `status = OPEN` count is zero. Holds if any BLOCKING issues remain.

**Tools executing in this phase:**
- `review_queue.load_issues`
- `review_queue.resolve_issue`
- `review_queue.snooze_issue`
- `review_queue.execute_bulk_action`

**Associated run_status values:** `REVIEW_HOLD` (typical), `RUNNING` (briefly, while issue loading is in progress).

**Failure behaviour:** Review phase does not fail in the traditional sense. The run remains in `REVIEW_HOLD` until the gate passes. The staleness watchdog in `human_review_approval_staleness_policy.md` escalates if the run has been in `REVIEW_HOLD` for too long without activity.

**Compensation path:** Not applicable. Review is a human-driven phase; there is nothing to compensate.

---

### 2.7 APPROVAL

**Description:** An authorised approver (typically the business owner or a designated accountant) reviews the complete run summary and provides explicit approval to proceed to finalization. Step-up MFA is required for approval.

**Entry condition:** REVIEW phase has exited successfully (gate passed).

**Exit condition:** A `workflow_run_approvals` row with `status = APPROVED` exists for the run and `approval_type = FINALIZATION`.

**Gate check:** `engine.gate_approval_granted` — verifies that a valid, non-expired approval record exists and that the approver's step-up token has been consumed. Holds if no approval exists or the most recent approval is expired or rejected.

**Tools executing in this phase:**
- `review_queue.present_run_summary`
- `engine.request_approval`
- `engine.record_approval`

**Associated run_status values:** `AWAITING_APPROVAL`, `REVIEW_HOLD` (if approval is rejected and the run is returned to review).

**Failure behaviour:** A rejected approval returns the run to `REVIEW_HOLD` status. The approver specifies a rejection reason. A new approval request is created by the accountant once the raised concerns are addressed.

**Compensation path:** Not applicable. Approval is a human-driven gate.

---

### 2.8 FINALIZATION

**Description:** The run is locked, ledger entries are permanently locked, the archive bundle is constructed and Object-Locked, the RFC 3161 timestamp is applied, and the period lock record is written. After finalization, the run status transitions to `FINALIZED`. No further modifications to the run's data are permitted without an adjustment workflow.

**Entry condition:** APPROVAL phase has exited successfully (gate passed).

**Exit condition:** `workflow_runs.run_status = FINALIZED`. `period_lock_status` row inserted. Archive bundle in Object Lock.

**Gate check:** `engine.gate_finalization_preconditions` — runs the full precondition checklist defined in `finalization_lock_policy.md`, including audit log quiescence check, ledger balance verification, archive manifest two-pass convergence, and step-up token validation.

**Tools executing in this phase:**
- `archive.construct_bundle`
- `archive.apply_rfc3161_timestamp`
- `archive.promote_manifest`
- `ledger.lock_entries`

**Associated run_status values:** `FINALIZING`, `FINALIZED`, `FAILED`, `COMPENSATING`.

**Failure behaviour:** If finalization fails after partial writes, the run enters `COMPENSATING` status. The `compensation_log` records the partial writes. The compensation sequence rolls back all partial writes.

**Compensation path:** Defined in `out_phase_compensation_policy.md` and `finalization_lock_policy.md`. All locks are reversed, archive objects are deleted from the staging bucket, and the run is returned to `AWAITING_APPROVAL` for a fresh finalization attempt.

---

## 3. Phase Ordering Rationale

The fixed ordering exists because each phase depends on outputs from the prior phase:

```
INTAKE     → produces: parsed transaction records
CLASSIFICATION → produces: account code assignments + confidence scores
MATCHING   → produces: confirmed match pairs (transaction ↔ invoice/bank row)
LEDGER_POST → produces: double-entry ledger entries
VAT_CALC   → produces: VAT entries derived from ledger entries
REVIEW     → resolves: quality issues from all prior phases
APPROVAL   → gates: human sign-off before irreversible finalization
FINALIZATION → produces: locked, timestamped, archived period record
```

No phase may be re-ordered or skipped. Skipping MATCHING before LEDGER_POST would produce unreconciled ledger entries. Skipping VAT_CALC before REVIEW would leave unresolved VAT issues hidden from the reviewer.

---

## 4. Integration with `tool_run_advance_phase` and `workflow_engine_core`

The `tool_run_advance_phase` tool is the sole mechanism for transitioning between phases. It:

1. Calls the gate check function for the current phase.
2. If the gate passes, inserts a `workflow_phase_states` row for the next phase with `status = RUNNING`.
3. Emits `WORKFLOW_GATE_PASSED` and `WORKFLOW_PHASE_STATE_TRANSITIONED` audit events.
4. Returns the new phase name to the caller.

The `workflow_engine_core` orchestrator calls `tool_run_advance_phase` at the end of each phase's tool sequence. The engine does not advance phases mid-sequence.

---

## 5. Phase Status in `workflow_phase_states`

Each phase has its own `workflow_phase_states` row tracking its individual execution status. The run-level `run_status` in `workflow_runs` is a derived representation of the active phase's status. The mapping is:

| Phase status | Run-level implication |
|-------------|----------------------|
| Phase `RUNNING` | Run is `RUNNING` |
| Phase `REVIEW_HOLD` | Run is `REVIEW_HOLD` |
| Phase `AWAITING_APPROVAL` | Run is `AWAITING_APPROVAL` |
| Phase `FINALIZED` (FINALIZATION only) | Run is `FINALIZED` |
| Phase `FAILED` | Run is `FAILED` |
| Phase `COMPENSATING` | Run is `COMPENSATING` |

---

## Related Documents

- `schemas/workflow_phase_states_schema.md`
- `schemas/workflow_run_schema.md`
- `schemas/gate_function_library_schema.md`
- `policies/out_phase_gate_policy.md`
- `policies/in_phase_gate_policy.md`
- `policies/finalization_lock_policy.md`
- `policies/out_phase_compensation_policy.md`
- `policies/retry_policy.md`
- `reference/workflow_state_enum.md`
- `reference/audit_event_taxonomy.md`
