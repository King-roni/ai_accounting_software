# analytics_refresh_runbook

**Category:** Runbooks · **Owning block:** 04 — Data Architecture · **Co-owner:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 1 cross-block runbook)

The procedure for refreshing analytics materialized views in response to `ARCHIVE_PROMOTION_COMPLETED`. Per Stage 1: "Analytics layer refresh: Eventual consistency via background jobs. Dashboards may lag a few minutes after finalization."

This runbook is invoked by `event_subscription_pipeline_integration` when the `archive_promotion_completed_event_integration` event fires. The runbook is also operator-callable for manual refreshes during maintenance.

---

## Procedure

### Step 1 — Identify scope

```sql
-- Given the event payload (archive_package_id, business_id, period_start, period_end)
-- Find affected MVs from materialized_view_dependency_map
SELECT mv_name
FROM materialized_view_dependency_map
WHERE archive_dependency = true
  AND period_dependency = true;
```

For MVP, the canonical affected MVs are:

- `archive.mv_ledger_entries_latest` (per `block_16_as_of_view_schema`)
- `analytics.mv_dashboard_cards` (per `dashboard_card_definitions_catalog`)
- `analytics.mv_multi_business_aggregate` (per `multi_business_aggregation_schema`)
- `analytics.mv_vat_summary` (per `vat_rate_table_cyprus` consumer)
- `analytics.mv_supplier_overview` (per Block 16 Phase 06)

### Step 2 — Acquire refresh-in-progress flag

```sql
SELECT pg_try_advisory_lock(hashtext('analytics_refresh_' || $business_id::text));
-- Returns false if another refresh is already running for this business
```

If the flag is held: log skip + return (the other refresh covers this event). Per `dashboard_card_policies` (now part of `dashboard_card_policies`), a missed event is acceptable — the next event picks up the difference.

### Step 3 — Refresh in dependency order

```sql
-- Independent refreshes (no FK dependencies)
REFRESH MATERIALIZED VIEW CONCURRENTLY archive.mv_ledger_entries_latest;

-- Dependent refreshes (read from the above)
REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_dashboard_cards;
REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_vat_summary;

-- Aggregate refreshes (read from cards)
REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_multi_business_aggregate;
REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_supplier_overview;
```

The `CONCURRENTLY` clause ensures dashboard reads continue against the old view while the refresh runs (Postgres-native MV double-buffering). The refresh swap is atomic per MV.

### Step 4 — Update refresh metadata

```sql
INSERT INTO analytics_refresh_log (
  business_id,
  archive_package_id,
  refresh_started_at,
  refresh_completed_at,
  refresh_duration_ms,
  mv_count,
  status
) VALUES ($1, $2, $started_at, now(), $duration, 5, 'COMPLETED');
```

### Step 5 — Emit completion event

```ts
emitAudit("ANALYTICS_REFRESH_COMPLETED", {
  business_id,
  archive_package_id,
  refresh_duration_ms
});
```

Block 16 subscribes to this event for dashboard invalidation per `dashboard_card_policies` — clients with active dashboards receive a server-push to re-fetch.

### Step 6 — Release the lock

```sql
SELECT pg_advisory_unlock(hashtext('analytics_refresh_' || $business_id::text));
```

## Failure handling

| Failure | Behavior |
| --- | --- |
| Refresh times out (> 5 min per MV) | Abort; emit `ANALYTICS_REFRESH_FAILED`; the existing MV remains queryable (eventual consistency from Stage 1); operator escalation per `cross_tenant_alerting_runbook` |
| Refresh fails on dependency MV | Skip dependent MVs; emit `ANALYTICS_REFRESH_FAILED` with `failed_mv` payload; subsequent event re-triggers the full refresh |
| `pg_try_advisory_lock` returns false | Log SKIP (another refresh in progress); return; the in-progress refresh covers the work |
| Database unavailable | Retry once after 10s; if still unavailable, the subscription's per-event retry policy applies per `event_subscription_pipeline_integration` |

## Manual invocation

Operators can manually trigger a refresh via:

```bash
psql -c "SELECT analytics.refresh_for_business('<business_id>')"
```

The function wraps the procedure above. Used when:

- Investigation reveals a stale MV from a missed event
- After a schema migration that requires MV rebuild
- Per `archive_promotion_failure_runbook` follow-up

Manual invocations also emit `ANALYTICS_REFRESH_TRIGGERED` per `audit_log_policies` with `actor_user_id` populated (system context).

## Performance considerations

Per `fixture_performance_budget` Block 04:

| MV | P50 | P95 | P99 |
| --- | --- | --- | --- |
| `mv_ledger_entries_latest` (single business, monthly volume) | 2 s | 8 s | 30 s |
| `mv_dashboard_cards` | 1 s | 4 s | 15 s |
| `mv_vat_summary` | 500 ms | 2 s | 8 s |
| `mv_multi_business_aggregate` (10 businesses) | 5 s | 20 s | 60 s |
| Full refresh chain | 5 s | 30 s | 120 s |

Heavy businesses (hundreds of transactions per month) approach the upper bounds. Operator alerts fire if any single MV refresh exceeds 5 minutes.

## Audit events

| Event | When |
| --- | --- |
| `ANALYTICS_REFRESH_TRIGGERED` | Refresh procedure starts (event-driven OR manual) |
| `ANALYTICS_REFRESH_COMPLETED` | All MVs refreshed successfully |
| `ANALYTICS_REFRESH_FAILED` | Any MV failed |

## Cross-references

- `archive_promotion_completed_event_integration` — the trigger
- `event_subscription_pipeline_integration` — subscription mechanism
- `block_16_as_of_view_schema` — the MV consumers
- `dashboard_card_policies` (consolidated) — per-card refresh rules
- `cross_tenant_alerting_runbook` — escalation
- `archive_promotion_failure_runbook` — sibling runbook
- `materialized_view_dependency_map` (Block 16 Reference data) — MV dependency tree
- `audit_log_policies` — `ANALYTICS_*` events
- Block 04 Phase 09 — analytics zone (architecture)
- Block 16 Phase 01 — schema, preferences & analytics consumption
- Stage 1 decision — analytics eventual-consistency lag
