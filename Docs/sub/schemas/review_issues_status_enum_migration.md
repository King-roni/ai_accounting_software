# review_issues_status_enum_migration

**Category:** Schemas · **Owning block:** 14 — Review Queue · **Co-owner:** 04 — Data Architecture · **Stage:** 4 sub-doc (Layer 1 cross-block schema)

The canonical migration script for the 2026-05-08 Block 14 amendment additions to `review_issues`. Adds 8 columns + extends the status enum + adds 4 indexes — all in one migration to keep deployment atomic.

This is the migration sub-doc; `review_issues_schema` is the canonical post-migration schema. The two are read together.

---

## Migration script

```sql
BEGIN;

-- Step 1: Extend the status enum
ALTER TYPE review_issue_status_enum ADD VALUE 'AUTO_RESOLVED_BY_RESCAN' BEFORE 'DISMISSED';

-- Step 2: Add the 8 new columns
ALTER TABLE review_issues
  ADD COLUMN card_payload_json                       jsonb,
  ADD COLUMN card_content_generated_at               timestamptz,
  ADD COLUMN card_content_tier_used                  tool_ai_tier_enum,
  ADD COLUMN card_content_fallback_applied           boolean NOT NULL DEFAULT false,
  ADD COLUMN assignment_notification_sent_at         timestamptz,
  ADD COLUMN snoozed_at                              timestamptz,
  ADD COLUMN snoozed_by                              uuid REFERENCES users(id),
  ADD COLUMN auto_resolution_trigger_issue_id        uuid REFERENCES review_issues(review_issue_id);

-- Step 3: Add the new constraints
ALTER TABLE review_issues
  ADD CONSTRAINT chk_review_issues_auto_resolved_requires_trigger
    CHECK (status != 'AUTO_RESOLVED_BY_RESCAN' OR auto_resolution_trigger_issue_id IS NOT NULL);

-- Step 4: Add the 4 indexes (per review_issues_index_schema)
CREATE INDEX idx_review_issues_queue
  ON review_issues(business_id, status, issue_group, severity DESC, created_at)
  WHERE status IN ('OPEN', 'SNOOZED');

CREATE INDEX idx_review_issues_subject
  ON review_issues(business_id, subject_kind, subject_id);

CREATE INDEX idx_review_issues_assigned
  ON review_issues(business_id, assigned_to_user_id, status)
  WHERE assigned_to_user_id IS NOT NULL;

CREATE INDEX idx_review_issues_snoozed
  ON review_issues(business_id, snooze_until)
  WHERE status = 'SNOOZED';

COMMIT;
```

## Migration order rationale

The order matters:

1. **Enum extension first** — `ALTER TYPE ... ADD VALUE` runs first because Postgres enforces that a new enum value is only available in transactions that started after the ALTER TYPE committed. Adding it at the top of the migration ensures subsequent statements see it.
2. **Column additions** — straightforward; defaults handle existing rows.
3. **Constraints** — added after columns; the CHECK references the new column and the new enum value, so it must come after both.
4. **Indexes** — last, because indexing on new columns requires the columns to exist.

## Backward compatibility

The migration is **forward-only** with limited rollback support:

- New columns can be DROP'd individually
- New constraints can be DROP'd individually
- New indexes can be DROP'd individually
- The new `AUTO_RESOLVED_BY_RESCAN` enum value **cannot be removed without recreating the enum** — Postgres has no `ALTER TYPE ... DROP VALUE`

Per the migration policy:

```sql
-- Rollback (limited)
BEGIN;
  DROP INDEX IF EXISTS idx_review_issues_snoozed;
  DROP INDEX IF EXISTS idx_review_issues_assigned;
  DROP INDEX IF EXISTS idx_review_issues_subject;
  DROP INDEX IF EXISTS idx_review_issues_queue;

  ALTER TABLE review_issues DROP CONSTRAINT chk_review_issues_auto_resolved_requires_trigger;

  ALTER TABLE review_issues
    DROP COLUMN auto_resolution_trigger_issue_id,
    DROP COLUMN snoozed_by,
    DROP COLUMN snoozed_at,
    DROP COLUMN assignment_notification_sent_at,
    DROP COLUMN card_content_fallback_applied,
    DROP COLUMN card_content_tier_used,
    DROP COLUMN card_content_generated_at,
    DROP COLUMN card_payload_json;

  -- The AUTO_RESOLVED_BY_RESCAN enum value remains in the type
  -- because Postgres cannot remove an enum value without recreating the type.
  -- For full rollback: recreate the type + migrate the column + drop the old type.
COMMIT;
```

