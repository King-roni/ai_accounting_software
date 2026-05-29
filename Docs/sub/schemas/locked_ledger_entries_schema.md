# Locked Ledger Entries Schema

**Category:** Schemas · **Owning block:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 2)

Defines the `archive.locked_ledger_entries` table — the immutable, finalization-committed counterpart to `draft_ledger_entries`. This table lives in a separate `archive` Postgres schema with RLS policies that make it structurally write-protected for all application roles outside an active lock sequence. It is the canonical authoritative record of every financial entry for every finalized period.

---

## 1. Schema placement

The table belongs to a dedicated `archive` Postgres schema, distinct from the operational schema that owns `draft_ledger_entries`. This physical separation:

- Enables tighter RLS: the `archive` schema's default privileges grant no INSERT/UPDATE/DELETE to any application role — access must be explicitly widened via session variables set by Block 15's finalization tools.
- Makes mutation attempts visible: any INSERT outside an active lock sequence fails immediately at the RLS layer, producing an `ARCHIVE_TAMPER_DETECTED`-adjacent violation log.
- Aligns with the Block 04 Phase 07 Finalized Secure Archive zone contract: the `archive` schema is the Postgres complement to Object-Locked archive bundle storage.

---

## 2. Table definition

```sql
CREATE TABLE archive.locked_ledger_entries (
  locked_ledger_entry_id    uuid PRIMARY KEY DEFAULT gen_uuid_v7(),

  -- Archive package linkage
  archive_package_id        uuid NOT NULL
                              REFERENCES archive_packages(id),
  manifest_version_number   integer NOT NULL,   -- which manifest version produced this row
                                                -- 1 = original finalization, 2+ = adjustment

  -- Business context
  organization_id           uuid NOT NULL,
  business_id               uuid NOT NULL,
  workflow_run_id           uuid NOT NULL
                              REFERENCES workflow_runs(workflow_run_id),

  -- Source record linkage (nullable: lifecycle-driven entries lack a direct transaction)
  transaction_id            uuid,               -- nullable for lifecycle-driven entries (e.g. WRITTEN_OFF bad-debt)
  invoice_id                uuid,               -- nullable for non-invoice entries

  -- Entry classification
  entry_type                locked_entry_type_enum NOT NULL,  -- ORIGINAL | ADJUSTMENT

  -- Double-entry fields
  debit_account_code        text NOT NULL,      -- references chart_of_accounts.account_code
  credit_account_code       text NOT NULL,
  amount                    numeric(15, 4) NOT NULL CHECK (amount > 0),
  currency                  char(3) NOT NULL,   -- ISO 4217

  -- VAT fields
  vat_treatment             vat_treatment_enum,     -- nullable; OUTSIDE_SCOPE entries may omit
  vat_amount                numeric(15, 4),         -- nullable when vat_treatment = OUTSIDE_SCOPE

  -- Period attribution
  tax_period_year           integer NOT NULL,
  tax_period_month          integer NOT NULL CHECK (tax_period_month BETWEEN 1 AND 12),

  -- Chart version frozen at finalization time
  chart_version_id          uuid NOT NULL,      -- FK to chart_of_accounts_versions.id

  -- Lock metadata
  locked_at                 timestamptz NOT NULL DEFAULT now(),

  -- Constraints
  CHECK (
    -- ADJUSTMENT entries require a parent transaction or invoice
    entry_type != 'ADJUSTMENT' OR (transaction_id IS NOT NULL OR invoice_id IS NOT NULL)
  ),
  CHECK (
    -- debit and credit must differ
    debit_account_code != credit_account_code
  ),
  CHECK (
    -- VAT amount must be present when vat_treatment implies a rate
    vat_treatment IS NULL
    OR vat_treatment IN ('OUTSIDE_SCOPE', 'UNKNOWN')
    OR vat_amount IS NOT NULL
  )
);

CREATE TYPE locked_entry_type_enum AS ENUM ('ORIGINAL', 'ADJUSTMENT');
```

### Column notes

**`manifest_version_number`** — pins the manifest version that wrote this row. `1` for original finalization; `2+` for adjustment-run finalization. Combined with `archive_package_id`, this allows a period's full ledger to be reconstructed one manifest version at a time.

**`transaction_id` / `invoice_id`** — both nullable to accommodate lifecycle-driven entries (e.g., bad-debt expense from `WRITTEN_OFF` invoices) which are invoice-keyed, and adjustment entries which may reference either or neither if they are period-level corrections.

**`chart_version_id`** — frozen at the moment of finalization. Future chart-of-accounts changes cannot retroactively alter the account codes under which historical entries are recorded.

**`vat_treatment`** — from `vat_treatment_enum` (8 closed values: `DOMESTIC_STANDARD`, `DOMESTIC_REDUCED`, `DOMESTIC_ZERO`, `EU_REVERSE_CHARGE`, `IMPORT_OR_ACQUISITION`, `NON_EU_SERVICE`, `OUTSIDE_SCOPE`, `UNKNOWN`). `UNKNOWN` entries in the locked ledger indicate an accountant-flagged row — they are permitted here but are advisory.

---

## 3. Indexes

