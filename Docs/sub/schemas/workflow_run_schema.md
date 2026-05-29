# workflow_run_schema

**Category:** Schemas · **Owning block:** 03 — Workflow Engine · **Co-owner:** 12 — OUT Workflow · **Stage:** 4 sub-doc (Layer 1 cross-block schema)

The canonical `workflow_runs` table definition. Every workflow run (OUT_MONTHLY, IN_MONTHLY, OUT_ADJUSTMENT, IN_ADJUSTMENT, INGESTION, etc.) is a row here. Per the 2026-05-08 Block 12 fix: column ownership consolidated to Block 03 — Block 12 contributes `paired_run_id` + trigger metadata, but the table itself is Block 03's.

---

## Table definition

```sql
CREATE TYPE workflow_type_enum AS ENUM (
  'INGESTION',
  'CLASSIFICATION',
  'EVIDENCE_DISCOVERY',
  'MATCHING',
  'INCOME_MATCHING',
  'LEDGER_PREPARATION',
  'OUT_MONTHLY',
  'IN_MONTHLY',
  'OUT_ADJUSTMENT',
  'IN_ADJUSTMENT',
  'FINALIZATION'
);

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

-- PAUSED: manual hold (operator-initiated). Added 2026-05-15 — see decisions-log amendment.
-- COMPENSATING: rollback-in-progress during Block 15 lock-sequence failure. Added 2026-05-15.

CREATE TYPE trigger_kind_enum AS ENUM ('MANUAL', 'EVENT');

CREATE TABLE workflow_runs (
  workflow_run_id            uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id                uuid NOT NULL REFERENCES business_entities(id),
  workflow_type              workflow_type_enum NOT NULL,
  status                     run_status_enum NOT NULL DEFAULT 'CREATED',
  state_changed_at           timestamptz NOT NULL DEFAULT now(),

  -- Period (NULL for non-period-bound types like INGESTION)
  period_start               date,
  period_end                 date,

  -- Trigger metadata (per Block 12 Phase 01)
  trigger_kind               trigger_kind_enum NOT NULL,
  triggered_by_user_id       uuid REFERENCES users(id),
  triggered_by_event_id      uuid,
  manual_trigger_note        text,

  -- Pairing (OUT/IN concurrent runs share the period; one row per direction)
  paired_run_id              uuid REFERENCES workflow_runs(workflow_run_id) DEFERRABLE INITIALLY DEFERRED,

  -- Adjustment lineage (parent_run_id present for *_ADJUSTMENT)
  parent_run_id              uuid REFERENCES workflow_runs(workflow_run_id),

  -- Phase tracking
  current_phase_name         text,
  current_phase_index        integer,
  effective_phase_sequence_json jsonb NOT NULL,

  -- Principal context snapshot (per Stage 1 role-change propagation rule)
  principal_context_snapshot_json jsonb NOT NULL,

  -- Pause / resume
  paused_at                  timestamptz,
  paused_by_user_id          uuid REFERENCES users(id),
  paused_reason              text,

  -- Approval (FINALIZATION step-up)
  approved_by_user_id        uuid REFERENCES users(id),
  approved_at                timestamptz,
  approval_step_up_token_id  uuid,

  -- Completion
  completed_at               timestamptz,
  completed_with_status      run_status_enum,
  failure_class              text,
  failure_message            text,

  created_at                 timestamptz NOT NULL DEFAULT now(),
  updated_at                 timestamptz NOT NULL DEFAULT now(),

  -- Constraints
  CHECK (status IN ('CREATED','RUNNING','PAUSED','REVIEW_HOLD','AWAITING_APPROVAL','FINALIZING','FINALIZED','FAILED','CANCELLED','COMPENSATING')),
  CHECK (
    -- _ADJUSTMENT types require parent_run_id
    (workflow_type NOT IN ('OUT_ADJUSTMENT','IN_ADJUSTMENT')) OR (parent_run_id IS NOT NULL)
  ),
  CHECK (
    -- paired_run_id only on OUT_MONTHLY / IN_MONTHLY pair
    paired_run_id IS NULL OR workflow_type IN ('OUT_MONTHLY','IN_MONTHLY')
  ),
  CHECK (
    -- period columns paired
    (period_start IS NULL AND period_end IS NULL) OR (period_start IS NOT NULL AND period_end IS NOT NULL AND period_end >= period_start)
  )
);
```

## Column rationale

### `paired_run_id`

Per Block 12 Phase 01: OUT_MONTHLY and IN_MONTHLY runs triggered by the same statement upload share a period and run in parallel. Each direction is a separate row; `paired_run_id` links them. Self-referential FK is `DEFERRABLE INITIALLY DEFERRED` so the two rows can be inserted in one transaction.

