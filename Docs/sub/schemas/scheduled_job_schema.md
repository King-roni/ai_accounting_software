# Scheduled Job Schema

**Namespace:** engine / data  
**Table:** `scheduled_jobs`  
**Status:** Active  
**Last Updated:** 2026-05-17

---

## Overview

The `scheduled_jobs` table is the registry of recurring background jobs that run on fixed schedules. It is the source of truth for what jobs exist, their cron expressions, current active status, and the outcome of their most recent execution. Job execution is triggered by Supabase `pg_cron` and performed by Edge Functions or database procedures depending on the job type.

This table does not store individual run history — that is handled by `workflow_run_log_schema.md` and job-type-specific tables. This table holds only the latest run state per job.

---

## Enum Definitions

```sql
CREATE TYPE job_type_enum AS ENUM (
  'TTL_PURGE',
  'BANK_SYNC',
  'ARCHIVE_INTEGRITY_CHECK',
  'EXPORT_CLEANUP',
  'VIES_SYNC',
  'REPORT_GENERATION'
);

CREATE TYPE job_run_status_enum AS ENUM (
  'PENDING',
  'RUNNING',
  'SUCCESS',
  'FAILED',
  'SKIPPED'
);
```

### job_type_enum Values

| Value | Description |
|---|---|
| `TTL_PURGE` | Purges rows from time-limited tables (sessions, step-up tokens, draft invoices past stale window). |
| `BANK_SYNC` | Pulls latest transactions from the Nordigen bank feed adapter for all active business entities with connected accounts. |
| `ARCHIVE_INTEGRITY_CHECK` | Verifies hash-chain integrity on archived bundles. Samples a configurable percentage of bundles per run. |
| `EXPORT_CLEANUP` | Removes expired export files from the `export-temp` storage zone and marks corresponding `audit_log_exports` rows as expired. |
| `VIES_SYNC` | Refreshes VIES validation cache entries that are nearing their staleness threshold per `vendor_memory_staleness_policy.md`. |
| `REPORT_GENERATION` | Triggers pre-generation of scheduled reports (e.g., monthly summaries) for business entities with auto-report enabled. |

### job_run_status_enum Values

| Value | Description |
|---|---|
| `PENDING` | Job is registered but has not yet run (initial state or after reset). |
| `RUNNING` | Job is currently executing. If this status persists beyond twice the expected run duration, a stale-job alert fires. |
| `SUCCESS` | Last run completed without errors. |
| `FAILED` | Last run encountered an unrecoverable error. See `last_error_message` for details. |
| `SKIPPED` | Last scheduled invocation was skipped (e.g., previous run was still `RUNNING`, or job was paused mid-schedule). |

---

## Table Definition

```sql
CREATE TABLE scheduled_jobs (
  id                 uuid                  NOT NULL DEFAULT gen_uuid_v7(),
  job_name           text                  NOT NULL,
  job_type           job_type_enum         NOT NULL,
  cron_expression    text                  NOT NULL,
  last_run_at        timestamptz           NULL,
  last_run_status    job_run_status_enum   NOT NULL DEFAULT 'PENDING',
  last_error_message text                  NULL,
  next_run_at        timestamptz           NOT NULL,
  is_active          boolean               NOT NULL DEFAULT true,
  created_at         timestamptz           NOT NULL DEFAULT now(),
  updated_at         timestamptz           NOT NULL DEFAULT now(),

  CONSTRAINT scheduled_jobs_pkey PRIMARY KEY (id),
  CONSTRAINT scheduled_jobs_job_name_unique UNIQUE (job_name)
);
```

---

## Column Descriptions

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK. `gen_uuid_v7()`. |
| `job_name` | text | NOT NULL | Human-readable unique identifier. Convention: `{job_type_lowercase}_{qualifier}` e.g. `ttl_purge_nightly`, `bank_sync_hourly`. |
| `job_type` | job_type_enum | NOT NULL | Categorises the job for routing and alerting. |
| `cron_expression` | text | NOT NULL | Standard 5-field cron expression (minute, hour, day, month, weekday) in UTC. Validated on insert. |
| `last_run_at` | timestamptz | NULL | Timestamp when the most recent run started. NULL if job has never run. |
| `last_run_status` | job_run_status_enum | NOT NULL | Status of the most recent run. |
| `last_error_message` | text | NULL | Error message from last failed run. NULL if last run succeeded. Cleared on next successful run. |
| `next_run_at` | timestamptz | NOT NULL | Expected next execution time, computed from cron expression and current time. Updated after each run. |
| `is_active` | boolean | NOT NULL | When `false`, pg_cron will not trigger the job at its next scheduled time. Skipped invocations are recorded with status `SKIPPED`. |
| `created_at` | timestamptz | NOT NULL | Row creation timestamp. |
| `updated_at` | timestamptz | NOT NULL | Updated via trigger on every modification. |

---

## Indexes

```sql
-- Fast lookup by job name (also enforced unique)
-- Covered by UNIQUE constraint index on job_name

-- Operational: find overdue or stuck jobs
CREATE INDEX idx_scheduled_jobs_next_run_at
  ON scheduled_jobs (next_run_at)
  WHERE is_active = true;

-- Monitoring: find recently failed jobs
CREATE INDEX idx_scheduled_jobs_last_run_status
  ON scheduled_jobs (last_run_status)
  WHERE last_run_status = 'FAILED';
```

---

## Supabase pg_cron Integration

Jobs are registered in pg_cron with the same `job_name` as a cron job name. The pg_cron job calls a database function or invokes a Supabase Edge Function via `net.http_post`. Example:

```sql
SELECT cron.schedule(
  'ttl_purge_nightly',
  '0 2 * * *',
  $$SELECT net.http_post(
      url := 'https://{project_ref}.supabase.co/functions/v1/ttl-purge',
      headers := '{"Authorization": "Bearer ' || current_setting('app.service_role_key') || '"}'::jsonb
  )$$
);
```

When a job is deactivated (`is_active = false`), the corresponding pg_cron schedule should also be unscheduled via `cron.unschedule(job_name)`. This is handled by an `AFTER UPDATE` trigger on the `scheduled_jobs` table that calls `cron.unschedule` when `is_active` transitions from `true` to `false`, and `cron.schedule` when it transitions back.

`next_run_at` is recomputed and written back by the Edge Function at the end of each successful run using the `cron_expression` and `pg_cron.cron_next_execution()` helper.

---

## Failure Alerting

When a job completes with `last_run_status = 'FAILED'`, a database trigger emits a `JOB.RUN_FAILED` audit event containing `job_name`, `job_type`, and `last_error_message`. This event routes through `security_alert_routing_policy.md` to the `#ops-alerts` Slack channel with severity HIGH.

A secondary stale-job monitor runs as part of the `TTL_PURGE` job: it queries for any `scheduled_jobs` row where `last_run_status = 'RUNNING'` and `last_run_at < now() - interval '2 hours'`. Matches are flagged as `FAILED` and a `JOB.RUN_STALE` audit event is emitted.

---

## Related Documents

- `schemas/workflow_run_log_schema.md` — Detailed per-run execution log
- `schemas/audit_log_export_schema.md` — `EXPORT_CLEANUP` job target table
- `policies/data_retention_policy.md` — TTL windows that drive `TTL_PURGE` job configuration
- `integrations/` — Bank feed adapter used by `BANK_SYNC` job
- `reference/supabase_project_config.md` — pg_cron configuration and scheduling environment
- `policies/archive_integrity_policy.md` — Integrity check sampling rate used by `ARCHIVE_INTEGRITY_CHECK`
