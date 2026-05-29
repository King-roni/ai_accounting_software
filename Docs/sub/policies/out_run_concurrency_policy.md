# out_run_concurrency_policy

**Category:** Policies · **Owning block:** 12 — OUT Workflow · **Stage:** 4 sub-doc (Layer 2)

Rules governing concurrent OUT workflow run execution. Every path that creates or advances an OUT workflow run must satisfy the invariants in this document. The invariants are checked by `engine.create_run` before any run row is written; conflicts produce structured errors, never silent failures.

---

## 1. Core invariant — one active OUT_MONTHLY run per period

At most one active (non-terminal) `OUT_MONTHLY` run may exist per `(business_id, period_start)`.

**Terminal states:** `FINALIZED`, `FAILED`, `CANCELLED`. A run in any of these states does not count toward the concurrency limit.

**Active states (non-terminal):** `CREATED`, `RUNNING`, `PAUSED`, `REVIEW_HOLD`, `AWAITING_APPROVAL`, `FINALIZING`, `COMPENSATING`. A run in any of these states blocks a new `OUT_MONTHLY` run for the same `(business_id, period_start)`.

---

## 2. Conflict check SQL predicate

`engine.create_run` executes the following predicate before writing a new `OUT_MONTHLY` run row. If this query returns one or more rows, run creation is blocked and `OUT_WORKFLOW_RUN_ALREADY_ACTIVE` is returned to the caller:

```sql
WHERE business_id = $1
  AND workflow_type = 'OUT_MONTHLY'
  AND period_start = $2
  AND status NOT IN ('FINALIZED', 'FAILED', 'CANCELLED')
```

This predicate is the authoritative conflict check. Application code must not implement alternative concurrency checks. The SQL uses the canonical `run_status_enum` values from `workflow_run_schema`; adding a new terminal state to the enum requires updating this predicate in lockstep.

The check runs inside a short transaction that holds a row-level advisory lock on `(business_id, 'OUT_MONTHLY', period_start)` via `pg_advisory_xact_lock` to prevent race conditions between concurrent creation attempts.

---

## 3. OUT_MONTHLY and IN_MONTHLY concurrent execution

`OUT_MONTHLY` and `IN_MONTHLY` runs for the same period run concurrently. They are not in conflict with each other. This is the paired-run design:

- Both runs are created atomically in the same transaction when a `STATEMENT_UPLOAD_COMPLETED` event fires (or when both are manually triggered for the same period).
- The two runs are linked via `workflow_runs.paired_run_id` (self-referential FK, `DEFERRABLE INITIALLY DEFERRED` to allow same-transaction insertion).
- The concurrency invariant for `IN_MONTHLY` is checked separately by `in_workflow.create_run` using an equivalent predicate scoped to `workflow_type = 'IN_MONTHLY'`.
- Block 16's `getCombinedRunProgress` query joins on `paired_run_id` to render a unified progress indicator for the paired runs.

The shared `INGESTION` and `CLASSIFICATION` phases are deduplicated via `tool_invocations.dedup_key` (Block 03 Phase 07): if the OUT run has already completed these phases for the period's upload, the IN run's execution of those phases short-circuits via `WORKFLOW_TOOL_DEDUP_HIT`.

---

## 4. OUT_ADJUSTMENT concurrency exception

`OUT_ADJUSTMENT` runs are exempt from the core invariant in Section 1. Specifically:

- An `OUT_ADJUSTMENT` run may be created for a period that already has a `FINALIZED` `OUT_MONTHLY` run (this is its normal use case).
- An `OUT_ADJUSTMENT` run may run concurrently with the **next** period's `OUT_MONTHLY` run (the Stage 1 adjustment-concurrency exception). Example: an adjustment for January 2026 may run while February 2026's `OUT_MONTHLY` run is active.
- The concurrency conflict check for `OUT_ADJUSTMENT` uses a different predicate scoped to `workflow_type = 'OUT_ADJUSTMENT'` and additionally verifies that a `FINALIZED` `OUT_MONTHLY` run exists for the targeted period.

`OUT_ADJUSTMENT` runs do not use `paired_run_id`; they use `parent_run_id` referencing the original `FINALIZED` `OUT_MONTHLY` run (or the most recent finalized adjustment for the same period).

---

## 5. Multi-period concurrency — permitted

Concurrent `OUT_MONTHLY` runs across **different** periods for the same business are explicitly permitted. Examples:

