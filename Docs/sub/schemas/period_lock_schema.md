# Period Lock Schema

**Category:** Schemas · Block 15 — Finalization & Secure Archive  
**Owner:** archive  
**Last updated:** 2026-05-16

---

## 1. Purpose

DDL and field reference for the `period_locks` table. This table records the permanent post-finalization lock on an accounting period. Each row represents an immutable, tamper-evident record that a given period has been finalized and is protected from mutation. See `period_lock_policy.md` for enforcement rules.

---

## 2. DDL

```sql
CREATE TYPE workflow_type_enum AS ENUM ('OUT', 'IN');

CREATE TABLE period_locks (
  id                  uuid          NOT NULL DEFAULT gen_uuid_v7(),
  business_id         uuid          NOT NULL REFERENCES business_entities(id),
  workflow_run_id     uuid          NOT NULL REFERENCES workflow_runs(id),
  period_year         integer       NOT NULL,
  period_month        integer       NOT NULL CHECK (period_month BETWEEN 1 AND 12),
  workflow_type       workflow_type_enum NOT NULL,
  locked_at           timestamptz   NOT NULL DEFAULT now(),
  locked_by_process   text          NOT NULL DEFAULT 'engine.finalize',
  archive_bundle_id   uuid          NULL REFERENCES archive_bundles(id),
  lock_hash           text          NOT NULL,

  CONSTRAINT period_locks_pkey PRIMARY KEY (id),

  CONSTRAINT uq_period_locks_business_period_type
    UNIQUE (business_id, period_year, period_month, workflow_type)
);
```

---

## 3. Column Reference

### `id` — `uuid NOT NULL DEFAULT gen_uuid_v7()`

Surrogate primary key. Uses `gen_uuid_v7()` (time-ordered UUID v7). This is a non-secret surrogate key used for joins and references — time-ordering is desirable for efficient B-tree indexing and chronological range queries. Compare with `step_up_tokens.id` which uses `gen_random_uuid()` because it is a bearer credential.

### `business_id` — `uuid NOT NULL REFERENCES business_entities(id)`

The business entity whose period is locked. Foreign key references `business_entities(id)`. Never references `businesses(id)`.

### `workflow_run_id` — `uuid NOT NULL REFERENCES workflow_runs(id)`

The specific workflow run that triggered the lock. Together with `business_id`, this provides a complete audit trail linking the lock to the exact finalization event.

### `period_year` — `integer NOT NULL`

The calendar year of the locked period (e.g., `2025`). Combined with `period_month` and `workflow_type`, this identifies the period uniquely per business.

### `period_month` — `integer NOT NULL CHECK (period_month BETWEEN 1 AND 12)`

The calendar month (1–12). A CHECK constraint enforces valid month values. January = 1, December = 12.

### `workflow_type` — `workflow_type_enum NOT NULL`

Whether this lock is for an outgoing (`OUT`) or incoming (`IN`) workflow run. A business may have separate OUT and IN locks for the same calendar period; the unique constraint covers `(business_id, period_year, period_month, workflow_type)`, so both can coexist.

### `locked_at` — `timestamptz NOT NULL DEFAULT now()`

Timestamp when the lock was written. This is set by the database server clock at the time of INSERT, not by the application. It is included in the `lock_hash` computation to make the hash temporally specific.

### `locked_by_process` — `text NOT NULL DEFAULT 'engine.finalize'`

Identifies the process that created the lock. Default is `'engine.finalize'` for standard finalization runs. May be set to a different value for system migrations or bulk-finalization scripts, providing traceability for non-standard lock creation paths. Free-form text; maximum 255 characters enforced at application layer.

### `archive_bundle_id` — `uuid NULL REFERENCES archive_bundles(id)`

Set after the archive promotion step completes — the archive bundle containing the finalized period's accountant pack, signed PDF, and hash chain tip. Initially `NULL` at lock creation time; updated by `archive.promote_bundle` after bundle construction.

Note: although this is an UPDATE to a `period_locks` row, the `archive_bundle_id` column is the sole permitted mutable field in `period_locks`. The RLS policy permits UPDATE of `archive_bundle_id` only when the current value is `NULL` and the actor is `service_role`. All other UPDATE attempts are blocked.

### `lock_hash` — `text NOT NULL`

A tamper-evident hash of the lock record itself, computed as:

```
lock_hash = SHA-256(
  business_id::text
  || workflow_run_id::text
  || period_year::text
  || period_month::text
  || locked_at::text
)
```

This hash allows verification that the lock record has not been modified since creation. It is computed by the application before INSERT and stored alongside the lock. Verification is performed by `archive.verify_hash_chain` and during archive bundle construction.

---

## 4. Unique Constraint

```sql
CONSTRAINT uq_period_locks_business_period_type
  UNIQUE (business_id, period_year, period_month, workflow_type)
```

Exactly one lock per `(business_id, period_year, period_month, workflow_type)`. This constraint is the database-level guarantee that a period can only be finalized once. Any second attempt to finalize the same period will fail with a unique constraint violation before reaching the application layer.

---

## 5. Indexes

```sql
CREATE INDEX idx_period_locks_business_id
  ON period_locks (business_id);

CREATE INDEX idx_period_locks_workflow_run_id
  ON period_locks (workflow_run_id);

CREATE INDEX idx_period_locks_year_month
  ON period_locks (period_year, period_month);
```

---

## 6. Append-Only Enforcement

The `period_locks` table is INSERT-only for all columns except `archive_bundle_id`. RLS policies:

```sql
-- Allow INSERT for service_role only
CREATE POLICY period_locks_insert
  ON period_locks FOR INSERT
  TO service_role
  WITH CHECK (true);

-- Allow UPDATE of archive_bundle_id only, and only when currently NULL
CREATE POLICY period_locks_update_bundle_id
  ON period_locks FOR UPDATE
  TO service_role
  USING (archive_bundle_id IS NULL)
  WITH CHECK (true);

-- No DELETE
-- No SELECT restriction (all authenticated roles may read)
```

No `authenticated` role (user-facing JWT) may INSERT or UPDATE `period_locks` directly. All writes go through `engine.finalize_run` and `archive.promote_bundle` which use `service_role` connections.

---

## 7. Data Zone and Retention

This table is in the **Operational data zone**. Retention: 7 years from `locked_at`, in compliance with Cyprus VAT and accounting record-keeping requirements.

There is no `deleted_at` or soft-delete column. Period lock records are permanent and may not be deleted.

---

## 8. Cross-References

- `period_lock_policy.md`
- `finalization_lock_schema.md`
- `archive_bundle_construction_schema.md`
- `workflow_run_schema.md`
- `audit_event_taxonomy.md`
