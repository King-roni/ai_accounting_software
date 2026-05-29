# Finalization Failure — Per-Mode Runbook

**Category:** Runbooks · **Owning block:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 2)

**Block reference:** Block 15, Phases 02–06 (gate evaluation, ledger lock, bundle construction, RFC 3161 timestamping, Object Lock, zone promotion).

**Purpose:** Operator response steps for every known finalization failure mode. Each mode maps to a distinct system state. Operators must identify the mode from the run's `workflow_runs.status`, the most-recent `FINALIZATION_*` or `ARCHIVE_*` audit event, and the `compensation_log` table before taking action. Do not retry a run without first confirming the mode; retrying the wrong mode can produce a second partial write.

---

## Pre-triage checklist

Before working a failure mode:

1. Confirm `workflow_runs.status` for the affected run. Valid post-failure values: `REVIEW_HOLD`, `FAILED`, `COMPENSATING`.
2. Pull the most-recent audit events for the run: query `audit_log` filtered by `workflow_run_id` and `event_type LIKE 'FINALIZATION_%' OR event_type LIKE 'ARCHIVE_%'`, ordered by `event_time DESC LIMIT 20`.
3. Check `compensation_log` for any row with `workflow_run_id` matching the run. A `COMPENSATION_TRIGGERED` row means Step 3 of the 5-step lock sequence has started a rollback.
4. Do not attempt a retry while `status = COMPENSATING`. Wait for the compensation job to complete.

---

## Failure modes

### 1. `GATE_PRECONDITIONS_NOT_MET`

**Signal:** `engine.gate_finalization_preconditions` returned HOLD. Audit event: `WORKFLOW_GATE_HOLD` with `gate_name = gate_finalization_preconditions`. Run status: `REVIEW_HOLD`.

**Cause:** One or more precondition checks did not pass at gate evaluation time. Common causes: open review issues above the severity threshold, unlocked ledger entries from a prior partial run, or a missing accountant approval record.

**Operator steps:**

1. Query `review_issues` for the run: `SELECT issue_type, severity, status FROM review_issues WHERE workflow_run_id = '<run_id>' AND status NOT IN ('RESOLVED', 'DISMISSED') ORDER BY severity DESC`.
2. Resolve or dismiss all BLOCKING and HIGH issues through the review queue UI. Each resolution emits `REVIEW_ISSUE_RESOLVED`.
3. Verify no open transactions: `SELECT COUNT(*) FROM transactions WHERE workflow_run_id = '<run_id>' AND match_status NOT IN ('CONFIRMED', 'EXCEPTION_DOCUMENTED', 'UNMATCHED_ACCEPTED')`.
4. Confirm an approval record exists: `SELECT * FROM workflow_approvals WHERE workflow_run_id = '<run_id>'`. If missing, the OWNER must submit approval through the finalization UI.
5. Re-trigger gate evaluation via `engine.gate_finalization_preconditions`. A passing evaluation transitions the run to `FINALIZING`.

---

### 2. `STEP_UP_EXPIRED`

**Signal:** The finalization flow received a `STEP_UP_TOKEN_EXPIRED` audit event mid-sequence. Run status: `REVIEW_HOLD` (the engine rolls back to HOLD on step-up expiry before any write occurs).

**Cause:** Step-up MFA tokens have a short TTL (5 minutes per `step_up_token_policy`). If the operator paused between clicking "Finalize" and completing the step-up challenge, or if network latency caused the token validation to arrive after expiry, the token is rejected.

**Operator steps:**

1. Confirm the run is in `REVIEW_HOLD` with no `compensation_log` entry. If a compensation row exists, work mode 10 instead.
2. Navigate to the finalization UI for the run. The UI will show "Session expired — re-authenticate to continue."
3. Complete the step-up MFA challenge. A fresh step-up token (UUID v4, 5-minute TTL) is issued.
4. Re-submit the finalization request within the TTL window. The engine re-evaluates `engine.gate_finalization_preconditions` from the HOLD state.

**Note:** No data was written during the expired attempt. This mode is safe to retry immediately.

---

### 3. `CONCURRENT_FINALIZATION`

**Signal:** A second finalization attempt returned a `409 Conflict` error with body `{"error": "CONCURRENT_FINALIZATION"}`. The first session's run is in `FINALIZING` or `AWAITING_APPROVAL`.

