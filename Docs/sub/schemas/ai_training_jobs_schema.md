# Schema: ai_training_jobs

**Block:** AI Classification
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`ai_training_jobs` tracks every execution of the AI model training pipeline. Each row represents one discrete training run: a batch of feedback rows selected from `ai_training_feedback`, shipped to the training system, and used to produce a new or updated model version.

Rows are created either by the scheduled training job (in which case `triggered_by` is NULL) or manually by an `org:owner` with platform-level access initiating a training run from the admin interface. The job lifecycle moves through QUEUED → RUNNING → COMPLETED or FAILED. There is no partial-success state: a job either completes and produces a model version target, or it fails with an error message.

This table is append-only in practice. Rows are never updated after reaching COMPLETED or FAILED. RUNNING rows are updated in place only by the training job process itself (setting `started_at`, `completed_at`, `model_version_target`, `error_message`).

---

## Enum Definition

```sql
CREATE TYPE ai_job_status_enum AS ENUM (
  'QUEUED',
  'RUNNING',
  'COMPLETED',
  'FAILED'
);
```

- `QUEUED` — job has been created and is waiting for the training worker to pick it up.
- `RUNNING` — the training worker has claimed the job and is actively processing feedback rows.
- `COMPLETED` — the job finished successfully. `model_version_target` is set. `completed_at` is set.
- `FAILED` — the job encountered an unrecoverable error. `error_message` is set. `completed_at` is set to the failure time.

Note: this enum is `ai_job_status_enum`, not `run_status_enum`. COMPLETED is a valid terminal state here. The distinction matters because workflow runs use a separate `run_status_enum` that does not include COMPLETED (workflow runs use FINALISED).

---

## DDL

```sql
CREATE TABLE ai_training_jobs (
  id                    UUID          NOT NULL DEFAULT gen_uuid_v7(),
  job_name              TEXT          NOT NULL,
  status                ai_job_status_enum NOT NULL DEFAULT 'QUEUED',
  feedback_row_count    INTEGER       NOT NULL DEFAULT 0,
  model_version_target  TEXT              NULL,
  triggered_by          UUID              NULL
                          REFERENCES org_members(id)
                          ON DELETE SET NULL,
  queued_at             TIMESTAMPTZ   NOT NULL DEFAULT now(),
  started_at            TIMESTAMPTZ       NULL,
  completed_at          TIMESTAMPTZ       NULL,
  error_message         TEXT              NULL,

  CONSTRAINT ai_training_jobs_pkey PRIMARY KEY (id),

  CONSTRAINT ai_training_jobs_job_name_nonempty
    CHECK (length(trim(job_name)) > 0),

  CONSTRAINT ai_training_jobs_feedback_row_count_nonneg
    CHECK (feedback_row_count >= 0),

  CONSTRAINT ai_training_jobs_completed_requires_started
    CHECK (
      completed_at IS NULL
      OR started_at IS NOT NULL
    ),

  CONSTRAINT ai_training_jobs_running_requires_started
    CHECK (
      status != 'RUNNING'
      OR started_at IS NOT NULL
    ),

  CONSTRAINT ai_training_jobs_completed_requires_version
    CHECK (
      status != 'COMPLETED'
      OR model_version_target IS NOT NULL
    ),

  CONSTRAINT ai_training_jobs_failed_requires_error
    CHECK (
      status != 'FAILED'
      OR error_message IS NOT NULL
    )
);
```

`triggered_by` uses `ON DELETE SET NULL`. If the org member who triggered the job is removed from the organisation, the job record is preserved — training history must not be orphaned. The NULL value indicates automated trigger when no human initiated the job; after a member deletion it is ambiguous, but the `queued_at` timestamp and `job_name` provide sufficient audit context.

`feedback_row_count` is set at job creation time, reflecting the number of `ai_training_feedback` rows selected for this training run. It does not change after the job is RUNNING.

`model_version_target` is the version identifier assigned by the training system upon successful completion. It is opaque to this schema — the format is defined by the external training pipeline. NULL on QUEUED/RUNNING/FAILED rows.

---

## Indexes

