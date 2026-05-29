# Dashboard Refresh Failure — Stale-State Recovery Runbook

**Category:** Runbooks · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

**Block reference:** Block 16, Phases 01–03 (analytics snapshot, report jobs, dashboard cache).

**Purpose:** Operator response steps for the five failure modes that cause dashboard analytics to show stale, missing, or error-state data. Each mode has distinct detection signals, SQL/tool-call sequences, and monitoring expectations. The recovery paths are non-destructive — they rebuild or refresh derived data, never touching source ledger or archive tables.

---

## Failure mode taxonomy

Five distinct failure modes cover the analytics stale-state surface. Each maps to a specific table state and monitoring signal.

---

### Mode 1 — `ANALYTICS_REBUILD_TIMEOUT`

**Description:** The `report.rebuild_analytics_snapshot` job exceeded the 5-minute execution timeout. The `analytics_snapshots` row for the affected period either was not created or was created with `snapshot_status = FAILED`.

**Detection signal:** Absence of `ANALYTICS_SNAPSHOT_REBUILT` within 10 minutes of `ARCHIVE_PROMOTION_COMPLETED` for the same `workflow_run_id`. Alternatively, the `report_jobs` row for the rebuild shows `status = FAILED` with `error_message` containing `TIMEOUT`.

**Operator steps:**

1. Identify the timed-out job:

   ```sql
   SELECT id, report_type, status, started_at, completed_at, error_message
   FROM report_jobs
   WHERE report_type = 'ANALYTICS_REBUILD'
     AND status = 'FAILED'
     AND error_message ILIKE '%TIMEOUT%'
   ORDER BY started_at DESC
   LIMIT 5;
   ```

2. Confirm no other rebuild job is currently `RUNNING` for the same `workflow_run_id` (concurrent rebuilds are rejected — only one active rebuild per run):

   ```sql
   SELECT id, status FROM report_jobs
   WHERE report_type = 'ANALYTICS_REBUILD'
     AND metadata->>'workflow_run_id' = '<run_id>'
     AND status = 'RUNNING';
   ```

3. If a running job exists, wait for it to complete or time out before re-queuing.
4. Reduce scope for the retry by triggering an incremental rebuild rather than a full rebuild:

   ```
   report.rebuild_analytics_snapshot({
     workflow_run_id: '<run_id>',
     mode: 'INCREMENTAL',
     snapshot_version_override: null
   })
   ```

   The incremental mode rebuilds only changed metric groups rather than the full snapshot, and typically completes within 60 seconds for standard period sizes.

5. Monitor for `ANALYTICS_SNAPSHOT_REBUILT` within 5 minutes of the retry invocation. If the incremental rebuild also times out, escalate to engineering — the period's dataset may be abnormally large or the analytics query is hitting an unindexed path.

---

### Mode 2 — `REPORT_JOB_STUCK`

**Description:** A `report_jobs` row has been in `status = RUNNING` for more than 30 minutes. The job is no longer making progress but has not emitted a failure event. `REPORT_JOB_FAILED` was never emitted.

**Detection signal:** Alerting dashboard fires on the query: `report_jobs` rows with `status = RUNNING` and `started_at < NOW() - INTERVAL '30 minutes'`.

**Operator steps:**

1. Identify stuck jobs:

   ```sql
   SELECT id, report_type, business_id, started_at,
          EXTRACT(EPOCH FROM (NOW() - started_at))/60 AS running_minutes,
          metadata
   FROM report_jobs
   WHERE status = 'RUNNING'
     AND started_at < NOW() - INTERVAL '30 minutes'
   ORDER BY started_at ASC;
   ```

2. Check whether the underlying Postgres worker process is still active:

   ```sql
   SELECT pid, state, query_start, query
   FROM pg_stat_activity
   WHERE query ILIKE '%report_jobs%'
     AND state != 'idle'
   ORDER BY query_start ASC;
   ```

3. If no active Postgres process corresponds to the job, the worker process crashed without updating the job row. Mark the job as FAILED:

   ```sql
   UPDATE report_jobs
   SET status = 'FAILED',
       completed_at = NOW(),
       error_message = 'ORPHANED_JOB: worker process exited without updating status'
   WHERE id = '<job_id>'
     AND status = 'RUNNING';
   ```

   This emits `REPORT_JOB_FAILED` via the `report_jobs` update trigger.

