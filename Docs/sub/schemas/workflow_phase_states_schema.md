# Workflow Phase States Schema

**Category:** Schemas · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2)

Canonical definition of the `workflow_phase_states` table. Each row records the execution state of one phase within one workflow run. The table is the authoritative source for phase-level progress, gate decisions, retry counts, and idempotency anchors. The phase execution engine (Block 03 Phase 06) reads and writes this table; the resumability framework (Block 03 Phase 07) uses the `idempotency_key` column as the re-entry boundary.

---

## Phase-state status vs run status: key distinction

The phase-level `status` enum is **not** the same as the run-level `run_status_enum` defined in `workflow_state_enum`. They are parallel tracking layers:

| Layer | Enum values | Where stored |
| --- | --- | --- |
| Run level | `CREATED · RUNNING · PAUSED · REVIEW_HOLD · AWAITING_APPROVAL · FINALIZING · FINALIZED · FAILED · CANCELLED · COMPENSATING` | `workflow_runs.status` |
| Phase level | `PENDING · RUNNING · COMPLETED · FAILED · SKIPPED · HOLDING` | `workflow_phase_states.status` |

When a run transitions to `PAUSED` or `REVIEW_HOLD`, the active phase state is **frozen in `RUNNING`** — the phase has not advanced; it is simply not executing. On run resume, the engine re-enters the phase from the last persisted boundary per Block 03 Phase 07 without creating a new phase state row.

---

## Table: `workflow_phase_states`

```sql
CREATE TYPE phase_state_status_enum AS ENUM (
  'PENDING',
  'RUNNING',
  'COMPLETED',
  'FAILED',
  'SKIPPED',
  'HOLDING'
);

CREATE TYPE gate_decision_enum AS ENUM (
  'ADVANCE',
  'HOLD',
  'FAIL'
);

CREATE TABLE workflow_phase_states (
  phase_state_id       uuid                    NOT NULL DEFAULT gen_uuid_v7(),
  workflow_run_id      uuid                    NOT NULL,
  phase_name           text                    NOT NULL,
  phase_index          integer                 NOT NULL,
  status               phase_state_status_enum NOT NULL DEFAULT 'PENDING',
  started_at           timestamptz,
  completed_at         timestamptz,
  gate_decision        gate_decision_enum,
  gate_evaluated_at    timestamptz,
  retry_count          integer                 NOT NULL DEFAULT 0
    CHECK (retry_count >= 0),
  last_error_class     text,
  last_error_message   text,
  idempotency_key      uuid                    NOT NULL DEFAULT gen_uuid_v7(),
  created_at           timestamptz             NOT NULL DEFAULT now(),

  CONSTRAINT workflow_phase_states_pkey       PRIMARY KEY (phase_state_id),
  CONSTRAINT workflow_phase_states_run_fk     FOREIGN KEY (workflow_run_id)
    REFERENCES workflow_runs(id) ON DELETE RESTRICT,
  CONSTRAINT workflow_phase_states_unique     UNIQUE (workflow_run_id, phase_name),
  CONSTRAINT workflow_phase_states_started_check
    CHECK (
      (status IN ('RUNNING', 'COMPLETED', 'FAILED', 'HOLDING') AND started_at IS NOT NULL)
      OR status IN ('PENDING', 'SKIPPED')
    ),
  CONSTRAINT workflow_phase_states_completed_check
    CHECK (
      (status IN ('COMPLETED', 'FAILED', 'SKIPPED') AND completed_at IS NOT NULL)
      OR status IN ('PENDING', 'RUNNING', 'HOLDING')
    )
);
```

### Column notes

| Column | Notes |
| --- | --- |
| `phase_state_id` | UUID v7 PK. Monotonically increasing; useful for time-ordered audit log queries referencing this table. |
| `workflow_run_id` | FK to `workflow_runs.id`. ON DELETE RESTRICT — a run with active phase states cannot be deleted; must be cancelled through the state machine first. |
| `phase_name` | String key matching the phase name in the run's `effective_phase_sequence_json`. Must match exactly; the engine resolves phase definitions by this name. |
| `phase_index` | Position of this phase in the effective sequence (0-based). Stored explicitly so that phase-order queries do not require parsing the sequence JSON on every read. |
| `status` | Current execution state of the phase. See status lifecycle below. |
| `started_at` | Set when the engine marks the phase `RUNNING`. NULL for `PENDING` and `SKIPPED` phases. |
| `completed_at` | Set when the phase reaches a terminal state (`COMPLETED`, `FAILED`, `SKIPPED`). NULL for in-progress phases. |
| `gate_decision` | The most recent gate evaluation result for this phase. NULL if no gate has been evaluated yet. `HOLDING` status rows typically have `gate_decision = 'HOLD'`. |
| `gate_evaluated_at` | Timestamptz of the most recent gate evaluation. NULL if no gate has run. |
| `retry_count` | Number of times this phase has been retried after a tool failure. Bounded by the retry policy in Block 03 Phase 08. Incremented before each retry attempt. |
| `last_error_class` | Short error class code from the most recent failure (e.g., `"EXTERNAL_API_TIMEOUT"`, `"VALIDATION_FAILED"`). Used for retry-policy branching and alert classification. |
| `last_error_message` | Human-readable error message from the most recent failure. Stored for operator display in the review queue. Truncated at 2048 characters. |
| `idempotency_key` | UUID v7, generated at phase state creation. Used by the single-writer tools as the idempotency anchor per `tool_atomicity_policy`. A resuming run re-uses the existing row and its `idempotency_key`; the single-writer performs `INSERT ... ON CONFLICT DO NOTHING` using this key. A new `idempotency_key` is generated only when the phase state row is first created. |
| `created_at` | Set on INSERT; immutable. |

