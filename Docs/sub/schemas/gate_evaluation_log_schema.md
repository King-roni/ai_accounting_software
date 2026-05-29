# Schema: gate_evaluation_logs

**Namespace:** engine
**Table:** gate_evaluation_logs
**Purpose:** Records every gate check evaluation that occurs during workflow run
processing. Each time an `engine.gate_<phase_descriptor>` check runs, one row is
inserted regardless of whether the gate passes or fails. This table is the authoritative
audit trail for finalization gate decisions and is used by the compliance reporting
pipeline to confirm that all required gates were evaluated before a run was finalized.

---

## Enum Definition

```sql
CREATE TYPE gate_result_enum AS ENUM (
  'PASS',   -- gate evaluated and all conditions met
  'FAIL',   -- gate evaluated and one or more conditions not met
  'SKIP'    -- gate declared but bypassed (e.g. phase not applicable to run type)
);
```

---

## Table Definition

```sql
CREATE TABLE gate_evaluation_logs (
  id               uuid        PRIMARY KEY DEFAULT gen_uuid_v7(),
  run_id           uuid        NOT NULL
                                 REFERENCES workflow_runs(id)
                                 ON DELETE RESTRICT,
  gate_name        text        NOT NULL,
  evaluated_at     timestamptz NOT NULL DEFAULT now(),
  result           gate_result_enum NOT NULL,
  failure_reason   text,
  failure_detail   jsonb,
  evaluated_by     text        NOT NULL,

  CONSTRAINT chk_gate_name_format
    CHECK (gate_name ~ '^engine\.gate_[a-z_]+$'),

  CONSTRAINT chk_failure_reason_on_fail
    CHECK (result != 'FAIL' OR failure_reason IS NOT NULL)
);
```

---

## Column Reference

| Column | Type | Nullable | Notes |
|---|---|---|---|
| id | uuid | NO | PK via gen_uuid_v7(); monotonically increasing |
| run_id | uuid FK | NO | References `workflow_runs(id)`; ON DELETE RESTRICT prevents dropping a run while log rows exist |
| gate_name | text | NO | Must match pattern `engine.gate_<phase_descriptor>` (two-part only). Examples: `engine.gate_finalization_check`, `engine.gate_classification_check` |
| evaluated_at | timestamptz | NO | Timestamp of evaluation; defaults to `now()` at insert |
| result | gate_result_enum | NO | PASS, FAIL, or SKIP |
| failure_reason | text | YES | Human-readable summary of why the gate failed. Mandatory when `result = FAIL` (enforced by CHECK) |
| failure_detail | jsonb | YES | Structured detail for programmatic consumption (e.g. list of failing conditions, unmatched ledger line IDs). Null on PASS or SKIP |
| evaluated_by | text | NO | Either the literal string `'system'` (for automated gate checks) or the `org_member_id` of the user who triggered a manual gate evaluation |

---

## Check Constraints

### `chk_gate_name_format`

```sql
CONSTRAINT chk_gate_name_format
  CHECK (gate_name ~ '^engine\.gate_[a-z_]+$')
```

Gate names must follow the `engine.gate_<phase_descriptor>` convention. The phase
descriptor is lowercase with underscores only. Dot notation is literal; names with
more than one dot are rejected. This prevents ad-hoc gate names from being logged
outside the approved taxonomy.

### `chk_failure_reason_on_fail`

When `result = FAIL`, `failure_reason` must be non-null. PASS and SKIP rows may have
a null `failure_reason`. This is enforced at the database layer so that application-
level bugs that omit failure reasons are caught immediately rather than silently
persisting incomplete audit records.

---

## Indexes

```sql
-- Primary lookup: all gate evaluations for a run, ordered by time
CREATE INDEX idx_gate_eval_logs_run_gate_time
  ON gate_evaluation_logs(run_id, gate_name, evaluated_at);

-- Support compliance queries: all FAILs across runs for a business
-- (joined through workflow_runs.business_entity_id)
CREATE INDEX idx_gate_eval_logs_result
  ON gate_evaluation_logs(result, evaluated_at)
  WHERE result = 'FAIL';
```

---

## Row-Level Security

```sql
ALTER TABLE gate_evaluation_logs ENABLE ROW LEVEL SECURITY;

-- SELECT: accessible to org:admin and org:accountant via run_id join
CREATE POLICY gate_evaluation_logs_select
  ON gate_evaluation_logs FOR SELECT
  USING (
    run_id IN (
      SELECT id FROM workflow_runs
      WHERE business_entity_id = auth.business_entity_id_for_session()
    )
  );

-- INSERT: only the system role (gate evaluation tools run as system)
CREATE POLICY gate_evaluation_logs_insert
  ON gate_evaluation_logs FOR INSERT
  WITH CHECK (
    current_setting('app.system_role_active', true) = 'true'
  );

-- UPDATE and DELETE: blocked for all roles
CREATE POLICY gate_evaluation_logs_no_update
  ON gate_evaluation_logs FOR UPDATE
  USING (false);

CREATE POLICY gate_evaluation_logs_no_delete
  ON gate_evaluation_logs FOR DELETE
  USING (false);
```

This table is INSERT-only for application roles. Rows cannot be modified or deleted
once written. This immutability property is required for the finalization audit trail.

---

## Usage: Finalization Audit Trail

Before a run transitions to `FINALIZED`, `tool_run_finalize.md` queries this table to
confirm that every required gate for the run's workflow type was evaluated and resulted
in PASS. The finalization tool executes:

```sql
SELECT gate_name, result
FROM gate_evaluation_logs
WHERE run_id = $1
  AND gate_name = ANY($required_gates)
ORDER BY evaluated_at DESC;
```

If any required gate is absent (never evaluated) or has its most recent result as FAIL,
finalization is blocked and the run enters `REVIEW_HOLD`. The set of required gates per
workflow type is defined in `workflow_type_registry_schema.md`.

SKIP rows count as evaluated but not passed. A SKIP on a required gate blocks
finalization unless the workflow type explicitly permits skipping that gate.

---

## Audit Events

| Event | Severity | Condition |
|---|---|---|
| ENGINE_GATE_EVALUATED | LOW | Any gate evaluation (PASS or SKIP) |
| ENGINE_GATE_FAILED | HIGH | `result = FAIL` on a required gate |

`ENGINE_GATE_FAILED` must include `run_id`, `gate_name`, `failure_reason`, and
`failure_detail` in the event payload. This event triggers a notification to any
org:admin members subscribed to run alerts for the business.

Note: `ENGINE_GATE_EVALUATED` and `ENGINE_GATE_FAILED` should be added to the audit
event taxonomy if not already present.

---

## Related Documents

- `workflow_run_schema.md` — `run_id` FK; `run_status_enum` transitions gated by
  PASS evaluations
- `workflow_type_registry_schema.md` — defines required gates per workflow type
- `tool_finalization_gate_check.md` — tool that inserts rows into this table
- `tool_run_finalize.md` — tool that reads this table to validate finalization
  preconditions
- `gate_function_library_schema.md` — SQL functions that back each named gate
- `in_phase_gate_policy.md` — policy for inbound workflow gate sequencing
- `out_phase_gate_policy.md` — policy for outbound workflow gate sequencing
- `finalization_lock_policy.md` — lock acquisition depends on gate PASS records
- `audit_event_naming_convention_policy.md` — DOMAIN_PAST_VERB naming for gate events
