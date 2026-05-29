# Tool: out_workflow.start

**Namespace:** `out_workflow`
**Action:** `start`
**WRITES_RUN_STATE:** Yes
**WRITES_AUDIT:** Yes
**Idempotent:** No
**Mobile:** No

---

## Purpose

Starts a new OUT workflow run for a given business entity and accounting period. The OUT workflow handles outbound financial activity: supplier invoice processing, expense classification, bank statement line matching, and VAT compilation for a single calendar month. This tool is the authoritative entry point for all OUT run creation.

---

## Parameters

| Parameter | Type | Required | Notes |
|---|---|---|---|
| `business_entity_id` | uuid | yes | FK to `business_entities(id)`. Must reference an active entity. |
| `period_id` | uuid | yes | FK to `vat_periods(id)`. Identifies the accounting month being processed. |
| `initiated_by` | uuid | yes | `org_member_id` of the member starting the run. Must hold role `OWNER` or `ADMIN` on the business. |

---

## Preconditions

1. `business_entity_id` must resolve to a row in `business_entities` with `status = 'ACTIVE'`.
2. `period_id` must resolve to a period that is not locked (`period_lock.locked_at IS NULL`).
3. `initiated_by` must resolve to an active org member (`org_members.status = 'ACTIVE'`) with role `OWNER` or `ADMIN` on the business.

---

## Steps

### Step 1 — Validate period not locked

Query `period_locks` for a row matching `(business_entity_id, period_id)` with `locked_at IS NOT NULL`. If found, return `PERIOD_ALREADY_LOCKED` (409) immediately without creating a run.

### Step 2 — Validate no active OUT run for same business and period

Query `workflow_runs` for rows where:

```sql
business_entity_id = $business_entity_id
AND period_id       = $period_id
AND workflow_type   = 'OUT_WORKFLOW'
AND run_status     IN ('RUNNING','PAUSED','REVIEW_HOLD','AWAITING_APPROVAL','FINALIZING')
```

If any row is found, return `ENGINE_RUN_ALREADY_ACTIVE` (409) with `conflicting_run_id` in the response body. No audit event is emitted for this rejection.

### Step 3 — Create workflow run

Insert a new row into `workflow_runs`:

```sql
INSERT INTO workflow_runs (
  id,                  -- gen_uuid_v7()
  business_entity_id,
  period_id,
  workflow_type,       -- 'OUT_WORKFLOW'
  run_status,          -- 'CREATED'
  initiated_by,
  created_at,
  updated_at
)
```

The insert is wrapped in a serializable transaction. A unique constraint on `(business_entity_id, period_id, workflow_type)` for active statuses enforces the concurrency rule at the database level and is the authoritative guard against race conditions.

### Step 4 — Set run status to RUNNING

Immediately after insertion, transition `run_status` from `CREATED` to `RUNNING` via `engine.transitionRun()`. This is a synchronous step within the same transaction.

### Step 5 — Trigger gate: engine.gate_out_intake_ready

Evaluate `engine.gate_out_intake_ready` for the new run. This gate checks whether the processing zone contains importable files for this business and period (i.e., at least one `intake_files` row with `status = 'PENDING'` or `status = 'READY'` matching the period).

Gate outcomes:

| Outcome | Result |
|---|---|
| `ADVANCE` | Gate passes; run stays `RUNNING` and the engine proceeds to phase 1. |
| `HOLD` | No importable files detected; run transitions to `REVIEW_HOLD` with `hold_reason = 'NO_IMPORTABLE_FILES'`. A HIGH severity review issue is raised in the review queue. |

### Step 6 — Emit audit events

Emit the following events in order:

1. `ENGINE_RUN_CREATED` (LOW) — after the `workflow_runs` row is inserted.
2. `ENGINE_RUN_STARTED` (LOW) — after the run status transitions to `RUNNING`.

> **Taxonomy note:** `ENGINE_RUN_STARTED` requires addition to `audit_event_taxonomy.md` before this tool goes to production. Payload: `run_id`, `business_entity_id`, `period_id`, `workflow_type`, `initiated_by`.

---

## Output

```json
{
  "run_id":     "uuid",
  "run_status": "RUNNING | REVIEW_HOLD",
  "period_id":  "uuid",
  "gate_result": "ADVANCE | HOLD"
}
```

---

## Error Paths

| Code | HTTP | Condition |
|---|---|---|
| `PERIOD_ALREADY_LOCKED` | 409 | The target period has a lock record with a non-null `locked_at`. |
| `ENGINE_RUN_ALREADY_ACTIVE` | 409 | An active OUT run already exists for this business-period. Response includes `conflicting_run_id`. |
| `INITIATOR_UNAUTHORIZED` | 403 | `initiated_by` does not hold `OWNER` or `ADMIN` role on the business. |
| `BUSINESS_ENTITY_NOT_ACTIVE` | 422 | The referenced `business_entity_id` does not resolve to an active entity. |
| `PERIOD_NOT_FOUND` | 404 | `period_id` does not resolve to a row in `vat_periods`. |
| `MOBILE_WRITE_REJECTED` | 403 | Request originates from a mobile session. See `mobile_write_rejection_endpoints.md`. |

---

## Mobile

`out_workflow.start` is rejected for all mobile sessions. Any call from a client with `client_form_factor = MOBILE` returns HTTP 403 with:

```json
{ "code": "MOBILE_WRITE_REJECTED", "tool": "out_workflow.start" }
```

The mobile UI surfaces the run status as a read-only indicator. Starting an OUT run from mobile is not supported.

---

## Related Documents

- `out_run_concurrency_policy.md` — single-active-run-per-period enforcement rules
- `out_phase_gate_policy.md` — gate evaluation framework for OUT workflow phases
- `out_monthly_trigger_policy.md` — scheduled trigger timing and idempotency key derivation
- `workflow_run_schema.md` — `workflow_runs` table definition
- `period_lock_policy.md` — when and how periods are locked
- `intake_file_schema.md` — `intake_files` table referenced by `engine.gate_out_intake_ready`
- `mobile_write_rejection_endpoints.md` — full list of mobile-rejected write tools
- `audit_event_taxonomy.md` — canonical audit event definitions
