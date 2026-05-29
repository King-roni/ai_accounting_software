# Audit Log Query Guide

**Block:** security
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This guide covers efficient querying of the `audit_log` table for operational, forensic, and export use cases. It assumes familiarity with the table structure defined in `audit_log_schema.md`. The guide documents query patterns, index usage, RLS considerations, pagination strategy, and partition pruning for this append-only log table.

The audit log is immutable from the application layer. No `UPDATE` or `DELETE` operations are permitted on `audit_log`. All queries in this guide are read-only.

## Table Structure Recap

Full schema is in `audit_log_schema.md`. Key columns for querying:

| Column | Type | Index |
|---|---|---|
| `id` | uuid (gen_uuid_v7) | PRIMARY KEY |
| `business_id` | uuid | Composite index with `occurred_at` |
| `occurred_at` | timestamptz | Composite index with `business_id` |
| `event_type` | text | Non-unique index |
| `severity` | text | Non-unique index |
| `actor_id` | uuid (nullable) | Non-unique index |
| `actor_type` | text | — |
| `entity_type` | text | — |
| `entity_id` | uuid | Non-unique index |
| `run_id` | uuid (nullable) | Non-unique index |
| `payload` | jsonb | GIN index on payload |
| `hash` | text | Unique index (tamper detection) |
| `prev_hash` | text | — |

The table is partitioned by month on `occurred_at`. Partition names follow the pattern `audit_log_YYYY_MM`. Always include `occurred_at` in WHERE clauses to enable partition pruning.

## Query Pattern 1 — All Events for a Business in a Date Range

```sql
SELECT
  id,
  occurred_at,
  event_type,
  severity,
  actor_id,
  actor_type,
  entity_type,
  entity_id,
  payload
FROM audit_log
WHERE business_id = :business_id
  AND occurred_at >= :start_date
  AND occurred_at < :end_date
ORDER BY occurred_at ASC, id ASC;
```

Performance notes:
- The composite index `(business_id, occurred_at)` is used for this query. Both columns must appear in the WHERE clause for the index to be applied.
- Keep date ranges narrow. A full quarter returns ~150K–450K rows for active businesses; always paginate.
- Do not use `occurred_at BETWEEN :start AND :end` — the upper bound is inclusive and can include the boundary row twice if timestamps align exactly. Use `>=` and `<`.

## Query Pattern 2 — Events for a Specific Run

```sql
SELECT
  id,
  occurred_at,
  event_type,
  severity,
  actor_id,
  actor_type,
  entity_type,
  entity_id,
  payload
FROM audit_log
WHERE business_id = :business_id
  AND run_id = :run_id
  AND occurred_at >= :run_created_at         -- partition pruning hint
  AND occurred_at < :run_created_at + INTERVAL '90 days'
ORDER BY occurred_at ASC, id ASC;
```

Notes:
- `run_id` alone does not enable partition pruning. Always add an `occurred_at` range around the expected run duration to keep the query within a small number of partitions.
- `run_created_at` is available from the `runs` table. A run rarely spans more than 7 days; the 90-day window is a conservative upper bound.
- If `run_id` is NULL (events not linked to a run), this query returns 0 rows — correct behavior.

## Query Pattern 3 — Failed Events (Severity HIGH or BLOCKING)

```sql
SELECT
  id,
  occurred_at,
  event_type,
  severity,
  actor_id,
  entity_type,
  entity_id,
  payload
FROM audit_log
WHERE business_id = :business_id
  AND severity IN ('HIGH', 'BLOCKING')
  AND occurred_at >= :start_date
  AND occurred_at < :end_date
ORDER BY occurred_at DESC, id DESC;
```

Notes:
- Normal runs produce fewer than 10 HIGH or BLOCKING events. A spike above 50 HIGH events in a single run warrants investigation.
- `severity` is not part of the composite index; the planner will apply the `(business_id, occurred_at)` index first and then filter on severity. This is efficient when the date range is narrow.
- Do not use `severity NOT IN ('LOW', 'MEDIUM')` — always use the positive filter on HIGH and BLOCKING to avoid issues if new severity levels are added.

## Query Pattern 4 — Events by a Specific User