4. Re-queue the job via the appropriate tool (`report.queue_report_job` with the same parameters as the stuck job's `metadata`).
5. If an active Postgres process is found and is legitimately running, extend the observation window to 60 minutes before forcibly marking it failed. Some large-period PDF renders are slow but will complete.

---

### Mode 3 — `DASHBOARD_CACHE_STALE`

**Description:** The cached dashboard snapshot for a business is older than 2 hours. The dashboard UI is displaying data from a stale cache entry while a newer analytics snapshot exists in `analytics_snapshots`.

**Detection signal:** Dashboard UI shows the "Last updated" timestamp as > 2 hours ago. Alternatively, query:

```sql
SELECT
    dc.business_id,
    dc.cached_at,
    EXTRACT(EPOCH FROM (NOW() - dc.cached_at))/3600 AS cache_age_hours,
    s.computed_at AS latest_snapshot_at
FROM dashboard_cache dc
JOIN analytics_snapshots s
    ON s.business_id = dc.business_id
   AND s.snapshot_version = (
       SELECT MAX(snapshot_version)
       FROM analytics_snapshots
       WHERE business_id = dc.business_id
   )
WHERE dc.cached_at < NOW() - INTERVAL '2 hours';
```

**Operator steps:**

1. Confirm a current analytics snapshot exists for the business:

   ```sql
   SELECT id, snapshot_version, computed_at, snapshot_status
   FROM analytics_snapshots
   WHERE business_id = '<biz_id>'
   ORDER BY snapshot_version DESC
   LIMIT 1;
   ```

   If `snapshot_status != 'COMPLETED'`, the cache is correctly stale — the underlying snapshot is not ready. Address the snapshot first (see Mode 1 or Mode 5).

2. If the snapshot is COMPLETED and the cache is stale, force a cache refresh:

   ```
   report.refresh_dashboard_cache({ business_id: '<biz_id>' })
   ```

3. Verify the refresh completed:

   ```sql
   SELECT cached_at FROM dashboard_cache WHERE business_id = '<biz_id>';
   ```

   The `cached_at` timestamp should be within the last 60 seconds.

4. If `report.refresh_dashboard_cache` returns an error, check whether the `dashboard_cache` row exists at all — the first-ever cache entry may need to be created via an explicit rebuild rather than a refresh.

---

### Mode 4 — `CARD_DATA_SOURCE_UNAVAILABLE`

**Description:** A specific dashboard card's data-source tool is returning errors. The card shows "Data temporarily unavailable" in the UI and logs `REPORT_DATA_SOURCE_FAILED`.

**Detection signal:** `REPORT_DATA_SOURCE_FAILED` audit event emitted (MEDIUM severity) with `card_id` and `tool_name` in the payload. The dashboard UI marks the affected card with an error state. Other cards on the same dashboard may render normally.

**Operator steps:**

1. Identify the affected card and tool from the `REPORT_DATA_SOURCE_FAILED` event payload. Fields: `card_id`, `tool_name`, `error_class`, `business_id`, `workflow_run_id`.

2. Check whether the tool's backing data exists:

   ```sql
   -- Example for a ledger-based card using report.export_ledger
   SELECT COUNT(*) FROM ledger_entries
   WHERE workflow_run_id = '<run_id>'
     AND business_id = '<biz_id>';
   ```

   A zero count suggests the underlying data has not been prepared for this run.

3. Attempt a manual tool invocation in dry-run mode to surface the error detail:

   ```
   report.health_check_card({ card_id: '<card_id>', workflow_run_id: '<run_id>' })
   ```

   This is a `READ_ONLY` tool that runs the card's data-source query and returns the error without writing to cache.

4. Common resolutions by error class:
   - `DATA_NOT_PREPARED` — the phase that populates the card's source data has not yet run. Check `workflow_phase_states` for the relevant phase status.
   - `SCHEMA_MISMATCH` — a schema migration changed the source table structure. Escalate to engineering.
   - `TIMEOUT` — the card's query is slow. Engineering may need to add an index or rewrite the query.
   - `RLS_DENIED` — the report job is running with incorrect session context. Escalate to engineering.

5. Once the underlying issue is resolved, the card will auto-recover on the next dashboard refresh. Trigger a refresh via `report.refresh_dashboard_cache` to surface the fix immediately rather than waiting for the next scheduled refresh interval.

---

### Mode 5 — `ARCHIVE_PROMOTION_ANALYTICS_DRIFT`

**Description:** `ARCHIVE_PROMOTION_COMPLETED` was emitted for a workflow run, but the analytics snapshot for that period has not been rebuilt. The dashboard shows data from before the finalized period.

**Detection signal:** Query for runs with `ARCHIVE_PROMOTION_COMPLETED` in the last 24 hours but no corresponding `ANALYTICS_SNAPSHOT_REBUILT`:

```sql
SELECT
    al.payload->>'workflow_run_id' AS workflow_run_id,
    al.payload->>'business_id' AS business_id,
    al.event_time AS promotion_completed_at,
    sn.id AS snapshot_id,
    sn.snapshot_status
FROM audit_log al
LEFT JOIN analytics_snapshots sn
    ON sn.workflow_run_id = (al.payload->>'workflow_run_id')::uuid
WHERE al.event_type = 'ARCHIVE_PROMOTION_COMPLETED'
  AND al.event_time > NOW() - INTERVAL '24 hours'
  AND (sn.id IS NULL OR sn.snapshot_status != 'COMPLETED')
ORDER BY al.event_time DESC;
```

**Operator steps:**

1. Confirm the `ARCHIVE_PROMOTION_COMPLETED` event is genuine (not a test or compensating event) by checking `workflow_runs.status = 'FINALIZED'` for the run.

2. Check whether an analytics rebuild job was queued at all:

   ```sql
   SELECT id, status, started_at, completed_at, error_message
   FROM report_jobs
   WHERE report_type = 'ANALYTICS_REBUILD'
     AND metadata->>'workflow_run_id' = '<run_id>'
   ORDER BY started_at DESC;
   ```

3. If no rebuild job exists, the event subscription did not fire or the subscriber failed silently. Trigger the rebuild manually:

   ```
   report.rebuild_analytics_snapshot({
     workflow_run_id: '<run_id>',
     mode: 'FULL',
     trigger_reason: 'MANUAL_DRIFT_RECOVERY'
   })
   ```

4. If a rebuild job exists but failed (see Mode 1 for timeout recovery), address the failure and re-queue.

5. After the rebuild completes (`ANALYTICS_SNAPSHOT_REBUILT` emitted), trigger a dashboard cache refresh:

   ```
   report.refresh_dashboard_cache({ business_id: '<biz_id>' })
   ```

6. Verify the dashboard reflects the finalized period's data. The "Last updated" timestamp should advance and the period's finalized figures should be visible.

7. If this drift occurs repeatedly for the same business, check the event subscription registration for `ARCHIVE_PROMOTION_COMPLETED` → analytics rebuild. Query `event_subscriptions` for `event_type = 'ARCHIVE_PROMOTION_COMPLETED'` and confirm `is_active = true` and `subscriber = 'report.rebuild_analytics_snapshot'`.

---

## Monitoring signals

The following three audit events must be monitored in the alerting dashboard. Alerts should fire on any occurrence within a 5-minute evaluation window.

| Event | Severity | Alert condition |
|---|---|---|
| `ANALYTICS_SNAPSHOT_REBUILT` | LOW | Absence within 15 minutes of `ARCHIVE_PROMOTION_COMPLETED` is an anomaly |
| `REPORT_JOB_FAILED` | MEDIUM | Any occurrence; correlate with `report_type` for triage priority |
| `REPORT_DATA_SOURCE_FAILED` | MEDIUM | Any occurrence; correlate with `card_id` to identify the affected surface |

Note: `ANALYTICS_SNAPSHOT_REBUILT` is synonymous with `ANALYTICS_SNAPSHOT_REBUILT` for monitoring purposes — both reference the same rebuild completion lifecycle. The alerting dashboard should monitor `ANALYTICS_SNAPSHOT_REBUILT` per the canonical taxonomy.

Recommended alerting configuration: group `REPORT_JOB_FAILED` events by `report_type` in the alerting dashboard so that a burst of failures from one job type (e.g., all PDF render jobs) is surfaced as a single actionable alert rather than individual noise.

---

## Cross-references

- `analytics_snapshot_schema.md` — `analytics_snapshots` table structure, `snapshot_status` enum, rebuild trigger conditions
- `report_job_schema.md` — `report_jobs` table structure, `status` enum, `metadata` shape per `report_type`
- `dashboard_widget_config_schema.md` — `dashboard_cache` table structure, card configuration, data-source tool mapping
- `audit_event_taxonomy.md` — `ANALYTICS_SNAPSHOT_REBUILT`, `REPORT_JOB_FAILED`, `REPORT_DATA_SOURCE_FAILED`, `ARCHIVE_PROMOTION_COMPLETED`
