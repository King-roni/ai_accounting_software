# Snooze and Carry-Forward Policy

**Category:** Policies · **Owning block:** 14 — Review Queue · **Block reference:** BLOCK_14 · **Stage:** 4 sub-doc (Layer 2)

This document defines the snooze mechanism for review issues, the conditions under which a snooze is cleared before its TTL expires, and the carry-forward behaviour for unresolved issues at period close.

---

## Purpose

Not every open issue requires immediate action. Snooze lets accountants defer low-priority issues for a defined window without hiding them permanently. Carry-forward ensures that issues that are still open when a period closes are not silently abandoned — they transfer into the next period's review queue with traceability back to their origin run.

Both mechanisms operate on the `review_issues` table and are coordinated through the `snooze_carry_forward_schema` tables. All state changes are lazy: the queue view re-evaluates issue visibility on load, not in real time.

---

## Snooze

### Permitted durations

An accountant with role ACCOUNTANT, OWNER, or ADMIN may snooze a review issue for exactly one of the following durations:

| Duration | Calendar days added to `now()` |
| --- | --- |
| Short | 1 day |
| Short-week | 3 days |
| Week | 7 days |
| Extended | 30 days |

There is no arbitrary-duration snooze. The fixed durations are enforced by `review_queue.snooze_issue` — calls with a duration outside this set are rejected.

Snoozed issues are not deleted or archived. The `review_issues` row remains; only `snoozed_until` is set. The default queue view applies a `WHERE (snoozed_until IS NULL OR snoozed_until <= now())` filter to hide snoozed issues from the active queue. Accountants can explicitly switch to a "show snoozed" filter to inspect them.

### Snooze storage

The snoozed state is stored on `review_issues`:

| Column | Type | Semantics |
| --- | --- | --- |
| `snoozed_until` | `timestamptz NULL` | Non-null when snoozed; null when active |
| `snoozed_by_user_id` | `uuid NULL` | FK to `users.id`; set when snoozed |
| `snooze_reason` | `text NULL` | Free-text reason; max 500 characters |
| `snooze_count` | `integer NOT NULL DEFAULT 0` | Incremented on each snooze action; never decremented |

`snooze_count` feeds the carry-forward escalation rule in `issue_escalation_policy`. An issue that has been snoozed multiple times across consecutive periods accumulates a higher `snooze_count` and may be automatically escalated in severity.

---

## Snooze auto-clear triggers

A snooze is cleared before its TTL in three conditions. In every case, clearing a snooze means setting `snoozed_until = NULL` and `snoozed_by_user_id = NULL` on the `review_issues` row.

### Trigger A — Underlying data change

When the data record that an issue references (a transaction, document, match record, or invoice) is modified in a way that may resolve the condition that raised the issue, any active snooze on that issue is cleared. This is implemented via the rescan-on-resolution pipeline: the modification event schedules a rescan, and the rescan pass clears snoozes on affected issues before re-evaluating them.

Covered modifications:

- A transaction's `effective_match_status` changes.
- A transaction's `classification_result` is updated by a confirmed re-classification.
- A document's `ocr_status` or `confidence_score` changes.
- A match record's `status` transitions (e.g., from `PROPOSED` to `CONFIRMED`).
- An invoice is amended, voided, or issued.

The clearing is handled by `review_queue.unsnooze_on_data_change` (side-effect class: `WRITES_RUN_STATE | WRITES_AUDIT`). The audit event `REVIEW_QUEUE_SNOOZE_CLEARED_DATA_CHANGE` is emitted.

### Trigger B — Period advances to FINALIZING

When a workflow run's `run_status` transitions to `FINALIZING`, all snoozed issues associated with that `workflow_run_id` are unconditionally cleared. This prevents snoozed issues from being overlooked during the final pre-finalization review pass.

The clearing is handled inside `engine.advance_to_finalizing` as part of the FINALIZING entry actions. The audit event `REVIEW_QUEUE_SNOOZE_CLEARED_DATA_CHANGE` is emitted per issue (the data-change variant is used because the triggering condition is a state transition in the run, not TTL expiry).

### Trigger C — Snooze TTL expires

When `snoozed_until <= now()`, the issue re-appears in the active queue on the next queue load. There is no background job that clears `snoozed_until` when the TTL passes — the value remains set in the database, and the queue query's `WHERE` filter treats it as active. The `snoozed_until` column is left as-is until the accountant takes an action on the issue (resolve, re-snooze, or dismiss), at which point it is cleared. The audit event `REVIEW_QUEUE_SNOOZE_CLEARED_TTL` is emitted on the first queue load that reveals the issue post-expiry, not when the TTL timestamp passes.

---

## Severity-elevation auto-clear

If an issue's severity is raised (e.g., from `LOW` to `HIGH`) by a downstream rule — including the carry-forward escalation rule in `issue_escalation_policy` — any active snooze on that issue is immediately cleared, regardless of whether the TTL has passed.

The severity elevation and snooze clear happen in the same write transaction inside `review_queue.escalate_severity` (side-effect class: `WRITES_RUN_STATE | WRITES_AUDIT`).

The audit event `REVIEW_QUEUE_SNOOZE_CLEARED_SEVERITY_ESCALATION` is emitted. This event is distinct from the TTL and data-change events because it indicates a policy decision — not just data state — caused the unsnooze. Operators monitoring for unexpected escalations can filter on this event name.

---

## Lazy vs. eager unsnooze

Unsnooze is lazy. The issue re-appears in the queue at the moment the accountant loads or refreshes the review queue, not at the exact instant the trigger condition fires. There is no real-time push notification for an unsnooze event; the queue view re-computes on load.

Consequences of lazy semantics:

