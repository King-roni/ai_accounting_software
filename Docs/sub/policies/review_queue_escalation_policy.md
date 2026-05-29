# Review Queue Escalation Policy

**Scope:** All review queue items across all workflow run types (IN monthly, OUT monthly, adjustment runs).
**Owning team:** Platform / Workflow & Classification (Block 14)
**Last reviewed:** 2026-05-17
**Cross-ref:** `review_queue_policy.md`, `tool_review_queue_escalate.md`, `tool_review_queue_assign.md`, `audit_event_taxonomy.md`

---

## Overview

This policy defines the rules governing when and how review queue items are escalated to a higher-tier reviewer. Escalation is the mechanism by which items that cannot be resolved at one level of the reviewer hierarchy are surfaced to more senior staff or admins. Escalation is not a failure state — it is an expected part of the review lifecycle for complex or ambiguous items.

Escalation applies to items in the `review_queue_items` table. It does not directly transition the parent workflow run, except in specific cases described in the REVIEW_HOLD section below.

---

## Escalation Levels

The platform uses a three-tier reviewer hierarchy:

| Level | Role | Typical responsibilities |
|---|---|---|
| L1 | Accountant | First-line review; handles routine classification, matching, and VAT queries |
| L2 | Senior Accountant | Handles items requiring deeper VAT knowledge, judgement calls on classification, and items exceeding L1 SLA |
| L3 | Admin / Owner | Final escalation tier; handles items requiring policy decisions, legal exposure questions, or client communications |

Tier assignments are set on `org_members.reviewer_tier`. Valid values: `L1`, `L2`, `L3`. The `review_queue:write` permission is required at all three levels to receive assignments.

---

## Auto-Escalation Triggers

The system automatically escalates queue items without manual intervention when any of the following conditions are met:

### 1. Inactivity in ASSIGNED status for more than 48 hours

If an item has been in `ASSIGNED` status for more than 48 consecutive hours (measured from `assigned_at`) with no resolution, dismissal, snooze, or comment activity, the item is automatically escalated to the next tier above the current assignee:

- L1 assignee → escalated to any available L2 reviewer (round-robin if multiple)
- L2 assignee → escalated to L3 (admin pool)
- L3 assignee → remains at L3; a BLOCKING alert is generated and the run is placed in REVIEW_HOLD

The 48-hour window is measured in calendar hours, not business hours. The escalation job runs every 30 minutes.

### 2. AI confidence below 0.50

If the `ai_classification_result` associated with the queue item has `confidence_score < 0.50`, the item is escalated at creation time rather than being assigned to an L1 reviewer. Items with confidence below 0.50 are considered outside the reliable classification range and require at minimum an L2 review. These items enter the queue at ESCALATED status (skipping PENDING/ASSIGNED) and are routed directly to the L2 pool.

Confidence threshold configuration is managed in `business_ai_config_schema.md`. The default threshold of 0.50 may not be lowered below 0.40 for any business.

### 3. Multiple reclassification attempts without convergence

If an item has been reclassified three or more times without reaching a RESOLVED or DISMISSED status, it is auto-escalated to L2. If it has been reclassified five or more times, it is auto-escalated to L3. The reclassification count is tracked in `review_queue_items.reclassification_count`.

The rationale: repeated reclassification without resolution indicates either ambiguous source data, a gap in the classification rule set, or a policy question that L1 cannot answer independently.

---

## Manual Escalation Rules

Any org member with `review_queue:write` permission may manually escalate an ASSIGNED item at any time using `tool_review_queue_escalate.md`. There is no minimum hold time before manual escalation is permitted.

Manual escalation rules:

- The escalating reviewer must provide a written `escalation_reason` of at least 20 characters.
- The reviewer may target a specific L2 or L3 org member, or leave the target unspecified (unassigned escalation consumed by any admin).
- A reviewer may escalate their own assigned item. Self-escalation is not restricted — it is appropriate when the reviewer recognises the item exceeds their authority.
- An item may only be escalated from ASSIGNED status. Items in PENDING or UNASSIGNED must first be assigned before they can be escalated.
- An item already in ESCALATED status cannot be re-escalated via the tool. If further escalation is needed, an L3 admin performs a direct reassignment.