```sql
CREATE INDEX idx_ai_training_jobs_status
  ON ai_training_jobs (status);

CREATE INDEX idx_ai_training_jobs_queued_at
  ON ai_training_jobs (queued_at DESC);

CREATE INDEX idx_ai_training_jobs_triggered_by
  ON ai_training_jobs (triggered_by)
  WHERE triggered_by IS NOT NULL;

CREATE INDEX idx_ai_training_jobs_status_queued
  ON ai_training_jobs (queued_at ASC)
  WHERE status = 'QUEUED';

CREATE INDEX idx_ai_training_jobs_completed_at
  ON ai_training_jobs (completed_at DESC)
  WHERE completed_at IS NOT NULL;
```

The partial index on `status = 'QUEUED'` is the hot path for the training worker polling for work. It stays small because jobs move out of QUEUED quickly.

---

## Column Reference

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | UUID | No | PK, generated with `gen_uuid_v7()` |
| `job_name` | TEXT | No | Human-readable name for the training run (e.g. `scheduled-2025-01-15` or `manual-hotfix`). |
| `status` | ai_job_status_enum | No | Current job lifecycle state. Default QUEUED. |
| `feedback_row_count` | INTEGER | No | Count of `ai_training_feedback` rows included in this job. Set at creation. |
| `model_version_target` | TEXT | Yes | Version identifier returned by the training system on COMPLETED. NULL otherwise. |
| `triggered_by` | UUID | Yes | FK to `org_members(id)`. NULL if automated. ON DELETE SET NULL. |
| `queued_at` | TIMESTAMPTZ | No | Timestamp when the job was created and queued. |
| `started_at` | TIMESTAMPTZ | Yes | Timestamp when the training worker began processing. NULL until RUNNING. |
| `completed_at` | TIMESTAMPTZ | Yes | Timestamp of terminal state (COMPLETED or FAILED). NULL until terminal. |
| `error_message` | TEXT | Yes | Error detail if status = FAILED. NULL otherwise. |

---

## Row-Level Security

```sql
ALTER TABLE ai_training_jobs ENABLE ROW LEVEL SECURITY;

-- Platform admin (service role) manages all rows
-- No business-entity-scoped RLS: training jobs are platform-level, not per-tenant

-- Members with platform admin access may read
CREATE POLICY ai_training_jobs_select_platform_admin
  ON ai_training_jobs
  FOR SELECT
  USING (
    (auth.jwt() ->> 'platform_role') = 'platform_admin'
  );
```

`ai_training_jobs` is a platform-level table, not tenant-scoped. Regular business entity members cannot read or write this table. All writes occur via the service role (training worker process). Platform admins may read for observability.

---

## Business Rules

1. A new QUEUED job must not be created if another QUEUED or RUNNING job already exists. The training worker enforces a single-job concurrency limit.
2. `feedback_row_count` must be greater than zero. A training job with no feedback rows is a no-op and must be rejected at creation time.
3. Only the service role (training worker) may transition a job from QUEUED to RUNNING, or from RUNNING to COMPLETED/FAILED. Application code may only create QUEUED rows.
4. `job_name` must be unique per calendar day. The naming convention is `{trigger}-{YYYY-MM-DD}[-{sequence}]`.
5. Once COMPLETED or FAILED, a row is immutable. No UPDATE is permitted by application code.

---

## Audit Events

| Event | Trigger |
|---|---|
| `AI_TRAINING_JOB_QUEUED` | Row inserted with status = QUEUED |
| `AI_TRAINING_JOB_STARTED` | Status transitions QUEUED → RUNNING |
| `AI_TRAINING_JOB_COMPLETED` | Status transitions RUNNING → COMPLETED |
| `AI_TRAINING_JOB_FAILED` | Status transitions RUNNING → FAILED |

All events are written to `audit_logs` by the training worker. The `triggered_by` value (or NULL for automated) is included in each event payload.

---

## Related Documents

- `ai_training_feedback_schema.md` — source rows consumed by training jobs
- `ai_classification_config_schema.md` — model configuration updated after successful training
- `ai_model_versioning_policy.md` — version lifecycle and rollback rules
- `ai_usage_records_schema.md` — runtime usage tracked separately from training
- `audit_log_schema.md` — audit event target for job lifecycle events
- `org_member_schema.md` — FK target for triggered_by
- `scheduled_job_schema.md` — scheduling configuration for automated training runs
