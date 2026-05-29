# Schema: report_jobs

**Namespace:** report
**Table:** report_jobs
**Purpose:** Tracks asynchronous report generation requests. Each call to
`report.generate` inserts one row. The row moves through `QUEUED → RUNNING → COMPLETED`
on success, or `QUEUED → RUNNING → FAILED` on error. Completed report files are stored
in the export-temp zone and expire 24 hours after completion. Re-generating a report
creates a new row; the prior row is retained for audit purposes.

---

## Enum Definitions

```sql
-- Not run_status_enum. This is a separate job-scoped enum. COMPLETED is permitted
-- here because report jobs are not workflow runs and do not use run_status_enum.
CREATE TYPE report_job_status_enum AS ENUM (
  'QUEUED',
  'RUNNING',
  'COMPLETED',
  'FAILED'
);

CREATE TYPE report_type_enum AS ENUM (
  'PROFIT_LOSS',
  'BALANCE_SHEET',
  'VAT_SUMMARY',
  'LEDGER_EXPORT'
);

CREATE TYPE report_output_format_enum AS ENUM (
  'PDF',
  'XLSX',
  'JSON'
);
```

---

## Table Definition

```sql
CREATE TABLE report_jobs (
  id                  uuid        PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_entity_id  uuid        NOT NULL
                                    REFERENCES business_entities(id)
                                    ON DELETE RESTRICT,
  report_type         report_type_enum NOT NULL,
  period_from         date        NOT NULL,
  period_to           date        NOT NULL,
  output_format       report_output_format_enum NOT NULL,
  status              report_job_status_enum NOT NULL DEFAULT 'QUEUED',
  storage_path        text,
  error_message       text,
  requested_by        uuid        NOT NULL
                                    REFERENCES org_members(id)
                                    ON DELETE RESTRICT,
  queued_at           timestamptz NOT NULL DEFAULT now(),
  started_at          timestamptz,
  completed_at        timestamptz,

  CONSTRAINT chk_period_order
    CHECK (period_from <= period_to),

  CONSTRAINT chk_storage_path_on_completed
    CHECK (
      status != 'COMPLETED' OR storage_path IS NOT NULL
    ),

  CONSTRAINT chk_error_message_on_failed
    CHECK (
      status != 'FAILED' OR error_message IS NOT NULL
    )
);
```

---

## Column Reference

| Column | Type | Nullable | Notes |
|---|---|---|---|
| id | uuid | NO | PK via gen_uuid_v7(); monotonically increasing |
| business_entity_id | uuid FK | NO | Tenant scope; RLS-enforced |
| report_type | report_type_enum | NO | PROFIT_LOSS, BALANCE_SHEET, VAT_SUMMARY, or LEDGER_EXPORT |
| period_from | date | NO | Start of the reporting period (inclusive) |
| period_to | date | NO | End of the reporting period (inclusive); must be >= period_from |
| output_format | report_output_format_enum | NO | PDF, XLSX, or JSON |
| status | report_job_status_enum | NO | QUEUED on insert; updated by async worker |
| storage_path | text | YES | Path in export-temp zone; set on COMPLETED. Format: `exports/{business_entity_id}/{id}/{report_type}.{ext}` |
| error_message | text | YES | Populated on FAILED; mandatory (enforced by CHECK) |
| requested_by | uuid FK | NO | References `org_members(id)`; the user who triggered the job |
| queued_at | timestamptz | NO | Row insert time; defaults to now() |
| started_at | timestamptz | YES | Set when worker transitions row to RUNNING |
| completed_at | timestamptz | YES | Set when status transitions to COMPLETED or FAILED |

---

## Check Constraints

### `chk_storage_path_on_completed`

When `status = 'COMPLETED'`, `storage_path` must be non-null. This prevents the worker
from marking a job complete without writing an output path. Files in the export-temp
zone expire 24 hours after upload per `report_generation_policy.md`.

### `chk_error_message_on_failed`

When `status = 'FAILED'`, `error_message` must be non-null. This ensures diagnostic
information is always available for operator investigation.

---

## Indexes

```sql
-- Primary access pattern: recent jobs for a business
CREATE INDEX idx_report_jobs_business_queued_at
  ON report_jobs(business_entity_id, queued_at DESC);

-- Support polling: in-progress jobs for a business
CREATE INDEX idx_report_jobs_business_status
  ON report_jobs(business_entity_id, status)
  WHERE status IN ('QUEUED', 'RUNNING');

-- Support concurrent limit check (see report_generation_policy.md)
CREATE INDEX idx_report_jobs_queued_count
  ON report_jobs(business_entity_id)
  WHERE status = 'QUEUED';
```

---

## Row-Level Security

```sql
ALTER TABLE report_jobs ENABLE ROW LEVEL SECURITY;

-- SELECT: org members may read jobs for their business
CREATE POLICY report_jobs_select
  ON report_jobs FOR SELECT
  USING (
    business_entity_id = auth.business_entity_id_for_session()
  );

-- INSERT: gated through report.generate tool (system role required)
CREATE POLICY report_jobs_insert
  ON report_jobs FOR INSERT
  WITH CHECK (
    current_setting('app.system_role_active', true) = 'true'
  );

-- UPDATE: async worker only
CREATE POLICY report_jobs_update_worker
  ON report_jobs FOR UPDATE
  USING (
    current_setting('app.report_worker_active', true) = 'true'
  );

-- DELETE: blocked for all application roles
CREATE POLICY report_jobs_no_delete
  ON report_jobs FOR DELETE
  USING (false);
```

---

## Status Transition Notes

`report_job_status_enum` is intentionally separate from `run_status_enum`. Report jobs
are not workflow runs. The COMPLETED state is permitted here and does not conflict with
the prohibition on COMPLETED in `run_status_enum`. Do not attempt to use `run_status_enum`
for report jobs or introduce FINALIZED/CANCELLED into this enum.

---

## Audit Events

| Event | Severity | When |
|---|---|---|
| REPORT_JOB_QUEUED | LOW | Row inserted (emitted by report.generate) |
| REPORT_JOB_COMPLETED | LOW | status transitions to COMPLETED |
| REPORT_JOB_FAILED | MEDIUM | status transitions to FAILED |

All three events use the DOMAIN_PAST_VERB naming pattern. Domain: `REPORT`.

---

## Related Documents

- `tool_report_generate.md` — tool that inserts rows into this table and enqueues work
- `report_generation_policy.md` — permission rules, lock requirements, concurrent limit,
  TTL, and re-generation rules
- `report_generation_failure_runbook.md` — operator steps for FAILED jobs
- `period_lock_schema.md` — locks checked before QUEUED insert (PDF/XLSX formats)
- `export_pipeline_policy.md` — export-temp zone TTL, storage_path format, and access
- `audit_event_naming_convention_policy.md` — REPORT_JOB_* event taxonomy
- `org_member_schema.md` — FK target for requested_by
