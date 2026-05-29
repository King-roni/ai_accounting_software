# Tool: review_queue.resolve_issue

**Block:** review_queue
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`review_queue.resolve_issue` marks an open review queue issue as resolved and records the resolution note and optional evidence. When a BLOCKING issue is resolved and all remaining BLOCKING issues for its parent run are also resolved, the tool automatically transitions the run from `REVIEW_HOLD` back to `RUNNING`.

Resolution is permanent. A resolved issue cannot be reopened via this tool. If a new problem of the same type is discovered, a new issue must be created via `review_queue.create_issue`.

Side effects: `WRITES_AUDIT`

## Tool Name

`review_queue.resolve_issue`

## Inputs

| Parameter | Type | Required | Description |
|---|---|---|---|
| issue_id | UUID | Yes | The ID of the review issue to resolve. |
| resolution_note | TEXT | Yes | A human-readable explanation of how the issue was resolved. Minimum 10 characters. Cannot be empty or whitespace-only. |
| resolution_evidence | JSONB | No | Structured evidence supporting the resolution. Schema varies by issue type — see Issue Type Evidence Schemas below. |

### resolution_note Requirements

The `resolution_note` is a required field. It is stored permanently on the issue record and appears in the accountant pack for any run where the issue was raised. Notes must be meaningful — the system enforces a minimum of 10 characters. The note should explain what was done to resolve the issue, not merely restate that it was resolved.

Examples of acceptable notes:
- "Matched to payment reference CY2024-00123 confirmed by client email dated 2024-11-03."
- "Duplicate confirmed — second row is a bank-side reversal. Excluded from ledger."
- "VAT number validated via VIES on 2024-11-05. Result: valid. vat_number_valid updated to true."

Examples of unacceptable notes:
- "done"
- "resolved"
- "ok"

The tool does not enforce content quality beyond the length minimum, but reviewers during finalization may flag inadequate notes as a soft warning.

### resolution_evidence Schema

The `resolution_evidence` JSONB field is optional but recommended for MEDIUM and HIGH severity issues. The expected structure depends on the issue type:

```json
{
  "source": "string — where the evidence came from (e.g., 'VIES_API', 'CLIENT_EMAIL', 'BANK_STATEMENT')",
  "reference": "string — identifier or reference number",
  "validated_at": "ISO 8601 timestamp",
  "notes": "string — any additional context"
}
```

For issues involving external document references, the evidence may include a `document_id` referencing a record in the `documents` table.

## Outputs

The tool returns the full updated issue record:

```json
{
  "id": "<issue_id>",
  "run_id": "<run_id>",
  "business_id": "<business_id>",
  "issue_type": "<issue_type>",
  "severity": "LOW | MEDIUM | HIGH | BLOCKING",
  "status": "RESOLVED",
  "resolution_note": "<supplied note>",
  "resolution_evidence": "<supplied evidence or null>",
  "resolved_by": "<caller_user_id>",
  "resolved_at": "<timestamp>",
  "created_at": "<timestamp>",
  "updated_at": "<timestamp>"
}
```

If the resolution triggers an automatic run transition (see Cascade Behavior), the response also includes a `run_transition` field:

```json
{
  "run_transition": {
    "run_id": "<run_id>",
    "previous_status": "REVIEW_HOLD",
    "new_status": "RUNNING",
    "triggered_by": "all_blocking_issues_resolved"
  }
}
```

## Preconditions

All preconditions are evaluated before any write occurs. If any precondition fails, the tool returns an error and no state change is made.

**PC-1: Issue exists.** An issue with the given `issue_id` must exist in the `review_issues` table. If not found, return `NOT_FOUND`.

**PC-2: Issue belongs to caller's business.** The authenticated caller must be an active member of the business that owns the issue (`review_issues.business_id`). RLS enforces this at the database layer.

**PC-3: Issue is in a resolvable status.** The issue's `status` must be one of `OPEN`, `IN_PROGRESS`, `SNOOZED`, or `ESCALATED`. An issue with `status = RESOLVED` or `status = DISMISSED` is not resolvable via this tool (see Idempotency section for RESOLVED handling).

