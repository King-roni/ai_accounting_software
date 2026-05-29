# Tool: engine.assign_run

**Block:** engine
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`engine.assign_run` assigns or reassigns a bookkeeping run to an accountant. The assigned accountant becomes the primary responsible party for progressing the run through its phases. Assignment is recorded on the run record and emitted to the audit log.

This tool does not change run status. A run in any non-terminal status may be reassigned. Reassignment is allowed whether the run is CREATED, RUNNING, PAUSED, REVIEW_HOLD, AWAITING_APPROVAL, or FINALIZING. Runs in terminal status (FINALIZED, FAILED, CANCELLED) cannot be reassigned.

Side effects: `WRITES_RUN_STATE` | `WRITES_AUDIT`

## Tool Name

`engine.assign_run`

## Inputs

| Parameter | Type | Required | Description |
|---|---|---|---|
| run_id | UUID | Yes | The ID of the run to assign. Must reference an existing run record. |
| accountant_id | UUID | Yes | The ID of the auth.users record to assign. Must be an active member of the owning business with role ACCOUNTANT or ADMIN. |

## Outputs

The tool returns the full updated run record after assignment:

```json
{
  "id": "<run_id>",
  "business_id": "<business_id>",
  "period_id": "<period_id>",
  "run_type": "OUT | IN | COMBINED",
  "status": "<current_status>",
  "current_phase": "<current_phase>",
  "assigned_to": "<accountant_id>",
  "created_by": "<creator_user_id>",
  "started_at": "<timestamp or null>",
  "paused_at": "<timestamp or null>",
  "completed_at": "<timestamp or null>",
  "metadata": {},
  "created_at": "<timestamp>",
  "updated_at": "<timestamp>"
}
```

The `assigned_to` field on the run record is updated to the new accountant's user ID. The `updated_at` timestamp is refreshed.

## Preconditions

All preconditions are evaluated before any write occurs. If any precondition fails, the tool returns an error and no state change is made.

**PC-1: Run exists.** A run with the given `run_id` must exist in the `runs` table. If not found, return `NOT_FOUND`.

**PC-2: Run belongs to caller's business.** The authenticated caller must be a member of the business that owns the run (`runs.business_id`). RLS enforces this at the database level, but the application layer checks it explicitly to return a meaningful error rather than a silent empty result.

**PC-3: Run is in a non-terminal status.** The run's `status` must not be one of `FINALIZED`, `FAILED`, `CANCELLED`. Reassigning a terminal run serves no operational purpose and is blocked to prevent misleading audit trails.

**PC-4: Accountant exists and is active.** The `accountant_id` must reference an existing record in `auth.users`. The corresponding `org_members` record for the owning business must have `status = 'ACTIVE'`.

**PC-5: Accountant has sufficient role.** The accountant's `org_members.role` for the owning business must be `ACCOUNTANT` or `ADMIN`. A member with role `VIEWER` cannot be assigned to a run.

**PC-6: Accountant belongs to the same business.** The accountant must be a member of the same business entity that owns the run. Cross-business assignment is not permitted.

## Behavior

### Self-assignment

A caller with ACCOUNTANT or ADMIN role may assign the run to themselves. This is the typical workflow for an accountant picking up an unassigned run from a queue.

### Reassignment from existing assignee

If the run already has an `assigned_to` value, the tool overwrites it with the new accountant. There is no notification mechanism in this tool — notifications are handled by the caller or a downstream event handler listening to the `RUN_ASSIGNED` audit event.

### Clearing assignment

Passing `accountant_id = null` is not permitted by this tool. To unassign a run (set `assigned_to = null`), use `engine.unassign_run` if that tool exists, or perform a direct admin operation. This constraint prevents accidental unassignment via misuse of the assign path.

### Idempotency

If the run is already assigned to the specified accountant (i.e., `runs.assigned_to = accountant_id`), the tool returns the current run record without modifying `updated_at` and without emitting a duplicate audit event. This makes the tool safe to call repeatedly in retry scenarios.

## Audit Event

On a successful (non-idempotent) assignment, the tool emits:

| Event | Severity | Fields |
|---|---|---|
| RUN_ASSIGNED | LOW | run_id, business_id, previous_assignee (null if first assignment), new_assignee, performed_by |

The audit event is written to the append-only audit log via `emit_audit_api.md`. The write is part of the same database transaction as the run record update. If the audit write fails, the entire operation rolls back.

