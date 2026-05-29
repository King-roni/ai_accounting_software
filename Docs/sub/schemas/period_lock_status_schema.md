# Period Lock Status Schema

**Category:** Schemas · **Owning block:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 2)

Defines the `period_lock_status` table — the authoritative lookup for whether a business period has been finalized. This table is the single source of truth consulted by the finalization gate's "is this period already locked?" pre-condition check, by adjustment-run admission guards, and by any other component that must determine period finalization state without reading the archive bundle directly.

---

## 1. Table definition

```sql
CREATE TABLE period_lock_status (
  lock_id                     uuid PRIMARY KEY DEFAULT gen_uuid_v7(),

  -- Tenant and period scope
  business_id                 uuid NOT NULL,
  period_start                date NOT NULL,
  period_end                  date NOT NULL,

  -- Run linkage — which run produced this lock row
  workflow_run_id             uuid NOT NULL
                                REFERENCES workflow_runs(workflow_run_id),

  -- Lock timestamp
  locked_at                   timestamptz NOT NULL DEFAULT now(),

  -- Manifest version — 1 for original finalization; incremented for each
  -- adjustment run that re-finalizes this period
  manifest_version            integer NOT NULL
                                CHECK (manifest_version >= 1),

  -- Currency flag — false if this row has been superseded by a
  -- higher manifest_version row for the same (business_id, period_start, period_end)
  is_current                  boolean NOT NULL DEFAULT true,

  -- Object storage path for the archive bundle associated with this lock
  archive_bundle_storage_key  text NOT NULL,

  -- Immutability constraint: one row per (business, period, version)
  UNIQUE (business_id, period_start, period_end, manifest_version)
);

CREATE INDEX idx_period_lock_status_business_period
  ON period_lock_status(business_id, period_start, period_end);

CREATE INDEX idx_period_lock_status_current
  ON period_lock_status(business_id, period_start, period_end)
  WHERE is_current = true;

CREATE INDEX idx_period_lock_status_run
  ON period_lock_status(workflow_run_id);
```

---

## 2. Field reference

| Field | Type | Notes |
|---|---|---|
| `lock_id` | UUID v7 PK | Monotonically increasing per `data_layer_conventions_policy` |
| `business_id` | UUID | Tenant scope; RLS SELECT-visible to all business roles |
| `period_start` | date | Inclusive start of the finalized period |
| `period_end` | date | Inclusive end of the finalized period |
| `workflow_run_id` | UUID FK | The workflow run whose lock sequence produced this row |
| `locked_at` | timestamptz | Wall-clock time at which `archive.promote_manifest` wrote this row (Step 5 of the lock sequence) |
| `manifest_version` | integer | `1` for the original finalization; incremented by 1 for each subsequent adjustment-run re-finalization |
| `is_current` | boolean | `true` for the row with the highest `manifest_version` for a given `(business_id, period_start, period_end)`; `false` for all superseded rows |
| `archive_bundle_storage_key` | text | Path in the `archive-bundles` Object Lock bucket for the bundle produced by this lock |

---

## 3. Immutability rules

Once a `period_lock_status` row is inserted, no UPDATE is permitted on any column. This is enforced by the RLS policy in Section 5 and is a design invariant: the row is a historical record of what was locked at what time with which bundle.

**Adjustment run re-finalization** does not modify existing rows. Instead:
1. A new row is inserted with `manifest_version = (previous_max + 1)` and `is_current = true`.
2. The previous row's `is_current` flag is set to `false`.

The `is_current = false` update on the previous row is the only permitted UPDATE on this table, and it is narrow: only `is_current` may be set to `false`, never to `true`. The RLS adjustment-update policy gates this operation on the `app.adjustment_lock_active` session variable set by Block 15's finalization tools.

---

## 4. Query patterns

**"Is this period finalized?" check (used by finalization gate):**

```sql
SELECT EXISTS (
  SELECT 1
  FROM period_lock_status
  WHERE business_id = $1
    AND period_start = $2
    AND period_end   = $3
    AND is_current   = true
);
```

**Current lock row for a period (used by dashboard, accountant pack):**

```sql
SELECT *
FROM period_lock_status
WHERE business_id = $1
  AND period_start = $2
  AND period_end   = $3
  AND is_current   = true;
```

