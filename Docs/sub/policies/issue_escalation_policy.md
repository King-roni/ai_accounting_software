# Issue Escalation Policy

**Category:** Policies · **Owning block:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 2)

Rules governing automatic severity escalation of review issues that remain unresolved across multiple consecutive workflow runs via the snooze mechanism. Escalation is system-initiated, applied at run start, and requires no human action to trigger. This policy is the single binding source for escalation thresholds, the severity ladder, and the audit trail requirement.

---

## 1. Escalation trigger and ownership

Escalation is evaluated and applied by `review_queue.unsnooze_at_run_start` at the start of every run, immediately before phase execution begins. The tool already owns the carry-forward counter logic (per `snooze_carry_forward_schema`); escalation is applied in the same pass, after the carry-forward counter is incremented for the current run.

The escalation check reads `snooze_records.carry_forward_count` on the most recent snooze row for each issue being resurfaced. If the threshold for the issue's current severity is met, the severity on the `review_issues` row is promoted to the next level before any gate evaluation for the new run sees it.

---

## 2. Escalation thresholds (binding)

| Current severity | Threshold | Escalates to | Blocking on run |
|---|---|---|---|
| `LOW` | `carry_forward_count >= 3` consecutive snoozed runs | `MEDIUM` | No |
| `MEDIUM` | `carry_forward_count >= 3` consecutive snoozed runs | `HIGH` | No — but see Section 3 |
| `HIGH` | — | Not escalated further | Yes — blocks at `REVIEW_HOLD` gate |
| `BLOCKING` | — | Cannot escalate; snooze is not permitted | Yes — always blocks |

"Consecutive" means the carry-forward count has incremented on each of the preceding runs without a reset (a reset occurs when the user resolves, dismisses, or takes any non-snooze resolution action on the issue). A non-consecutive snooze sequence — snooze in run N, resolve in run N+1, snooze again in run N+2 — resets the counter to 0 on the new snooze row; the prior snooze history does not accumulate toward escalation.

---

## 3. Effect on run gate behaviour after escalation

**`LOW → MEDIUM` escalation:** the issue is now `MEDIUM`. `MEDIUM` issues do not block the finalization gate. The user will encounter the issue in the review queue with elevated prominence but may still snooze it (subject to `snooze_carry_forward_schema` MEDIUM snooze rules).

**`MEDIUM → HIGH` escalation:** the issue is now `HIGH`. `HIGH` issues block the `REVIEW_HOLD` gate if unresolved. The run transitions to `REVIEW_HOLD` state per `workflow_state_enum` until the issue is resolved. A user may snooze a `HIGH` issue once per its lifetime; a second snooze attempt is rejected.

**`HIGH` (no further escalation):** `HIGH` issues remain `HIGH` across runs. They continue to block the `REVIEW_HOLD` gate on every run where they appear as open. An unresolved `HIGH` issue prevents the run from reaching `AWAITING_APPROVAL` and therefore prevents finalization.

**`BLOCKING` (no escalation, no snooze):** `BLOCKING` issues cannot be snoozed, per `snooze_carry_forward_schema` Section 3.1. They block the finalization gate unconditionally. The snooze path that drives carry-forward escalation is unavailable for `BLOCKING` issues; this policy has no interaction with `BLOCKING` severity.

---

## 4. Severity column update mechanics

When escalation applies, `review_queue.unsnooze_at_run_start` performs a direct UPDATE on `review_issues.severity` for the affected row. The column's value reflects the escalated severity from that point forward.

**Original severity preservation:** the original severity at issue creation is frozen in the `review_issues` row's `created_severity` column (set at INSERT time, never updated). Audit history in the audit log records the original severity in the `REVIEW_ISSUE_CREATED` event payload. The `severity` column on the current row always reflects the effective (possibly escalated) severity; `created_severity` preserves the baseline.