Block 03's `getCombinedRunProgress` consumer (Block 16) joins on `paired_run_id` to render the unified progress indicator the user sees.

Only OUT_MONTHLY ↔ IN_MONTHLY pairs use this column. Other workflow types leave it null.

### `parent_run_id`

`OUT_ADJUSTMENT` and `IN_ADJUSTMENT` runs reference the original monthly run (or the most recent adjustment for the same period). Per Block 13 Phase 11's `v_invoices_with_adjustments` view, the manifest-version chain follows this column.

### `principal_context_snapshot_json`

Per Stage 1 decision "Role-change propagation: apply to new actions only; active workflow runs continue with the principal context they started under." This column snapshots the principal's role at run start; subsequent role changes don't affect the run.

Shape:

```json
{
  "user_id": "...",
  "business_id": "...",
  "role": "Bookkeeper",
  "permission_surfaces_granted": ["WORKFLOW_TRIGGER", "REVIEW_QUEUE_RESOLVE", "..."],
  "snapshot_taken_at": "2026-01-15T09:00:00Z"
}
```

### `effective_phase_sequence_json`

The workflow-type's phase sequence at run start. Per `tool_naming_convention_policy` Section 5 deprecation rules, this snapshot ensures a run that started before a deprecation continues to use the deprecated phase order.

Shape: array of phase names in execution order. Block 03 Phase 06's execution engine reads this rather than re-resolving the registry per phase.

### `current_phase_index`

Pointer into `effective_phase_sequence_json` array. Per the Block 16 scan fix: Block 16 reads this dynamically rather than hard-coding "11/8" phase numbers.

### `trigger_kind` + `triggered_by_*`

Per Stage 1: "Run triggers: Manual + event-based; no scheduled triggers in MVP." `MANUAL` triggers carry `triggered_by_user_id`; `EVENT` triggers carry `triggered_by_event_id` referencing `trigger_events_processed`.

### `failure_class` + `failure_message`

Populated on transition to `FAILED`. Failure classes are per Block 03 Phase 08's retry policy taxonomy.

## Indexes

```sql
CREATE INDEX idx_workflow_runs_business_status ON workflow_runs(business_id, status);
CREATE INDEX idx_workflow_runs_business_type_period ON workflow_runs(business_id, workflow_type, period_start, period_end);
CREATE INDEX idx_workflow_runs_paired ON workflow_runs(paired_run_id) WHERE paired_run_id IS NOT NULL;
CREATE INDEX idx_workflow_runs_parent ON workflow_runs(parent_run_id) WHERE parent_run_id IS NOT NULL;
CREATE INDEX idx_workflow_runs_completed_at ON workflow_runs(business_id, completed_at DESC) WHERE completed_at IS NOT NULL;
```

## RLS

Standard tenant isolation:

```sql
CREATE POLICY workflow_runs_business_isolation ON workflow_runs
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

Per `permission_matrix`: every role with any business access can SELECT runs from that business (visibility is universal; the surfaces for triggering and approving are separate).

## Migrations

The schema was assembled across multiple Stage 2 phase docs and the 2026-05-08 amendment. The Stage 4 sub-doc consolidates them into one canonical CREATE TABLE.

Key migration moments captured in `Docs/decisions_log.md`:

- 2026-05-08: `paired_run_id`, `trigger_kind`, `triggered_by_user_id`, `triggered_by_event_id`, `manual_trigger_note` added per Block 12 Phase 01
- 2026-05-15: `PAUSED` and `COMPENSATING` added to `run_status_enum` and `CHECK` constraint. Both are forward-compatible additions — no existing row needs to change value. See Stage 4 Layer 2 amendment in decisions log.

## Lint rules

- Every insertion of a workflow_run goes through `transitionRun(null → CREATED)` per Block 03 Phase 04 — direct INSERTs forbidden
- `parent_run_id` must reference a FINALIZED run when set (CHECK constraint is partial — full integrity via the state-machine engine)
- `paired_run_id` references must be symmetric (A.paired_run_id = B AND B.paired_run_id = A) — enforced by the engine at run-pair creation, not by SQL constraint

## Cross-references

- `adjustment_record_schema` — sibling table for adjustment deltas
- `trigger_events_processed_schema` — `triggered_by_event_id` references this table
- `workflow_run_state_changed_event_schema` — audit event on every status change
- `data_layer_conventions_policy` — UUID v7 generation, canonical JSON for snapshot
- `audit_log_policies` — `WORKFLOW_RUN_*` event family
- `permission_matrix` — visibility rules
- Block 03 Phase 01 — workflow run schema (architecture)
- Block 03 Phase 04 — state machine & lifecycle controls
- Block 12 Phase 01 — schema migration adding paired_run_id
- 2026-05-08 decisions-log amendment — paired_run_id column