**Full version history for a period (used by adjustment-run admission guard):**

```sql
SELECT *
FROM period_lock_status
WHERE business_id = $1
  AND period_start = $2
  AND period_end   = $3
ORDER BY manifest_version DESC;
```

The partial index `idx_period_lock_status_current` (WHERE `is_current = true`) makes the first two patterns P95 < 5 ms regardless of how many adjustment versions exist for the period.

---

## 5. RLS policies

```sql
-- All business roles may SELECT; period lock status is visible to everyone
-- with a valid session on the business
CREATE POLICY period_lock_status_read_all_roles
  ON period_lock_status
  FOR SELECT
  USING (business_id = ANY (auth.business_ids_for_session()));

-- INSERT: only Block 15 finalization tools (app.original_lock_active or
-- app.adjustment_lock_active session variable must be set)
CREATE POLICY period_lock_status_insert_lock_sequence
  ON period_lock_status
  FOR INSERT
  WITH CHECK (
    current_setting('app.original_lock_active', true) = 'true'
    OR current_setting('app.adjustment_lock_active', true) = 'true'
  );

-- UPDATE: restricted to setting is_current = false during adjustment re-lock
CREATE POLICY period_lock_status_update_supersede
  ON period_lock_status
  FOR UPDATE
  USING (
    current_setting('app.adjustment_lock_active', true) = 'true'
  )
  WITH CHECK (
    is_current = false  -- may only set the flag to false, never back to true
  );

-- DELETE: blocked unconditionally
CREATE POLICY period_lock_status_no_delete
  ON period_lock_status
  FOR DELETE
  USING (false);
```

No application role may insert, update, or delete rows outside an active Block 15 lock sequence context. Any attempt outside that context is denied by RLS and generates an `ARCHIVE_TAMPER_DETECTED` alert via the statement-level audit trigger on the table.

---

## 6. Mobile rejection

Reads from `period_lock_status` are available to mobile clients (via the relevant API endpoints). Write operations — INSERT and the `is_current` UPDATE — are performed exclusively by Block 15 finalization tools, which are listed in `mobile_write_rejection_endpoints`. Mobile clients cannot initiate or interact with the lock sequence.

---

## 7. Audit events

| Event | Severity | When |
|---|---|---|
| `PERIOD_LOCKED` | LOW | Emitted by `archive.promote_manifest` (lock sequence Step 5) when a `period_lock_status` row is inserted. Payload includes `lock_id`, `business_id`, `period_start`, `period_end`, `manifest_version`, `workflow_run_id`, `archive_bundle_storage_key` |

`PERIOD_LOCKED` is emitted on the business-scoped hash chain. It is a domain `ARCHIVE` event per `audit_log_policies`. The event is LOW severity because the lock is expected and correct; an unexpected lock or tamper attempt would surface as `ARCHIVE_TAMPER_DETECTED` (HIGH).

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK generation; date column conventions; immutability contract
- `lock_sequence_policies` — the 5-step lock sequence that produces `period_lock_status` rows; Step 5 (`archive.promote_manifest`) as the INSERT site; session variables `app.original_lock_active` and `app.adjustment_lock_active`
- `archive_bundle_file_manifest` — `archive_bundle_storage_key` path format and bucket name (`archive-bundles`)
- `locked_ledger_entries_schema` — the `archive.locked_ledger_entries` table written in the same lock sequence; `manifest_version` alignment
- `audit_log_policies` — `PERIOD_LOCKED` event naming; `ARCHIVE` domain; business-scoped hash chain
- `audit_event_taxonomy` — `ARCHIVE` domain canonical events; `PERIOD_LOCKED` entry
- `mobile_write_rejection_endpoints` — Block 15 lock sequence tools listed as mobile-rejected
- `workflow_state_enum` — `FINALIZING → FINALIZED` transition that drives Step 5 INSERT; `AWAITING_APPROVAL` pre-condition
- Block 15 Phase 02 — finalization preconditions; "is period already locked?" gate check consuming this table
- Block 15 Phase 04 — `archive.promote_manifest` tool; lock sequence Step 5
- Block 15 Phase 06 — manifest versioning for adjustment runs; `manifest_version` increment logic
- Block 04 Phase 07 — Finalized Secure Archive zone; Object Lock bucket
