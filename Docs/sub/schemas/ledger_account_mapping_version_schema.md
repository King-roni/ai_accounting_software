# Schema: ledger_account_mapping_versions

**Category:** Schemas · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

Defines the versioned chart-of-accounts mapping table, version freeze semantics, version-pin resolution for ledger entries, and the migration guard that prevents uncontrolled mapping changes from affecting unfinalized ledger data.

---

## Block reference

Block 11 — Ledger & Cyprus VAT. The `ledger.prepare_entries` tool reads the active mapping version to resolve transaction categories to account codes. The `archive.lock_period` step freezes the mapping version at finalization time.

---

## Purpose

A business's chart-of-accounts category-to-account-code mapping may change over time (account restructuring, regulatory updates, reclassifications). Ledger entries must always be readable against the mapping version that was active when they were prepared, regardless of subsequent changes. This table provides the versioning infrastructure that makes that guarantee.

---

## Table DDL

```sql
CREATE TABLE ledger_account_mapping_versions (
  id                  UUID        NOT NULL DEFAULT gen_uuid_v7(),
  business_id         UUID        NOT NULL REFERENCES business_entities(id),
  version             INTEGER     NOT NULL,
  mapping_config      JSONB       NOT NULL,
  effective_from      DATE        NOT NULL,
  effective_to        DATE        NULL,
  frozen_at           TIMESTAMPTZ NULL,
  created_by_user_id  UUID        NOT NULL REFERENCES users(id),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ledger_account_mapping_versions_pkey PRIMARY KEY (id),
  CONSTRAINT ledger_account_mapping_versions_business_version_unique
    UNIQUE (business_id, version),
  CONSTRAINT ledger_account_mapping_versions_effective_check
    CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE INDEX ledger_account_mapping_versions_business_current
  ON ledger_account_mapping_versions (business_id, effective_from DESC)
  WHERE effective_to IS NULL;
```

All UUIDs are UUID v7 (`gen_uuid_v7()`) per `data_layer_conventions_policy`. The `(business_id, version)` unique constraint ensures version integers are unambiguous within a business. At most one row per business may have `effective_to = NULL` (the current version); this invariant is enforced by the application layer on every version insert.

---

## Column reference

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| `id` | UUID | NOT NULL | `gen_uuid_v7()` | Primary key. UUID v7. |
| `business_id` | UUID | NOT NULL | — | FK to `business_entities.id`. Tenant isolation. |
| `version` | integer | NOT NULL | — | Monotonically increasing per business. Version 1 is the first mapping. Auto-incremented by the application layer: `version = MAX(version) + 1` for the business at insert time, inside a transaction. |
| `mapping_config` | JSONB | NOT NULL | — | Maps transaction category codes to chart-of-accounts account codes. Structure: `{ "<category_code>": { "debit_account": "<code>", "credit_account": "<code>", "description": "<text>" }, ... }`. All categories present in the system's category enum must have entries; any missing category is an application error. |
| `effective_from` | date | NOT NULL | — | The first date on which this mapping version applies. Inclusive. |
| `effective_to` | date | NULL | `NULL` | The last date on which this mapping version applies. Inclusive. NULL means this is the current version. |
| `frozen_at` | timestamptz | NULL | `NULL` | Set when the mapping version is frozen (see freeze semantics). Non-null means no further changes are permitted to ledger entries pinned to this version. |
| `created_by_user_id` | UUID | NOT NULL | — | FK to `users.id`. The user who created this version. |
| `created_at` | timestamptz | NOT NULL | `now()` | Row creation timestamp. |

---

## Version freeze semantics

A mapping version is frozen when a period that used it is finalized.

**Freeze trigger:** when `archive.lock_period` runs for a period, it identifies the mapping version active on the last day of the period (i.e., the version where `effective_from <= period_end` and `effective_to IS NULL OR effective_to >= period_end`). That version's `frozen_at` is set to the current timestamp.

**Frozen version behaviour:**

- `frozen_at IS NOT NULL` on a mapping version means the version is immutable for the finalized period's purpose.
- The platform refuses to delete or modify a frozen mapping version row.
- A new mapping version may still be created for future periods. The frozen version's `effective_to` is set to the finalization date when the new version is activated.
- Retroactive changes to account codes for categories in a frozen version do not affect finalized periods. The ledger entries for those periods remain pinned to the frozen version.

