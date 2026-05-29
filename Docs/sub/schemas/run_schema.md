# Run Schema

**Block:** engine
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

The `runs` table is the central record for each bookkeeping processing cycle. A run represents one complete pass through the intake, classification, matching, ledger posting, VAT calculation, and finalization pipeline for a specific business entity and VAT period. Every significant operation in the processing pipeline references a run record for traceability.

Runs are created via `engine.create_run`, progressed through phases via `engine.advance_phase`, and finalized via `engine.finalize_run`. All state transitions are audit-logged. The run record is the authoritative source of truth for pipeline progress and is referenced by review queue issues, audit events, ledger entries, and archive bundles.

## DDL

```sql
-- Status enum
CREATE TYPE run_status_enum AS ENUM (
  'CREATED',
  'RUNNING',
  'PAUSED',
  'REVIEW_HOLD',
  'AWAITING_APPROVAL',
  'FINALIZING',
  'FINALIZED',
  'FAILED',
  'CANCELLED',
  'COMPENSATING'
);

-- Phase enum
CREATE TYPE run_phase_enum AS ENUM (
  'INTAKE',
  'PARSE',
  'CLASSIFY',
  'MATCH',
  'LEDGER',
  'VAT',
  'FINALIZE',
  'ARCHIVE'
);

-- Runs table
CREATE TABLE runs (
  id                  UUID          NOT NULL DEFAULT gen_uuid_v7(),
  business_id         UUID          NOT NULL REFERENCES business_entities(id),
  period_id           UUID          NOT NULL REFERENCES vat_periods(id),
  run_type            TEXT          NOT NULL CHECK (run_type IN ('OUT', 'IN', 'COMBINED')),
  status              run_status_enum NOT NULL DEFAULT 'CREATED',
  current_phase       run_phase_enum,

  -- Assignment
  created_by          UUID          NOT NULL REFERENCES auth.users(id),
  assigned_to         UUID          REFERENCES auth.users(id),

  -- Timestamps for lifecycle events
  started_at          TIMESTAMPTZ,
  paused_at           TIMESTAMPTZ,
  paused_reason       TEXT,
  resumed_at          TIMESTAMPTZ,
  completed_at        TIMESTAMPTZ,
  failed_at           TIMESTAMPTZ,
  failure_reason      TEXT,
  compensating_since  TIMESTAMPTZ,

  -- Metadata for extension without schema changes
  metadata            JSONB         NOT NULL DEFAULT '{}',

  -- Standard audit columns
  created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now()
);

ALTER TABLE runs ADD CONSTRAINT runs_pkey PRIMARY KEY (id);
```

## Indexes

```sql
-- Filtered queries by business + status (dashboard, queue views)
CREATE INDEX idx_runs_business_status
  ON runs (business_id, status);

-- Queries for runs in a specific period (period lock checks, VAT return association)
CREATE INDEX idx_runs_business_period
  ON runs (business_id, period_id);

-- Accountant workqueue: find RUNNING runs assigned to a specific user
CREATE INDEX idx_runs_assigned_running
  ON runs (assigned_to)
  WHERE status = 'RUNNING';
```

## Row-Level Security

```sql
ALTER TABLE runs ENABLE ROW LEVEL SECURITY;

-- Members can read runs belonging to their business
CREATE POLICY runs_select ON runs
  FOR SELECT
  USING (
    business_id IN (
      SELECT business_id FROM org_members
      WHERE user_id = auth.uid()
        AND status = 'ACTIVE'
    )
  );

-- Only ACCOUNTANT and ADMIN roles can insert runs
CREATE POLICY runs_insert ON runs
  FOR INSERT
  WITH CHECK (
    business_id IN (
      SELECT business_id FROM org_members
      WHERE user_id = auth.uid()
        AND status = 'ACTIVE'
        AND role IN ('ACCOUNTANT', 'ADMIN')
    )
  );

-- Updates routed through Edge Functions using service role;
-- direct UPDATE from client role is blocked
CREATE POLICY runs_update ON runs
  FOR UPDATE
  USING (false);

-- Direct DELETE blocked; cancellation goes through engine.cancel_run
CREATE POLICY runs_delete ON runs
  FOR DELETE
  USING (false);
```

