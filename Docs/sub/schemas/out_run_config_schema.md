# OUT Run Config Schema

**Category:** Schemas · **Owning block:** 12 — OUT Workflow · **Stage:** 4 sub-doc (Layer 2)

**Purpose.** Define the `out_run_configs` table, which is the OUT_MONTHLY-specific extension of `workflow_runs`. Every `OUT_MONTHLY` run has exactly one `out_run_configs` row; the base `workflow_runs` row carries shared state (status, phase pointer, timing) and the config row carries OUT_MONTHLY-specific parameters: the bank uploads in scope, the period, and any phase override configuration. The config row is written once at run creation time and is thereafter immutable unless a re-run creates a new config row under a new `workflow_run_id`.

---

## Table DDL

```sql
CREATE TABLE out_run_configs (
    id                    UUID        NOT NULL DEFAULT gen_uuid_v7()     PRIMARY KEY,
    workflow_run_id       UUID        NOT NULL                           REFERENCES workflow_runs(id),
    business_id           UUID        NOT NULL                           REFERENCES business_entities(id),
    period_year           INTEGER     NOT NULL,
    period_month          INTEGER     NOT NULL  CHECK (period_month BETWEEN 1 AND 12),
    bank_upload_ids       UUID[]      NOT NULL  DEFAULT '{}',
    phase_override_config JSONB,
    manual_trigger        BOOLEAN     NOT NULL  DEFAULT FALSE,
    triggered_by_user_id  UUID,
    created_at            TIMESTAMPTZ NOT NULL  DEFAULT now(),

    CONSTRAINT out_run_configs_workflow_run_uniq UNIQUE (workflow_run_id)
);

CREATE INDEX idx_out_run_configs_business_period
    ON out_run_configs (business_id, period_year, period_month);
```

All UUIDs are generated via `gen_uuid_v7()` per `data_layer_conventions_policy`. The `triggered_by_user_id` column is nullable: it is populated for manually triggered runs and null for scheduler-driven runs.

---

## Column reference

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | UUID v7 | No | Primary key |
| `workflow_run_id` | UUID v7 | No | FK → `workflow_runs.id`; UNIQUE (one config per run) |
| `business_id` | UUID v7 | No | FK → `business_entities.id`; tenant scope |
| `period_year` | integer | No | Calendar year of the accounting period (e.g. 2026) |
| `period_month` | integer | No | Calendar month 1–12 |
| `bank_upload_ids` | UUID v7[] | No | Array of `bank_uploads.id` values in scope for this run |
| `phase_override_config` | JSONB | Yes | Per-phase timeout and gate overrides; null = use defaults |
| `manual_trigger` | boolean | No | `true` if triggered by an operator action, `false` if scheduler-driven |
| `triggered_by_user_id` | UUID v7 | Yes | User who triggered a manual run; null for scheduler runs |
| `created_at` | timestamptz | No | Row creation timestamp |

---

## Period uniqueness

The UNIQUE constraint on `(workflow_run_id)` ensures that a single workflow run has at most one config row. Period uniqueness (only one ACTIVE run per `(business_id, period_year, period_month)` for the `OUT_MONTHLY` workflow type) is enforced at the `workflow_runs` level by a partial unique index owned by `workflow_run_creation_policy`. The config row is subordinate to that constraint.

The partial index on `workflow_runs`:

```sql
CREATE UNIQUE INDEX idx_workflow_runs_active_period_uniq
    ON workflow_runs (business_id, workflow_type, period_year, period_month)
    WHERE status NOT IN ('FINALIZED', 'FAILED', 'CANCELLED');
```

Attempts to create a second active OUT_MONTHLY run for the same `(business_id, period_year, period_month)` fail at the `workflow_runs` insert before `out_run_configs` is written. See `workflow_run_creation_policy` for the full rejection handling.

---

## `bank_upload_ids` handling

- **Empty array (`{}`):** all `bank_uploads` rows for the business and period (where `upload_status = 'PARSED'` and `period_start`/`period_end` overlaps the run month) are included automatically at Phase 1 (INGESTION). The phase queries by `business_id` and period overlap, not by this array.
- **Non-empty array:** only the specified upload IDs are included. The phase validates that each ID exists, belongs to the business, and has `upload_status = 'PARSED'`. If any ID fails validation, the run transitions to `FAILED` before Phase 1 begins and `ENGINE_RUN_CREATION_REJECTED_DUPLICATE` is NOT the relevant event — instead, `WORKFLOW_RUN_FAILED` is emitted with `failure_reason = 'INVALID_BANK_UPLOAD_ID'`.

The `bank_upload_ids` array is immutable after creation. Re-scoping uploads requires creating a new run.

---

## `phase_override_config` JSONB shape

Used for re-runs and emergency processing to override per-phase behaviour without changing phase code.

```json
{
  "<phase_number>": {
    "timeout_minutes": 60,
    "skip_gate_check": false
  }
}
```

| Field | Type | Description |
|---|---|---|
| `timeout_minutes` | integer | Override the default phase timeout. Must be > 0 and ≤ 480 (8 hours). |
| `skip_gate_check` | boolean | If `true`, the gate function for this phase is bypassed and the run advances unconditionally. OWNER role required to set `true`. |

`skip_gate_check: true` is a break-glass option. Setting it requires an explicit step-up authentication at the call site and emits a `WORKFLOW_GATE_EVALUATED` event with `gate_decision = SKIPPED_OVERRIDE`. This option is not available for the finalization gate (`engine.gate_finalization_ready`) regardless of the flag value.

A null `phase_override_config` means all phases run with their default timeout and gate behaviour.

---

## Audit event

`OUT_WORKFLOW_RUN_CONFIGURED` (LOW) — emitted by `out_workflow.configure_run` when the `out_run_configs` row is successfully inserted. Payload:

```json
{
  "config_id": "<out_run_configs.id>",
  "workflow_run_id": "<workflow_run_id>",
  "business_id": "<business_id>",
  "period_year": 2026,
  "period_month": 5,
  "bank_upload_ids_count": 2,
  "manual_trigger": false,
  "triggered_by_user_id": null,
  "phase_override_config_present": false
}
```

`bank_upload_ids` array values are not included in the payload (volume; available via the table row); only the count is recorded.

---

## RLS and access

`out_run_configs` rows are tenant-scoped by `business_id`. RLS denies SELECT to any session whose active role does not have a grant on the row's `business_id`. The config row carries no encrypted fields; all columns are stored in plaintext in the operational database. The `triggered_by_user_id`, if present, is a UUID reference — it does not carry PII directly.

---

## Immutability

The `out_run_configs` row is immutable after creation. There is no UPDATE path. If a run needs to be reconfigured (e.g., additional bank uploads discovered mid-run), the run must be cancelled and a new run created with a new config row. This is by design: mutable run configuration during execution would invalidate the audit trail and break idempotency guarantees for phases that have already consumed the config.

The engine's phase execution tools read `out_run_configs` at phase start and cache the values for the duration of the phase. Reading the config from the table at each step inside a phase is not required.

---

## Cross-references

- `workflow_run_schema.md` — base `workflow_runs` table DDL; the partial unique index for period uniqueness
- `workflow_run_creation_policy.md` — full constraints on run creation, duplicate detection, backdated run rules
- `out_monthly_phase_sequence.md` — how phases consume `bank_upload_ids` and `phase_override_config` at runtime