**PC-4: Caller is an active business member.** The caller must have an active `org_members` record for the owning business. Any role (VIEWER, ACCOUNTANT, ADMIN) may resolve an issue. Role restrictions on issue resolution, if required, are configured at the issue type level in `issue_type_registry_schema.md`.

**PC-5: resolution_note is non-empty and meets minimum length.** The `resolution_note` must be present, non-null, non-whitespace, and at least 10 characters in length.

## Behavior

### Standard Resolution

On a successful call, the tool:

1. Locks the issue row (`SELECT ... FOR UPDATE`).
2. Validates all preconditions.
3. Updates the issue record: `status = 'RESOLVED'`, `resolution_note`, `resolution_evidence`, `resolved_by = caller_user_id`, `resolved_at = now()`, `updated_at = now()`.
4. Emits the `REVIEW_ISSUE_RESOLVED` audit event.
5. Evaluates cascade conditions (see Cascade Behavior).
6. Commits the transaction.

### Cascade Behavior: REVIEW_HOLD to RUNNING Transition

When the resolved issue has `severity = 'BLOCKING'` and the issue's `run_id` is not null, the tool queries for any remaining unresolved BLOCKING issues for the same run:

```sql
SELECT COUNT(*) FROM review_issues
WHERE run_id = $run_id
  AND severity = 'BLOCKING'
  AND status NOT IN ('RESOLVED', 'DISMISSED')
```

If the count is zero (this resolution was the last unresolved BLOCKING issue for the run), and the run's current `status = 'REVIEW_HOLD'`, the tool automatically transitions the run:

```sql
UPDATE runs SET status = 'RUNNING', updated_at = now() WHERE id = $run_id AND status = 'REVIEW_HOLD'
```

This transition is performed within the same database transaction as the issue resolution. If the run transition fails (e.g., the run was concurrently moved to a different status), the issue resolution still commits. The `run_transition` field in the response reflects the outcome.

The cascade only triggers for `BLOCKING` severity. Resolving `HIGH`, `MEDIUM`, or `LOW` severity issues does not trigger any automatic run transition, regardless of how many remain open.

### SNOOZED Issue Resolution

Issues with `status = SNOOZED` may be resolved directly via this tool. The snooze carry-forward record (if any) for this issue is not automatically cleaned up — it will expire naturally. If immediate cleanup is required, callers should call `archive.cancel_snooze` after resolution.

### ESCALATED Issue Resolution

Issues with `status = ESCALATED` may be resolved via this tool without requiring any special privilege. The escalation chain is effectively closed by the resolution. The original escalation record is preserved in the audit log.

### Idempotency

If the issue already has `status = RESOLVED`, the tool returns the current issue record as-is, without modifying any fields and without emitting a duplicate audit event. The HTTP response code is 200 (not 409). This makes the tool safe to call in retry scenarios where the client is uncertain whether the previous call succeeded.

## Audit Event

On a successful (non-idempotent) resolution, the tool emits:

| Event | Severity | Fields |
|---|---|---|
| REVIEW_ISSUE_RESOLVED | LOW | issue_id, run_id, business_id, issue_type, issue_severity, resolution_note (truncated to 500 chars in audit payload), resolved_by |

If the cascade triggers a run transition, an additional audit event is emitted in the same transaction:

| Event | Severity | Fields |
|---|---|---|
| RUN_RESUMED_BY_ISSUE_RESOLUTION | LOW | run_id, business_id, triggering_issue_id, previous_status, new_status |

Both events are written to the append-only audit log via `emit_audit_api.md` within the same transaction.

## Error Codes

| Code | HTTP Status | Condition |
|---|---|---|
| NOT_FOUND | 404 | issue_id does not exist or is not visible to caller |
| INVALID_STATUS | 422 | Issue status is not OPEN, IN_PROGRESS, SNOOZED, or ESCALATED |
| RESOLUTION_NOTE_EMPTY | 422 | resolution_note is null, empty, or whitespace-only |
| RESOLUTION_NOTE_TOO_SHORT | 422 | resolution_note is fewer than 10 characters |
| UNAUTHORIZED | 401 | Caller is not authenticated |
| FORBIDDEN | 403 | Caller is not an active member of the business |

## Database Operations

