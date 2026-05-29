# vendor_memory_conflicts schema

**Category:** Schemas · **Owning block:** 08 — Transaction Classification · **Stage:** 4 sub-doc (Layer 2)

Records cases where two `vendor_memory` entries for the same counterparty within a business disagree on a classification field. Conflict detection is triggered by `vendor_memory_staleness_policy.md` when a new vendor memory write would produce a value inconsistent with an existing entry for the same counterparty. Conflicts must be resolved (manually or automatically) before the classification pipeline can use vendor memory for the affected counterparty.

---

## Table: `vendor_memory_conflicts`

```sql
CREATE TYPE vendor_memory_conflict_type AS ENUM (
  'TAG_MISMATCH',
  'VAT_RATE_MISMATCH',
  'ACCOUNT_CODE_MISMATCH'
);

CREATE TYPE vendor_memory_conflict_resolution_status AS ENUM (
  'UNRESOLVED',
  'RESOLVED_MANUAL',
  'RESOLVED_AUTO'
);

CREATE TABLE vendor_memory_conflicts (
  id                      uuid          NOT NULL DEFAULT gen_uuid_v7()
                                        PRIMARY KEY,
  business_id             uuid          NOT NULL
                                        REFERENCES business_entities(id),
  counterparty_id         uuid          NOT NULL
                                        REFERENCES counterparties(id),
  conflict_type           vendor_memory_conflict_type NOT NULL,

  -- The two conflicting vendor memory entries
  entry_a_id              uuid          NOT NULL REFERENCES vendor_memory(id),
  entry_b_id              uuid          NOT NULL REFERENCES vendor_memory(id),

  -- The conflicting values at the time of detection
  entry_a_value           text          NOT NULL,
  entry_b_value           text          NOT NULL,

  -- Which field is in conflict (e.g. 'tag', 'vat_rate', 'account_code')
  conflict_field          text          NOT NULL,

  -- Detection metadata
  detected_at             timestamptz   NOT NULL DEFAULT now(),

  -- Resolution
  resolution_status       vendor_memory_conflict_resolution_status
                                        NOT NULL DEFAULT 'UNRESOLVED',
  resolved_at             timestamptz   NULL,
  resolved_by_user_id     uuid          NULL REFERENCES users(id),
  resolution_note         text          NULL,

  -- Workflow context in which the conflict was detected
  workflow_run_id         uuid          NULL REFERENCES workflow_runs(id),

  -- Audit timestamps
  created_at              timestamptz   NOT NULL DEFAULT now(),
  updated_at              timestamptz   NOT NULL DEFAULT now()
);
```

---

## Column reference

| Column | Type | Nullable | Description |
| --- | --- | --- | --- |
| `id` | uuid | NOT NULL | UUID v7 primary key. |
| `business_id` | uuid | NOT NULL | FK to `business_entities.id`. Tenant isolation key. |
| `counterparty_id` | uuid | NOT NULL | FK to `counterparties.id`. The counterparty whose vendor memory entries conflict. |
| `conflict_type` | enum | NOT NULL | `TAG_MISMATCH` — two entries propose different primary tags. `VAT_RATE_MISMATCH` — two entries propose different VAT rates. `ACCOUNT_CODE_MISMATCH` — two entries propose different chart-of-accounts codes. |
| `entry_a_id` | uuid | NOT NULL | FK to `vendor_memory.id`. The first conflicting entry (the older of the two, by convention). |
| `entry_b_id` | uuid | NOT NULL | FK to `vendor_memory.id`. The second conflicting entry (the newer write that triggered detection). |
| `entry_a_value` | text | NOT NULL | The field value from `entry_a` at the time of detection. Snapshot copy — not a live FK to the field. |
| `entry_b_value` | text | NOT NULL | The field value from `entry_b` at the time of detection. Snapshot copy. |
| `conflict_field` | text | NOT NULL | The name of the field in conflict: `'tag'`, `'vat_rate'`, or `'account_code'`. Used for display and routing. |
| `detected_at` | timestamptz | NOT NULL | When the conflict was first detected. |
| `resolution_status` | enum | NOT NULL | `UNRESOLVED` — conflict is active and blocks vendor memory use for this counterparty. `RESOLVED_MANUAL` — an operator chose which entry to retain. `RESOLVED_AUTO` — the staleness policy or a rule resolved the conflict automatically. |
| `resolved_at` | timestamptz | NULL | When the conflict was resolved. Null while unresolved. |
| `resolved_by_user_id` | uuid | NULL | FK to `users.id`. The user who resolved the conflict (manual path only). Null for auto-resolved or unresolved rows. |
| `resolution_note` | text | NULL | Optional free-text note explaining the resolution decision (max 500 chars recommended). |
| `workflow_run_id` | uuid | NULL | FK to `workflow_runs.id`. The run during which the conflict was detected, if applicable. Null when detected by a background job outside a run context. |
| `created_at` | timestamptz | NOT NULL | Row creation timestamp. |
| `updated_at` | timestamptz | NOT NULL | Last update timestamp. Maintained by trigger. |