`LEDGER_MAPPING_VERSION_FROZEN` is emitted when `frozen_at` is set.

---

## Version-pin resolution

Every `ledger_entries` row carries a `mapping_version_id` FK that references the `ledger_account_mapping_versions` row active at the time the entry was prepared.

**Read rule:** when reading a ledger entry, always join to `ledger_entries.mapping_version_id`, not to the current active version for the business.

```sql
-- Correct: join to the pinned version
SELECT le.*, lamv.mapping_config
FROM ledger_entries le
JOIN ledger_account_mapping_versions lamv
  ON lamv.id = le.mapping_version_id
WHERE le.id = $entry_id;

-- Incorrect: join to the current version (never do this)
SELECT le.*, lamv.mapping_config
FROM ledger_entries le
JOIN ledger_account_mapping_versions lamv
  ON lamv.business_id = le.business_id
  AND lamv.effective_to IS NULL
WHERE le.id = $entry_id;
```

The incorrect join produces wrong account codes for entries prepared under a prior version. The correct join is enforced by the `ledger_entry_schema.md` read helpers and validated in the test suite.

---

## Migration guard

If a new mapping version is created that changes the `debit_account` or `credit_account` for any category that currently has unfinalized ledger entries in the system (i.e., `ledger_entries` rows with `is_locked = false` referencing the current mapping version), the system enters `REVIEW_HOLD` before the new version goes live.

**Procedure:**

1. The application layer detects the conflict at new-version creation time by querying for unfinalized entries that map to any changed category.
2. A review issue is created with issue type `LEDGER_MAPPING_VERSION_CONFLICT`, listing the affected categories and entry count.
3. The new version row is inserted but `effective_from` is set to a future date; the current version remains active.
4. The workflow run that triggered the new version creation is placed in `REVIEW_HOLD`.
5. Once the reviewer resolves the conflict (either by accepting the change and re-preparing affected entries, or by reverting the new version), the hold is lifted.

This guard prevents a mid-period mapping change from silently producing entries under two different account structures for the same period.

---

## Audit events

| Event | Severity | Trigger |
| --- | --- | --- |
| `LEDGER_MAPPING_VERSION_CREATED` | LOW | A new `ledger_account_mapping_versions` row is inserted |
| `LEDGER_MAPPING_VERSION_FROZEN` | LOW | `frozen_at` is set on a mapping version row during period finalization |

`LEDGER_MAPPING_VERSION_CREATED` payload: `version_id`, `business_id`, `version`, `effective_from`, `created_by_user_id`, `changed_category_count` (number of categories whose account codes differ from the prior version).

`LEDGER_MAPPING_VERSION_FROZEN` payload: `version_id`, `business_id`, `version`, `frozen_at`, `frozen_during_run_id`.

Both events are LOW severity. The mapping version is an administrative configuration record; its creation and freezing are expected operational events.

---

## mapping_config JSONB structure

```json
{
  "OFFICE_SUPPLIES": {
    "debit_account": "6300",
    "credit_account": "2100",
    "description": "Office supplies and stationery"
  },
  "PROFESSIONAL_SERVICES": {
    "debit_account": "6100",
    "credit_account": "2100",
    "description": "Legal, accounting, consulting fees"
  },
  "VEHICLE_EXPENSE": {
    "debit_account": "6500",
    "credit_account": "2100",
    "description": "Vehicle running costs (50% VAT deductibility)"
  }
}
```

Account codes are strings; they correspond to the business's chart of accounts. The platform ships with a default Cyprus-compliant chart; businesses may customise account codes via the ledger configuration interface. The `description` field is for human reference only; it is not used in any computation.

The `mapping_config` JSONB must include an entry for every value in the transaction category enum. A deployment migration validates this invariant on every version insert.

---

## Cross-references

- `ledger_entry_schema.md` — `ledger_entries` table; `mapping_version_id` FK column; `is_locked` column
- `vat_entry_schema.md` — VAT entries reference the same `mapping_version_id` indirectly via `ledger_entry_id`
- `period_lock_status_schema.md` — period lock records created at finalization; trigger for mapping version freeze
- Block 11 — Ledger & Cyprus VAT phase doc
- Block 15 — Finalization & Secure Archive (lock sequence that triggers freeze)
- `data_layer_conventions_policy.md` — UUID v7, canonical JSON for JSONB payloads
