# exception_documented_match_status_migration

**Category:** Schemas · **Owning block:** 12 — OUT Workflow · **Co-owner:** 04 — Data Architecture · **Stage:** 4 sub-doc (Layer 2 schema)

The canonical ALTER TYPE migration adding `EXCEPTION_DOCUMENTED` to `effective_match_status_enum`. Per the Block 12 Phase 06 scan fix: this value lives on `transactions.effective_match_status` (transaction-level), NOT on `match_records.match_status` (per-pair). The migration is on the transactions-table enum only.

This sub-doc is the migration script + rollback notes + backfill semantics for the addition. The canonical post-migration table definition is in `transactions_schema`.

---

## Why the value lives on `transactions`, not `match_records`

Per Block 12 Phase 06: documenting a missing-evidence exception is a transaction-level fact ("this OUT_EXPENSE has no invoice and the user has acknowledged that"). There is no document to pair the transaction with, so no `match_records` row exists. A per-pair status like `match_records.match_status = 'EXCEPTION_DOCUMENTED'` would require a synthetic NULL-document row — a structurally invalid pair.

The Block 04 Phase 03 six-value `match_records.match_status` enum is unchanged:

```
PROPOSED, CONFIRMED, REJECTED, AUTO_CONFIRMED, SUPERSEDED, EXCEPTION_DOCUMENTED  -- NO
```

Instead, the value lands on the denormalised transaction-level enum (six values per `transactions_schema`):

```
UNMATCHED, MATCHED_PROPOSED, MATCHED_CONFIRMED, MATCHED_AUTO_HIGH_CONFIDENCE,
MATCHED_REJECTED, EXCEPTION_DOCUMENTED
```

The cross-block contract for Block 10: if a future invoice upload matches the exception-documented transaction, the matcher creates the `match_records` row normally and flips `transactions.effective_match_status` back to the matched value. The exception is fully reversible via upload.

---

## Migration script

```sql
BEGIN;

-- Step 1: Extend the enum.
-- ALTER TYPE ... ADD VALUE runs first because Postgres only makes the new value
-- visible to transactions that started after the ALTER TYPE committed. Putting
-- it at the top of the migration ensures subsequent statements see it.
ALTER TYPE effective_match_status_enum ADD VALUE 'EXCEPTION_DOCUMENTED'
  AFTER 'MATCHED_REJECTED';

-- Step 2: Add the supporting columns on transactions (per Block 12 Phase 06).
ALTER TABLE transactions
  ADD COLUMN exception_reason          text,
  ADD COLUMN exception_documented_by   uuid REFERENCES users(id),
  ADD COLUMN exception_documented_at   timestamptz;

-- Step 3: Add the consistency CHECK constraint.
-- An exception-documented row must carry the reason + actor + timestamp; conversely
-- a row that is NOT exception-documented must NOT carry those columns populated.
ALTER TABLE transactions
  ADD CONSTRAINT chk_transactions_exception_consistency
  CHECK (
    (effective_match_status = 'EXCEPTION_DOCUMENTED'
       AND exception_reason          IS NOT NULL
       AND exception_documented_by   IS NOT NULL
       AND exception_documented_at   IS NOT NULL)
    OR
    (effective_match_status != 'EXCEPTION_DOCUMENTED'
       AND exception_reason          IS NULL
       AND exception_documented_by   IS NULL
       AND exception_documented_at   IS NULL)
  );

-- Step 4: Index the exception subset for the manual-upload-hold gate query.
CREATE INDEX idx_transactions_exception_documented
  ON transactions(business_id, exception_documented_at DESC)
  WHERE effective_match_status = 'EXCEPTION_DOCUMENTED';

COMMIT;
```

## Migration order rationale

The order matters and matches the pattern in `review_issues_status_enum_migration`:

1. **Enum extension first** — `ALTER TYPE ... ADD VALUE` runs before any statement that references the new value. Postgres requires the new value to be visible in a separate transaction; in a single-transaction migration, the ALTER must come first.
2. **Column additions** — three nullable columns; existing rows get NULL.
3. **Consistency CHECK** — added after both the enum value and the columns exist. The check enforces that the three columns are populated if-and-only-if `effective_match_status = 'EXCEPTION_DOCUMENTED'`.
4. **Partial index** — last, because indexing on the new enum value requires the value to exist in the type.

## Backfill semantics

Existing rows keep `effective_match_status` unchanged. The migration does NOT auto-flip any row to `EXCEPTION_DOCUMENTED`:

- Rows with `effective_match_status = 'UNMATCHED'` stay `UNMATCHED`.
- Rows with NULL `effective_match_status` (if any predate the column's NOT NULL DEFAULT) stay NULL.
- Future `out_workflow.document_exception` invocations flip rows to `EXCEPTION_DOCUMENTED` one at a time.

There is no historical-rewrite. A run that was finalised before this migration has its locked records preserved — the `archive_locked_ledger_entries` for those runs reference the pre-migration state and remain immutable per `archive_bundle_layout_schema`.

A run that is currently held in `MANUAL_UPLOAD_HOLD` at migration time can immediately use the new value once the migration commits; Block 03 Phase 07's resumability framework picks up the new gate-clear vocabulary on the next gate evaluation.

## Rollback limitations

Postgres has no `ALTER TYPE ... DROP VALUE`. Rollback is partial:

```sql
-- Rollback (limited)
BEGIN;
  DROP INDEX IF EXISTS idx_transactions_exception_documented;

  ALTER TABLE transactions
    DROP CONSTRAINT IF EXISTS chk_transactions_exception_consistency;

  ALTER TABLE transactions
    DROP COLUMN IF EXISTS exception_documented_at,
    DROP COLUMN IF EXISTS exception_documented_by,
    DROP COLUMN IF EXISTS exception_reason;

  -- The EXCEPTION_DOCUMENTED enum value remains in the type because Postgres
  -- has no DROP VALUE. Code that no longer emits the value will simply never
  -- write rows with it; existing rows (if any) must be migrated to a different
  -- value before the enum can be fully recreated.
COMMIT;
```

Full enum recreation requires:
1. Create `effective_match_status_enum_v2` with the original five values.
2. Add a new column `effective_match_status_v2` of the new type.
3. Migrate every row, mapping `EXCEPTION_DOCUMENTED` rows to a target (typically `UNMATCHED` with the exception columns preserved for audit).
4. Drop the old column, rename the new column.
5. Drop the old type.

This procedure is documented generically in `field_encryption_migration_runbook` (Block 05) — the runbook applies to all type-recreation scenarios.

Per `out_adjustment_policies`: rolling back a value that has been emitted into finalised archives is not a clean operation; the archive bundle's manifest records the prior `effective_match_status`, and a rollback would create cross-version inconsistency. Rollback is not expected in production.

## Deployment notes

- Run inside a maintenance window or via Postgres' DDL-statement-level lock semantics for low-volume tables.
- `transactions` is high-volume (one row per parsed bank-statement row, many rows per business). The CHECK constraint validation scans every row; for a multi-million-row table this can take several seconds. Use `CREATE CONSTRAINT ... NOT VALID` followed by `VALIDATE CONSTRAINT` for online deployment per Block 04 Phase 02's high-volume migration guidance.
- The partial index `idx_transactions_exception_documented` is small at deployment time (zero rows match the predicate); `CREATE INDEX CONCURRENTLY` is the post-MVP enhancement for online creation.
- Test on a staging environment with realistic row counts.

## Identifier and serialization conventions

Per `data_layer_conventions_policy`: no new UUID v7 or hashing usage is introduced by this migration. The `exception_documented_by` FK uses the existing `users.id` UUID v7. Audit `event_payload_canonical_json` for the supporting `OUT_WORKFLOW_DOCUMENT_EXCEPTION_RECORDED` event follows RFC 8785 ordering per `audit_log_policies`.

## Mobile rejection

Per `mobile_write_rejection_endpoints`: `out_workflow.document_exception` rejects `client_form_factor = MOBILE` with HTTP 403 + `MOBILE_WRITE_REJECTED`. The new columns can therefore only be populated from desktop sessions.

## Audit

The migration itself emits no audit events — schema migrations are recorded in the deployment log per Block 05's audit retention policy. The first `out_workflow.document_exception` invocation post-migration emits `OUT_WORKFLOW_DOCUMENT_EXCEPTION_RECORDED` (existing event in `audit_event_taxonomy`) with `effective_match_status_after = EXCEPTION_DOCUMENTED`.

## Cross-references

- `transactions_schema` — canonical post-migration table definition
- `data_layer_conventions_policy` — UUID v7, SHA-256, canonical JSON (no new conventions introduced; reference for downstream-reader continuity)
- `audit_log_policies` — `OUT_WORKFLOW_DOCUMENT_EXCEPTION_RECORDED` event family, chain partitioning
- `out_adjustment_policies` — finalised-period rollback constraints
- `match_records` schema (`Docs/sub/schemas/`) — confirms the value is NOT mirrored on per-pair status
- `mobile_write_rejection_endpoints` — `out_workflow.document_exception` is mobile-rejected
- Block 12 Phase 06 — `MANUAL_UPLOAD_HOLD` phase (consumer)
- Block 04 Phase 02 — bank statement & transaction schema (table owner)
- Block 10 — matching engine cross-block contract for exception reversal on later upload
- `review_issues_status_enum_migration` — sibling migration with identical ALTER TYPE pattern

## Open items deferred

- Stage 2+ unified `effective_match_status` across OUT and IN — the IN side does NOT currently use this column per Block 13 Phase 10. A unified status enum is deferred.
- Programmatic re-evaluation of `EXCEPTION_DOCUMENTED` rows when a later run uploads matching evidence — Block 10 owns the contract; this sub-doc commits only the storage shape.