---

## Indexes

```sql
-- Tenant isolation + conflict lookup by business
CREATE INDEX vendor_memory_conflicts_business_id_idx
  ON vendor_memory_conflicts (business_id);

-- Counterparty conflict lookup (most common access pattern)
CREATE INDEX vendor_memory_conflicts_counterparty_idx
  ON vendor_memory_conflicts (business_id, counterparty_id);

-- Filter by conflict type
CREATE INDEX vendor_memory_conflicts_conflict_type_idx
  ON vendor_memory_conflicts (business_id, conflict_type);

-- Open conflicts queue
CREATE INDEX vendor_memory_conflicts_unresolved_idx
  ON vendor_memory_conflicts (business_id, resolution_status)
  WHERE resolution_status = 'UNRESOLVED';
```

---

## Row-level security

```sql
ALTER TABLE vendor_memory_conflicts ENABLE ROW LEVEL SECURITY;

CREATE POLICY vendor_memory_conflicts_tenant_isolation
  ON vendor_memory_conflicts
  USING (business_id = current_setting('app.current_business_id')::uuid);
```

RLS is enforced on `business_id`. Platform admin role bypasses RLS per `rls_helper_functions.md`.

---

## Conflict detection

Conflict detection is triggered by `classification.write_vendor_memory` when it attempts to write a new classification for a counterparty that already has an active (non-stale, non-pruned) vendor memory entry with a different value for the same field. The detection flow:

1. `classification.write_vendor_memory` queries `vendor_memory` for the counterparty.
2. If an existing entry is found with a differing `tag`, `vat_rate`, or `account_code`, a `vendor_memory_conflicts` row is inserted with `resolution_status = UNRESOLVED`.
3. The new write is staged but not committed to `vendor_memory` until the conflict is resolved.
4. A `REVIEW_HOLD` review issue of type `VENDOR_MEMORY_CONFLICT` is raised for the business.
5. `CLASSIFICATION_VENDOR_CONFLICT_DETECTED` is emitted.

Conflict detection is also run by the monthly background staleness sweep in `vendor_memory_staleness_policy.md` as a cross-entry consistency check. The sweep may detect conflicts that were missed at write-time (e.g., due to concurrent writes in separate workflow runs).

---

## Resolution paths

### Manual resolution

An Owner, Admin, or Bookkeeper reviews the two conflicting entries in the review queue and selects the authoritative value. The resolution writes:
- `resolution_status = 'RESOLVED_MANUAL'`
- `resolved_at = now()`
- `resolved_by_user_id = $actor_user_id`
- `resolution_note` (optional)

The losing entry in `vendor_memory` is either deactivated or updated to match the winning value, depending on the `tag_conflict_resolution_policy.md` rule for the conflict type.

### Automatic resolution

The staleness background job may auto-resolve a conflict when one entry has been marked stale (i.e., `is_stale = true`) and the other remains active. In that case:
- The stale entry is treated as the losing entry.
- `resolution_status = 'RESOLVED_AUTO'`
- `resolved_by_user_id` remains null.

---

## Audit events

| Event | Severity | When |
| --- | --- | --- |
| `CLASSIFICATION_VENDOR_CONFLICT_DETECTED` | MEDIUM | A new `vendor_memory_conflicts` row is inserted with `resolution_status = UNRESOLVED` |
| `CLASSIFICATION_VENDOR_CONFLICT_RESOLVED` | LOW | `resolution_status` transitions to `RESOLVED_MANUAL` or `RESOLVED_AUTO` |

`CLASSIFICATION_VENDOR_CONFLICT_DETECTED` payload: `conflict_id`, `business_id`, `counterparty_id`, `conflict_type`, `conflict_field`, `entry_a_id`, `entry_b_id`, `entry_a_value`, `entry_b_value`, `workflow_run_id`.

`CLASSIFICATION_VENDOR_CONFLICT_RESOLVED` payload: `conflict_id`, `business_id`, `counterparty_id`, `conflict_type`, `resolution_status`, `resolved_by_user_id` (null for auto), `resolved_at`.

---

## Cross-references

- `vendor_memory_schema.md` — the `vendor_memory` table whose entries this table tracks conflicts between
- `vendor_memory_staleness_policy.md` — staleness sweep that triggers and auto-resolves conflicts
- `tag_conflict_resolution_policy.md` — rules governing which entry wins in a TAG_MISMATCH conflict
- `counterparty_resolution_policy.md` — counterparty identity resolution used upstream of vendor memory writes
- `audit_event_taxonomy.md` — `CLASSIFICATION_VENDOR_CONFLICT_DETECTED`, `CLASSIFICATION_VENDOR_CONFLICT_RESOLVED`
- `rls_helper_functions.md` — standard RLS helper patterns
