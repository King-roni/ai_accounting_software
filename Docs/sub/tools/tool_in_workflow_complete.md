# Tool: in_workflow.complete

| Field              | Value                  |
|--------------------|------------------------|
| Namespace          | in_workflow            |
| WRITES_RUN_STATE   | Yes                    |
| WRITES_AUDIT       | Yes                    |
| Idempotent         | No                     |
| Mobile             | No                     |

## Purpose

Transitions an IN workflow run from `RUNNING` to `AWAITING_APPROVAL`. This tool is the terminal step of active processing. After it succeeds the run is frozen for accountant review; no further invoice mutations, classification changes, or ledger posts are permitted until approval or rejection.

---

## Parameters

| Parameter      | Type   | Required | Description                                              |
|----------------|--------|----------|----------------------------------------------------------|
| `run_id`       | uuid   | Yes      | The ID of the IN workflow run to complete.               |
| `completed_by` | uuid   | Yes      | The user ID of the team member marking the run complete. |

---

## Pre-conditions

- The caller must hold permission `in_workflow:complete` on the business entity that owns the run.
- The run must be in status `RUNNING`. Any other status causes an immediate error before gate evaluation begins.
- No step-up authentication is required at this step; step-up is enforced at the subsequent approval stage.

---

## Steps

### 1. Load and validate run state

Fetch the run record by `run_id`. Confirm:

- `run.status = 'RUNNING'`
- `run.workflow_type = 'IN'`
- `run.business_entity_id` matches the caller's active business context

If any condition fails, return error `RUN_NOT_IN_RUNNING_STATE` with the current status in the error detail. Do not proceed to gate evaluation.

### 2. Evaluate engine.gate_in_completion

Call `engine.gate_in_completion` for the run. The gate performs the following sub-checks in order. All sub-checks must pass. A failure in any sub-check causes the gate to fail and returns the sub-check identifier in the error payload.

**Sub-check A — invoice_statuses_resolved**

All invoices linked to the run must be in one of `SENT`, `PAID`, or `VOID`. No invoice may remain in `DRAFT`, `PARTIALLY_PAID`, or `OVERDUE`.

Invoices in `OVERDUE` status block completion. The accountant must either record a payment, apply a credit note, or void the invoice before completing.

**Sub-check B — recurring_runs_processed**

If the run period includes any active recurring invoice templates associated with the business entity, all expected recurring invoice runs for the period must have a final status of `GENERATED` or `SKIPPED`. A recurring run in `PENDING` or `FAILED` status blocks completion.

**Sub-check C — no_pending_credit_notes**

There must be no credit notes linked to the run's period with status `ISSUED` that have not yet been applied. A credit note in `ISSUED` status with `consumed_amount < credit_amount` is considered pending if it was created during this run's period.

**Sub-check D — no_open_review_hold_items**

The review queue must have zero open items with `run_id` equal to this run and `status` not in (`RESOLVED`, `DISMISSED`, `SNOOZED`). Items in `SNOOZED` state are permitted; the snooze carry-forward policy governs whether they resurface in the next period.

### 3. Transition run status

Inside a database transaction:

1. Update `workflow_runs.status` from `RUNNING` → `AWAITING_APPROVAL`.
2. Set `workflow_runs.completed_at = now()`.
3. Set `workflow_runs.completed_by = completed_by`.
4. Insert a row into `workflow_run_log` recording the transition with the `completed_by` user ID and timestamp.

The transaction must be committed before emitting the audit event. If the commit fails, return `RUN_TRANSITION_FAILED` and do not emit the event.

### 4. Emit audit event

Emit `ENGINE_RUN_AWAITING_APPROVAL` with payload:

```json
{
  "run_id": "<uuid>",
  "business_entity_id": "<uuid>",
  "completed_by": "<uuid>",
  "transitioned_from": "RUNNING",
  "transitioned_to": "AWAITING_APPROVAL",
  "completed_at": "<iso8601>"
}
```

The event is emitted via `emit_audit` with namespace `in_workflow`. If audit emission fails after a successful commit, the failure is logged to `audit_dead_letter` and does not roll back the status transition.

---

## Error Reference

| Error Code                        | HTTP | Description                                                                                   |
|-----------------------------------|------|-----------------------------------------------------------------------------------------------|
| `RUN_NOT_FOUND`                   | 404  | No run with the given ID exists for the caller's business context.                            |
| `RUN_NOT_IN_RUNNING_STATE`        | 409  | Run is not in `RUNNING` status. Current status is included in the error detail.               |
| `GATE_FAILED_INVOICE_STATUSES`    | 422  | Sub-check A failed. List of invoice IDs with blocking statuses returned in `gate_detail`.     |
| `GATE_FAILED_RECURRING_RUNS`      | 422  | Sub-check B failed. List of recurring run IDs in blocking state returned in `gate_detail`.    |
| `GATE_FAILED_PENDING_CREDIT_NOTES`| 422  | Sub-check C failed. List of credit note IDs blocking completion returned in `gate_detail`.    |
| `GATE_FAILED_OPEN_REVIEW_ITEMS`   | 422  | Sub-check D failed. Count and IDs of open review items returned in `gate_detail`.             |
| `RUN_TRANSITION_FAILED`           | 500  | Database commit failed during status transition. Safe to retry.                               |

Gate failure responses include a `gate_detail` object with `sub_check`, `blocking_ids`, and a human-readable `reason` string.

---

## Mobile

This tool is not exposed on mobile clients. The IN workflow completion action requires deliberate desktop use; the approval flow has its own step-up requirements.

---

## Concurrency

Only one in-flight call to `in_workflow.complete` is permitted per run at any time. A database-level advisory lock keyed on `run_id` is acquired at the start of Step 1 and released after the audit event is emitted. If a concurrent call acquires the same lock, it will receive a `RUN_NOT_IN_RUNNING_STATE` error because the first call will have already transitioned the status, making the second call's validation fail gracefully.

## Audit Taxonomy Note

`ENGINE_RUN_AWAITING_APPROVAL` is used here. Verify this event exists in the audit taxonomy (`audit_event_naming_convention_policy.md`). If not present, add it with domain `ENGINE`, entity `RUN`, verb `AWAITING_APPROVAL`.

---

## Related Documents

- `policies/in_phase_gate_policy.md` — Gate evaluation rules and ordering for IN workflow phases.
- `tools/tool_in_workflow_start.md` — The corresponding start tool that sets `RUNNING`.
- `tools/tool_run_finalize.md` — Subsequent finalization after approval.
- `schemas/workflow_run_schema.md` — Run record definition including `run_status_enum`.
- `policies/review_queue_policy.md` — Snoozed item behavior at completion time.
- `policies/recurring_invoice_policy.md` — Recurring run completion requirements.
- `runbooks/in_workflow_live_integration_runbook.md` — End-to-end integration test steps.
- `tools/tool_run_advance_phase.md` — Phase advancement tool used in earlier workflow stages.
- `policies/step_up_auth_for_workflow_approval_policy.md` — Step-up requirements enforced at the approval stage that follows this tool.