Production rollback is not expected. If needed, the enum-value cleanup requires a type-recreation procedure documented in `field_encryption_migration_runbook` (Block 05 — the runbook applies generally to schema-recreation patterns, not just encryption).

## Backfill

The migration adds columns to an existing table. Existing rows get NULL for the new nullable columns, `false` for `card_content_fallback_applied` (per its NOT NULL DEFAULT).

Existing rows do **not** get backfilled `card_payload_json` — the column starts NULL. The Block 14 generation code populates it on the next regeneration or on the next issue-creation. Historical issues without card payload render via the existing `title` + `description` columns; the card payload column is the canonical post-migration source.

## Deployment notes

- Run the migration in a maintenance window or use Postgres' DDL-as-statement-level-lock behavior for low-volume tables
- The table `review_issues` is high-volume (one row per issue, many issues per workflow run); the index creations may take a few seconds in a large business. Online creation via `CREATE INDEX CONCURRENTLY` is the post-MVP enhancement
- Test on a staging environment with realistic row counts before applying

## Audit

The migration itself emits no audit events. Per Block 05's audit retention policy, schema migrations are recorded in the deployment log (separate from the application audit log). The first issue created post-migration emits `REVIEW_ISSUE_CREATED` normally with the new columns populated.

## Rollback procedure

If the migration must be rolled back after applying:

1. Run the limited rollback script from the "Backward compatibility" section above inside a transaction.
2. Verify that no application code has written `status = 'AUTO_RESOLVED_BY_RESCAN'` to the table; if rows exist with that status, they must be transitioned to a valid pre-migration status (e.g., `RESOLVED`) before dropping the constraint — the CHECK constraint drop must precede any status update.
3. The `AUTO_RESOLVED_BY_RESCAN` enum value cannot be removed from the type without recreating it. If a full enum rollback is required, use the type-recreation procedure: create a new enum type without the value, alter the column to use a `TEXT` cast intermediary, drop the old type, recreate without the new value, and re-cast the column. This is documented in `field_encryption_migration_runbook` as the canonical schema-recreation pattern.
4. Indexes drop cleanly — no data dependency.
5. After rollback, re-deploy the pre-migration application code before resuming writes.

## Zero-downtime notes

The migration as written uses `ALTER TABLE ... ADD COLUMN` with a NOT NULL DEFAULT (`card_content_fallback_applied DEFAULT false`) and nullable columns. Postgres can add such columns without a full table rewrite, making the migration low-impact on a live table. The index creations are the highest-latency operations; if the table has millions of rows, replace `CREATE INDEX` with `CREATE INDEX CONCURRENTLY` in a migration window where the wrapping `BEGIN/COMMIT` transaction is removed (CONCURRENTLY cannot run inside a transaction block).

## Cross-references

- `data_layer_conventions_policy` — UUID v7 for `auto_resolution_trigger_issue_id` FK + canonical JSON for `card_payload_json` (no new UUID/hash conventions introduced by this migration; reference is for downstream-reader continuity)
- `review_issues_schema` — canonical post-migration schema
- `review_issues_index_schema` (Block 14) — index query-plan details
- `tool_ai_tier_metadata` — `tool_ai_tier_enum` type for `card_content_tier_used`
- `audit_log_policies` — `REVIEW_AUTO_RESOLVED_BY_RESCAN` event
- `issue_group_enum` — orthogonal taxonomy (not affected by this migration)
- `severity_enum` — orthogonal taxonomy (not affected by this migration)
- Block 14 Phase 01 — schema extensions (architecture)
- Block 04 Phase 04 — ledger & review schema (consumer)
- 2026-05-08 decisions-log amendment — `review_issues` schema reconciliation
