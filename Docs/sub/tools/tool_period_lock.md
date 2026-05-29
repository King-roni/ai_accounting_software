# Tool: ledger.lock_period

**Block:** Ledger  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

`ledger.lock_period` permanently locks a VAT or accounting period against any further modifications to ledger entries, transactions, or classifications that fall within that period's date range. Once locked, no posting, adjustment, or reclassification can target the period without going through the formal amendment flow described in `runbooks/period_amendment_runbook.md`.

Period locking is a one-way operation — there is no `ledger.unlock_period` tool. Reversal requires a BLOCKING-level approval through the amendment workflow, which creates an explicit amendment record and a full audit trail. This design satisfies the Cyprus VAT law requirement for immutable accounting records for the 7-year retention window.

---

## Tool Signature

```
ledger.lock_period(
  period_id    UUID,    -- the period to lock
  lock_reason  TEXT     -- human-readable reason, stored on the period lock record
) -> period_lock_result
```

### Capabilities

| Flag               | Value |
|--------------------|-------|
| WRITES_RUN_STATE   | YES   |
| WRITES_AUDIT       | YES   |
| READS_LEDGER       | YES   |

---

## Inputs

### period_id
- Type: UUID (gen_uuid_v7 format)
- Required: YES
- References `vat_periods(id)`. Must belong to the calling user's `business_entity_id` as resolved from the session context.
- The period must not already be locked. Calling on an already-locked period returns 409 PERIOD_ALREADY_LOCKED.

### lock_reason
- Type: TEXT
- Required: YES
- Minimum length: 10 characters. Maximum length: 500 characters.
- Free-text reason stored verbatim on the `period_locks` record. Typical values: "VAT return filed and accepted", "Year-end close", "Auditor request".
- This text appears in the audit trail and is visible to all org admins.

---

## Outputs

```json
{
  "period_lock_id":  "<UUID>",
  "period_id":       "<UUID>",
  "locked_at":       "<TIMESTAMPTZ>",
  "locked_by":       "<user_id>",
  "lock_reason":     "<TEXT>"
}
```

---

## Preconditions

All of the following must be satisfied before the lock is applied. If any check fails, the tool returns the corresponding error and no lock is written.

### 1. All Runs in Period are FINALIZED or CANCELLED

Query `workflow_runs` where `period_id` matches and `business_entity_id` matches. Every row must have `run_status` in (`FINALIZED`, `CANCELLED`). Any run in RUNNING, PAUSED, REVIEW_HOLD, AWAITING_APPROVAL, FINALIZING, CREATED, or COMPENSATING blocks the lock with error `RUNS_NOT_SETTLED`.

```sql
SELECT run_id, run_status
FROM workflow_runs
WHERE period_id = $1
  AND business_entity_id = $2
  AND run_status NOT IN ('FINALIZED', 'CANCELLED');
```

If this query returns any rows, return the list in the error payload so the caller can act on specific runs.

### 2. No Open Review Issues in Period

Query `review_issues` where `period_id` matches and `status NOT IN ('RESOLVED', 'WAIVED')`. Any open or snoozed issue blocks the lock with error `OPEN_REVIEW_ISSUES`. The error payload includes the `issue_id` list.

### 3. VAT Return Filed or Explicitly Waived

Query `vat_returns` for the period. The record must exist and have `status IN ('SUBMITTED', 'ACCEPTED', 'AMENDED')`. If no VAT return record exists, or if the status is `DRAFT` or `REJECTED`, the lock is blocked with error `VAT_RETURN_NOT_FILED` unless a waiver flag `vat_return_waived = true` is set on the `vat_periods` record by an org admin. Waiver must itself be logged as a MEDIUM audit event before this tool is called.

---

## Lock Operation

Once all preconditions pass:

1. Insert a row into `period_locks` with `gen_uuid_v7()` as the PK.
2. Update `vat_periods` set `status = 'LOCKED'`, `locked_at = now()`, `locked_by = $actor_id`.
3. Emit PERIOD_LOCKED audit event.
4. The operation is wrapped in a single database transaction — all three writes succeed or all roll back.

