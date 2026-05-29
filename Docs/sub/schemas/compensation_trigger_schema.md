# Compensation Trigger Schema

**Category:** Schemas · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2)

**Purpose.** Define the `compensation_triggers` table, which records the state of the rollback infrastructure when the Workflow Engine detects a partial-write failure after a committed state transition. A compensation trigger is created when Phase N has committed a state change to the operational database but the tool call for Phase N+1 has failed in a way that leaves the run in an inconsistent state that cannot be safely resumed. The trigger drives the engine's compensating execution loop until all reversible commits are undone or the retry budget is exhausted.

---

## Table DDL

```sql
CREATE TYPE compensation_status_enum AS ENUM (
    'PENDING',
    'IN_PROGRESS',
    'COMPLETED',
    'EXHAUSTED'
);

CREATE TABLE compensation_triggers (
    id                  UUID                    NOT NULL DEFAULT gen_uuid_v7()  PRIMARY KEY,
    workflow_run_id     UUID                    NOT NULL                        REFERENCES workflow_runs(id),
    triggered_at        TIMESTAMPTZ             NOT NULL DEFAULT now(),
    trigger_phase       INTEGER                 NOT NULL,
    trigger_reason      TEXT                    NOT NULL  CHECK (char_length(trigger_reason) <= 500),
    compensation_steps  JSONB                   NOT NULL  DEFAULT '[]',
    retry_budget        INTEGER                 NOT NULL  DEFAULT 3,
    retries_used        INTEGER                 NOT NULL  DEFAULT 0,
    status              compensation_status_enum NOT NULL DEFAULT 'PENDING',
    completed_at        TIMESTAMPTZ,
    last_error          TEXT,

    CONSTRAINT compensation_triggers_workflow_run_uniq UNIQUE (workflow_run_id),
    CONSTRAINT compensation_triggers_retry_budget_valid CHECK (retry_budget > 0 AND retry_budget <= 10),
    CONSTRAINT compensation_triggers_retries_used_valid CHECK (retries_used >= 0 AND retries_used <= retry_budget)
);

CREATE INDEX idx_compensation_triggers_status
    ON compensation_triggers (status)
    WHERE status IN ('PENDING', 'IN_PROGRESS');
```

All UUIDs are generated via `gen_uuid_v7()` per `data_layer_conventions_policy`. The partial index on `status` covers the watchdog query that polls for triggers requiring action.

The UNIQUE constraint on `workflow_run_id` enforces that a run has at most one active compensation trigger at a time. If a prior trigger has reached `COMPLETED` or `EXHAUSTED`, a new one can be created for a subsequent partial failure only in an adjustment run context; standard `OUT_MONTHLY`/`IN_MONTHLY` runs that reach `EXHAUSTED` transition directly to `FAILED`.

---

## Column reference

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | UUID v7 | No | Primary key |
| `workflow_run_id` | UUID v7 | No | FK → `workflow_runs.id`; UNIQUE |
| `triggered_at` | timestamptz | No | Timestamp when the compensation trigger was created |
| `trigger_phase` | integer | No | Phase number where the partial failure was detected |
| `trigger_reason` | text (≤500) | No | Human-readable description of the failure causing compensation |
| `compensation_steps` | JSONB | No | Ordered array of step descriptors; see shape below |
| `retry_budget` | integer | No | Maximum number of compensation retry attempts (default 3) |
| `retries_used` | integer | No | Count of attempts consumed so far |
| `status` | compensation_status_enum | No | Current status of the compensation sequence |
| `completed_at` | timestamptz | Yes | Timestamp when status reached `COMPLETED` or `EXHAUSTED` |
| `last_error` | text | Yes | Error detail from the most recent failed attempt |

---

## `compensation_steps` JSONB shape

The `compensation_steps` field is an ordered JSON array. Steps are executed in array order; already-completed steps are skipped on retry using the `idempotency_key`.

```json
[
  {
    "step_name": "reverse_ledger_entries",
    "tool_call": "ledger.reverse_entries",
    "idempotency_key": "comp-<workflow_run_id>-step-0",
    "completed": false
  },
  {
    "step_name": "unlink_match_records",
    "tool_call": "matching.unlink_records",
    "idempotency_key": "comp-<workflow_run_id>-step-1",
    "completed": false
  }
]
```

