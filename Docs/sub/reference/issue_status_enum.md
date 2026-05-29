# issue_status_enum Reference

**Schema object:** `issue_status_enum` (PostgreSQL enum type)
**Owning block:** Block 08 — Review Queue
**Cross-ref:** `review_queue_schema.md`, `review_queue_policy.md`, `issue_group_enum.md`, `audit_event_taxonomy.md`

---

## DDL

```sql
CREATE TYPE issue_status_enum AS ENUM (
    'OPEN',
    'IN_PROGRESS',
    'RESOLVED',
    'SNOOZED',
    'ESCALATED',
    'AUTO_CLOSED',
    'VOID'
);
```

---

## Value Definitions

### OPEN

The issue has been created and is awaiting accountant action. OPEN is the initial status for all issues created by the engine or manually by an accountant. The SLA timer starts when the issue enters OPEN status.

An OPEN issue with BLOCKING severity places the parent workflow run in REVIEW_HOLD status. The run cannot advance to the next phase until all BLOCKING issues are RESOLVED, VOID, or explicitly overridden.

### IN_PROGRESS

An accountant has started working on the issue. The transition from OPEN to IN_PROGRESS is triggered when an accountant opens the issue detail view in the UI or explicitly marks it as in progress via the API. The SLA timer continues to run in IN_PROGRESS status.

IN_PROGRESS has no mechanical effect on run phase gates — it is a workflow status for accountant coordination and queue visibility.

### RESOLVED

The issue has been corrected and the accountant has marked it resolved. RESOLVED is a stable status; a resolved issue does not reopen automatically. The SLA timer stops at the transition to RESOLVED.

Resolving a BLOCKING issue releases the REVIEW_HOLD on the parent run if no other BLOCKING issues remain open.

### SNOOZED

The accountant has deferred the issue for a defined period (1, 3, 7, or 30 days per `review_queue_policy.md`). The SLA timer is paused for the duration of the snooze. When the snooze expires, the issue returns to OPEN status and the SLA timer resumes.

A SNOOZED BLOCKING issue does not release REVIEW_HOLD. Snoozing does not constitute resolution.

### ESCALATED

The SLA deadline has been breached without the issue reaching RESOLVED status. The system automatically transitions the issue to ESCALATED and notifies the org owner. The SLA timer is considered breached at this point.

Escalated issues remain the responsibility of the original assignee unless reassigned. They continue to appear in the review queue and block phase gates (if BLOCKING severity) until RESOLVED.

### AUTO_CLOSED

The issue was automatically closed by the system when the parent workflow run reached FINALIZED or CANCELLED status. AUTO_CLOSED is a terminal status. Issues in AUTO_CLOSED status cannot be reopened; if the same condition recurs on a future run, a new issue is created.

AUTO_CLOSED is distinguished from RESOLVED to maintain an accurate record of issues that were closed by run lifecycle events rather than by human resolution. This matters for SLA reporting — AUTO_CLOSED issues are excluded from SLA compliance calculations.

### VOID

The issue was created in error or is no longer relevant due to upstream data correction. VOID is a terminal status used only by ADMIN or OWNER role users. It indicates that the issue should be disregarded entirely — it did not represent a real problem.

VOID is not a substitute for RESOLVED. VOID must only be used when the issue was factually invalid (e.g., created for the wrong run, triggered by a bug that has since been fixed). Fixing an issue and marking it done is RESOLVED; retracting an issue that should not have existed is VOID.

---

## State Transition Diagram

```
[engine or accountant creates issue]
                |
                v
              OPEN
             / |  \
            /  |   \
[accountant  /   |    \ [SLA
 starts     /    |     \ breach]
 work]     v     |      v
       IN_PROGRESS      ESCALATED
           |   \          |
           |    \         |
    [snooze]    [resolve] [resolve]
           |        \    /
           v         v  v
        SNOOZED    RESOLVED (stable)
           |
    [snooze expires]
           |
           v
          OPEN (resume)

[parent run FINALIZED or CANCELLED]
           |
           v
       AUTO_CLOSED (terminal)

[ADMIN/OWNER retracts invalid issue]
           |
           v
         VOID (terminal)
```

---

## Transition Rules

| From | To | Actor | Condition |
|---|---|---|---|
| OPEN | IN_PROGRESS | Accountant (any role) | Issue opened in UI or explicitly marked |
| OPEN | SNOOZED | Accountant (role-gated by snooze duration) | Snooze action taken |
| OPEN | ESCALATED | System | SLA deadline breached |
| OPEN | AUTO_CLOSED | System | Parent run reaches FINALIZED or CANCELLED |
| OPEN | VOID | ADMIN, OWNER | Manual retraction |
| IN_PROGRESS | RESOLVED | Accountant (any role) | Fix applied and issue marked resolved |
| IN_PROGRESS | SNOOZED | Accountant (role-gated by snooze duration) | Snooze action taken |
| IN_PROGRESS | ESCALATED | System | SLA deadline breached |
| IN_PROGRESS | AUTO_CLOSED | System | Parent run reaches FINALIZED or CANCELLED |
| SNOOZED | OPEN | System | Snooze duration expires |
| SNOOZED | RESOLVED | Accountant (any role) | Resolved while snoozed (early resolution) |
| SNOOZED | AUTO_CLOSED | System | Parent run reaches FINALIZED or CANCELLED |
| ESCALATED | RESOLVED | Accountant (any role) | Fix applied post-escalation |
| ESCALATED | IN_PROGRESS | Accountant (any role) | Work restarted after escalation |
| ESCALATED | AUTO_CLOSED | System | Parent run reaches FINALIZED or CANCELLED |

---

## Terminal Statuses

RESOLVED, AUTO_CLOSED, and VOID are terminal statuses. Once an issue reaches a terminal status, it cannot be transitioned to any other status. If the same condition recurs, a new issue must be created.

---

## Audit Events on Status Change

| Status change | Audit event | Severity |
|---|---|---|
| → OPEN (issue created) | `REVIEW_ISSUE_CREATED` | LOW |
| → RESOLVED | `REVIEW_ISSUE_RESOLVED` | LOW |
| → SNOOZED | `REVIEW_ISSUE_SNOOZED` | LOW |
| → ESCALATED | `REVIEW_ISSUE_ESCALATED` | MEDIUM |
| → AUTO_CLOSED | `REVIEW_ISSUE_AUTO_CLOSED` | LOW |
| → VOID | `REVIEW_ISSUE_VOIDED` | LOW |

All events carry `issue_id`, `run_id`, `from_status`, `to_status`, `actor_id` (null for system transitions), and `business_id`.

---

## Usage in review_queue_schema.md

```sql
-- review_queue_issues table (excerpt)
status  issue_status_enum  NOT NULL  DEFAULT 'OPEN'
```

All status transitions are performed through the review queue tool layer. Direct SQL updates to `review_queue_issues.status` from application code outside the tool layer are not permitted.

---

## SLA Timer Behaviour by Status

| Status | SLA timer state |
|---|---|
| OPEN | Running |
| IN_PROGRESS | Running |
| SNOOZED | Paused |
| ESCALATED | Breached (timer stopped; breach recorded) |
| RESOLVED | Stopped (met SLA if resolved before deadline) |
| AUTO_CLOSED | Stopped (excluded from SLA calculations) |
| VOID | Stopped (excluded from SLA calculations) |

---

## Related Documents

- `issue_group_enum.md` line 90 — references this document
- `review_queue_schema.md` — full table definition
- `review_queue_policy.md` — SLA targets, snooze rules, escalation policy
- `audit_event_taxonomy.md` — REVIEW_ISSUE_* event definitions
