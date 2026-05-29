# tool_run_cancel

**Category:** Tools — Block 03: Workflow Engine
**Tool name:** `engine.run_cancel`
**Side effect class:** `WRITES_RUN_STATE | WRITES_AUDIT`
**Mobile rejection:** YES — mobile clients cannot call `engine.run_cancel`. See `mobile_write_rejection_endpoints.md`.

---

## Purpose

Cancels a workflow run, optionally triggering a compensation sequence to reverse any
ledger entries that have already been written. The tool enforces role-based access
control, validates the run's current status, and handles all status transitions
atomically.

---

## Input Schema

```json
{
  "run_id":               "uuid",
  "cancelled_by_user_id": "uuid",
  "cancellation_reason":  "text",
  "trigger_compensation": "boolean (DEFAULT true)",
  "idempotency_key":      "string"
}
```

All fields are required. `trigger_compensation` defaults to `true` if omitted.

---

## Output Schema

```json
{
  "run_id":                 "uuid",
  "final_status":           "CANCELLED | COMPENSATING",
  "compensation_triggered": "boolean"
}
```

---

## Role Check

The caller identified by `cancelled_by_user_id` must hold `OWNER` or `ADMIN` role for
the `business_id` associated with the run.

- `ACCOUNTANT` role cannot cancel runs under any circumstances.
- Attempts by an `ACCOUNTANT` return `403 INSUFFICIENT_ROLE`.
- Role is checked before any status validation.

---

## Cancellable Statuses

A run may only be cancelled when its `run_status` is one of:

| Status             | Cancellable |
|---|---|
| `CREATED`          | YES         |
| `RUNNING`          | YES         |
| `PAUSED`           | YES         |
| `REVIEW_HOLD`      | YES         |
| `AWAITING_APPROVAL`| YES         |
| `FINALIZING`       | NO          |
| `FINALIZED`        | NO          |
| `FAILED`           | NO          |
| `CANCELLED`        | NO (idempotent — see below) |
| `COMPENSATING`     | NO          |

Attempting to cancel a run in a non-cancellable status (excluding `CANCELLED`) returns
`409 RUN_NOT_CANCELLABLE` with the current status in the response body.

---

## Compensation Path

When `trigger_compensation = true` AND at least one ledger entry has been written for
the run:

1. `run_status` transitions to `COMPENSATING` immediately (atomic with the lock).
2. The compensation policy is invoked:
   - For OUT-type runs: `out_phase_compensation_policy.md`
   - For IN-type runs: `in_run_abort_policy.md`
3. Upon compensation completion, `run_status` transitions to `CANCELLED`.
4. The `ENGINE_RUN_COMPENSATION_TRIGGERED` audit event is written at the start of step 2.
5. `final_status` in the response is `COMPENSATING` (the run has not yet reached
   `CANCELLED` when the tool returns — compensation is asynchronous).

---

## No-Compensation Path

When `trigger_compensation = false` OR no ledger entries have been written for the run:

1. `run_status` transitions directly to `CANCELLED`.
2. `compensation_triggered = false` in the response.
3. `final_status` in the response is `CANCELLED`.

---

## Approval Invalidation

Regardless of compensation path, all `PENDING` workflow approvals for this `run_id`
are set to `EXPIRED` atomically with the initial status transition. This prevents
orphaned approval records from being acted on after the run is cancelled.

---

## Idempotency

If the run is already in `CANCELLED` status when the tool is called:

- Returns success immediately.
- `final_status = 'CANCELLED'`, `compensation_triggered = false`.
- No audit event is written for the repeated call.
- No approval invalidation is re-attempted.

---

## Primary Key References

`cancelled_by_user_id` must reference a valid user in `business_entity_members`.
`run_id` must reference a row in `workflow_runs`. Both foreign keys use
`REFERENCES business_entities(id)` via the run's `business_id`.

---

## Audit Events

| Event                                  | Severity | Trigger                              |
|---|---|---|
| `ENGINE_RUN_CANCELLED`                 | MEDIUM   | run_status transitions to CANCELLED  |
| `ENGINE_RUN_COMPENSATION_TRIGGERED`    | HIGH     | compensation sequence is initiated   |

Both events are written to `audit_log` with `run_id` as the correlated reference.
`ENGINE_RUN_COMPENSATION_TRIGGERED` is written before the compensation policy executes,
not after, to ensure auditability even if compensation fails.

---

## Error Codes

| Code                     | HTTP | Meaning                                          |
|---|---|---|
| `RUN_NOT_FOUND`          | 404  | run_id does not exist                            |
| `INSUFFICIENT_ROLE`      | 403  | caller is ACCOUNTANT or has no role              |
| `RUN_NOT_CANCELLABLE`    | 409  | run is in a terminal or locked status            |
| `COMPENSATION_FAILED`    | 500  | compensation policy returned a failure           |
| `LOCK_ACQUISITION_FAILED`| 503  | advisory lock on run_id could not be acquired    |

---

## Cross-References

- `workflow_run_schema.md` — run_status enum, run table DDL
- `out_run_abort_policy.md` — OUT-type abort and compensation rules
- `in_run_abort_policy.md` — IN-type abort and compensation rules
- `out_phase_compensation_policy.md` — phase-level compensation steps for OUT runs
- `mobile_write_rejection_endpoints.md` — mobile rejection policy and error format

## Mobile

All write operations in this tool are rejected on mobile clients. Mobile apps receive `HTTP 405 Method Not Allowed` with error code `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full endpoint rejection list.