```sql
SELECT
  id,
  occurred_at,
  event_type,
  severity,
  entity_type,
  entity_id,
  payload
FROM audit_log
WHERE business_id = :business_id
  AND actor_id = :user_id
  AND occurred_at >= :start_date
  AND occurred_at < :end_date
ORDER BY occurred_at ASC, id ASC;
```

Notes:
- `actor_id` is NULL for system-initiated events (`actor_type = 'SYSTEM'` or `actor_type = 'API_KEY'` where the key has been revoked). Filter on `actor_type = 'USER'` first if you want only human-actor events.
- For API key actor queries, use `payload->>'actor_key_prefix' = :prefix` — the key prefix is stored in the JSON payload because `actor_id` holds the key's internal UUID.

## Query Pattern 5 — Tamper Detection (Hash Chain Verification)

The audit log uses a rolling hash chain: each row's `hash` is computed from its content plus the `prev_hash` of the immediately preceding row (ordered by `occurred_at, id` within the same `business_id`). Verification detects row deletion, insertion, or modification.

```sql
-- Step 1: Pull the chain for a business over a period
WITH ordered_events AS (
  SELECT
    id,
    occurred_at,
    event_type,
    payload,
    hash,
    prev_hash,
    LAG(hash) OVER (
      PARTITION BY business_id
      ORDER BY occurred_at ASC, id ASC
    ) AS computed_prev_hash
  FROM audit_log
  WHERE business_id = :business_id
    AND occurred_at >= :start_date
    AND occurred_at < :end_date
)
SELECT
  id,
  occurred_at,
  event_type,
  hash,
  prev_hash,
  computed_prev_hash,
  CASE
    WHEN prev_hash IS DISTINCT FROM computed_prev_hash THEN 'CHAIN_BREAK'
    ELSE 'OK'
  END AS chain_status
FROM ordered_events
WHERE prev_hash IS DISTINCT FROM computed_prev_hash
ORDER BY occurred_at ASC;
```

If the query returns 0 rows, the chain is intact for the period. Any returned rows indicate a break point.

Notes:
- The first event for a business has `prev_hash = NULL`; its chain status is always OK if `prev_hash IS NULL AND computed_prev_hash IS NULL`.
- This query runs within a single partition if the date range is narrow. For chain verification spanning multiple months, call the query per month and verify the last `hash` of month N equals the first `prev_hash` of month N+1.
- Hash computation algorithm is SHA-256. The exact input string format is in `audit_log_schema.md`. Do not attempt to recompute hashes in SQL; use the Edge Function `security.verify_hash_chain` for authoritative verification.
- The tamper detection forensic runbook (`/sub/runbooks/tamper_detection_forensic_runbook.md`) documents the response procedure when a chain break is detected.

## Query Pattern 6 — Export of Audit Events for a Period

For full audit exports (e.g., for accountant packs or regulatory disclosure), use the data export pipeline rather than running raw queries. See `data_export_policy.md` for the FULL export scope which includes an audit excerpt.

For internal tooling or admin bulk exports, the following pattern pages through the log efficiently:

```sql
-- Keyset pagination — first page
SELECT
  id,
  occurred_at,
  event_type,
  severity,
  actor_id,
  actor_type,
  entity_type,
  entity_id,
  payload
FROM audit_log
WHERE business_id = :business_id
  AND occurred_at >= :start_date
  AND occurred_at < :end_date
ORDER BY occurred_at ASC, id ASC
LIMIT 500;

-- Subsequent pages: pass last row's (occurred_at, id) as cursor
SELECT
  id,
  occurred_at,
  event_type,
  severity,
  actor_id,
  actor_type,
  entity_type,
  entity_id,
  payload
FROM audit_log
WHERE business_id = :business_id
  AND occurred_at >= :start_date
  AND occurred_at < :end_date
  AND (occurred_at, id) > (:last_occurred_at, :last_id)
ORDER BY occurred_at ASC, id ASC
LIMIT 500;
```

See the Pagination section below for rationale on keyset vs. OFFSET.

## Performance Notes

### Use the Composite Index

The primary performance contract of the audit log is: `(business_id, occurred_at)` is always covered by the query's WHERE clause. Queries missing either column will trigger a full table (or full partition) scan.

Bad (avoid):
```sql
-- No business_id — scans all tenants' data
SELECT * FROM audit_log WHERE event_type = 'PAYMENT_RECORDED';
```

