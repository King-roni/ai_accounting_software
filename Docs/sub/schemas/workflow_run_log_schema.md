# Workflow Run Log Schema

**Namespace:** engine  
**Block:** 03 — Workflow Engine  
**Category:** Schemas  
**Stage:** 4 sub-doc (Layer 2)

---

## Overview

`workflow_run_logs` is an append-only event log capturing state transitions and significant events that occur within a single workflow run. Every phase entry, phase exit, gate evaluation, tool invocation result, actor action, and error event is written here as an immutable row. The table is the authoritative record for post-run forensic analysis and the primary input for the run-history UI.

`workflow_run_logs` is distinct from `audit_logs`. The audit log is the tamper-evident, cross-domain record of business-level events. `workflow_run_logs` is the operational event stream for a single run, surfaced to tools and the review UI. Both are append-only; neither permits UPDATE or DELETE.

---

## 1. Enum Definitions

```sql
CREATE TYPE log_event_type_enum AS ENUM (
    -- Phase lifecycle
    'PHASE_ENTERED',
    'PHASE_EXITED',
    'GATE_EVALUATED',
    'GATE_HELD',
    'GATE_PASSED',

    -- Run lifecycle
    'RUN_STARTED',
    'RUN_PAUSED',
    'RUN_RESUMED',
    'RUN_CANCELLED',
    'RUN_FAILED',
    'RUN_COMPENSATION_STARTED',
    'RUN_COMPENSATION_COMPLETED',
    'RUN_FINALIZATION_STARTED',
    'RUN_FINALIZED',

    -- Approval
    'APPROVAL_REQUESTED',
    'APPROVAL_GRANTED',
    'APPROVAL_REJECTED',
    'APPROVAL_EXPIRED',

    -- Review queue interaction
    'REVIEW_HOLD_ENTERED',
    'REVIEW_HOLD_CLEARED',

    -- Tool execution
    'TOOL_INVOKED',
    'TOOL_COMPLETED',
    'TOOL_FAILED',
    'TOOL_RETRIED',

    -- Actor-driven events
    'MANUAL_OVERRIDE',
    'COMMENT_ADDED',
    'CONFIGURATION_CHANGED',

    -- Error and warning
    'ERROR_RECORDED',
    'WARNING_RECORDED'
);
```

---

## 2. Table Definition

```sql
CREATE TABLE workflow_run_logs (
    id               uuid        PRIMARY KEY DEFAULT gen_uuid_v7(),
    run_id           uuid        NOT NULL REFERENCES workflow_runs(workflow_run_id) ON DELETE RESTRICT,
    phase            run_phase_enum,                    -- NULL for run-level events not scoped to a phase
    event_type       log_event_type_enum NOT NULL,
    payload          jsonb       NOT NULL DEFAULT '{}',
    actor_id         uuid        REFERENCES org_members(id) ON DELETE SET NULL,  -- NULL for system-originated events
    occurred_at      timestamptz NOT NULL DEFAULT now()
);
```

### 2.1 Column Notes

- **id** — `gen_uuid_v7()` provides monotonically increasing IDs with millisecond-precision time embedding, ensuring natural sort order matches insertion order without a secondary sort key on `occurred_at`.
- **run_id** — foreign key to `workflow_runs(workflow_run_id)`. `ON DELETE RESTRICT` prevents a run from being deleted while log rows exist; runs are never hard-deleted in the Operational zone.
- **phase** — nullable. Set for phase-scoped events (`PHASE_ENTERED`, `GATE_EVALUATED`, `TOOL_INVOKED`, etc.). NULL for run-level events (`RUN_STARTED`, `RUN_FINALIZED`, `APPROVAL_GRANTED`).
- **event_type** — typed enum. Adding new event types requires a migration; ad hoc string values are prohibited. Use `payload` for event-specific detail, not event_type proliferation.
- **payload** — JSONB object. Schema varies per `event_type`. Payload schemas are documented in `audit_event_payload_schemas.md`. Required top-level keys per event type are enforced by the tool layer, not a DB CHECK constraint (payload complexity would make CHECK constraints unmaintainable).
- **actor_id** — NULL for all system-originated events (tool invocations, automatic gate evaluations). Non-null only when a human org member directly triggered the event (approval, comment, manual override, pause).
- **occurred_at** — server-side timestamp. Never set by the caller; always `DEFAULT now()`. Callers must not pass `occurred_at` in INSERT statements.

---

## 3. Indexes

```sql
-- Primary access pattern: all log entries for a run, in order
CREATE INDEX idx_workflow_run_logs_run_occurred
    ON workflow_run_logs (run_id, occurred_at ASC);

-- Phase-scoped queries (e.g., all events in the CLASSIFICATION phase of a run)
CREATE INDEX idx_workflow_run_logs_run_phase
    ON workflow_run_logs (run_id, phase)
    WHERE phase IS NOT NULL;

-- Event type queries (e.g., find all GATE_HELD events across a run)
CREATE INDEX idx_workflow_run_logs_run_event_type
    ON workflow_run_logs (run_id, event_type);

-- Actor queries (e.g., all actions taken by a specific org member within a run)
CREATE INDEX idx_workflow_run_logs_actor
    ON workflow_run_logs (actor_id, occurred_at DESC)
    WHERE actor_id IS NOT NULL;
```

