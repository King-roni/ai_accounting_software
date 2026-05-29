# Period Lock Policy

**Category:** Policies · Block 15 — Finalization & Secure Archive  
**Owner:** archive  
**Last updated:** 2026-05-16

---

## 1. Purpose

This policy defines how accounting periods are locked after finalization, what data the lock covers, how the lock is enforced at the database layer, and what the permitted exception path is for post-finalization corrections.

---

## 2. Lock Definition

A period lock prevents any new ledger entries, VAT entries, invoice modifications, match changes, or review issue mutations from being written to a FINALIZED period. The lock is recorded as a row in the `period_locks` table (see `period_lock_schema.md`).

The lock is associated with a specific combination of:
- `business_id`
- `period_year`
- `period_month`
- `workflow_type` (`OUT` or `IN`)

---

## 3. Lock Trigger

The period lock is applied atomically within the same database transaction that transitions `workflow_runs.run_status` to `FINALIZED`. Sequence:

1. Finalization engine calls `engine.finalize_run`.
2. Inside the transaction: `run_status` is set to `FINALIZED` AND a row is inserted into `period_locks`.
3. If either write fails, the entire transaction rolls back and the run remains in `FINALIZING` status.
4. On successful commit: audit event `ARCHIVE_PERIOD_LOCKED` (MEDIUM) is emitted.

The atomicity guarantee ensures there is never a FINALIZED run without a corresponding period lock, and no period lock without a FINALIZED run.

---

## 4. Scope of the Lock

The lock applies to all data associated with the `workflow_run_id` and its period. Protected data sets:

| Table | Protection |
|-------|-----------|
| `ledger_entries` | No INSERT, UPDATE, or DELETE for matching `(business_id, period_year, period_month)` |
| `vat_entries` | Same |
| `invoices` | No status changes, amount modifications, or deletion |
| `credit_notes` | No void, modification, or allocation changes |
| `match_records` | No new confirmations, rejections, or reversals |
| `review_issues` | No new issues may be assigned to the locked period |

---

## 5. Lock Enforcement

The RLS layer enforces the lock via a `period_lock_check` trigger function on each protected table. The trigger runs `BEFORE INSERT OR UPDATE OR DELETE` and:

1. Queries `period_locks` for a row matching `(business_id, period_year, period_month, workflow_type)`.
2. If a lock row exists, raises an application error `PERIOD_LOCKED` with the `lock_id` from `period_locks.id`.
3. The triggering statement is aborted.

The trigger runs under `SECURITY DEFINER` to ensure even `service_role` connections cannot bypass it. The only permitted write to locked-period data is a new `ledger_entries` row created by the amendment process (section 6), which sets `is_amendment = true` and `references_locked_period = true` — the trigger allows this specific case.

Any write attempt blocked by the trigger emits audit event `ARCHIVE_LOCK_VIOLATION_ATTEMPTED` (HIGH) with the caller's `user_id`, `session_id`, and the attempted operation.

---

## 6. Amendment Exception

An ADMIN may request a period amendment after finalization. Amendments do not unlock the period. Instead:

1. The ADMIN initiates an amendment request via `archive.request_amendment`, providing a reason.
2. The amendment request enters a re-approval workflow (`out_adjustment_policies.md`).
3. On approval, new `ledger_entries` rows are written with:
   - `is_amendment = true`
   - `references_locked_period_lock_id` pointing to the original `period_locks.id`
   - `period_year` / `period_month` of the locked period (for reporting attribution)
4. The original locked rows are never modified.
5. Amendment entries are included in the next period's opening balances and in restated reports.

Step-up authentication (`archive_step_up_policy.md`) is required to initiate an amendment request.

---

## 7. Lock Visibility

Accountants can see the lock status on the period detail page in the UI:

- Locked periods display a lock indicator alongside the `locked_at` timestamp from `period_locks`.
- The `locked_by_process` field identifies the engine process that applied the lock.
- The `archive_bundle_id` (if set) links to the associated archive bundle.

Lock status is surfaced via `data.get_period_lock_status`, which returns the full `period_locks` row or `null` if the period is not locked.

---

## 8. Carry-Forward of Review Issues

Review issues from a locked period are not re-opened in the locked period. Instead, `review_queue.carry_forward` creates new `review_issues` rows in the next period's workflow run, copying the issue context and setting `carried_from_period_lock_id`. This is governed by `snooze_carry_forward_policy.md`. The carry-forward action does not unlock the period.

---

## 9. Lock Permanence

A period lock is permanent. There is no `archive.unlock_period` tool or admin action. Once written, the `period_locks` row cannot be deleted or updated — the table is INSERT-only (RLS enforced).

If a lock was applied in error (e.g., a run finalized prematurely), the correct resolution is an amendment (section 6), not an unlock. This permanence guarantees the integrity of the finalized record for audit and regulatory purposes.

---

## 10. Tools

| Tool | Action |
|------|--------|
| `engine.finalize_run` | Atomically sets FINALIZED status and writes period lock |
| `archive.request_amendment` | Initiates post-finalization amendment request |
| `archive.verify_hash_chain` | Verifies audit log integrity for the locked period |
| `data.get_period_lock_status` | Returns period lock record or null |
| `review_queue.carry_forward` | Carries open issues to next period |

All `archive` WRITE tools: see `mobile_write_rejection_endpoints.md` — write operations are rejected on mobile clients.

---

## 11. Audit Events

| Event | Severity | Trigger |
|-------|----------|---------|
| `ARCHIVE_PERIOD_LOCKED` | MEDIUM | Period lock written on FINALIZED transition |
| `ARCHIVE_LOCK_VIOLATION_ATTEMPTED` | HIGH | Write blocked by period_lock_check trigger |

---

## 12. Cross-References

- `period_lock_schema.md`
- `finalization_lock_policy.md`
- `out_adjustment_policies.md`
- `snooze_carry_forward_policy.md`
- `archive_step_up_policy.md`
- `workflow_run_schema.md`
- `mobile_write_rejection_endpoints.md`