- January 2026 `OUT_MONTHLY` in state `AWAITING_APPROVAL` while February 2026 `OUT_MONTHLY` is in state `RUNNING`: permitted.
- Three periods running simultaneously: permitted, subject to resource constraints (not enforced by this policy).

The conflict check predicate in Section 2 is scoped to a single `period_start` value and does not consider other periods.

---

## 6. Conflict error semantics

When the Section 2 predicate detects a conflict, `engine.create_run` returns a structured error object:

```json
{
  "error_code": "OUT_WORKFLOW_RUN_ALREADY_ACTIVE",
  "conflicting_run_id": "<uuid>",
  "conflicting_run_status": "<status>",
  "business_id": "<uuid>",
  "period_start": "<date>"
}
```

No run row is written. No audit event is emitted for the failed creation attempt (the `ACCESS_DENIED` or `OUT_WORKFLOW_RUN_ALREADY_ACTIVE` error is surfaced to the caller; the caller is responsible for any user-facing messaging).

---

## 7. Run state and the concurrency invariant

The 10-value `run_status_enum` maps to the invariant as follows:

| Status | Counts toward concurrency limit? |
| --- | --- |
| `CREATED` | Yes — active |
| `RUNNING` | Yes — active |
| `PAUSED` | Yes — active |
| `REVIEW_HOLD` | Yes — active |
| `AWAITING_APPROVAL` | Yes — active |
| `FINALIZING` | Yes — active |
| `COMPENSATING` | Yes — active |
| `FINALIZED` | No — terminal |
| `FAILED` | No — terminal |
| `CANCELLED` | No — terminal |

A run in `COMPENSATING` still blocks new runs for the same period. Compensation is system-owned and must complete before the period is available for a new run. If compensation resolves to `FAILED`, the period becomes available for a new run.

---

## 8. UI aggregation of concurrent runs

Block 16's `getCombinedRunProgress` query is the canonical consumer of concurrent-run data for UI rendering. It:

1. Selects all `OUT_MONTHLY` runs for a business in non-terminal states.
2. Joins on `paired_run_id` to fetch the corresponding `IN_MONTHLY` run for each.
3. Returns a unified progress structure that the dashboard renders as a single period-progress indicator.

This query is read-only and does not enforce the concurrency invariant. Enforcement is solely at write time via `engine.create_run`.

---

## 9. Invariant monitoring

An integrity job (Block 03 Phase 09 or Block 05 Phase 10) runs a nightly check equivalent to:

```sql
SELECT business_id, period_start, COUNT(*) AS active_run_count
FROM workflow_runs
WHERE workflow_type = 'OUT_MONTHLY'
  AND status NOT IN ('FINALIZED', 'FAILED', 'CANCELLED')
GROUP BY business_id, period_start
HAVING COUNT(*) > 1;
```

Any row returned indicates a violated invariant. The check raises a `HIGH` severity security alert (`SECURITY_ALERT_RAISED`) and pages the on-call operator. Legitimate causes (a race that bypassed the advisory lock) must be resolved manually by identifying and cancelling the duplicate run.

---

## Cross-references

- `out_monthly_trigger_policy` — trigger rules that invoke `engine.create_run`; `OUT_WORKFLOW_RUN_ALREADY_ACTIVE` error handling
- `workflow_run_schema` — `paired_run_id`, `parent_run_id`, `workflow_type`, `status` columns; `run_status_enum` definition
- `workflow_state_enum` — canonical 10-value state set; terminal state definition; `COMPENSATING` semantics
- `in_monthly_trigger_policy` — IN-side concurrency invariant (parallel structure)
- `audit_event_taxonomy` — `WORKFLOW_TOOL_DEDUP_HIT`; `IN_WORKFLOW_RUN_PAIR_LINKED`
- Block 03 Phase 07 — resumability; `tool_invocations.dedup_key` for shared-phase deduplication
- Block 03 Phase 09 — trigger engine; `trigger_events_processed`
- Block 03 Phase 10 — per-business concurrency lock; advisory lock mechanism
- Block 12 Phase 04 — OUT/IN parallel coordination; dedup contract for shared phases
- Block 12 Phase 09 — `OUT_ADJUSTMENT` workflow type; parent-run linkage
- `decisions_log.md` — Stage 1 adjustment-concurrency exception; paired-run design