- The `REVIEW_QUEUE_SNOOZE_CLEARED_TTL` event is emitted on queue load, not at TTL boundary. If no accountant loads the queue for several days after a TTL expires, the event is not emitted until the next load.
- Severity-elevation unsnooze (Trigger C from the section above, i.e., `REVIEW_QUEUE_SNOOZE_CLEARED_SEVERITY_ESCALATION`) is the exception: it fires immediately within the escalation write transaction, because the escalation path is itself eager (triggered by a rule evaluation, not a query load).
- Data-change unsnooze (Trigger A) fires within the rescan pass, which is scheduled promptly after the triggering modification but is not synchronous with the modification itself. See `review_queue_rescan_on_resolution_policy` for the debounce and depth rules.

---

## Carry-forward

### Semantics

When a workflow run completes — moving to `FINALIZED` status — any review issues associated with that run that are still in a non-terminal state (i.e., `status NOT IN ('RESOLVED', 'DISMISSED')`) are carried forward into the next period's review queue.

Carry-forward is not an automatic escalation. The issue is transferred with:

- `workflow_run_id` updated to the new period's run ID.
- `carried_forward_from_run_id` set to the original run ID (or the most recent prior run ID if already carried forward once before).
- `snoozed_until` cleared: carried-forward issues start un-snoozed, regardless of their snooze state in the source run.
- `carry_forward_count` incremented by 1.
- `severity` unchanged at carry-forward time. The escalation rule in `issue_escalation_policy` evaluates separately and may raise severity after carry-forward based on `carry_forward_count`.

### Carry-forward trigger

`review_queue.carry_forward_issues` is called during the period-close sequence, after `FINALIZATION_LOCK_COMMITTED` and before the archive promotion step. It is idempotent: if called twice for the same source run, the second call is a no-op (the `carried_forward_from_run_id` FK ensures each issue is carried forward at most once per run).

### Carry-forward and un-snooze

The un-snooze at carry-forward time is unconditional. An issue that was snoozed with 25 days remaining in the prior period starts the new period fully visible in the active queue. This prevents snoozes from spanning across period boundaries, which would obscure the actual state of the queue at the start of each period.

### Chain of custody

The `carried_forward_from_run_id` reference creates a traceable chain. A query joining on `carried_forward_from_run_id` can reconstruct the full history of an issue across multiple periods. This chain is one level deep per hop — each carry-forward stores its immediate predecessor, not a full ancestry list. To walk the full chain, traverse recursively.

---

## Audit events

### `REVIEW_QUEUE_ISSUE_SNOOZED`

Severity: `LOW`

Emitted by `review_queue.snooze_issue` on each successful snooze.

Payload:

| Field | Type | Description |
| --- | --- | --- |
| `review_issue_id` | uuid | Issue that was snoozed |
| `workflow_run_id` | uuid | Run the issue belongs to |
| `snoozed_until` | timestamptz | When the snooze expires |
| `snooze_count` | integer | Updated count after this snooze |
| `snoozed_by_user_id` | uuid | Actor |
| `snooze_reason` | text | Optional reason text |

---

### `REVIEW_QUEUE_SNOOZE_CLEARED_TTL`

Severity: `LOW`

Emitted when a snoozed issue re-appears in the active queue because its TTL has expired (on the queue load that first detects expiry).

Payload: `review_issue_id`, `workflow_run_id`, `original_snoozed_until`, `cleared_at`, `cleared_by_queue_load_user_id`.

---

### `REVIEW_QUEUE_SNOOZE_CLEARED_DATA_CHANGE`

Severity: `LOW`

Emitted when a snooze is cleared because the underlying data record changed (Trigger A) or because the run advanced to FINALIZING (Trigger B).

Payload: `review_issue_id`, `workflow_run_id`, `trigger_type` (`DATA_CHANGE` or `PERIOD_FINALIZING`), `cleared_at`.

---

### `REVIEW_QUEUE_SNOOZE_CLEARED_SEVERITY_ESCALATION`

Severity: `MEDIUM`

Emitted when a snooze is cleared because the issue's severity was elevated. MEDIUM because the combination of severity escalation and forced unsnooze represents a policy-driven visibility override — it should be visible to supervisors.

Payload: `review_issue_id`, `workflow_run_id`, `previous_severity`, `new_severity`, `cleared_at`, `escalation_rule_id`.

---

### `REVIEW_QUEUE_ISSUE_CARRIED_FORWARD`

Severity: `LOW`

Emitted by `review_queue.carry_forward_issues` for each issue that is transferred to a new run.

Payload:

| Field | Type | Description |
| --- | --- | --- |
| `review_issue_id` | uuid | Issue that was carried forward |
| `source_run_id` | uuid | The run the issue originated in this hop |
| `target_run_id` | uuid | The new run it now belongs to |
| `carry_forward_count` | integer | Incremented count after this transfer |
| `issue_type` | text | Preserved for routing traceability |
| `severity` | text | Severity at time of carry-forward |

---

## Cross-references

- `review_issue_history_schema.md` — schema for the per-issue state history log, which records every snooze and unsnooze event
- `issue_escalation_policy.md` — escalation rules that reference `carry_forward_count` and `snooze_count`
- `snooze_carry_forward_schema.md` — DDL for the `review_issues` snooze columns and `carry_forward_log` table
- `review_queue_rescan_on_resolution_policy.md` — how data-change unsnooze is triggered via the rescan pipeline
- `audit_event_taxonomy.md` — `REVIEW_QUEUE_ISSUE_SNOOZED`, `REVIEW_QUEUE_SNOOZE_CLEARED_TTL`, `REVIEW_QUEUE_SNOOZE_CLEARED_DATA_CHANGE`, `REVIEW_QUEUE_SNOOZE_CLEARED_SEVERITY_ESCALATION`, `REVIEW_QUEUE_ISSUE_CARRIED_FORWARD`