---

## Phase-state status lifecycle

```
PENDING → RUNNING → COMPLETED
                  → FAILED     (retry_count increments; may loop back to RUNNING)
                  → HOLDING    (gate returned HOLD; awaiting re-evaluation)
        → SKIPPED              (phase was skipped per effective sequence config)
```

| Status | Meaning |
| --- | --- |
| `PENDING` | Phase state row created; engine has not started executing this phase. |
| `RUNNING` | Phase is actively executing tools. Also the frozen state when the parent run is `PAUSED` or `REVIEW_HOLD`. |
| `COMPLETED` | All tools in the phase completed successfully and the exit gate returned `ADVANCE`. |
| `FAILED` | A tool failed after exhausting retries, or the gate returned `FAIL`. |
| `SKIPPED` | Phase was bypassed per the effective sequence configuration for this business/workflow type. |
| `HOLDING` | Exit or entry gate returned `HOLD`; phase execution is paused pending a gate re-evaluation. Distinct from a run-level `PAUSED`: `HOLDING` is gate-driven; `PAUSED` is operator-driven. |

---

## Idempotency and resume-safe re-entry

The `idempotency_key` is the binding anchor for `tool_atomicity_policy`'s single-writer pattern. When the execution engine resumes a phase after a crash or retry:

1. The engine reads the existing `workflow_phase_states` row for `(workflow_run_id, phase_name)`.
2. The `idempotency_key` is passed to each single-writer tool in the phase.
3. The single-writer performs its DB write with `INSERT ... ON CONFLICT (idempotency_key) DO NOTHING` (or equivalent). A duplicate invocation produces no second write.
4. The `idempotency_key` is never regenerated for an existing phase state row; it is stable across retries and resumes.

A new `idempotency_key` is generated only when a new `workflow_phase_states` row is first created (i.e., the first time the engine enters a phase in a given run).

---

## Indexes

```sql
-- Phase progress query: enumerate all phases for a run in order.
CREATE INDEX idx_wps_run_index
  ON workflow_phase_states (workflow_run_id, phase_index);

-- Phase-by-status queries: find all HOLDING or FAILED phases across runs.
CREATE INDEX idx_wps_run_status
  ON workflow_phase_states (workflow_run_id, status);
```

The UNIQUE constraint on `(workflow_run_id, phase_name)` also creates an implicit index covering phase-name lookups within a run.

---

## RLS

`workflow_phase_states` is business-scoped. The RLS policy joins through `workflow_runs.business_id` to the standard tenancy template from `rls_policy_template`. The engine writes to this table via the service role; application-layer reads (progress UI, review queue) use the authenticated role under RLS.

Mobile clients may read phase state data (progress display). Write operations (phase state creation and updates) are engine-internal and never called directly from any client, mobile or otherwise. They are therefore not governed by `mobile_write_rejection_endpoints.md` (no client-facing endpoint exists for these writes).

---

## Audit events

| Event | Trigger | Severity |
| --- | --- | --- |
| `WORKFLOW_PHASE_STATE_TRANSITIONED` | `status` column changes value | LOW |

This event is emitted by the engine on every phase-status transition via `security.emit_audit`. The payload includes `phase_state_id`, `workflow_run_id`, `phase_name`, `from_status`, `to_status`, `gate_decision` (if applicable), and `retry_count`. Severity is LOW for all phase-level transitions; run-level severity is tracked separately via `WORKFLOW_RUN_STATE_CHANGED` in `workflow_state_enum`.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK and `idempotency_key`; canonical JSON for audit payloads
- `workflow_state_enum` — the 10-value run status enum; phase status is a distinct parallel enum
- `tool_atomicity_policy` — `idempotency_key` usage in the proposer + single-writer pattern
- `workflow_run_schema` — `workflow_runs` table; `workflow_run_id` FK
- `tool_invocation_schema` — `tool_invocations` table; tool invocations reference `phase_name`
- `audit_log_policies` — `WORKFLOW_PHASE` domain naming convention, severity enum
- `audit_event_taxonomy` — `WORKFLOW_PHASE_STATE_TRANSITIONED` catalogue entry
- `rls_policy_template` — RLS template for business-scoped tables
- `Docs/phases/03_workflow_engine/06_phase_execution_engine.md` — owning phase (writes this table)
- `Docs/phases/03_workflow_engine/07_resumability_and_idempotency.md` — resume-from-boundary logic using `idempotency_key`
- `Docs/phases/03_workflow_engine/08_failure_policy_and_retry.md` — retry policy that governs `retry_count`