All state-modifying operations on run records are performed by Edge Functions using the service role, which bypasses RLS. The `runs_update` and `runs_delete` policies block direct client-side writes, ensuring all mutations go through the tool layer where preconditions and audit logging are enforced.

## Column Reference

| Column | Type | Nullable | Description |
|---|---|---|---|
| id | UUID | No | Primary key. Generated via `gen_uuid_v7()` for time-ordered insertion. |
| business_id | UUID | No | FK to `business_entities(id)`. Identifies the tenant that owns this run. |
| period_id | UUID | No | FK to `vat_periods(id)`. The VAT period this run processes. |
| run_type | TEXT | No | `OUT` (outgoing invoices only), `IN` (incoming/expense documents only), `COMBINED` (both). |
| status | run_status_enum | No | Current lifecycle status. See Status Lifecycle section. |
| current_phase | run_phase_enum | Yes | Active pipeline phase. NULL when status is CREATED, FINALIZED, FAILED, or CANCELLED. |
| created_by | UUID | No | FK to `auth.users(id)`. User who created the run. |
| assigned_to | UUID | Yes | FK to `auth.users(id)`. Accountant currently responsible for this run. NULL if unassigned. |
| started_at | TIMESTAMPTZ | Yes | Timestamp when the run transitioned from CREATED to RUNNING. |
| paused_at | TIMESTAMPTZ | Yes | Timestamp of the most recent PAUSE transition. |
| paused_reason | TEXT | Yes | Human-readable explanation for the pause. Set on PAUSE, cleared on RESUME. |
| resumed_at | TIMESTAMPTZ | Yes | Timestamp of the most recent RESUME transition. |
| completed_at | TIMESTAMPTZ | Yes | Timestamp when the run reached FINALIZED status. |
| failed_at | TIMESTAMPTZ | Yes | Timestamp when the run transitioned to FAILED. |
| failure_reason | TEXT | Yes | System-generated or operator-provided description of the failure cause. |
| compensating_since | TIMESTAMPTZ | Yes | Timestamp when compensation (rollback) began. Set on COMPENSATING transition. |
| metadata | JSONB | No | Extension field for run-type-specific configuration and runtime state. Default `{}`. |
| created_at | TIMESTAMPTZ | No | Insertion timestamp. Managed by the database. |
| updated_at | TIMESTAMPTZ | No | Last update timestamp. Updated on every state change. |

## Status Lifecycle

Valid status transitions:

```
CREATED → RUNNING          (engine.start_run)
RUNNING → PAUSED           (engine.pause_run)
RUNNING → REVIEW_HOLD      (review_queue.create_issue with BLOCKING severity)
RUNNING → AWAITING_APPROVAL (engine.advance_phase at approval gate)
RUNNING → FINALIZING       (engine.finalize_run preconditions met)
RUNNING → FAILED           (unrecoverable error in phase)
RUNNING → COMPENSATING     (rollback triggered)
PAUSED → RUNNING           (engine.resume_run)
PAUSED → CANCELLED         (engine.cancel_run)
REVIEW_HOLD → RUNNING      (review_queue.resolve_issue clears all BLOCKING issues)
REVIEW_HOLD → CANCELLED    (engine.cancel_run)
AWAITING_APPROVAL → RUNNING (approval granted)
AWAITING_APPROVAL → CANCELLED (approval rejected or expired)
FINALIZING → FINALIZED     (finalization completes)
FINALIZING → FAILED        (finalization error)
COMPENSATING → FAILED      (compensation completes — treated as failed run)
COMPENSATING → CANCELLED   (compensation completes — operator-initiated)
```

Terminal statuses (no further transitions): `FINALIZED`, `FAILED`, `CANCELLED`.

The `COMPENSATING` status indicates that the system is actively rolling back ledger entries and other side effects from a partially completed run. Compensation completion always results in either FAILED or CANCELLED depending on the initiating cause. See `out_phase_compensation_policy.md` for compensation procedures.

## run_type Semantics

| Value | Processes | Notes |
|---|---|---|
| OUT | Outgoing invoices, client receipts | Standard outgoing workflow; see `tool_out_workflow_start.md` |
| IN | Incoming expense documents, supplier invoices | Incoming workflow; see `tool_in_workflow_start.md` |
| COMBINED | Both OUT and IN in a single run | Used for monthly combined bookkeeping cycles |

