# block_16_as_of_view_schema

**Category:** Schemas · **Owning block:** 16 — Dashboard & Reporting · **Co-owner:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 1 cross-block schema)

The Postgres views Block 16 queries to render dashboards and drill-downs with manifest-chain support — "as-of original finalization" vs "latest with adjustments applied." Per Block 16 Phase 02 + 08: drill-down rendering needs both modes; users can toggle.

This sub-doc declares the canonical view definitions and the join pattern across `archive.locked_ledger_entries` + `archive.archive_manifests`.

---

## Why two views

A period that's been adjusted has multiple manifest versions. Two consumer needs:

1. **As-of original** — show what the books looked like at the moment the period was first finalized. Useful for audit traceback, "what did we file at the time" queries.
2. **Latest** — show what the books look like now, after all adjustments. The default view; what an accountant uses to prepare current reports.

Both views need to be fast at scale — they're hit on every dashboard render.

## View definitions

### `archive.v_ledger_entries_as_of_original`

Returns rows from `archive.locked_ledger_entries` filtered to the **original** manifest (i.e., `manifest_version_number = 1`).

```sql
CREATE OR REPLACE VIEW archive.v_ledger_entries_as_of_original AS
SELECT le.*
FROM archive.locked_ledger_entries le
INNER JOIN archive.archive_packages ap
  ON ap.id = le.archive_package_id
WHERE le.manifest_version_number = 1
  AND le.source_adjustment_run_id IS NULL;
```

Performance characteristics: clean B-tree scan on the indexed `(archive_package_id, manifest_version_number)` columns. No adjustment-overlay logic.

### `archive.v_ledger_entries_latest`

Returns rows with all adjustment overlays applied — the "current truth" view.

```sql
CREATE OR REPLACE VIEW archive.v_ledger_entries_latest AS
WITH latest_per_package AS (
  SELECT
    archive_package_id,
    MAX(manifest_version_number) AS max_version
  FROM archive.locked_ledger_entries
  GROUP BY archive_package_id
)
SELECT le.*
FROM archive.locked_ledger_entries le
INNER JOIN latest_per_package lpp
  ON lpp.archive_package_id = le.archive_package_id
WHERE le.manifest_version_number = lpp.max_version
   OR (
     -- Include earlier-version rows that survived the latest adjustment
     -- (rows untouched by the adjustment carry forward by reference)
     le.manifest_version_number < lpp.max_version
     AND NOT EXISTS (
       SELECT 1
       FROM archive.locked_ledger_entries le_newer
       WHERE le_newer.archive_package_id = le.archive_package_id
         AND le_newer.manifest_version_number > le.manifest_version_number
         AND le_newer.original_ledger_entry_id = le.locked_ledger_entry_id
     )
   );
```

Performance characteristics: requires the WITH-CTE plus the NOT EXISTS subquery — heavier than `as_of_original`. Materialized in the Block 16 MV layer per `materialized_view_dependency_map`.

### Materialized view for performance

```sql
CREATE MATERIALIZED VIEW archive.mv_ledger_entries_latest AS
  SELECT * FROM archive.v_ledger_entries_latest;

CREATE INDEX idx_mv_ledger_latest_business_period
  ON archive.mv_ledger_entries_latest(business_id, period_start, period_end);

CREATE INDEX idx_mv_ledger_latest_account_code
  ON archive.mv_ledger_entries_latest(business_id, account_code);
```

Refresh trigger: `ARCHIVE_PROMOTION_COMPLETED` event from Block 15 (per `audit_event_taxonomy` + the 2026-05-08 amendment). The event-bus subscription in `event_subscription_pipeline_integration` dispatches the refresh.

Per `archive_promotion_atomicity_policy`: the refresh is best-effort; a missed refresh window doesn't cause data corruption, only display lag. Block 16 surfaces a `stale_data_indicator` on dashboards while a refresh is pending.

## Cross-business multi-package queries

For the multi-business consolidated view per Stage 1 ("Multi-business consolidated view: included in MVP with full drill-down across businesses"):

```sql
CREATE OR REPLACE VIEW archive.v_ledger_entries_latest_multi_business AS
SELECT *
FROM archive.v_ledger_entries_latest
WHERE business_id = ANY (auth.business_ids_for_session());
```

RLS applies — the consolidated view doesn't bypass tenant isolation.

## As-of timestamp queries (deferred)

Stage 2+: a more general view `archive.v_ledger_entries_as_of(t timestamptz)` that returns the state as of any historical timestamp. MVP carries only `as_of_original` and `latest`.

The deferred form is reachable from the manifest chain: each manifest version carries its `created_at`, so a binary search lands the appropriate manifest version per `(t, business_id, period)`.

## Cross-cache interaction

Per the Block 16 scan fix: the dashboard's materialized view cache + the archive verification cache (per Block 15 Phase 07) live side-by-side:

- **MV cache** — refreshed on `ARCHIVE_PROMOTION_COMPLETED`; lifetime is "until next archive promotion"
- **Archive verification cache** — per-session 30-minute TTL per `archive_pre_read_verification_policy` (Block 15)

When Block 16 reads from `mv_ledger_entries_latest`, the verification cache short-circuits the per-read hash check. Concurrent refresh + drill-down handled correctly: drill-down reads stale MV data while refresh runs, then sees fresh data after refresh commits.

## Audit events

| Event | When |
| --- | --- |
| `DASHBOARD_VIEWED` | Per dashboard render — aggregated per session per business |
| `ARCHIVE_DATA_READ` | Per access to archive views — aggregated per `audit_log_policies` |

Drill-down into archive data is logged; the user's identity is captured.

## Cross-references

- `data_layer_conventions_policy` — UUID v7 for archive_package_id continuity in the views
- `archive_schema` — `locked_ledger_entries` host table
- `archive_manifest_schemas` (Block 15) — manifest chain query patterns
- `archive_promotion_completed_event_integration` — refresh trigger
- `archive_promotion_atomicity_policy` (now merged into `archive_bundle_policies`) — refresh resilience
- `archive_pre_read_verification_policy` (merged into `lock_sequence_policies`) — per-session verification cache
- `event_subscription_pipeline_integration` — `ARCHIVE_PROMOTION_COMPLETED` event-bus dispatch
- `materialized_view_dependency_map` (Block 16) — MV layer
- `analytics_refresh_runbook` (Block 04) — refresh procedure
- Block 16 Phase 02 — drill-down routing & permissions
- Block 16 Phase 08 — drill-down list & detail views
- Block 15 Phase 06 — manifest versioning for adjustments
- 2026-05-08 decisions-log amendment — `ARCHIVE_PROMOTION_COMPLETED` canonical event