**Cause:** Two operator sessions or two automated triggers both attempted to initiate finalization for the same run within a short window. The engine's optimistic-lock check on `workflow_runs` (`status = REVIEW_HOLD` precondition) rejects the second write.

**Operator steps:**

1. Query `workflow_runs` for the affected `business_id` and period: `SELECT id, status, updated_at FROM workflow_runs WHERE business_id = '<biz_id>' AND period_start = '<period>'`.
2. Identify which session is the active run (status `FINALIZING` or `AWAITING_APPROVAL`).
3. If the active run is progressing normally (status advancing, recent `FINALIZATION_*` events), take no action — the other session's attempt is safely rejected.
4. If the active run appears stuck (no audit events for > 15 minutes), investigate using the stall detection runbook (`resumability_policy`) before taking any action.
5. Do not force-cancel an actively running finalization. Cancellation of a `FINALIZING` run triggers the compensation sequence.

---

### 4. `LEDGER_LOCK_FAILED`

**Signal:** `ledger.lock_entries` returned an error. Audit event: `FINALIZATION_PRECONDITION_FAILED` with `detail = 'ledger_lock_failed'`. Run status: `REVIEW_HOLD` (lock failure before the 5-step sequence does not trigger compensation).

**Cause:** An open transaction or an uncommitted write is holding a row lock on one or more ledger entries targeted for bulk lock. Typically caused by a long-running classification or matching tool invocation that has not yet committed.

**Operator steps:**

1. Identify blocking transactions:

   ```sql
   SELECT pid, state, wait_event_type, wait_event, query_start, query
   FROM pg_stat_activity
   WHERE state != 'idle'
     AND query ILIKE '%ledger_entries%'
   ORDER BY query_start ASC;
   ```

2. If a blocking query belongs to a workflow tool, check `workflow_phase_states` for the phase to confirm it is still RUNNING. If the phase completed but left an uncommitted connection open, the Postgres idle-in-transaction timeout (60 seconds) will clear it automatically. Wait and re-check.

3. If the blocking session is idle-in-transaction and has persisted for more than 5 minutes, the Postgres `idle_in_transaction_session_timeout` should have terminated it. Verify the timeout parameter: `SHOW idle_in_transaction_session_timeout;`. If it reads `0`, escalate to engineering — the timeout is misconfigured.

4. Once no blocking sessions remain, re-attempt finalization from the HOLD state. `ledger.lock_entries` will re-run as part of the lock sequence.

---

### 5. `HASH_CHAIN_BROKEN`

**Signal:** Audit event: `AUDIT_HASH_CHAIN_VERIFICATION_FAILED` (domain `AUDIT`, BLOCKING severity). Run status: `REVIEW_HOLD`. The finalization gate (`engine.gate_finalization_preconditions`) checks hash-chain integrity before allowing the lock sequence to proceed.

**Cause:** A `chain_hash` value on `audit_log_hash_chain` does not match the recomputed value for that sequence number. This indicates either data corruption in the audit log table or tampering with a stored event payload.

**Action: Do NOT retry finalization.**

**Operator steps:**

1. Record the `first_broken_sequence_number` and `audit_log_id` from the event payload.
2. Do not modify any audit log rows. The audit log is append-only; any write attempt must go through `emitAudit()`.
3. Escalate immediately to engineering with the full event payload, the `workflow_run_id`, and the `business_id`.
4. Engineering will run the forensic procedure from `tamper_detection_forensic_runbook.md`.
5. The run remains in `REVIEW_HOLD` until engineering confirms the root cause and approves a remediation path. Finalization cannot proceed until the chain is verified clean from a known-good anchor.
6. If the break is confirmed as a storage provider integrity issue (not tampering), engineering applies the remediation defined in `archive_verification_policy.md`. This requires a platform-admin action and a `decisions_log.md` entry.

---

### 6. `BUNDLE_PASS1_MISSING_DOCUMENTS`

**Signal:** Audit event: `ARCHIVE_BUNDLE_PASS1_COMPLETED` is absent; instead `ARCHIVE_BUNDLE_INTEGRITY_FAILED` is emitted with `failure_detail` referencing a missing Object Storage key. Run status: `REVIEW_HOLD`.

**Cause:** One or more documents referenced in the archive manifest were not found in Object Storage at bundle construction time. The document row exists in the database but the corresponding object is absent from the `documents` bucket.

**Operator steps:**