The tool performs the following operations in a single serializable transaction:

1. `SELECT ... FOR UPDATE` on the `review_issues` row.
2. Evaluate all preconditions.
3. `UPDATE review_issues SET status='RESOLVED', resolution_note=$note, resolution_evidence=$evidence, resolved_by=$caller, resolved_at=now(), updated_at=now() WHERE id=$issue_id`.
4. Insert `REVIEW_ISSUE_RESOLVED` audit log row.
5. If BLOCKING severity: query remaining BLOCKING issues for the run.
6. If count = 0 and run status = REVIEW_HOLD: `UPDATE runs SET status='RUNNING', updated_at=now() WHERE id=$run_id AND status='REVIEW_HOLD'`.
7. If step 6 executed: insert `RUN_RESUMED_BY_ISSUE_RESOLUTION` audit log row.
8. Commit.

The conditional `AND status='REVIEW_HOLD'` in step 6 acts as an optimistic lock. If the run was concurrently moved to another status, step 6 updates zero rows and the tool does not record a transition.

## Integration Points

**review_queue_schema.md** — Defines the full `review_issues` table DDL, including the `status` enum values and all fields updated by this tool.

**review_queue_policy.md** — Governs when issues are created, escalation rules, snooze limits, and resolution authorization.

**review_queue_rescan_on_resolution_policy.md** — After an issue is resolved, some issue types trigger a rescan of the related transaction or document. This policy defines which issue types trigger rescans and what the rescan checks.

**tool_review_queue_create_issue.md** — Creates new issues. Used when a new instance of the same problem is discovered after a prior resolution.

**run_schema.md** — The `runs` table; `REVIEW_HOLD` and `RUNNING` statuses referenced in cascade behavior.

**snooze_carry_forward_schema.md** — Snooze records associated with SNOOZED issues; not automatically cleaned up on resolution.

**issue_type_registry_schema.md** — Defines per-issue-type configuration, including whether the issue type supports evidence, minimum note length overrides, and role restrictions on resolution.

## Mobile

This tool writes to the audit log (`WRITES_AUDIT`). The following mobile-specific considerations apply.

**Online requirement:** Issue resolution must be performed with an active network connection. The resolution note and evidence must be submitted to the server in real time. Offline queuing of resolution actions is not supported because the cascade behavior (run transition check) requires a live database query.

**Rejection endpoint:** `review_queue.resolve_issue` is listed in `mobile_write_rejection_endpoints.md` under the WRITES_AUDIT category. Calls made while the mobile client is offline are rejected before reaching the API.

**Resolution note input:** Mobile clients should present a multi-line text input for the resolution note with a visible character counter. The minimum 10-character requirement should be enforced client-side before submission to provide immediate feedback. The server enforces the same rule independently.

**Cascade notification:** If the resolution triggers a run transition from REVIEW_HOLD to RUNNING, the mobile client should refresh the run record immediately after receiving the response. The `run_transition` field in the response signals that the run status has changed, allowing the client to update its local state without a separate polling call.

**Optimistic UI:** Do not apply optimistic resolution status in the mobile UI. If the resolution fails (e.g., precondition failure, network drop), showing the issue as RESOLVED before server confirmation creates a confusing inconsistency. Show a loading state instead.

**ESCALATED issues on mobile:** Issues with ESCALATED status may require additional context before resolution. Mobile clients should surface the escalation history (available in `review_issue_history_schema.md`) before presenting the resolve action, so the accountant has full context.

## Related Documents

- `schemas/review_issues_schema.md` — Review issues table DDL
- `schemas/review_queue_schema.md` — Full review queue schema
- `schemas/run_schema.md` — Runs table DDL
- `policies/review_queue_policy.md` — Issue lifecycle and resolution policy
- `policies/review_queue_rescan_on_resolution_policy.md` — Post-resolution rescan triggers
- `tools/tool_review_queue_create_issue.md` — Issue creation tool
- `tools/emit_audit_api.md` — Audit emission API
- `reference/issue_status_enum.md` — Full issue status enum
- `reference/issue_type_registry_schema.md` — Per-type configuration
- `reference/mobile_write_rejection_endpoints.md` — Mobile offline write rejection list