---

## 4. Row-Level Security

`workflow_run_logs` is covered by Supabase RLS. The policies enforce:

1. **INSERT allowed** — any tool operating within the correct `business_id` context may insert. The tool layer is responsible for validating that `run_id` belongs to the calling business before inserting.
2. **SELECT allowed** — org members may read log rows for runs belonging to their business.
3. **UPDATE prohibited** — no policy permits UPDATE. Any UPDATE attempt is rejected by the absence of a permitting policy (RLS default-deny).
4. **DELETE prohibited** — no policy permits DELETE. `workflow_run_logs` rows are permanent for the lifetime of the run. Run-level archival (when a run moves to the Archive zone) copies logs to the archive bundle and does not delete from the operational table until the Operational zone 7-year retention window expires.

```sql
ALTER TABLE workflow_run_logs ENABLE ROW LEVEL SECURITY;

-- Read: org members see logs for their business's runs
CREATE POLICY wrl_select_business_isolation
    ON workflow_run_logs
    FOR SELECT
    USING (
        run_id IN (
            SELECT workflow_run_id FROM workflow_runs
            WHERE business_id = (SELECT current_setting('app.business_id')::uuid)
        )
    );

-- Insert: tool service role only
CREATE POLICY wrl_insert_service_role
    ON workflow_run_logs
    FOR INSERT
    WITH CHECK (true);  -- business_id scoping enforced at the tool layer
```

The service role bypass applies only to INSERT. No UPDATE or DELETE policy exists; the table is structurally INSERT-only at the RLS layer.

---

## 5. Immutability Rules

- No tool, migration, or operator script may issue `UPDATE` or `DELETE` on `workflow_run_logs` rows.
- If an event was logged in error (e.g., a TOOL_COMPLETED followed immediately by a TOOL_FAILED for the same invocation due to a retry race), the correct remediation is to insert a `WARNING_RECORDED` or `ERROR_RECORDED` row noting the correction, not to delete or amend the original row.
- Hash chain integrity for the audit system is computed over `audit_logs`, not `workflow_run_logs`. `workflow_run_logs` does not participate in the hash chain. Its immutability is enforced by RLS and application convention only.
- Archive bundles produced at run finalization include a snapshot of all `workflow_run_logs` rows for the run, serialized to JSONL within the bundle. See `archive_bundle_layout_schema.md`.

---

## 6. How Tools Write Log Entries

All workflow engine tools write log entries via the `engine.log_run_event` helper tool rather than inserting directly into `workflow_run_logs`. This ensures:

- `run_id` ownership is validated before insert (the run must belong to the calling business).
- `occurred_at` is always set server-side.
- Payload schema validation for known `event_type` values is applied before insert.
- Log writes are never wrapped in the same database transaction as the state mutation they record. This prevents a rolled-back state mutation from silently reverting its log entry. If the state mutation succeeds, the log write is issued as a separate atomic INSERT.

Tools must not suppress log writes on error paths. A `TOOL_FAILED` row must be written even when the tool is terminating abnormally, using a best-effort connection if the primary transaction has been aborted.

---

## 7. Payload Conventions

Common payload fields across all event types:

| Field | Type | Required | Description |
|---|---|---|---|
| `tool_name` | text | For TOOL_* events | The namespaced tool identifier, e.g. `classification.apply_rules` |
| `gate_name` | text | For GATE_* events | The gate identifier, e.g. `engine.gate_intake_complete` |
| `error_code` | text | For TOOL_FAILED, ERROR_RECORDED | The error code from `error_code_catalog.md` |
| `error_message` | text | For TOOL_FAILED, ERROR_RECORDED | Human-readable description |
| `duration_ms` | integer | For TOOL_COMPLETED | Execution duration |
| `retry_attempt` | integer | For TOOL_RETRIED | 1-based retry count |

---

## 8. Relationship to audit_logs

| Dimension | workflow_run_logs | audit_logs |
|---|---|---|
| Scope | Single run's operational event stream | All business-level events across the platform |
| Consumers | Workflow engine, run-history UI, runbooks | Compliance, security, GDPR, DPO |
| Hash chain | No | Yes (permanent tamper-evident chain) |
| Retention | Operational zone (7 years), then archive bundle | Permanent append-only |
| Redaction | Not subject to GDPR field redaction | GDPR redaction applies to payload fields per `redaction_policies.md` |

---

## Related Documents

- `schemas/workflow_run_schema.md` — parent table definition
- `reference/run_phase_enum.md` — valid values for the `phase` column
- `reference/audit_event_taxonomy.md` — audit events emitted alongside log entries
- `audit_event_payload_schemas.md` — payload schemas per event type
- `schemas/audit_log_schema.md` — the parallel tamper-evident audit log table
- `policies/data_retention_policy.md` — Operational zone 7-year retention
- `schemas/archive_bundle_layout_schema.md` — how run logs are serialized into archive bundles
- `policies/tool_atomicity_policy.md` — why log writes are outside the state-mutation transaction
- `reference/error_code_catalog.md` — error codes referenced in TOOL_FAILED payloads