**History record:** each escalation emits `REVIEW_ISSUE_ESCALATED` (see Section 6). The audit event payload includes `previous_severity`, `new_severity`, `carry_forward_count`, and `workflow_run_id`, providing a complete escalation history in the audit log.

---

## 5. De-escalation

De-escalation — reducing `severity` after an incorrect initial assessment — is not supported as an automated or user-driven operation on an existing `review_issues` row. The reasons:

1. Severity is part of the finalization gate contract. Retroactively reducing severity on an open issue could silently unblock a gate that should remain held.
2. The audit chain records the escalated severity; reducing it would create an inconsistency between the live row and the audit record.

If the original severity was assessed incorrectly, the correct remediation is: resolve or dismiss the existing issue, then create a new issue with the corrected lower severity. This preserves the audit record of both the original and replacement issues.

---

## 6a. Interaction with `max_carry_forward` business setting

Business owners may raise `max_carry_forward` from the default of 3 to a maximum of 5 via business settings (per `snooze_carry_forward_schema`). This setting controls how many snooze cycles are permitted before the `auto_escalated` advisory flag is set on the snooze record. It does NOT change the escalation threshold in this policy.

The escalation threshold (`carry_forward_count >= 3`) is a platform-level constant. The `max_carry_forward` setting governs the snooze lifecycle independently. These two mechanisms interact as follows: if `max_carry_forward = 5`, the `auto_escalated` flag fires at count 5; but severity escalation still fires at count 3. Between counts 3 and 5, the issue is escalated in severity but may still be re-snoozed (subject to severity-based snooze rules in `snooze_carry_forward_schema`). This means a `LOW` issue escalated to `MEDIUM` at count 3 may be snoozed again (as `MEDIUM`) for up to 2 more runs before `auto_escalated` flags at count 5.

This separation of concerns is intentional: escalation is a regulatory-facing gate mechanism (it ensures issues do not stay unnoticed indefinitely); the carry-forward limit is a workflow-management mechanism (it alerts owners that a snoozed issue has been deferred many times).

---

## 6b. Escalation ordering within a run-start pass

When `review_queue.unsnooze_at_run_start` processes a batch of snoozed issues at run start, escalation is applied before the gate evaluation for any of those issues in the new run. The ordering within the batch is:

1. Increment `carry_forward_count` for all issues being resurfaced.
2. Apply severity escalation for all issues whose counter now meets the threshold.
3. Emit `REVIEW_ISSUE_ESCALATED` for all escalated issues (batch emit is permitted to manage audit volume).
4. Set `status = OPEN` for all resurfaced issues.
5. Return control to the engine; gate evaluation proceeds with the escalated severity values visible.

This ordering guarantees that a gate which evaluates `REVIEW_HOLD` based on `HIGH` severity sees the escalated value in the same run where the threshold was crossed, not the following run.

---

## 6. Escalation audit event

| Event | Severity | When |
|---|---|---|
| `REVIEW_ISSUE_ESCALATED` | MEDIUM | Emitted once per issue per escalation step; payload includes `review_issue_id`, `previous_severity`, `new_severity`, `carry_forward_count`, `workflow_run_id`, `business_id` |

`REVIEW_ISSUE_ESCALATED` is emitted on the business-scoped hash chain per `audit_log_policies`. It is a domain `REVIEW` event. It is distinct from `REVIEW_ISSUE_CARRY_FORWARD_ESCALATED` (defined in `snooze_carry_forward_schema`), which is an advisory flag on the snooze record, not the severity-mutation event. Both events may fire in the same `unsnooze_at_run_start` pass for the same issue.

---

## 7. Notification and visibility of escalated issues

When an issue escalates, users assigned to the issue (or the business Owner if no assignee is set) are notified via the in-app notification system. The notification includes the issue title, the previous severity, and the new severity. Notification dispatch is performed by the review queue notification subsystem (Block 14 Phase 06); the escalation event `REVIEW_ISSUE_ESCALATED` is the trigger.

