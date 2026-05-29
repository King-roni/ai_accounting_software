# Issue Group Routing Policy

**Category:** Policies · **Owning block:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 2)

Rules governing how newly created review issues are routed to issue groups and assigned to users. This policy is the single binding source for group assignment logic, within-group user assignment modes, eligibility constraints by role, and the consequences of leaving high-severity issues unassigned.

---

## 1. Group assignment on creation

Every `review_issues` row is assigned to exactly one issue group at the time of INSERT. The five permitted values are those of the `issue_group_enum` (as defined in `review_issue_card_schema`):

```
Missing Documents
Needs Confirmation
Possible Wrong Match
Possible Tax/VAT Issue
Unusual Transaction
```

Group assignment is not a caller-supplied value. The producing block passes an `issue_type` string; the engine resolves the canonical group from the `issue_type_registry` table via the `issue_group` column on the matching row. The producing block must not pass `issue_group` directly. An unregistered `issue_type` causes the INSERT to fail with an FK violation (deferred FK on `review_issues.issue_type → issue_type_registry.issue_type`).

The group value written to `review_issues.issue_group` is frozen at creation time from the registry. Subsequent amendments to the registry entry do not retroactively change existing rows.

The `issue_type_to_group_mapping` reference doc is the exhaustive per-`issue_type` group table assembled from all producing blocks' `registerIssueType` calls. This policy does not replicate that table; it governs only the routing mechanism.

---

## 2. User assignment modes

Within a group, issues are assigned to a user based on the business's assignment configuration. Three modes are supported, set per business in `business_entities.review_assignment_mode`:

| Mode | Behaviour |
|---|---|
| `ROUND_ROBIN` | Default. The engine cycles through active Bookkeepers and Admins in deterministic round-robin order per group. The ordering is by `users.created_at ASC` within the eligible set. On creation of a new issue, the next eligible user in the cycle receives the assignment. |
| `MANUAL` | The issue is created as unassigned (`assigned_to_user_id IS NULL`). The Owner must assign it explicitly via `review_queue.assign_issue`. |
| `UNASSIGNED` | Issues are always created unassigned. No automatic assignment runs. Owners and Admins may still assign manually. |

The assignment mode is resolved at issue-creation time; changing the business setting mid-run affects only subsequently created issues, not existing open issues.

---

## 3. Role eligibility for assignment

Not every role may be assigned to every group. The following constraints are binding:

1. **Bookkeepers** may be assigned issues in the groups `Missing Documents`, `Needs Confirmation`, `Possible Wrong Match`, and `Unusual Transaction`.
2. **Bookkeepers may not be assigned issues in the `Possible Tax/VAT Issue` group** — this group requires VAT and ledger expertise beyond the Bookkeeper role scope per the `permission_matrix`.
3. **Bookkeepers may not be assigned issues whose `issue_group` maps to any group tagged as `FINALIZATION`-scope** — there are no `FINALIZATION`-scoped groups in the current `issue_group_enum`; this constraint applies if a `FINALIZATION`-associated group is added in a future schema migration.
4. **Admins** may be assigned issues in all five groups.
5. **Owners** are not assigned issues; they can assign, reassign, and view all issues, but are not in the assignment rotation.
6. **Accountants** are not in the assignment rotation; they consume the queue as read-only observers.

If `ROUND_ROBIN` mode would cycle to a user who is ineligible for the issue's group, that user is skipped and the next eligible user in the cycle is selected. If no eligible user exists in the rotation, the issue is created as unassigned and an in-app notification is dispatched to the Owner.

---

## 4. Assignment change logging

Every change to `review_issues.assigned_to_user_id` — whether via `ROUND_ROBIN` auto-assignment, `MANUAL` assignment, or reassignment — must be logged as an `ASSIGNED` action in `review_issue_history`. The `action_payload_json` includes `previous_assignee_user_id` (nullable), `new_assignee_user_id`, and `assignment_method` (`ROUND_ROBIN`, `MANUAL`, or `REASSIGNED`).

The `review_queue.assign_issue` tool owns all assignment writes. No other tool or application code may directly update `review_issues.assigned_to_user_id`. The tool's side-effect class is `WRITES_RUN_STATE | WRITES_AUDIT`.

Audit event `REVIEW_ISSUE_REASSIGNED` is emitted on the business-scoped hash chain for every assignment change per `audit_log_policies`.

---

## 5. Unassigned HIGH and BLOCKING issue escalation

If a review issue has severity `HIGH` or `BLOCKING` and `assigned_to_user_id IS NULL` for 24 hours from `review_issues.created_at`, a `SECURITY_ALERT` is raised and dispatched to all Owners of the business. The alert text identifies the issue by its `issue_type`, `issue_group`, and `severity`. The alert is raised via the security alerting subsystem (Block 05 Phase 10) as a `SECURITY_ALERT_RAISED` event.

This 24-hour window applies regardless of the business's assignment mode. In `MANUAL` and `UNASSIGNED` modes, the Owner is responsible for assignment; the alert is the mechanism by which the system enforces that high-severity issues do not persist unassigned indefinitely.

The alert is deduplicated: if a `SECURITY_ALERT` for the same `review_issue_id` and `alert_reason = UNASSIGNED_HIGH_SEVERITY` is already active, a new alert is not raised. The deduplication follows `SECURITY_ALERT_DEDUPLICATED` semantics per `audit_event_taxonomy`.