| Field | Type | Description |
|---|---|---|
| `step_name` | text | Human-readable name for the step; used in audit payloads and operator dashboards |
| `tool_call` | text | Fully qualified tool name per `tool_naming_convention_policy` (`<namespace>.<action>`) |
| `idempotency_key` | text | Unique key used by the tool's idempotency check; prevents re-execution of already-applied reversals |
| `completed` | boolean | Set to `true` by the engine when the step's tool call succeeds; persisted immediately so partial progress survives a restart |

Steps are written by the engine's partial-failure detector at the time the trigger row is created. The step list is determined by evaluating which committed phases must be reversed, working backwards from `trigger_phase`. The step list is immutable after creation; retry attempts execute the same steps in the same order, skipping `completed = true` entries.

---

## Condition evaluation

A compensation trigger is created when the Workflow Engine's phase execution loop detects a **partial failure**: Phase N has written committed state to the operational database and the Phase N+1 tool call has failed in a non-retryable way (error class `FATAL` or retry budget for the phase-level retry loop exhausted).

The engine evaluates two questions:
1. Which prior phase commits are reversible? Not all phases are reversible — finalization locks (`archive.lock_period`) are not included in the compensation step list because they are by design irreversible. Reversible phases are declared in the phase sequence definition per `out_monthly_phase_sequence.md` and `in_monthly_phase_sequence.md`.
2. Is partial reversal sufficient for a safe re-run? If yes, the compensation trigger is created. If no (e.g., the failure was in a phase with no reversible predecessors), the run transitions directly to `FAILED` without creating a trigger.

The creation of a `compensation_triggers` row coincides with the run's `status` transitioning to `COMPENSATING`.

---

## Status transitions

```
PENDING → IN_PROGRESS → COMPLETED
                      → EXHAUSTED (retries_used = retry_budget)
```

- `PENDING`: trigger row created; compensation loop has not started.
- `IN_PROGRESS`: compensation loop is executing steps.
- `COMPLETED`: all steps reached `completed = true`; the run transitions from `COMPENSATING` to `FAILED` (compensation does not restore a run to a runnable state; it cleans up so a re-run can start fresh).
- `EXHAUSTED`: `retries_used` has reached `retry_budget` and at least one step remains `completed = false`; the run transitions to `FAILED` and operator intervention is required.

---

## Retry budget

The default `retry_budget` of 3 covers transient failures in the compensation step tool calls themselves (e.g., a database write that times out). Each retry attempt:
1. Increments `retries_used`.
2. Executes all steps with `completed = false` in order.
3. Marks each successful step `completed = true` immediately (written inside a short transaction per step).
4. If all steps complete, `status → COMPLETED`.
5. If the attempt fails before all steps complete, `last_error` is updated and the loop checks `retries_used < retry_budget`.
6. If `retries_used = retry_budget` and steps remain incomplete, `status → EXHAUSTED`.

When `status` reaches `EXHAUSTED`, the event `ENGINE_COMPENSATION_EXHAUSTED` is emitted and the `workflow_runs.status` transitions to `FAILED`. A re-run (OWNER role required) must be requested manually.

---

## Audit event

`ENGINE_COMPENSATION_EXHAUSTED` (HIGH) — emitted when `compensation_triggers.status` transitions to `EXHAUSTED`. HIGH because exhaustion means automatic rollback failed and the run is left in an indeterminate state requiring operator investigation.

Payload:

```json
{
  "compensation_trigger_id": "<uuid>",
  "workflow_run_id": "<uuid>",
  "business_id": "<uuid>",
  "trigger_phase": 4,
  "retries_used": 3,
  "retry_budget": 3,
  "incomplete_steps": ["reverse_ledger_entries"],
  "last_error": "<error text>",
  "exhausted_at": "<iso8601>"
}
```

`incomplete_steps` lists the `step_name` values of steps that did not reach `completed = true`.

---

## Cross-references

- `compensation_log_schema.md` — `compensation_log` rows appended per step execution; fed by the compensation loop; `COMPENSATION_LOG_APPENDED` event
- `workflow_run_schema.md` — `run_status_enum`, `COMPENSATING` status, FK relationship
- `workflow_phase_states_schema.md` — phase-state rows whose status feeds the engine's partial-failure detector
