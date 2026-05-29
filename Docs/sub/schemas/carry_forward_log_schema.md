# carry_forward_log_schema

**Category:** Schemas · **Owning block:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 2 schema)

DDL for the `carry_forward_log` table. Each row records a single transfer of a review issue from one workflow run to the next at period close or on abort. The table reconstructs the full carry-forward chain for any review issue.

---

## Table definition

```sql
CREATE TABLE carry_forward_log (
  id                              uuid        PRIMARY KEY DEFAULT gen_uuid_v7(),

  review_issue_id                 uuid        NOT NULL REFERENCES review_issues(id),
  source_run_id                   uuid        NOT NULL REFERENCES workflow_runs(workflow_run_id),
  target_run_id                   uuid        NOT NULL REFERENCES workflow_runs(workflow_run_id),

  carried_at                      timestamptz NOT NULL DEFAULT now(),

  -- Snapshot of the carry_forward_count on the review_issues row at the moment of transfer.
  -- Stored here so escalation history is preserved even if the source row is later updated.
  carry_forward_count_at_time     integer     NOT NULL,

  -- Snapshot of severity at transfer time, used by issue_escalation_policy to determine
  -- whether severity should be promoted on the target run.
  severity_at_carry_forward       text        NOT NULL
    CHECK (severity_at_carry_forward IN ('LOW', 'MEDIUM', 'HIGH', 'BLOCKING')),

  -- Audit trail of which process performed the carry-forward.
  -- DEFAULT covers the normal path; override allowed for compensation-triggered carry-forward.
  carried_by_process              text        NOT NULL DEFAULT 'review_queue.carry_forward_issues',

  business_id                     uuid        NOT NULL REFERENCES business_entities(id),

  -- Each issue is carried forward at most once per source run.
  CONSTRAINT uq_carry_forward_per_source_run
    UNIQUE (review_issue_id, source_run_id)
);
```

---

## Column rationale

### `id`

UUID v7 primary key via `gen_uuid_v7()`. Time-ordered for efficient range queries on carry-forward history. Session-scoped IDs (OAuth state, step-up tokens, etc.) use `gen_random_uuid()` instead; this table does not fall in that category.

### `review_issue_id`

FK to `review_issues(id)`. A single review issue may accumulate multiple carry_forward_log rows over its lifetime — one per period boundary it crosses. Joining on `review_issue_id` ordered by `carried_at` reconstructs the full carry-forward chain.

### `source_run_id` / `target_run_id`

Both reference `workflow_runs(workflow_run_id)`. `source_run_id` is the run being closed or aborted; `target_run_id` is the run the issue is being transferred into.

`source_run_id` and `target_run_id` may reference runs with `workflow_type` in `{OUT_MONTHLY, OUT_ADJUSTMENT, IN_MONTHLY, IN_ADJUSTMENT}`. Carry-forward does not cross workflow type boundaries; an OUT issue is carried forward to another OUT run and an IN issue to another IN run.

### `carry_forward_count_at_time`

Snapshot of `review_issues.carry_forward_count` at the moment of transfer. This value is what the escalation policy reads when determining whether to promote severity — it reads the log snapshot, not the live row, to ensure deterministic escalation history even if the source row is modified.

### `severity_at_carry_forward`

Snapshot of the issue's severity at transfer time. The escalation policy (`issue_escalation_policy.md`) uses this to decide whether severity should be promoted in the target run. For example, if an issue is `MEDIUM` at carry-forward and the `carry_forward_count_at_time` crosses the escalation threshold, the policy upgrades it to `HIGH` in the target run.

The snapshot is taken immediately before the carry-forward action executes, so it reflects the severity the accountant saw in the source run.

### `carried_by_process`

Records which process executed the carry-forward. The default value covers the normal path via `review_queue.carry_forward_issues`. Overrides are recorded when carry-forward is triggered as part of an abort sequence (see `out_run_abort_policy.md` and `in_run_abort_policy.md`).

This column is not a FK to a process registry; it is a free-text audit string. Valid values are tool names in `<namespace>.<action>` format per `tool_naming_convention_policy.md`.

### `business_id`

FK to `business_entities(id)`. Denormalized for efficient RLS evaluation and for direct queries scoped to a business without joining through `review_issues` or `workflow_runs`. Must match the `business_id` on both the source and target run.

---

## Uniqueness constraint

```sql
CONSTRAINT uq_carry_forward_per_source_run UNIQUE (review_issue_id, source_run_id)
```

Each review issue is carried forward at most once per source run. This prevents double-carrying (e.g., if `review_queue.carry_forward_issues` is called twice for the same source run). The constraint is idempotency enforcement at the database level.

---

## Indexes

```sql
CREATE INDEX idx_carry_forward_log_review_issue
  ON carry_forward_log(review_issue_id);

CREATE INDEX idx_carry_forward_log_source_run
  ON carry_forward_log(source_run_id);

CREATE INDEX idx_carry_forward_log_target_run
  ON carry_forward_log(target_run_id);

CREATE INDEX idx_carry_forward_log_business
  ON carry_forward_log(business_id, carried_at DESC);
```

The `business_id` index with descending `carried_at` supports the Block 14 carry-forward history panel, which displays recent transfers for a business ordered by recency.

---

## Append-only enforcement

This table is append-only. No UPDATE or DELETE operations are permitted. Enforcement is at two levels:

1. RLS policy `audit_append_only` — the same policy applied to `audit_log` entries — rejects any UPDATE or DELETE via the application role.
2. Application-layer: `review_queue.carry_forward_issues` only executes INSERTs; there is no update path in the tool.

If a carry-forward was recorded in error, the correction is a compensating INSERT in the target run's review queue — the erroneous log row is never deleted.

---

## Reconstructing the carry-forward chain

To reconstruct the full carry-forward history for a review issue, join `carry_forward_log` on `review_issue_id` ordered by `carried_at`:

```sql
SELECT
  cfl.source_run_id,
  cfl.target_run_id,
  cfl.carried_at,
  cfl.carry_forward_count_at_time,
  cfl.severity_at_carry_forward,
  cfl.carried_by_process
FROM carry_forward_log cfl
WHERE cfl.review_issue_id = $1
  AND cfl.business_id = $2
ORDER BY cfl.carried_at ASC;
```

Each row is one hop. The chain is linear: `source_run_id` of row N should equal the run that contains the issue after row N-1's `target_run_id`.

---

## Audit events

`REVIEW_QUEUE_ISSUE_CARRIED_FORWARD` (LOW) is emitted by `review_queue.carry_forward_issues`, not by a database INSERT trigger. The tool emits the event after confirming the INSERT succeeded. Payload includes: `carry_forward_log_id`, `review_issue_id`, `source_run_id`, `target_run_id`, `business_id`, `carry_forward_count_at_time`, `severity_at_carry_forward`.

---

## Cross-references

- `snooze_carry_forward_schema.md` — sibling table for snooze-specific carry-forward metadata
- `snooze_carry_forward_policy.md` — policy governing when issues are carried forward (including at FINALIZING entry and on abort)
- `review_issue_history_schema.md` — per-issue history log (complements carry_forward_log)
- `issue_escalation_policy.md` — uses `carry_forward_count_at_time` and `severity_at_carry_forward` to determine escalation
- `audit_log_policies.md` — audit event naming convention and append-only enforcement