## Error Codes

| Code | HTTP Status | Condition |
|---|---|---|
| NOT_FOUND | 404 | run_id does not exist or is not visible to caller |
| ACCOUNTANT_NOT_FOUND | 404 | accountant_id does not exist |
| ACCOUNTANT_NOT_ACTIVE | 422 | Accountant's org_members.status is not ACTIVE |
| INSUFFICIENT_ROLE | 403 | Accountant's role is VIEWER |
| CROSS_BUSINESS_FORBIDDEN | 403 | accountant_id belongs to a different business |
| RUN_TERMINAL | 422 | Run status is FINALIZED, FAILED, or CANCELLED |
| UNAUTHORIZED | 401 | Caller is not authenticated |
| FORBIDDEN | 403 | Caller is not a member of the run's business |

## Database Operations

The tool performs the following operations in a single serializable transaction:

1. `SELECT ... FOR UPDATE` on the `runs` row to lock it during the operation.
2. Evaluate all preconditions against the locked row and the `org_members` record.
3. If all preconditions pass and the operation is not idempotent: `UPDATE runs SET assigned_to = $accountant_id, updated_at = now() WHERE id = $run_id`.
4. Insert the `RUN_ASSIGNED` audit log row.
5. Commit.

The `FOR UPDATE` lock prevents concurrent assignment operations on the same run from producing inconsistent results.

## Integration Points

**workflow_run_creation_policy.md** — Defines the conditions under which a run is created unassigned vs. pre-assigned. This tool handles all subsequent assignment and reassignment operations.

**run_schema.md** — The `assigned_to` FK references `auth.users(id)`. The column is nullable. The index `CREATE INDEX ON runs (assigned_to) WHERE status = 'RUNNING'` supports queue queries for in-progress runs by assignee.

**permission_matrix.md** — Defines which roles can call this tool. ACCOUNTANT and ADMIN may call it. VIEWER cannot.

**tool_run_resume.md** — When resuming a PAUSED run, if no accountant is currently assigned, the resuming user is typically auto-assigned via this tool as part of the resume flow.

**tool_run_advance_phase.md** — Phase advance operations check `assigned_to` to determine whether the calling user is the assigned accountant. Assignment via this tool gates phase progression.

## Mobile

This tool modifies run state (`WRITES_RUN_STATE`) and writes to the audit log (`WRITES_AUDIT`). The following mobile-specific considerations apply.

**Optimistic UI:** Mobile clients should not apply optimistic updates for assignment changes. The confirmation round-trip from the server is fast (single indexed lookup + update), and showing a stale assignee in the UI during the round-trip is confusing in multi-user scenarios.

**Offline behavior:** This tool must not be queued for offline execution. Run assignment has immediate team visibility implications. If the mobile client is offline, the user should be shown a clear error and prompted to retry when connectivity is restored.

**Rejection endpoint:** `engine.assign_run` is listed in `mobile_write_rejection_endpoints.md` under the WRITES_RUN_STATE category. Calls made while the client is in offline mode are rejected by the mobile network layer before reaching the API.

**Push notification:** When a run is assigned to an accountant, the platform may send a push notification to the newly assigned accountant's mobile device. This notification is triggered by the `RUN_ASSIGNED` audit event handler, not by this tool directly. The tool itself does not send notifications.

**Concurrent assignment on mobile:** If two users (e.g., two admins) attempt to assign the same run simultaneously from mobile clients, the `FOR UPDATE` lock on the runs row ensures one succeeds and the other sees the updated state. The losing request returns the current (updated) run record without error, allowing the mobile client to refresh its UI.

## Related Documents

- `schemas/run_schema.md` — Canonical runs table DDL
- `policies/workflow_run_creation_policy.md` — Run creation and initial assignment policy
- `tools/tool_run_create.md` — Creates a new run (may pre-assign)
- `tools/tool_run_resume.md` — Resume a paused run; may trigger auto-assignment
- `tools/tool_run_advance_phase.md` — Phase advance; checks assigned_to
- `reference/permission_matrix.md` — Role-based access control matrix
- `reference/mobile_write_rejection_endpoints.md` — Mobile offline write rejection list
- `policies/audit_log_policies.md` — Audit log write guarantees
- `tools/emit_audit_api.md` — Audit emission API
