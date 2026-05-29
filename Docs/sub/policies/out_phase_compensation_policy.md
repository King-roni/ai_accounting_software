# out_phase_compensation_policy

**Category:** Policies · **Owning block:** 12 — OUT Workflow · **Stage:** 4 sub-doc (Layer 2 policy)

Defines the compensation sequence for a partially-executed OUT workflow run: what triggers it, which states are reversed, which are retained, and how idempotency is maintained across interruptions.

---

## Compensation trigger

Compensation is initiated when `engine.abort` is called on an OUT run (`workflow_type` in `{OUT_MONTHLY, OUT_ADJUSTMENT}`) that has already written state beyond the initial CREATED or early RUNNING phase. Specifically, compensation is required when any of the following are true at abort time:

- Ledger entries have been posted (`ledger_entries` rows exist with `source_run_id = run_id`)
- Workflow approvals in `APPROVED` status exist for the run
- A `FINALIZATION_LOCK` was acquired for the run (only possible during the FINALIZING phase)

Trigger conditions and their precedence are enumerated in `compensation_trigger_schema.md`. The engine evaluates all trigger conditions before starting compensation; a run with no trigger conditions active transitions directly to `CANCELLED` without entering `COMPENSATING`.

---

## COMPENSATING status

When compensation is required:

1. `run_status` transitions to `COMPENSATING` before `CANCELLED`.
2. While in `COMPENSATING`, no new phase entry is permitted. Calls to `engine.advance_phase` for this run return `ADVANCE_FORBIDDEN`.
3. Compensation actions execute in reverse phase order — the highest-index committed phase is compensated first, down to the first phase that wrote durable state.
4. When all compensation actions complete, `run_status` transitions from `COMPENSATING` to `CANCELLED`.

---

## What is compensated

### Ledger entries

Posted ledger entries are reversed via compensating double-entries. Each reversal entry:

- Has `compensation_for_entry_id` FK pointing to the original `ledger_entries.id`.
- Has a `description` prefixed with `"COMPENSATION:"` followed by the original description.
- Uses the same account codes as the original but with debits and credits swapped.
- Has `source_run_id` set to the same run being aborted, so the compensating entries are traceable to the abortion event.

Compensating entries are written in a single transaction per original phase's entry batch. Partial reversal within a batch is not permitted; all entries from a phase batch are reversed together.

### Approved workflow approvals

`workflow_run_approvals` rows with `status = APPROVED` for this run are revoked: `status` transitions to `REVOKED` with `revoked_at = now()` and `revoked_reason = 'RUN_COMPENSATED'`.

PENDING approvals are expired (set to `EXPIRED`) per `out_run_abort_policy.md` before compensation starts. Only APPROVED approvals are revoked during the compensation sequence itself.

### Resolved review issues

Review issues resolved within the aborted run (i.e., `review_issues` rows where `resolved_in_run_id = run_id`) are re-opened: `status` transitions back to `OPEN` and `resolved_in_run_id` is cleared. The resolution action payload is retained in `review_issue_history` for audit.

This re-opening ensures that issues which were resolved mid-run do not appear silently resolved when the run is re-attempted.

### Locked exception records

`out_exception_documented` records that were locked during this run are unlocked: the `locked_by_run_id` FK is cleared. The exception record itself is retained per `out_run_abort_policy.md`.

### FINALIZATION_LOCK

If a `FINALIZATION_LOCK` was acquired for this run (indicating the run reached the FINALIZING phase before abort), the lock is released. Releasing the lock allows a new run for the same period to acquire it in a future attempt.

---

## What is NOT compensated

The following are intentionally not reversed:

- Audit log entries — the audit log is append-only. No reversal entries are written and no existing entries are deleted. The compensation actions themselves generate new audit events documenting what was reversed.
- `bank_statement_rows` — retained for traceability. Marked with the aborted run's `source_run_id`.
- `out_run_configs` — the run configuration is retained for audit and potential re-run reference.
- `carry_forward_log` rows — carry-forward records are append-only and are retained even after abort.

---

## Idempotency

Compensation is idempotent. If the `COMPENSATING` state is interrupted (engine crash, timeout), the compensation sequence can be re-run safely:

- Already-reversed ledger entries are detected by the presence of a `compensation_for_entry_id` row matching the original; the engine skips them.
- Already-revoked approvals (`status = REVOKED`) are skipped.
- Already-re-opened review issues (`resolved_in_run_id IS NULL`) are skipped.
- An already-released `FINALIZATION_LOCK` (lock row absent or `released_at` set) is skipped.

The engine records each compensation step completion in `compensation_step_log` (schema: `compensation_trigger_schema.md`) before proceeding to the next step. On resume, completed steps are skipped by checking this log.

---

## Uncompensatable failures

If any compensation action fails after exhausting retries:

- `run_status` remains `COMPENSATING`.
- A HIGH alert is raised per `alert_rule_configuration_schema.md`.
- No further automatic state transitions occur. An operator must diagnose and resolve the failure manually before the run can be transitioned to `CANCELLED`.

An uncompensatable failure is treated as a data integrity incident.

---

## Audit events

| Event | Severity | When |
| --- | --- | --- |
| `OUT_WORKFLOW_COMPENSATION_STARTED` | HIGH | Run transitions to COMPENSATING |
| `OUT_WORKFLOW_COMPENSATION_STEP_COMPLETE` | LOW | Each individual compensation action (ledger reversal batch, approval revocation, issue re-open, lock release) completes |
| `OUT_WORKFLOW_COMPENSATION_COMPLETE` | MEDIUM | All compensation actions done; run transitions to CANCELLED |

`OUT_WORKFLOW_COMPENSATION_STARTED` payload includes: `run_id`, `business_id`, `trigger_conditions` (list of matched trigger codes from `compensation_trigger_schema.md`).

---

## Ordering of compensation steps

Compensation steps execute in this fixed order, regardless of which phases actually wrote state in the specific run:

1. Release `FINALIZATION_LOCK` (if held) — highest priority; releases the period lock first so no other process is blocked.
2. Revoke APPROVED workflow approvals.
3. Reverse ledger entries in reverse phase order (highest phase index first).
4. Re-open resolved review issues (resolved within this run).
5. Unlock exception records (locked within this run).

Steps for which no durable state was written are no-ops. The `compensation_step_log` records which steps were skipped (with reason `NO_STATE_TO_REVERSE`) as well as which were executed.

---

## Relationship to IN workflow compensation

The IN workflow compensation is governed by `in_run_abort_policy.md` and does not follow this doc. IN compensation additionally voids DRAFT invoices and rejects match proposals, which are not applicable to OUT runs. The `out_phase_compensation_policy.md` applies only to `{OUT_MONTHLY, OUT_ADJUSTMENT}` run types.

---

## Cross-references

- `compensation_trigger_schema.md` — trigger conditions, step log schema, and idempotency record
- `workflow_run_schema.md` — `run_status_enum`, COMPENSATING state definition and lifecycle
- `ledger_entry_schema.md` — `compensation_for_entry_id` column and compensating entry conventions
- `resumability_and_idempotency.md` — general idempotency framework used by compensation
- `out_run_abort_policy.md` — the abort policy that initiates this compensation sequence
- `in_run_abort_policy.md` — compensation for IN workflow runs (parallel document, different scope)
- `audit_log_policies.md` — audit event naming convention
