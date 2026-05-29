# Tool: review_queue.escalate_item

**Namespace:** review_queue
**WRITES_RUN_STATE:** No
**WRITES_AUDIT:** Yes
**Idempotent:** No
**Mobile:** No

## Overview

`review_queue.escalate_item` escalates a review queue item from its current assignee to a higher-tier reviewer or admin. Escalation is appropriate when the current assignee cannot resolve an item, when the item exceeds SLA thresholds, or when the issue requires a decision above the current reviewer's authority level.

Escalation is a one-way transition: an ESCALATED item cannot be de-escalated to ASSIGNED. The escalated item may be resolved by any reviewer at the target tier or above. The escalation record is permanent and preserved in the audit log regardless of subsequent resolution.

---

## Tool Name

`review_queue.escalate_item`

---

## Inputs

| Parameter | Type | Required | Description |
|---|---|---|---|
| queue_item_id | UUID | Yes | The ID of the review queue item to escalate. |
| escalation_reason | TEXT | Yes | A documented reason for escalation. Minimum 20 characters. |
| escalated_by | UUID | Yes | The `org_member_id` of the reviewer initiating escalation. |
| escalate_to | UUID | No | The `org_member_id` of the target reviewer. NULL = escalate to any admin (unassigned escalation). |

### Parameter Notes

- `escalation_reason` — required and enforced. A minimum of 20 characters is required because escalation reasons are reviewed during audits. A note such as "unsure" or "needs review" is rejected. The reason is stored on the queue item and included in the audit payload.
- `escalate_to` — when provided, the item is reassigned to the named org member, who must hold `review_queue:write` and be at L2 (senior accountant) or L3 (admin) tier. When NULL, the item is placed in an unassigned ESCALATED state and any admin may pick it up.

---

## Outputs

```json
{
  "queue_item_id": "<uuid>",
  "previous_assignee_id": "<uuid or null>",
  "escalated_to": "<uuid or null>",
  "escalated_by": "<uuid>",
  "status": "ESCALATED",
  "escalation_reason": "<text>",
  "escalated_at": "<timestamptz>",
  "admin_notification_dispatched": true
}
```

---

## Preconditions

All preconditions are evaluated before any write. A failure in any precondition returns an error and makes no state change.

**PC-1: Item exists.** The `queue_item_id` must match an existing `review_queue_items` row visible to the caller's business.

**PC-2: Item is in ASSIGNED status.** Only ASSIGNED items may be escalated. Items in PENDING, UNASSIGNED, RESOLVED, or DISMISSED status cannot be escalated. An item already in ESCALATED status is also not re-escalatable via this tool — escalating an already-escalated item is handled by admins via direct reassignment.

**PC-3: Caller (`escalated_by`) is an active org member with `review_queue:write`.** Any reviewer with the write permission may escalate — including the current assignee. Escalation is not limited to the assigned reviewer; any team member with write access on the queue may escalate.

**PC-4: `escalate_to` (if provided) is an active org member at L2 or L3 tier.** The target must hold `review_queue:write` and must be a senior accountant or admin. L1 (standard accountant) targets are rejected. If `escalate_to` is NULL, this check is skipped.

**PC-5: `escalation_reason` meets minimum length.** Must be non-null, non-whitespace, and at least 20 characters.

---

## Steps

1. Validate `queue_item_id` exists; acquire row lock (`SELECT ... FOR UPDATE`).
2. Check item status is `ASSIGNED` (PC-2).
3. Validate `escalated_by` holds `review_queue:write` (PC-3).
4. If `escalate_to` is provided, validate target is L2 or L3 and holds write permission (PC-4).
5. Validate `escalation_reason` length (PC-5).
6. Record `previous_assignee_id` from the current `review_queue_items.assignee_id`.
7. Update `review_queue_items`: set `status = 'ESCALATED'`, `assignee_id = $escalate_to` (may be NULL), `escalation_reason = $escalation_reason`, `escalated_by = $escalated_by`, `escalated_at = now()`, `updated_at = now()`.
8. Emit `REVIEW_ISSUE_ESCALATED` audit event. Note: the current taxonomy entry for `REVIEW_ISSUE_ESCALATED` describes auto-severity-promotion escalation. A distinct `REVIEW_QUEUE_ITEM_ESCALATED` event should be added to the taxonomy for manual tool-driven escalation. Until that addition is made, emit `REVIEW_ISSUE_ESCALATED` with `escalation_source = 'MANUAL'` in the payload to distinguish from the automated severity-promotion path.
9. Notify all admins in the business via `tool_notify_send.md`. If `escalate_to` is non-null, also send a targeted notification to the named reviewer.
10. Commit transaction.