Only one run per `(business_id, period_id, run_type)` combination may be in a non-terminal status at any time. A second run of the same type for the same period cannot be created until the existing run reaches FINALIZED, FAILED, or CANCELLED.

## metadata Field

The `metadata` JSONB column stores run-type-specific configuration and intermediate state that does not warrant a dedicated column. It is not queryable via index (except via GIN index if added) and should not be used for high-cardinality filter predicates.

Common metadata keys:

```json
{
  "phase_config": {
    "skip_vies": false,
    "ai_tier_override": null
  },
  "phase_checkpoints": {
    "INTAKE": { "completed_at": "<timestamp>", "row_count": 142 },
    "PARSE": { "completed_at": "<timestamp>", "row_count": 138 }
  },
  "flags": {
    "manual_override_applied": false,
    "compensating_for_run_id": null
  }
}
```

The structure of `metadata` is not enforced by the database. Edge Functions that read or write metadata keys are responsible for handling missing keys gracefully.

## Data Zone and Retention

The `runs` table is in the **Operational zone**. Finalized run records are retained for **7 years** from creation per `data_retention_policy.md`.

Run records in terminal status (FINALIZED, FAILED, CANCELLED) with `completed_at` or `failed_at` older than 7 years are eligible for deletion by the scheduled retention cleanup job. The deletion is blocked if the run is referenced by an active archive bundle.

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| RUN_CREATED | LOW | New run record inserted |
| RUN_STARTED | LOW | Status transitions CREATED → RUNNING |
| RUN_PAUSED | LOW | Status transitions any → PAUSED |
| RUN_RESUMED | LOW | Status transitions PAUSED → RUNNING |
| RUN_FINALIZED | LOW | Status transitions FINALIZING → FINALIZED |
| RUN_FAILED | HIGH | Status transitions any → FAILED |
| RUN_CANCELLED | MEDIUM | Status transitions any → CANCELLED |
| RUN_COMPENSATING | HIGH | Status transitions any → COMPENSATING |

All audit events are written to the append-only audit log in the same transaction as the status update. If the audit write fails, the status update rolls back. See `audit_log_schema.md` and `audit_log_policies.md`.

## Integration Points

This table is referenced by virtually every tool in the processing pipeline. Key integrations:

- **tool_run_create.md** — Creates the initial run record (status = CREATED)
- **tool_run_assign.md** — Updates `assigned_to`
- **tool_run_pause.md** — Transitions to PAUSED, sets `paused_at` and `paused_reason`
- **tool_run_resume.md** — Transitions to RUNNING, sets `resumed_at`
- **tool_run_cancel.md** — Transitions to CANCELLED
- **tool_run_finalize.md** — Transitions FINALIZING → FINALIZED, sets `completed_at`
- **tool_run_advance_phase.md** — Updates `current_phase`
- **tool_review_queue_resolve.md** — May trigger REVIEW_HOLD → RUNNING when last BLOCKING issue resolved
- **schemas/review_issues_schema.md** — `review_issues.run_id` FK references `runs.id`
- **schemas/ledger_entry_schema.md** — `ledger_entries.run_id` FK references `runs.id`
- **schemas/archive_schema.md** — `archive_bundles.run_id` FK references `runs.id`
- **schemas/workflow_run_schema.md** — Workflow metadata associated with a run

## Related Documents

- `tools/tool_run_create.md` — Run creation tool
- `tools/tool_run_assign.md` — Run assignment tool
- `tools/tool_run_pause.md` — Run pause tool
- `tools/tool_run_resume.md` — Run resume tool
- `tools/tool_run_cancel.md` — Run cancellation tool
- `tools/tool_run_finalize.md` — Run finalization tool
- `tools/tool_run_advance_phase.md` — Phase advance tool
- `tools/tool_out_workflow_start.md` — Outgoing workflow entry point
- `tools/tool_in_workflow_start.md` — Incoming workflow entry point
- `policies/workflow_run_creation_policy.md` — Run creation preconditions and concurrency rules
- `policies/out_phase_compensation_policy.md` — Compensation (rollback) procedures
- `policies/out_run_concurrency_policy.md` — One-run-per-period enforcement
- `policies/data_retention_policy.md` — Retention rules for Operational zone
- `reference/run_phase_enum.md` — Full phase enum reference
- `reference/workflow_state_enum.md` — Status enum reference
- `schemas/audit_log_schema.md` — Audit log table
