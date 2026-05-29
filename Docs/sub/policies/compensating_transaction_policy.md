# Policy: Compensating Transactions and COMPENSATING Run Status

## Scope

This policy defines when a workflow run enters `COMPENSATING` status, what operations are permitted during compensation, who may initiate compensation, how compensation interacts with the archive hash chain, and what the valid exit conditions are.

---

## 1. What Triggers COMPENSATING Status

A run transitions to `COMPENSATING` when finalization fails mid-way after partial writes have already been committed. This is a partial-failure scenario: some portion of the finalization work completed successfully (for example, ledger entries were created and some documents were archived) before the failure occurred.

Because partial writes leave the system in an inconsistent state, normal retry logic is insufficient. A compensating sequence is required to roll back the effects of the partial finalization before the run can re-enter the review queue.

Specific triggers:

- **Ledger posting partially completed:** Some but not all double-entry pairs for the run's documents were posted before the finalization job failed.
- **Archive partially promoted:** Some documents were written to the archive bundle and their hash chain entries were created, but others were not processed before failure.
- **Run finalize lock acquired but not released:** The finalization lock was obtained and intermediate state was written, but the process terminated before the lock was properly released.

The transition to `COMPENSATING` is performed by `tool_run_finalize` when it detects a partial-write condition after a failed finalization attempt. The transition is system-initiated and logged in `workflow_run_log`.

---

## 2. Allowed Compensating Actions

During `COMPENSATING` status, only the following operations are permitted on the run:

### 2a. Reverse ledger entries created during failed finalization

Use `tool_ledger_reverse` to create reversing entries for each ledger entry that was created during the failed finalization. Each reversal must:
- Reference the original ledger entry ID in the reversal record.
- Use the same account code and amount as the original, with sides inverted.
- Be tagged with `reversal_reason = 'COMPENSATION'` and `originating_run_id` pointing to the failed run.

Reversal entries are real ledger entries and participate in the hash chain normally.

### 2b. Unmark archived documents

Any documents that were promoted to the archive during the partial finalization must have their archive promotion reversed:
- Set `archive_entries.status = 'COMPENSATION_REVERSED'` for affected entries.
- Add a REVERSAL entry to the hash chain for each reversed archive entry (see section 5).
- The underlying document record (`documents.archived_at`, `documents.archive_bundle_id`) is cleared.

### 2c. Restore run to REVIEW_HOLD

Once all compensating actions have been confirmed successful, the run transitions to `REVIEW_HOLD`. From `REVIEW_HOLD`, the accountant can review the situation, correct any underlying issues, and re-initiate finalization.

No other status transitions are permitted during `COMPENSATING`. The run cannot be cancelled, paused, or sent to `FAILED` via direct transition while compensation is in progress.

---

## 3. Who Can Initiate Compensation

Compensation is **system-initiated only**. No user, accountant, or org:owner may manually trigger the compensation sequence.

