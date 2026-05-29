# Review Queue Policy

**Scope:** All review queue items created within workflow runs.
**Owning team:** Platform / Workflow & Classification (Blocks 08, 09)
**Last reviewed:** 2026-05-17
**Cross-ref:** `tool_review_queue_create_issue.md`, `review_queue_schema.md`, `error_code_catalog.md`, `audit_event_taxonomy.md`

---

## Overview

The review queue holds issues that block or require attention during a workflow run. Issues are created automatically by the engine when certain conditions are met (low-confidence classification, matching failures, parse errors) or manually by accountants via the `review_queue.create_issue` endpoint. This policy defines what triggers an issue, severity tiers, SLA targets, assignment rules, auto-close behaviour, snooze rules, and escalation paths.

---

## Issue Triggers

Review queue issues are created in the following circumstances:

| Trigger | Issue type | Default severity |
|---|---|---|
| Classification confidence score below threshold (< 0.70) | `CLASSIFICATION_LOW_CONFIDENCE` | WARNING |
| Matching result is `NO_MATCH` after all match strategies attempted | `MATCHING_NO_MATCH` | WARNING |
| Matching result is `AMBIGUOUS` (multiple candidates, no clear winner) | `MATCHING_AMBIGUOUS` | WARNING |
| Document parse error that did not abort the parse (partial parse) | `PARSE_PARTIAL_FAILURE` | WARNING |
| Document parse error that aborted the parse entirely | `PARSE_TOTAL_FAILURE` | BLOCKING |
| Ledger phase gate failure | `LEDGER_GATE_FAILURE` | BLOCKING |
| VAT period locked during posting | `VAT_PERIOD_LOCKED` | BLOCKING |
| Manual escalation by accountant | `MANUAL_ESCALATION` | INFO (default; accountant can override) |
| Run held by engine (REVIEW_HOLD status) | `ENGINE_REVIEW_HOLD` | BLOCKING |

New trigger types can be added by the platform team without a policy update; the trigger table above reflects the initial set.

---

## Issue Severity Tiers

### INFO

Informational issues require no immediate action. They are recorded for audit trail purposes and to give accountants visibility into edge cases that were handled automatically. INFO issues do not block run phase advancement.

### WARNING

Warning issues require accountant review but do not immediately block run phase advancement. If a WARNING issue remains unresolved when the run reaches the FINALIZATION phase gate, the gate fails and the run is held until the issue is resolved or snoozed.

### BLOCKING

Blocking issues halt the run at the current phase. The run enters REVIEW_HOLD status and no further phase advancement occurs until all BLOCKING issues for the run are resolved or explicitly overridden by an OWNER-role user.

---

## SLA Targets

| Severity | Resolution SLA | Escalation trigger |
|---|---|---|
| BLOCKING | 1 business day from creation | Auto-escalates to org owner at SLA breach |
| WARNING | 5 business days from creation | Auto-escalates to org owner at SLA breach |
| INFO | No SLA | No escalation |

Business days are calculated using the `target2_holiday_calendar` table (same calendar used for ECB rate grace periods). SLA timers start at `created_at` and are paused while an issue is in SNOOZED status.

---

## Auto-Close Rules

Issues are automatically closed (transitioned to AUTO_CLOSED status) when:

1. The parent workflow run reaches FINALIZED status.
2. The parent workflow run is CANCELLED (all open issues for the run are auto-closed).

Auto-close applies to issues in any non-terminal status: OPEN, IN_PROGRESS, SNOOZED, WARNING. Issues already in RESOLVED or VOID status are not affected.

`REVIEW_ISSUE_AUTO_CLOSED` (LOW) is emitted for each auto-closed issue with `trigger` set to `RUN_FINALIZED` or `RUN_CANCELLED`.

---

## Assignment Rules

- Issues are assigned to the accountant who owns the parent run (`workflow_runs.owner_user_id`).
- If the run has no owner (null `owner_user_id`), the issue is created in OPEN status with no assignee.
- Assignment can be changed by any ADMIN or OWNER role user via `review_queue.reassign_issue`.
- Re-assignment does not reset the SLA timer.

---

## Snooze Policy

Accountants may snooze an issue to suppress notifications and pause the SLA timer for a defined period.

| Snooze duration | Available to |
|---|---|
| 1 day | ACCOUNTANT, ADMIN, OWNER |
| 3 days | ACCOUNTANT, ADMIN, OWNER |
| 7 days | ADMIN, OWNER |
| 30 days | OWNER only |

Snooze rules:

- An issue can be snoozed multiple times; each snooze replaces the previous snooze expiry.
- BLOCKING issues can be snoozed, but this does not release the REVIEW_HOLD on the run. To release REVIEW_HOLD, a BLOCKING issue must be RESOLVED or explicitly overridden by an OWNER.
- When a snooze expires, the issue returns to OPEN status and the SLA timer resumes from where it was paused.
- `REVIEW_ISSUE_SNOOZED` (LOW) is emitted on each snooze action with `snooze_duration_days` in the payload.

---

## Escalation

When an issue's SLA is breached (resolution deadline passes without the issue reaching RESOLVED status):

1. The issue status transitions to ESCALATED.
2. `REVIEW_ISSUE_ESCALATED` (MEDIUM) is emitted with `sla_target_days`, `days_overdue`, `assigned_user_id`, and `business_id` in the payload.
3. A notification is sent to the org owner (`business_members` row with role `OWNER`).
4. The issue remains in ESCALATED status until it is resolved or the run is finalized/cancelled.

Escalation does not change the assignee. The org owner receives notification but the original assignee remains responsible unless reassigned.

If the org owner role is vacant (no OWNER member on the business), escalation notifications are routed to the platform support queue.

---

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `REVIEW_ISSUE_CREATED` | LOW | Any new issue inserted into review_queue |
| `REVIEW_ISSUE_RESOLVED` | LOW | Issue status set to RESOLVED |
| `REVIEW_ISSUE_SNOOZED` | LOW | Issue snoozed; SLA timer paused |
| `REVIEW_ISSUE_ESCALATED` | MEDIUM | SLA breach; issue transitioned to ESCALATED |
| `REVIEW_ISSUE_AUTO_CLOSED` | LOW | Issue auto-closed on run finalization or cancellation |

All events carry `issue_id`, `run_id`, `business_id`, and `issue_type` as base payload fields. See `audit_event_taxonomy.md` for full payload schemas.

---

## Issue Limits

To prevent unbounded growth of the review queue:

- Maximum 500 open issues per workflow run. New issues beyond this limit are rejected with `REVIEW_QUEUE_LIMIT_EXCEEDED`.
- Maximum 10,000 total issues (any status) per business per calendar year. Exceeding this limit triggers a MEDIUM alert to the platform team for capacity review.

---

## Related Documents

- `tool_review_queue_create_issue.md` — implementation of issue creation
- `review_queue_schema.md` — issue_status_enum, issue_severity_enum column definitions
- `issue_status_enum.md` — state transition diagram
- `error_code_catalog.md` line 110 — review queue error code definitions
- `audit_event_taxonomy.md` — REVIEW_ISSUE_* event definitions