```sql
-- Primary query pattern: all entries for a package, sorted for version-walk
CREATE INDEX idx_locked_ledger_archive_package
  ON archive.locked_ledger_entries(archive_package_id, manifest_version_number DESC, locked_at);

-- Period reconstruction by business
CREATE INDEX idx_locked_ledger_business_period
  ON archive.locked_ledger_entries(business_id, tax_period_year, tax_period_month);

-- Transaction drill-down from the UI
CREATE INDEX idx_locked_ledger_transaction
  ON archive.locked_ledger_entries(transaction_id)
  WHERE transaction_id IS NOT NULL;

-- Run-level access for finalization verification
CREATE INDEX idx_locked_ledger_workflow_run
  ON archive.locked_ledger_entries(workflow_run_id);
```

---

## 4. RLS policies

### INSERT gate (session-variable controlled)

Only Block 15's finalization tools may INSERT. The gate uses two mutually exclusive Postgres session variables:

```sql
-- Original finalization path (manifest_version_number = 1)
CREATE POLICY locked_ledger_insert_original
  ON archive.locked_ledger_entries
  FOR INSERT
  WITH CHECK (
    current_setting('app.original_lock_active', true) = 'true'
    AND manifest_version_number = 1
  );

-- Adjustment finalization path (manifest_version_number >= 2)
CREATE POLICY locked_ledger_insert_adjustment
  ON archive.locked_ledger_entries
  FOR INSERT
  WITH CHECK (
    current_setting('app.adjustment_lock_active', true) = 'true'
    AND manifest_version_number >= 2
  );
```

The session variables `app.original_lock_active` and `app.adjustment_lock_active` are set for the duration of the lock transaction by Block 15 Phase 04's `archive.lock_period` tool. All other sessions see the default value of empty string, which evaluates to `false`, causing the INSERT to be denied.

### UPDATE / DELETE — blocked unconditionally

```sql
CREATE POLICY locked_ledger_no_update
  ON archive.locked_ledger_entries
  FOR UPDATE
  USING (false);

CREATE POLICY locked_ledger_no_delete
  ON archive.locked_ledger_entries
  FOR DELETE
  USING (false);
```

No application role may UPDATE or DELETE. Any attempt returns a structured Postgres RLS denial. Block 05's audit subsystem detects these attempts as `ARCHIVE_TAMPER_DETECTED` events via the statement-level audit trigger on the `archive` schema.

### SELECT — unrestricted for authorized roles

```sql
CREATE POLICY locked_ledger_select
  ON archive.locked_ledger_entries
  FOR SELECT
  USING (business_id = ANY (auth.business_ids_for_session()));
```

Any authenticated role with an active session on the `business_id` may SELECT. No step-up required for reads. Reads emit a session-summary aggregate event (`ARCHIVE_DATA_READ_SESSION_SUMMARY`) per Block 15 Phase 01's audit-volume policy.

---

## 5. Archive package version-walk query pattern

To reconstruct the full ledger for a period across all manifest versions (original finalization + all subsequent adjustments), ordered to show the most recent manifest version first:

```sql
SELECT
  lle.*,
  ap.period_start,
  ap.period_end
FROM archive.locked_ledger_entries lle
JOIN archive_packages ap ON ap.id = lle.archive_package_id
WHERE lle.archive_package_id = $1          -- the archive_packages.id for the period
ORDER BY
  lle.manifest_version_number DESC,        -- latest manifest version first
  lle.locked_at;                           -- within version, creation order
```

For a "current effective ledger" view (only the latest manifest version's entries):

```sql
WITH latest_version AS (
  SELECT MAX(manifest_version_number) AS mv
  FROM archive.locked_ledger_entries
  WHERE archive_package_id = $1
)
SELECT lle.*
FROM archive.locked_ledger_entries lle
JOIN latest_version lv ON lle.manifest_version_number = lv.mv
WHERE lle.archive_package_id = $1
ORDER BY lle.locked_at;
```

---

## 6. Audit events

| Event | When |
|---|---|
| `FINALIZATION_LEDGER_BULK_LOCKED` | One event per lock sequence with aggregate count of rows promoted. Per-row events are suppressed per the audit-volume guard in `audit_event_taxonomy`. |
| `ARCHIVE_DATA_READ_SESSION_SUMMARY` | Aggregate event per read session when a user or tool reads from this table. |

Both events already exist in the `FINALIZATION` and `ARCHIVE` domains of `audit_event_taxonomy`.

---

## Cross-references
- `data_layer_conventions_policy` — UUID v7 PK generation; `numeric(15,4)` currency representation (no floats); canonical JSON for audit payloads
- `archive_manifest_schemas` — `archive_package_id` and `manifest_version_number` FK targets; version-walk context
- `vat_treatment_enum` — 8-value `vat_treatment` column enum
- `chart_of_accounts_schema` — `chart_version_id` FK; `debit_account_code` / `credit_account_code` values
- `workflow_run_schema` — `workflow_run_id` FK
- `audit_log_policies` — `FINALIZATION_LEDGER_BULK_LOCKED`, `ARCHIVE_DATA_READ_SESSION_SUMMARY` event naming
- `audit_event_taxonomy` — FINALIZATION and ARCHIVE domain events
- `permission_matrix` — `FINALIZATION` surface; read surfaces for SELECT
- Block 15 Phase 01 — archive schema overview (architecture)
- Block 15 Phase 04 — lock sequence; `archive.lock_period` tool that sets session variables
- Block 04 Phase 07 — Finalized Secure Archive zone