The escalated severity is immediately reflected in the review queue card for the issue. The card's severity badge updates to the new level. If the escalation moved the issue to `HIGH`, the issue moves to the top of the default sort order (severity DESC) in the queue view for the current run.

Accountant-role users can see `REVIEW_ISSUE_ESCALATED` events in the audit history slice for an issue (per the per-role audit RLS overlay in `audit_log_policies`). Owner and Admin can see the full escalation history including the previous severity values.

---

## 8. Mobile rejection

`review_queue.unsnooze_at_run_start` is a system-initiated tool invoked by the engine, not by a user-facing API endpoint. It is not accessible from any client surface. Mobile clients cannot trigger, suppress, or observe escalation directly; they see the escalated severity in read-only queue views, which are permitted on mobile per `snooze_carry_forward_schema` Section 6.

---

## 8. Relationship to `REVIEW_ISSUE_CARRY_FORWARD_ESCALATED`

Two separate escalation-adjacent events exist in the `REVIEW` domain and are easily confused:

- `REVIEW_ISSUE_CARRY_FORWARD_ESCALATED` (MEDIUM) — emitted by `snooze_carry_forward_schema` when `carry_forward_count` reaches `max_carry_forward` on a snooze row. This is an advisory flag; it does not change severity. The `auto_escalated` column on the snooze record is set to `true`. The issue remains snoozed.
- `REVIEW_ISSUE_ESCALATED` (MEDIUM) — emitted by this policy when severity is promoted. It changes the `severity` column on the `review_issues` row. The issue may or may not be snoozed at the moment of escalation; escalation fires at unsnooze time.

The two events may co-fire in the same `unsnooze_at_run_start` pass if `carry_forward_count` equals both 3 (escalation threshold) and `max_carry_forward` at the same time — i.e., when `max_carry_forward` is also 3 (the default). Both events are emitted for the same issue in the same run in that scenario.

---

## 9. Invariant summary

1. Only system-initiated; no human action can trigger or suppress escalation within a run.
2. Escalation only moves severity upward (`LOW → MEDIUM → HIGH`); it never moves it down.
3. `BLOCKING` issues are outside the escalation path because snooze is not permitted for `BLOCKING`.
4. `HIGH` is the ceiling for auto-escalation; no further automatic promotion exists.
5. The carry-forward counter must reach the threshold on consecutive runs; a resolution event resets it.
6. Every escalation step emits `REVIEW_ISSUE_ESCALATED` before any gate evaluates the issue's severity in the new run.

---

## Cross-references

- `review_issue_card_schema` — `issue_type_registry` and `review_issues` table; `severity` and `created_severity` columns; severity enum values
- `snooze_carry_forward_schema` — `snooze_records.carry_forward_count`; `max_carry_forward`; `auto_escalated` flag; `review_queue.unsnooze_at_run_start` tool; severity-based snooze eligibility table
- `workflow_state_enum` — `REVIEW_HOLD` state triggered by `HIGH` issues after escalation; canonical 10-value state set
- `audit_log_policies` — `REVIEW_ISSUE_ESCALATED` event naming; `REVIEW` domain; business-scoped hash chain
- `audit_event_taxonomy` — `REVIEW` domain canonical events; `REVIEW_ISSUE_ESCALATED` entry
- `tool_naming_convention_policy` — `review_queue.unsnooze_at_run_start` tool name; `WRITES_RUN_STATE | WRITES_AUDIT` side-effect class
- `mobile_write_rejection_endpoints` — system tools not exposed to mobile write surfaces
- Block 14 Phase 02 — severity enum canonical values; gate-hold predicates for `HIGH` and `BLOCKING`
- Block 14 Phase 07 — snooze and cross-run carry-forward architecture; escalation context
- Block 03 Phase 07 — resumability framework; `unsnooze_at_run_start` placement at run start
- Block 03 Phase 05 — gate evaluation framework; `REVIEW_HOLD` gate predicate for `HIGH` / `BLOCKING` issues