---

## Permanence and the Amendment Flow

A locked period cannot be modified through normal ledger posting. Attempting to post a ledger entry with a `posting_date` inside a locked period returns 409 PERIOD_LOCKED from `tool_ledger_post`.

If a post-lock correction is required (e.g., a misclassified expense discovered after lock):

1. A BLOCKING-level review issue must be created referencing the period.
2. Org owner and an accountant must both approve the amendment in the `workflow_approvals` table.
3. `ledger.open_period_amendment` creates an `amendment_periods` record linked to the original period.
4. Corrections are applied to the amendment period, not the locked period.
5. A new amended VAT return is filed if the corrections affect VAT figures.

Full details: `runbooks/period_amendment_runbook.md`.

---

## RLS and Authorization

Only users with `org_role IN ('OWNER', 'ADMIN')` may call this tool. This is enforced at two layers:

1. RLS policy on `period_locks` table — INSERT is denied unless `auth.jwt() ->> 'org_role' IN ('owner', 'admin')`.
2. Tool-level authorization check — `engine.gate_period_lock` runs before any database write and returns 403 FORBIDDEN if the role check fails.

Accountant-role users cannot lock periods. They may prepare the period for locking (file VAT return, resolve review issues) but must request an admin to execute the final lock.

---

## Audit Events

| Event          | Severity | Trigger                                      |
|----------------|----------|----------------------------------------------|
| PERIOD_LOCKED  | MEDIUM   | Successful lock of a period                  |

Audit payload includes: `period_lock_id`, `period_id`, `locked_by`, `locked_at`, `lock_reason`, `vat_return_id` (if applicable).

---

## Error Reference

| Code                     | HTTP | Description                                                                         |
|--------------------------|------|-------------------------------------------------------------------------------------|
| PERIOD_ALREADY_LOCKED    | 409  | Period is already locked                                                            |
| PERIOD_NOT_FOUND         | 404  | period_id does not exist or belongs to a different business entity                  |
| RUNS_NOT_SETTLED         | 409  | One or more workflow runs in this period are not FINALIZED or CANCELLED             |
| OPEN_REVIEW_ISSUES       | 409  | One or more review issues in this period are not RESOLVED or WAIVED                 |
| VAT_RETURN_NOT_FILED     | 409  | No accepted VAT return exists for the period and no waiver is recorded              |
| FORBIDDEN                | 403  | Caller does not have OWNER or ADMIN role                                            |
| LOCK_TRANSACTION_FAILED  | 500  | Database transaction rolled back; safe to retry                                     |

---

## Mobile

`ledger.lock_period` carries both `WRITES_RUN_STATE` and `WRITES_AUDIT`. It is therefore subject to the mobile write rejection rule.

- Mobile clients (identified by `client_platform = 'MOBILE'` in the session context) are **blocked** from calling this tool.
- Attempts from a mobile session return HTTP 403 with error code `MOBILE_WRITE_REJECTED`.
- The period lock operation requires deliberate accountant or admin action on a desktop session where the full precondition checklist can be reviewed.
- Mobile clients may query period lock status via the read-only `ledger.get_period_status` tool, but cannot initiate or confirm a lock.

---

## Related Documents

- `runbooks/period_amendment_runbook.md` — amendment flow after a locked period requires correction
- `schemas/period_lock_schema.md` — DDL for the period_locks table
- `schemas/vat_period_schema.md` — vat_periods table and status lifecycle
- `schemas/vat_return_schema.md` — VAT return filing record
- `policies/period_lock_policy.md` — lock sequencing and waiver rules
- `policies/lock_sequence_policies.md` — ordering constraints across lock types
- `tools/tool_vat_calc.md` — VAT calculation prior to locking
- `tools/tool_run_finalize.md` — run finalization required before period lock