---

## Audit Events

| Event | Severity | Payload |
|---|---|---|
| `REVIEW_ISSUE_ESCALATED` | MEDIUM | `queue_item_id`, `escalated_by`, `previous_assignee_id`, `escalated_to` (null if unassigned), `escalation_reason` (truncated to 500 chars), `escalation_source: 'MANUAL'`, `business_entity_id`, `escalated_at` |

Note for taxonomy maintainers: add `REVIEW_QUEUE_ITEM_ESCALATED` to the REVIEW_QUEUE domain in `reference/audit_event_taxonomy.md` for manual escalations. This event should be MEDIUM severity. Until added, use `REVIEW_ISSUE_ESCALATED` with `escalation_source = 'MANUAL'` as noted above.

---

## Error Codes

| Code | HTTP Status | Condition |
|---|---|---|
| `NOT_FOUND` | 404 | `queue_item_id` does not exist or is not visible to caller |
| `INVALID_STATUS` | 422 | Item is not in ASSIGNED status |
| `ESCALATION_REASON_TOO_SHORT` | 422 | `escalation_reason` is fewer than 20 characters |
| `ESCALATION_REASON_EMPTY` | 422 | `escalation_reason` is null or whitespace-only |
| `TARGET_NOT_FOUND` | 404 | `escalate_to` does not reference an active org member |
| `TARGET_INSUFFICIENT_TIER` | 403 | `escalate_to` is not L2 or L3 |
| `CALLER_INSUFFICIENT_PERMISSION` | 403 | `escalated_by` does not hold `review_queue:write` |
| `UNAUTHORIZED` | 401 | Caller is not authenticated |
| `FORBIDDEN` | 403 | Caller is not an active member of the business |

---

## Database Operations

All operations execute in a single serializable transaction:

1. `SELECT ... FOR UPDATE` on `review_queue_items` row.
2. Evaluate preconditions PC-1 through PC-5.
3. Capture `previous_assignee_id`.
4. `UPDATE review_queue_items SET status='ESCALATED', assignee_id=$escalate_to, escalation_reason=$reason, escalated_by=$escalated_by, escalated_at=now(), updated_at=now() WHERE id=$queue_item_id`.
5. Insert `REVIEW_ISSUE_ESCALATED` audit log row via `emit_audit_api.md`.
6. Commit.

Admin and assignee notifications are dispatched asynchronously after commit. Notification failure does not roll back the escalation.

---

## Mobile

This tool writes audit events and modifies queue item state. Mobile clients may initiate escalations subject to the following constraints.

**Online requirement:** Escalation must occur with an active server connection. The escalation reason must be submitted in real time. Offline queuing of escalation actions is not supported.

**Escalation reason input:** Mobile clients must present a text field with a minimum character counter. The 20-character minimum should be enforced client-side before submission. The server enforces the same constraint independently.

**Admin notification:** After escalation, all admins in the business receive a push notification. On mobile, this appears in the device notification tray with a deep-link to the queue item. The escalating reviewer also sees a confirmation screen with the escalation summary.

**Target selection:** When the mobile user selects `escalate_to`, the UI should filter the reviewer picker to show only L2 and L3 org members. Including ineligible reviewers in the list and rejecting them at the server creates unnecessary friction.

**No de-escalation:** Mobile clients must not expose a de-escalation action. Once ESCALATED, the item is actioned by the target tier or resolved without de-escalation.

---

## Related Documents

- `schemas/review_queue_schema.md` — Full review queue schema including status enum
- `policies/review_queue_policy.md` — Issue lifecycle and escalation authority
- `policies/review_queue_escalation_policy.md` — Auto-escalation triggers, tiers, SLAs
- `tools/tool_review_queue_assign.md` — Assignment tool (precursor to escalation)
- `tools/tool_review_queue_resolve.md` — Resolution tool (closes ESCALATED items)
- `tools/tool_can_perform_helper.md` — Permission check helper
- `tools/tool_notify_send.md` — Push notification dispatch
- `tools/emit_audit_api.md` — Audit emission API
- `reference/audit_event_taxonomy.md` — Event taxonomy (REVIEW domain)
- `reference/issue_status_enum.md` — Full issue status enum values