---

## Escalation Target Selection

When `escalate_to` is NULL (unassigned escalation), the following selection logic determines which admins are notified:

1. All L3 org members for the business with `status = 'ACTIVE'` receive a push notification.
2. The item appears in the unassigned escalation queue, visible to all L3 members.
3. The first L3 member to pick up the item claims it via `tool_review_queue_assign.md`.

When `escalate_to` is provided:

1. The named reviewer must be L2 or L3.
2. The item is assigned directly to that reviewer.
3. A targeted push notification is sent to the named reviewer.
4. L3 admins are also notified (for visibility), but the item is already assigned.

---

## Resolution SLAs per Escalation Level

| Level | SLA from escalation | Breach action |
|---|---|---|
| L1 initial assignment | 48 hours | Auto-escalate to L2 |
| L2 escalation | 72 hours (3 business days) | Auto-escalate to L3 |
| L3 escalation | 120 hours (5 business days) | REVIEW_HOLD on run; BLOCKING alert to platform team |

SLA timers start at the timestamp when the item enters that tier (initial `assigned_at` for L1, `escalated_at` for L2/L3). Timers are paused while the item is in SNOOZED status. SLA calculations use calendar hours, not business hours.

SLA breach detection runs as a scheduled job every 60 minutes.

---

## REVIEW_HOLD Escalation: When L3 Cannot Resolve

If an L3 escalation SLA is breached and the item is associated with a `BLOCKING` severity issue on an active run, the following actions are taken:

1. The workflow run is transitioned to `REVIEW_HOLD` status (if not already in REVIEW_HOLD).
2. A BLOCKING severity alert is emitted via the platform alert system.
3. The item is flagged with `manual_period_handling_required = true`.
4. The accountant pack for the affected period is marked with a manual intervention note.
5. The period cannot be finalised until the item is resolved by an L3 admin or an explicit override is applied by an OWNER-role user.

Items flagged `manual_period_handling_required = true` appear in the admin dashboard under the "Requires Manual Handling" category. These items are excluded from bulk action operations.

---

## Audit Trail

All escalation events — both auto-escalation and manual — are recorded in the audit log. The relevant events are:

| Event | Trigger | Severity |
|---|---|---|
| `REVIEW_ISSUE_ESCALATED` | Auto-severity-promotion (carry_forward_count threshold) | MEDIUM |
| `REVIEW_QUEUE_ITEM_ESCALATED` (pending taxonomy addition) | Manual tool escalation | MEDIUM |
| Auto-escalation by inactivity | Scheduler job | MEDIUM |

Until `REVIEW_QUEUE_ITEM_ESCALATED` is added to the taxonomy, the `escalation_source` field in the `REVIEW_ISSUE_ESCALATED` payload distinguishes manual (`MANUAL`) from automatic (`AUTO_INACTIVITY`, `AUTO_LOW_CONFIDENCE`, `AUTO_RECLASSIFICATION_LIMIT`) escalation paths.

---

## Related Documents

- `policies/review_queue_policy.md` — Issue lifecycle, SLA targets, severity tiers
- `policies/issue_escalation_policy.md` — Carry-forward escalation and severity promotion
- `tools/tool_review_queue_escalate.md` — Manual escalation tool spec
- `tools/tool_review_queue_assign.md` — Assignment tool spec
- `tools/tool_review_queue_resolve.md` — Resolution tool spec
- `schemas/review_queue_schema.md` — Queue item schema
- `schemas/review_issues_schema.md` — Review issues schema
- `reference/audit_event_taxonomy.md` — REVIEW domain events
- `reference/issue_status_enum.md` — Issue status enum values