1. From the `ARCHIVE_BUNDLE_INTEGRITY_FAILED` event payload, extract the `object_key` of the missing document.
2. Look up the document record: `SELECT id, filename, evidence_hash, upload_status FROM documents WHERE storage_key = '<object_key>'`.
3. Verify the document was actually uploaded by checking `document_uploads` for the corresponding `document_id`.
4. If the document was uploaded successfully but the object is missing from storage, this is a storage provider data-loss event. Open a support ticket with the storage provider immediately and escalate to engineering.
5. If the document was never uploaded (upload status shows `PENDING` or `FAILED`), instruct the business to re-upload the document through the document intake UI. Once uploaded and OCR-verified, re-trigger bundle construction.
6. After the missing document is confirmed present in Object Storage, re-attempt finalization. `archive.construct_bundle` will re-run Pass 1 from scratch.

---

### 7. `BUNDLE_PASS2_HASH_MISMATCH`

**Signal:** Audit event: `ARCHIVE_BUNDLE_INTEGRITY_FAILED` emitted during Pass 2 with `expected_sha256_hex` ≠ `computed_sha256_hex`. Run status: `REVIEW_HOLD`.

**Cause:** The SHA-256 hash of the bytes retrieved from Object Storage does not match the hash stored on the `documents` row at write time. The stored document has been modified after the hash was recorded, or the storage object was corrupted.

**Action: Do NOT retry finalization.**

**Operator steps:**

1. Record the `object_key`, `expected_sha256_hex`, and `computed_sha256_hex` from the event payload.
2. Check Object Storage access logs for any write operations on the affected key after the document's `created_at` timestamp.
3. Escalate to engineering immediately. This is a potential tamper or storage integrity event.
4. Engineering follows the forensic procedure in `tamper_detection_forensic_runbook.md`.
5. The run stays in `REVIEW_HOLD` until root cause is confirmed. Do not re-upload the document without engineering authorization — overwriting the object destroys the evidence.

---

### 8. `OBJECT_LOCK_FAILED`

**Signal:** Audit event: `OBJECT_LOCK_VIOLATION_DETECTED` or the lock sequence Step 5 returning a storage API error. Run status: `COMPENSATING` (if lock failed mid-sequence after prior steps committed), or `REVIEW_HOLD` (if lock failed before any write).

**Cause:** The Object Lock API call to the storage provider failed. Most commonly a transient storage provider error (5xx), a misconfigured bucket policy, or a rate-limit event.

**Operator steps:**

1. Check `compensation_log` first: `SELECT * FROM compensation_log WHERE workflow_run_id = '<run_id>'`. If a compensation row exists, the run is in `COMPENSATING` — work mode 10 instead.
2. If no compensation row, the failure was caught before writes committed. Check the storage provider's status page for ongoing incidents.
3. Wait 15 minutes, then re-attempt finalization from the `REVIEW_HOLD` state.
4. If the error persists after two retries, open a support ticket with the storage provider, referencing the specific bucket name and the storage API error code from the event payload.
5. Verify the bucket's Object Lock configuration is intact: the bucket must have `objectLockEnabled = true` and the default retention mode must be `COMPLIANCE`. If either is wrong, escalate to engineering — this is a configuration drift that blocks all future finalizations.

---

### 9. `RFC3161_TIMESTAMP_FAILED`

**Signal:** Audit event: `RFC3161_TIMESTAMP_FAILED` (HIGH severity). Run status: deferred — per `rfc3161_timestamp_policy.md`, timestamping failure is non-blocking for finalization progression. The run may continue to `FINALIZED` with a deferred timestamp.

**Cause:** The RFC 3161 TSA (Timestamp Authority) was unavailable after three retry attempts. The TSA endpoint may be experiencing an outage.

**Operator steps:**

1. Confirm from the event payload which TSA endpoint was attempted (`tsa_endpoint`) and the `attempt_count`.
2. Check the TSA's public status page if available.
3. The system defers re-timestamping automatically per `rfc3161_timestamp_policy.md`. The `archive_bundles` row will have `rfc3161_status = PENDING_RETRY`.
4. Wait 1 hour. The retry job runs on a scheduled interval and will re-attempt the TSA call when the endpoint recovers.
5. Monitor for `RFC3161_TIMESTAMP_APPLIED` on the `archive_package_id` from the original failure event. Once emitted, the bundle is fully sealed.
6. If the retry job fails repeatedly over 24 hours, escalate to engineering. The TSA provider SLA may need to be reviewed or a secondary TSA endpoint configured.