Good:
```sql
SELECT * FROM audit_log
WHERE business_id = :business_id
  AND event_type = 'PAYMENT_RECORDED'
  AND occurred_at >= :start
  AND occurred_at < :end;
```

### Avoid Full Table Scans

Never issue a query against `audit_log` without a `business_id` filter except from a service-role admin context with an explicit `EXPLAIN ANALYZE` review beforehand.

### GIN Index on Payload

The `payload` column has a GIN index for jsonb operators. Use `payload @> '{"key": "value"}'::jsonb` for key-value matching in JSON. Avoid `payload->>'key' = 'value'` in high-volume queries (this pattern does not use the GIN index).

```sql
-- Efficient: uses GIN index
SELECT id FROM audit_log
WHERE business_id = :business_id
  AND occurred_at >= :start AND occurred_at < :end
  AND payload @> '{"run_id": "018f4e2a-1234-7000-8000-000000000099"}'::jsonb;
```

## RLS Bypass Pattern for Admin Audit Views

By default, Supabase RLS policies on `audit_log` restrict rows to `business_id = auth.jwt()->>'business_id'`. Tenant-scoped queries work automatically through the anon/authenticated roles.

For admin audit views (e.g., tamper detection across all tenants, compliance reporting), RLS must be bypassed. This is only permitted from Edge Functions using the service role key. Never expose the service role key to the frontend.

```typescript
// In an Edge Function
const adminClient = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
);

const { data, error } = await adminClient
  .from('audit_log')
  .select('id, occurred_at, event_type, severity, business_id, hash, prev_hash')
  .gte('occurred_at', startDate)
  .lt('occurred_at', endDate)
  .order('occurred_at', { ascending: true })
  .order('id', { ascending: true })
  .limit(500);
```

Cross-tenant admin queries must be logged themselves to a separate admin audit table. Do not write admin queries as part of the regular business audit log.

## Pagination

### Use Keyset Pagination

OFFSET pagination (`LIMIT n OFFSET m`) is prohibited on `audit_log`. The table grows continuously; OFFSET queries drift between pages as new rows are inserted, and performance degrades linearly with offset depth.

Keyset pagination on `(occurred_at, id)` is stable, index-backed, and performs consistently regardless of table size. Both columns are needed in the cursor because multiple events can share the same `occurred_at` timestamp (microsecond resolution still allows collisions in batch processing).

The cursor must be passed as two separate bound parameters, not interpolated as a string. Interpolation risks SQL injection and timestamp parsing errors.

### Page Size

Default page size: 250 rows for UI-facing queries. 500 rows for export pipelines. Do not exceed 1000 rows per page; the result set serialization overhead is not worth the reduction in round trips at that scale.

## Partition Pruning

Monthly partitions mean the planner can skip irrelevant months entirely when `occurred_at` bounds are present. Always verify partition pruning is active using `EXPLAIN (ANALYZE, BUFFERS)` on new query patterns:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*) FROM audit_log
WHERE business_id = :business_id
  AND occurred_at >= '2026-01-01'
  AND occurred_at < '2026-02-01';
```

Expected output: `Seq Scan on audit_log_2026_01` — only one partition scanned. If you see `Seq Scan on audit_log` without a partition suffix, the planner is not pruning; check that `occurred_at` bounds are not wrapped in a function that defeats constraint exclusion (e.g., `date_trunc('month', occurred_at) = '2026-01-01'` — use range bounds instead).

## Typical Event Volumes

These are indicative for a normally operating business. Deviations warrant investigation.

| Severity | Events per run (normal) | Events per run (alert threshold) |
|---|---|---|
| LOW | ~500 | >5,000 (possible loop or flood) |
| MEDIUM | ~50 | >500 |
| HIGH | <10 | >50 |
| BLOCKING | 0 | >0 (always investigate) |

A completed quarterly run for an active business with ~2,000 transactions typically produces 2,000–3,000 LOW events, 100–200 MEDIUM events, and 0–5 HIGH events.

## Related Documents

- `/sub/reference/audit_event_taxonomy.md`
- `/sub/reference/supabase_rls_policy_map.md`
- `/sub/reference/security_alerting_internal.md`
- `/sub/runbooks/tamper_detection_forensic_runbook.md`
- `/sub/runbooks/accountant_pack_tamper_runbook.md`
- `/sub/ui/audit_log_viewer_ui_spec.md`
