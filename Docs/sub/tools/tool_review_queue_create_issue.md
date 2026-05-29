# tool_review_queue_create_issue

**Category:** Tools — Block 14: Review Queue
**Tool name:** `review_queue.create_issue`
**Side effect class:** `WRITES_RUN_STATE | WRITES_AUDIT`
**Mobile rejection:** YES — mobile clients cannot call `review_queue.create_issue`. See `mobile_write_rejection_endpoints.md`.

---

## Purpose

Creates a new review issue in the review queue for a workflow run. Issues represent
discrete problems that must be resolved — by a human reviewer, an automated rule, or
both — before the run can proceed past `REVIEW_HOLD`. The tool deduplicates, routes
to the correct review group, escalates severity if applicable, and transitions run
status when a `BLOCKING` issue is created.

---

## Input Schema

```json
{
  "run_id":          "uuid",
  "business_id":     "uuid",
  "issue_type":      "text",
  "reference_id":    "uuid",
  "reference_table": "text",
  "severity":        "LOW | MEDIUM | HIGH | BLOCKING",
  "description":     "text",
  "auto_resolvable": "boolean (DEFAULT false)",
  "idempotency_key": "string"
}
```

All fields are required except `auto_resolvable` (defaults to `false`).

---

## Output Schema

```json
{
  "issue_id":     "uuid",
  "issue_status": "OPEN",
  "severity":     "text",
  "is_duplicate": "boolean"
}
```

`severity` in the response reflects the post-escalation severity, which may differ from
the input value if escalation rules applied.

---

## Issue Type Validation

`issue_type` must exist in the `issue_type_registry` table. If the value is not found,
the tool returns `400 UNKNOWN_ISSUE_TYPE`. The registry controls the set of valid issue
types; new types must be registered before they can be used. See
`issue_type_registry_schema.md`.

---

## Deduplication

Before creating a new row, the tool checks for an existing open issue with the same
`(run_id, issue_type, reference_id)` tuple where `issue_status = 'OPEN'`.

- If a duplicate is found: returns the existing `issue_id` with `is_duplicate = true`.
  No new row is written, no audit event is emitted.
- If no duplicate: proceeds to creation.

Deduplication does not apply to closed or resolved issues — a new issue may be created
for the same tuple after the previous one is resolved.

---

## Severity Escalation

After a new issue is created (not for duplicates), the escalation rules in
`issue_escalation_policy.md` are evaluated synchronously:

1. The run's existing open issue set is inspected for escalation triggers.
2. If an escalation rule matches, the newly-created issue's severity is raised.
3. Escalation is upward-only — severity can never be reduced by escalation.
4. The final (post-escalation) severity is stored on the issue row and returned.

---

## Group Routing

`issue_type` is looked up in `full_issue_type_to_group_routing_table.md` to determine
the `review_group` assignment. The routing table maps each `issue_type` to exactly one
group (e.g., `TAX_REVIEW`, `MATCH_REVIEW`, `COMPLIANCE_REVIEW`). The resolved group is
stored on the issue row at creation time and determines which reviewer queue the issue
appears in.

---

## Run Status Effect

| Severity after escalation | Effect on run_status                                         |
|---|---|
| `LOW`                     | No change                                                    |
| `MEDIUM`                  | No change                                                    |
| `HIGH`                    | No change                                                    |
| `BLOCKING`                | `run_status` transitions to `REVIEW_HOLD` if not already held |

If `run_status` is `AWAITING_APPROVAL`, the approval gate is re-evaluated after the
`BLOCKING` issue is created. If the gate fails, the run is held at `REVIEW_HOLD`
pending issue resolution.

The `REVIEW_QUEUE_RUN_HELD` audit event is written only when the status transition to
`REVIEW_HOLD` occurs (i.e., not if the run was already in `REVIEW_HOLD`).

---

## auto_resolvable Flag

If `auto_resolvable = true`, the review engine will attempt automated resolution
immediately after creation (e.g., re-running a matching rule or re-validating a VAT
rate). If auto-resolution succeeds, the issue transitions to `AUTO_RESOLVED` without
appearing in any human review queue. If it fails, the issue remains `OPEN` and is
routed normally.

`auto_resolvable = false` (default): the issue goes directly to the review queue with
no auto-resolution attempt.

---

## Primary Key

Issue rows use `gen_uuid_v7()` as the PK. See `review_issues_schema.md` for the full
DDL, including the composite index on `(run_id, issue_type, reference_id, issue_status)`.

---

## Idempotency

If `idempotency_key` matches an existing record for the same `run_id`:

- The original `issue_id` and current `issue_status` are returned.
- `is_duplicate = true`.
- No new row is written, no audit event is emitted.

Idempotency keys expire after 24 hours.

---

## Audit Events

| Event                          | Severity | Trigger                                    |
|---|---|---|
| `REVIEW_QUEUE_ISSUE_CREATED`   | LOW      | New issue row written to review_issues     |
| `REVIEW_QUEUE_RUN_HELD`        | MEDIUM   | run_status transitions to REVIEW_HOLD      |

Both events include `run_id`, `business_id`, `issue_id`, and `severity` in the payload.

---

## Error Codes

| Code                     | HTTP | Meaning                                              |
|---|---|---|
| `RUN_NOT_FOUND`          | 404  | run_id does not exist                                |
| `UNKNOWN_ISSUE_TYPE`     | 400  | issue_type not in issue_type_registry                |
| `REFERENCE_NOT_FOUND`    | 404  | reference_id not found in reference_table            |
| `INVALID_SEVERITY`       | 400  | severity not in LOW / MEDIUM / HIGH / BLOCKING       |
| `ROUTING_NOT_FOUND`      | 500  | issue_type missing from routing table                |

---

## Cross-References

- `review_issues_schema.md` — full DDL for the review_issues table
- `issue_type_registry_schema.md` — issue type registry DDL and management
- `issue_escalation_policy.md` — escalation rule engine and trigger conditions
- `full_issue_type_to_group_routing_table.md` — complete issue_type → review_group map
- `mobile_write_rejection_endpoints.md` — mobile rejection policy and error format

## Mobile

All write operations in this tool are rejected on mobile clients. Mobile apps receive `HTTP 405 Method Not Allowed` with error code `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full endpoint rejection list.