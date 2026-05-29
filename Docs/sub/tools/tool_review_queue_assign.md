# Tool: review_queue.assign_item

**Namespace:** review_queue
**WRITES_RUN_STATE:** No
**WRITES_AUDIT:** Yes
**Idempotent:** No
**Mobile:** No

## Overview

`review_queue.assign_item` assigns a review queue item to a specific reviewer within the organisation. It validates that the item is in an assignable status, verifies the assignee holds the required permission, updates the item's assignee field, transitions the item to ASSIGNED status, emits an audit event, and dispatches a push notification to the assignee.

Assignment does not transfer ownership of the underlying run or issue — it designates the person responsible for actioning the item. Any org member with `review_queue:write` permission may assign items, including self-assignment.

---

## Tool Name

`review_queue.assign_item`

---

## Inputs

| Parameter | Type | Required | Description |
|---|---|---|---|
| queue_item_id | UUID | Yes | The ID of the review queue item to assign. |
| assignee_id | UUID | Yes | The `org_member_id` of the reviewer to assign the item to. |
| assigned_by | UUID | Yes | The `org_member_id` of the caller performing the assignment. |

### Parameter Notes

- `queue_item_id` — references `review_queue_items.id`. The item must exist and belong to the caller's business.
- `assignee_id` — must reference an active `org_members` row for the same business. The assignee does not need to be the caller; admins may assign to any reviewer.
- `assigned_by` — the org member performing the assignment. Used for the audit trail and notification context. Must match the authenticated caller's `org_member_id`.

---

## Outputs

```json
{
  "queue_item_id": "<uuid>",
  "assignee_id": "<uuid>",
  "assigned_by": "<uuid>",
  "status": "ASSIGNED",
  "assigned_at": "<timestamptz>",
  "notification_dispatched": true
}
```

---

## Preconditions

All preconditions are evaluated before any write. If any fails, the tool returns an error and no state change is made.

**PC-1: Item exists.** A `review_queue_items` row with `queue_item_id` must exist. If not found, return `NOT_FOUND`.

**PC-2: Item belongs to caller's business.** RLS enforces tenant isolation. The item's `business_entity_id` must match the caller's active business.

**PC-3: Item status is PENDING or UNASSIGNED.** Items in any other status — ASSIGNED, ESCALATED, RESOLVED, or DISMISSED — may not be assigned via this tool. Use `review_queue.reassign_item` to reassign an already-ASSIGNED item.

**PC-4: Assignee is an active org member.** The `assignee_id` must reference an `org_members` row with `status = 'ACTIVE'` for the same `business_entity_id`.

**PC-5: Assignee has review_queue:write permission.** The assignee's role must include `review_queue:write`. Roles without this permission cannot receive assignments. The permission check uses `can_perform_helper` per `tools/tool_can_perform_helper.md`.

**PC-6: Caller has review_queue:write permission.** The `assigned_by` org member must also hold `review_queue:write`. Observers and read-only roles may not perform assignments.

---

## Steps

1. Validate `queue_item_id` exists; acquire row lock (`SELECT ... FOR UPDATE`).
2. Check item status is `PENDING` or `UNASSIGNED` (PC-3).
3. Validate `assignee_id` is active and holds `review_queue:write` (PC-4, PC-5).
4. Validate `assigned_by` holds `review_queue:write` (PC-6).
5. Update `review_queue_items`: set `assignee_id = $assignee_id`, `status = 'ASSIGNED'`, `assigned_at = now()`, `assigned_by = $assigned_by`, `updated_at = now()`.
6. Emit `REVIEW_ISSUE_REASSIGNED` audit event (see Audit Events section). Note: the taxonomy currently lists `REVIEW_ISSUE_REASSIGNED` for reassignment actions; a dedicated `REVIEW_ISSUE_ASSIGNED` event should be added to the taxonomy for first-time assignments. Until that addition is made, emit `REVIEW_ISSUE_REASSIGNED` with `previous_assignee_id = null` to distinguish initial assignment from reassignment.
7. Dispatch push notification to `assignee_id` via `tool_notify_send.md`.
8. Commit transaction.

---

## Audit Events

| Event | Severity | Payload |
|---|---|---|
| `REVIEW_ISSUE_REASSIGNED` | LOW | `queue_item_id`, `assignee_id`, `previous_assignee_id` (null for first assignment), `assigned_by`, `business_entity_id`, `assigned_at` |

Note for taxonomy maintainers: a distinct `REVIEW_ISSUE_ASSIGNED` event should be added to the REVIEW domain in `reference/audit_event_taxonomy.md` to distinguish initial assignment from reassignment. Until added, use `REVIEW_ISSUE_REASSIGNED` with `previous_assignee_id = null`.

---

## Error Codes

| Code | HTTP Status | Condition |
|---|---|---|
| `NOT_FOUND` | 404 | `queue_item_id` does not exist or is not visible to caller |
| `INVALID_STATUS` | 422 | Item status is not PENDING or UNASSIGNED |
| `ASSIGNEE_NOT_FOUND` | 404 | `assignee_id` does not reference an active org member |
| `ASSIGNEE_INSUFFICIENT_PERMISSION` | 403 | Assignee does not hold `review_queue:write` |
| `CALLER_INSUFFICIENT_PERMISSION` | 403 | `assigned_by` does not hold `review_queue:write` |
| `UNAUTHORIZED` | 401 | Caller is not authenticated |
| `FORBIDDEN` | 403 | Caller is not an active member of the business |

---

## Database Operations

All operations execute in a single serializable transaction:

1. `SELECT ... FOR UPDATE` on `review_queue_items` row.
2. Evaluate preconditions PC-1 through PC-6.
3. `UPDATE review_queue_items SET assignee_id=$assignee_id, status='ASSIGNED', assigned_at=now(), assigned_by=$assigned_by, updated_at=now() WHERE id=$queue_item_id`.
4. Insert `REVIEW_ISSUE_REASSIGNED` audit log row via `emit_audit_api.md`.
5. Commit.

Push notification dispatch (step 7) occurs after commit via an async job. Notification failure does not roll back the assignment.

---

## Mobile

This tool emits `WRITES_AUDIT` and modifies queue item state. It is callable from mobile clients but subject to the following constraints.

**Online requirement:** Assignment requires a live server connection. Offline queuing of assignment actions is not supported. If the mobile client is offline when assignment is attempted, the request is rejected before reaching the API.

**Push notification delivery:** The assignee receives a push notification via the platform notification system. On mobile, the notification appears in the device notification tray and within the in-app notification centre. The notification payload includes the queue item summary, the assigning user's display name, and a deep-link to the queue item detail screen.

**Assignee confirmation:** Mobile clients should not assume the assignment succeeded until the server response is received. Do not apply optimistic UI state for the assignment.

**Self-assignment:** Mobile users may self-assign items. The UI should present the current user's name as the first option in the assignee picker to streamline self-assignment.

---

## Related Documents

- `schemas/review_queue_schema.md` — Full review queue schema including status enum
- `schemas/review_issues_schema.md` — Review issues table DDL
- `policies/review_queue_policy.md` — Assignment rules and permission model
- `policies/review_queue_escalation_policy.md` — Escalation rules triggered by unactioned assignments
- `tools/tool_review_queue_escalate.md` — Escalation tool
- `tools/tool_review_queue_resolve.md` — Resolution tool
- `tools/tool_can_perform_helper.md` — Permission check helper
- `tools/tool_notify_send.md` — Push notification dispatch
- `tools/emit_audit_api.md` — Audit emission API
- `reference/audit_event_taxonomy.md` — Event taxonomy (REVIEW domain)