Once the issue is assigned (or resolved), the active alert is acknowledged automatically via the security alerting subsystem.

---

## 6. Mobile rejection

`review_queue.assign_issue` is a write operation. Mobile clients attempting to invoke the assignment endpoint receive HTTP 405 `MOBILE_WRITE_REJECTED`. The assignment endpoint is listed in `mobile_write_rejection_endpoints.md`. Read access to assignment state (the assigned user badge on issue cards) is available on mobile.

---

## 7. Audit events

| Event | Severity | When |
|---|---|---|
| `REVIEW_ISSUE_REASSIGNED` | LOW | Emitted by `review_queue.assign_issue` on any assignment change; emitted on initial auto-assignment and on reassignment |
| `SECURITY_ALERT_RAISED` | HIGH | Emitted when an unassigned `HIGH` or `BLOCKING` issue remains unassigned for 24 hours |

Both events are emitted on the business-scoped hash chain per `audit_log_policies`.

---

## 8. Round-robin cycle persistence

For `ROUND_ROBIN` mode, the assignment cycle position is stored per `(business_id, issue_group)` in a lightweight state row (not replicated here; see Block 14 Phase 06). The cycle advances atomically with the issue INSERT using a row-level lock on the cycle state row. This prevents two concurrently created issues in the same group from being assigned to the same user.

The cycle position is not reset between runs. A user removed from the rotation (deactivated or role changed) is skipped going forward; the cycle re-normalises to the remaining eligible users. If the eligible user set drops to zero mid-run, all subsequent issues for that group in that run are created as `UNASSIGNED` and the Owner is notified.

---

## 9. Reassignment and self-assignment

An Owner or Admin may reassign any issue at any time using `review_queue.assign_issue`. A Bookkeeper may self-assign an issue that is in an eligible group via `send_to_my_inbox` resolution action (per `resolution_action_payload_schema`). Self-assignment does not advance the round-robin cycle; it is treated as a `MANUAL` assignment for the purpose of the history log.

An issue may not be assigned to a user whose role is ineligible for the issue's group. The application enforces this before the UPDATE; the tool returns HTTP 422 `REVIEW_ASSIGNMENT_ROLE_INELIGIBLE` if the target user is ineligible.

---

## 10. Invariant summary

1. Every review issue is assigned to exactly one of the five `issue_group_enum` values at creation; assignment is registry-derived, never caller-supplied.
2. Three user assignment modes exist; `ROUND_ROBIN` is the default.
3. Bookkeepers may not be assigned issues in the `Possible Tax/VAT Issue` group.
4. `review_queue.assign_issue` is the sole write path for `assigned_to_user_id`.
5. Every assignment change is logged in `review_issue_history` with an `ASSIGNED` row.
6. Unassigned `HIGH` or `BLOCKING` issues trigger a `SECURITY_ALERT` after 24 hours.
7. Self-assignment via `send_to_my_inbox` is permitted for Bookkeepers in eligible groups.
8. A user ineligible for the issue's group cannot be assigned; the tool rejects the request.

---

## 11. Interaction with issue severity

Group routing and severity assignment are independent dimensions of a review issue. The group is derived from the `issue_type` registry; the severity is also derived from the registry's `default_severity` for that `issue_type`, and may be escalated later by `review_queue.unsnooze_at_run_start` per `issue_escalation_policy`. The routing policy has no knowledge of severity at routing time and does not adjust group assignment based on severity.

However, severity influences which users may be assigned. Specifically:

- `BLOCKING` issues require resolution, not reassignment, as the first response. The assignment rotation still runs (to place the issue with a responsible user), but the primary imperative for `BLOCKING` issues is resolution. Reassignment of a `BLOCKING` issue to another eligible user is permitted but does not satisfy the finalization gate — only resolution does.
- `HIGH` issues that remain unassigned for 24 hours trigger the alert described in Section 5. This alert is severity-gated; `LOW` and `MEDIUM` unassigned issues do not trigger the 24-hour alert.

---

## Cross-references

- `issue_group_enum` — closed 5-value set `{Missing Documents, Needs Confirmation, Possible Wrong Match, Possible Tax/VAT Issue, Unusual Transaction}`
- `issue_type_to_group_mapping` — exhaustive per-`issue_type` group table; canonical routing reference
- `review_issue_card_schema` — `issue_type_registry` table; `issue_group` and `assigned_to_user_id` columns on `review_issues`; FK deferred constraint enforcement
- `review_issue_history_schema` — `ASSIGNED` action type; assignment change logging requirement
- `permission_matrix` — Bookkeeper role scope; group eligibility by role
- `audit_log_policies` — `REVIEW_ISSUE_REASSIGNED` and `SECURITY_ALERT_RAISED` event naming; business-scoped hash chain
- `audit_event_taxonomy` — `REVIEW` domain; `SECURITY_ALERT_RAISED` deduplication semantics
- `tool_naming_convention_policy` — `review_queue.assign_issue` tool name; `WRITES_RUN_STATE | WRITES_AUDIT` side-effect class
- `mobile_write_rejection_endpoints` — assignment endpoint listed as mobile-rejected
- Block 14 Phase 02 — issue groups, routing table, severity architecture
- Block 14 Phase 06 — assignment and notes architecture; assignment notification subsystem
- Block 05 Phase 10 — security alerting subsystem; `SECURITY_ALERT_RAISED` emission