---

### 10. `COMPENSATION_TRIGGERED`

**Signal:** Audit event: `COMPENSATION_LOG_APPENDED` (HIGH severity). Run status: `COMPENSATING`.

**Cause:** A partial write occurred during the 5-step lock sequence — some steps committed successfully before a subsequent step failed. The compensation job is rolling back the partial writes to return the run to a consistent state.

**Operator steps:**

1. Do not touch the run while `status = COMPENSATING`. The compensation job is running autonomously.
2. Poll `workflow_runs.status` every 2 minutes: `SELECT status, updated_at FROM workflow_runs WHERE id = '<run_id>'`.
3. The expected transition is `COMPENSATING` → `FAILED`. If this transition does not occur within 30 minutes, escalate to engineering — the compensation job itself may be stuck.
4. Once status is `FAILED`, check `compensation_log` for the `compensation_outcome` field. A value of `ROLLED_BACK_CLEAN` means all partial writes were successfully reversed.
5. If `compensation_outcome = PARTIAL_ROLLBACK`, escalate to engineering immediately. The data state is inconsistent and requires manual reconciliation before finalization can be re-attempted.
6. After a clean rollback (`ROLLED_BACK_CLEAN`), identify the root cause of the original failure from the `partial_write_description` in the compensation row, address it, and re-attempt finalization from `REVIEW_HOLD`.

---

### 11. `AUDIT_QUIESCENT_TIMEOUT`

**Signal:** Audit event: `FINALIZATION_AUDIT_LOG_QUIESCENT_HOLD` emitted. Run status: `REVIEW_HOLD`. The quiescence check gate (`engine.gate_finalization_preconditions`) polls the audit log to verify no in-flight emits are pending for the run before the lock sequence begins.

**Cause:** One or more audit write jobs for the run did not complete within the quiescence timeout window (typically 30 seconds). This may indicate a stuck audit emit, a database deadlock on `chain_heads`, or an unusually high audit emit backlog.

**Operator steps:**

1. Query for pending audit emit jobs: check the job queue table for any rows with `job_type = 'AUDIT_EMIT'` and `workflow_run_id = '<run_id>'` in a non-terminal state.
2. Check for lock contention on `chain_heads`: `SELECT * FROM pg_locks WHERE relation = 'chain_heads'::regclass`. A long-held lock indicates a stuck transaction.
3. If the stuck transaction can be identified from `pg_stat_activity` and belongs to a non-critical system process, escalate to engineering for safe termination. Do not terminate without engineering approval.
4. Once the job queue is clear and `pg_locks` shows no contention on `chain_heads`, re-attempt finalization. The quiescence gate will re-evaluate.
5. If the issue recurs, check for Postgres replica lag — the quiescence check reads from the primary, but a lagging replica serving the job queue may produce false positives. Review `pg_stat_replication` for lag values.

---

### 12. `ARCHIVE_PROMOTION_FAILED`

**Signal:** Audit event: `ARCHIVE_PROMOTION_FAILED` (domain `ARCHIVE`). Run status: `FAILED` (zone promotion is the final step; a failure here means the bundle is built and locked but not yet promoted to the Archive zone).

**Cause:** The zone-promotion step — which moves data from the Processing zone (7-day TTL) to the permanent Archive zone — failed. The archive bundle is Object-Locked in storage but the `archive_packages` row has not been flagged as Archive-zone resident.

**Operator steps:**

1. Confirm the Object Lock is in place: verify `archive_bundles.lock_status = 'LOCKED'` and check the storage provider console for the object's lock retention configuration.
2. The Object Lock protects the bundle regardless of the zone-promotion status — the physical object will not expire.
3. Retry zone promotion via `archive.retry_promotion`: this tool is idempotent and re-runs only the zone-promotion flag write.

   ```
   archive.retry_promotion({ workflow_run_id: '<run_id>' })
   ```

4. On success, `ARCHIVE_PROMOTION_COMPLETED` is emitted and the run transitions to `FINALIZED`.
5. If `archive.retry_promotion` fails repeatedly, check for a database write error on `archive_packages` (constraint violation, RLS deny, or schema mismatch). Escalate to engineering with the Postgres error from the tool's output.
6. Monitor: after a successful promotion, confirm `ANALYTICS_REFRESH_TRIGGERED` fires within 5 minutes (the analytics rebuild subscriber listens for `ARCHIVE_PROMOTION_COMPLETED`).

