# finalization_lock_schema

**Category:** Schemas — Block 15: Finalization & Secure Archive
**Table:** `finalization_locks`

---

## Purpose

`finalization_locks` is the distributed lock table that gates the finalization execution
window. Only one `HELD` lock may exist per `(business_id, period_year, period_month,
workflow_type)` tuple at any time. The lock is acquired at the start of `engine.finalize`
and released on completion or failure. This table is engine-internal and is not exposed
via any user-facing API.

---

## DDL

```sql
CREATE TABLE finalization_locks (
    id                    uuid            NOT NULL DEFAULT gen_uuid_v7()   PRIMARY KEY,
    business_id           uuid            NOT NULL REFERENCES business_entities(id),
    workflow_run_id       uuid            NOT NULL REFERENCES workflow_runs(id),
    period_year           integer         NOT NULL,
    period_month          integer         NOT NULL CHECK (period_month BETWEEN 1 AND 12),
    workflow_type         text            NOT NULL,
    acquired_at           timestamptz     NOT NULL DEFAULT now(),
    expires_at            timestamptz     NOT NULL
        GENERATED ALWAYS AS (acquired_at + INTERVAL '30 minutes') STORED,
    last_renewed_at       timestamptz     NULL,
    renewal_count         integer         NOT NULL DEFAULT 0,
    released_at           timestamptz     NULL,
    status                finalization_lock_status NOT NULL DEFAULT 'HELD',
    acquired_by_process   text            NOT NULL DEFAULT 'engine.finalize',
    stale_detected_at     timestamptz     NULL,
    created_at            timestamptz     NOT NULL DEFAULT now()
);

CREATE TYPE finalization_lock_status AS ENUM (
    'HELD',
    'RELEASED',
    'STALE',
    'CONFLICT'
);
```

`expires_at` is stored as a generated column derived from `acquired_at`. It is
read by the stale-detection background job and by the `engine.finalize` precondition
check.

---

## Uniqueness Constraint

```sql
CREATE UNIQUE INDEX finalization_locks_active_lock_uidx
    ON finalization_locks (business_id, period_year, period_month, workflow_type)
    WHERE status = 'HELD';
```

This partial unique index ensures that only one `HELD` lock exists per
business-period-type combination at any point in time. Attempting to acquire a second
lock while one is `HELD` will violate this constraint and return a `409
FINALIZATION_LOCK_HELD` error from `engine.finalize`.

---

## Indexes

```sql
CREATE INDEX finalization_locks_business_id_idx      ON finalization_locks (business_id);
CREATE INDEX finalization_locks_workflow_run_id_idx  ON finalization_locks (workflow_run_id);
CREATE INDEX finalization_locks_status_idx           ON finalization_locks (status);
CREATE INDEX finalization_locks_expires_at_idx       ON finalization_locks (expires_at)
    WHERE status = 'HELD';
```

The `expires_at` partial index is used exclusively by the stale-detection job for
efficient scanning of overdue locks.

---

## Status Transitions

This table is NOT append-only. Status transitions are performed via `UPDATE`. Unlike
`audit_log`, the lock row is mutated in place because it represents a live resource
state, not an immutable event record.

| From       | To         | Trigger                                               |
|---|---|---|
| `HELD`     | `RELEASED` | `engine.finalize` completes (success or failure)      |
| `HELD`     | `STALE`    | Background job detects `expires_at < now()`           |
| `HELD`     | `CONFLICT` | Manual override by operations team (runbook only)     |
| `STALE`    | `RELEASED` | Stale recovery procedure in finalization_lock_policy  |

There is no transition back to `HELD` from any other status. Stale or conflict locks
are archived in place; a new lock row is inserted for the retry.

---

## Stale Detection

A background job runs every 60 seconds and executes:

```sql
UPDATE finalization_locks
SET    status = 'STALE',
       stale_detected_at = now()
WHERE  status = 'HELD'
  AND  expires_at < now();
```

When a stale lock is detected, `ENGINE_FINALIZATION_LOCK_STALE_DETECTED` (HIGH) is
written to `audit_log`. Operations must investigate whether the finalization process
crashed mid-sequence before clearing the lock and scheduling a retry. See
`finalization_lock_policy.md` for recovery procedures.

---

## Lock Renewal

`engine.finalize` may renew the lock if the finalization sequence is running longer
than expected (e.g., a large archive bundle upload). Renewal increments `renewal_count`
and sets `last_renewed_at = now()`. `expires_at` is recomputed on renewal by updating
`acquired_at` to the renewal time.

Maximum renewal count: 5. After 5 renewals, the lock cannot be renewed and the
finalization process must complete or fail within the remaining window.

---

## RLS Policy

```sql
-- Engine-internal table: no user-facing RLS policies.
-- Access is restricted to service_role only.
ALTER TABLE finalization_locks ENABLE ROW LEVEL SECURITY;
-- No permissive policies are created for authenticated or anon roles.
```

No `authenticated` or `anon` role policies exist. This table is never queried by
client-side code.

---

## Retention

Lock rows are retained indefinitely for audit trail purposes. The `status` and
`stale_detected_at` columns provide the historical record of any anomalous lock
events. Rows are not deleted by any TTL job.

---

## Audit Events

| Event                                      | Severity | Trigger                                    |
|---|---|---|
| `ENGINE_FINALIZATION_LOCK_ACQUIRED`        | LOW      | New HELD lock row inserted                 |
| `ENGINE_FINALIZATION_LOCK_RELEASED`        | LOW      | status transitions to RELEASED             |
| `ENGINE_FINALIZATION_LOCK_STALE_DETECTED`  | HIGH     | Background job sets status to STALE        |

All events include `business_id`, `workflow_run_id`, `period_year`, `period_month`,
and `workflow_type` in the audit payload.

---

## Cross-References

- `finalization_lock_policy.md` — acquisition, renewal, stale recovery, conflict resolution
- `period_lock_schema.md` — DDL for the period_locks table (written atomically with archive.promote)
- `workflow_run_schema.md` — run_status enum and workflow_runs DDL