The compensation sequence is started automatically by the finalization failure handler in `tool_run_finalize`. The handler evaluates whether partial writes occurred (by checking `compensation_log` for the run's finalization attempt) and, if so, transitions the run to `COMPENSATING` and enqueues the compensation job.

Users cannot initiate, cancel, or interfere with a compensation sequence that is in progress. The review queue will surface a notification to the assigned accountant informing them that the run is in compensation and that no action is required from them until `REVIEW_HOLD` is restored.

---

## 4. Idempotency Requirements

All compensation steps must be idempotent. This is a hard requirement because the compensation job may fail and be retried.

Idempotency is enforced as follows:

- Each compensation action is recorded in `compensation_log` before execution, with a `status` of `PENDING`.
- After successful execution, the log entry is updated to `COMPLETED`.
- On retry, the compensation handler checks `compensation_log` before attempting each action. If an entry exists with `status = 'COMPLETED'`, the step is skipped.
- If an entry exists with `status = 'PENDING'` and the action appears to have already been applied (detected via database state), the handler marks it `COMPLETED` without re-executing.

The `compensation_log.idempotency_key` is constructed as `<run_id>:<step_type>:<target_id>` to ensure uniqueness per run per action.

---

## 5. Hash Chain Interaction

The archive hash chain is an append-only structure. Compensation does not delete hash chain entries; it **appends REVERSAL entries** that logically cancel the original entry.

For each archive entry reversed during compensation:

1. A new row is appended to the hash chain with `entry_type = 'REVERSAL'`.
2. The `previous_hash` of the reversal entry is the hash of the original entry being reversed.
3. The `reversal_ref_id` field on the reversal entry points to the original entry's ID.
4. The chain integrity is maintained: `hash_chain_verify` will recognize `REVERSAL` entry pairs as valid and will not flag them as tampering.

The original entry is not modified. The pair (original + reversal) is the permanent record of what happened during compensation.

---

## 6. Exit Conditions from COMPENSATING

### 6a. Success → REVIEW_HOLD

If all compensation steps complete successfully (all `compensation_log` entries for the run have `status = 'COMPLETED'`):

1. Transition `workflow_runs.status` from `COMPENSATING` → `REVIEW_HOLD`.
2. Create a review queue issue of type `FINALIZATION_COMPENSATION_COMPLETED` to notify the accountant.
3. Emit `ENGINE_RUN_COMPENSATION_SUCCEEDED` audit event.

From `REVIEW_HOLD`, the standard review and re-finalization path applies.

### 6b. Failure → FAILED

If the compensation sequence itself fails (the compensation job exhausts its retry budget without completing all steps):

1. Transition `workflow_runs.status` from `COMPENSATING` → `FAILED`.
2. Leave `compensation_log` entries in `PENDING` or `FAILED` state for forensic review.
3. Emit `ENGINE_RUN_COMPENSATION_FAILED` audit event with the list of incomplete steps.
4. Create a `BLOCKING` severity review queue issue requiring manual intervention from an operator with `org:owner` role.

A run in `FAILED` status cannot be recovered through normal tooling. Manual database intervention by an operator is required, and this must follow the forensic runbook (`tamper_detection_forensic_runbook.md`).

---

## 7. Audit Taxonomy Notes

The following audit events are used in compensation flows. Verify each exists in the taxonomy:

- `ENGINE_RUN_COMPENSATION_SUCCEEDED` — domain `ENGINE`, entity `RUN`, verb `COMPENSATION_SUCCEEDED`
- `ENGINE_RUN_COMPENSATION_FAILED` — domain `ENGINE`, entity `RUN`, verb `COMPENSATION_FAILED`
- `LEDGER_ENTRY_REVERSED` — domain `LEDGER`, entity `ENTRY`, verb `REVERSED` (tagged with `reversal_reason = 'COMPENSATION'`)
- `ARCHIVE_ENTRY_COMPENSATION_REVERSED` — domain `ARCHIVE`, entity `ENTRY`, verb `COMPENSATION_REVERSED`

---

## Related Documents

- `schemas/compensation_log_schema.md` — Log table tracking individual compensation steps.
- `schemas/compensation_trigger_schema.md` — Trigger conditions that initiate compensation.
- `tools/tool_run_finalize.md` — The tool that detects partial failure and initiates compensation.
- `tools/tool_ledger_reverse.md` — Used to create reversing ledger entries during compensation.
- `policies/hash_chain_verification_policy.md` — How REVERSAL entries are handled during chain verification.
- `policies/archive_integrity_policy.md` — Archive integrity rules that govern reversal entry structure.
- `runbooks/run_finalization_failure_runbook.md` — Operator response when a run enters FAILED from COMPENSATING.
- `runbooks/tamper_detection_forensic_runbook.md` — Forensic procedure for runs stuck in unrecoverable states.
- `schemas/workflow_run_schema.md` — Run record definition including `run_status_enum` values for `COMPENSATING` and `FAILED`.
- `policies/resumability_and_idempotency.md` — Platform-wide idempotency conventions that compensation steps must follow.