---

### 13. `FINALIZATION_GATE_REOPENED`

**Signal:** A downstream data change (e.g., a document re-upload, a ledger entry correction, or an admin override) caused `engine.gate_finalization_preconditions` to re-evaluate to HOLD after the finalization sequence had already begun. Audit event: `WORKFLOW_GATE_HOLD` emitted for a run in `FINALIZING` status. Run status: forced back to `REVIEW_HOLD`.

**Cause:** The gate reopening is a safety mechanism. If data changes occur concurrently with finalization (which should not happen under normal operating conditions — the UI blocks writes once `FINALIZING` begins), the engine must halt and revert.

**Operator steps:**

1. Identify the data change that triggered the gate reopening. Look for `LEDGER_ENTRIES_RECOMPUTED`, `DOCUMENT_STATE_CHANGED`, or `MANUAL_OVERRIDE_REJECTED_FINALIZED_PERIOD` events emitted close in time to the `WORKFLOW_GATE_HOLD` event.
2. If the change was made in error, reverse it through the appropriate review queue or ledger tool and document the reversal in the review queue notes.
3. If the change was legitimate, allow it to propagate. The gate will evaluate the new data state when finalization is re-attempted.
4. Run `engine.gate_finalization_preconditions` to get the current blocking-issue list before re-submitting finalization.
5. Confirm the run status is `REVIEW_HOLD` (not `COMPENSATING`) before re-attempting. A `FINALIZATION_GATE_REOPENED` event does not trigger compensation — no lock-sequence writes were committed after the gate re-held.
6. Investigate how the concurrent write was possible: the finalization write-lock in the UI should prevent this. If this mode appears repeatedly, escalate to engineering to audit the write-lock enforcement on the finalization surface.

---

## Run status reference

| Mode | Status at detection | Expected resolution status |
|---|---|---|
| `GATE_PRECONDITIONS_NOT_MET` | `REVIEW_HOLD` | `FINALIZED` (after resolution) |
| `STEP_UP_EXPIRED` | `REVIEW_HOLD` | `FINALIZED` (after re-auth) |
| `CONCURRENT_FINALIZATION` | `FINALIZING` (first run) | `FINALIZED` (first run proceeds) |
| `LEDGER_LOCK_FAILED` | `REVIEW_HOLD` | `FINALIZED` (after lock cleared) |
| `HASH_CHAIN_BROKEN` | `REVIEW_HOLD` | Engineering decision |
| `BUNDLE_PASS1_MISSING_DOCUMENTS` | `REVIEW_HOLD` | `FINALIZED` (after re-upload) |
| `BUNDLE_PASS2_HASH_MISMATCH` | `REVIEW_HOLD` | Engineering decision |
| `OBJECT_LOCK_FAILED` | `COMPENSATING` or `REVIEW_HOLD` | `FAILED` → `FINALIZED` (after provider recovery) |
| `RFC3161_TIMESTAMP_FAILED` | `FINALIZED` (deferred) | `FINALIZED` (timestamp applied by retry job) |
| `COMPENSATION_TRIGGERED` | `COMPENSATING` | `FAILED` → `FINALIZED` (after clean rollback) |
| `AUDIT_QUIESCENT_TIMEOUT` | `REVIEW_HOLD` | `FINALIZED` (after queue cleared) |
| `ARCHIVE_PROMOTION_FAILED` | `FAILED` | `FINALIZED` (after retry) |
| `FINALIZATION_GATE_REOPENED` | `REVIEW_HOLD` | `FINALIZED` (after data reconciliation) |

---

## Cross-references

- `finalization_gate_sql_schema.md` — gate precondition SQL and blocking-issue query shapes
- `lock_sequence_policies.md` — the 5-step lock sequence and per-step failure semantics
- `compensation_log_schema.md` — `compensation_log` table structure and `compensation_outcome` enum
- `archive_verification_policy.md` — post-finalization verification checks and false-positive procedure
- `tamper_detection_forensic_runbook.md` — forensic trace for hash-mismatch and tamper events
- `rfc3161_timestamp_policy.md` — TSA retry schedule and deferred-timestamp handling
- `audit_event_taxonomy.md` — canonical event names referenced throughout this runbook
