# adjustment_record_schema

**Category:** Schemas · **Owning block:** 03 — Workflow Engine · **Co-owners:** 12, 13 · **Stage:** 4 sub-doc (Layer 1 cross-block schema)

The canonical `adjustment_records` table. Per the 2026-05-08 Block 12 fix: table ownership consolidated to Block 03 (Block 12 originally hosted it; the Phase 01 schema migration moved it to Block 03 alongside `workflow_run_approvals`).

Each row records a single delta — what a `*_ADJUSTMENT` run changes on a previously-finalized record. The Block 13 fix combined the OUT-side and IN-side delta kinds into a single 8-value enum.

---

## Table definition

```sql
CREATE TYPE adjustment_target_kind_enum AS ENUM (
  'transactions',
  'invoices',
  'documents',
  'review_issues',
  'ledger_entries',
  'match_records'
);

CREATE TYPE delta_kind_enum AS ENUM (
  -- OUT-side (4 values)
  'CORRECT_VAT_TREATMENT',
  'ADD_EVIDENCE',
  'RECLASSIFY_TYPE',
  'CORRECT_MATCH',
  -- IN-side (3 values)
  'CONVERT_TO_TAX_INVOICE',
  'ISSUE_CREDIT_NOTE',
  'WRITE_OFF_INVOICE',
  -- Shared catch-all
  'OTHER'
);

CREATE TABLE adjustment_records (
  adjustment_record_id        uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id                 uuid NOT NULL REFERENCES business_entities(id),

  -- The adjustment run that produced this record
  adjustment_run_id           uuid NOT NULL REFERENCES workflow_runs(workflow_run_id),

  -- The target record being adjusted
  target_record_kind          adjustment_target_kind_enum NOT NULL,
  target_record_id            uuid NOT NULL,

  -- The nature of the change
  delta_kind                  delta_kind_enum NOT NULL,
  delta_payload               jsonb NOT NULL,
    -- Structure per delta_kind defined in adjustment_delta_payload_schema (sibling sub-doc)

  -- Audit + governance
  reason_text                 text NOT NULL,
  created_by_user_id          uuid NOT NULL REFERENCES users(id),
  created_at                  timestamptz NOT NULL DEFAULT now(),

  -- Accountant-review flag (per Block 12 Phase 09 — delta_kind = OTHER triggers required review)
  requires_accountant_review  boolean NOT NULL DEFAULT false,

  -- Constraints
  CHECK (
    -- delta_kind must match workflow type via the run lookup
    -- (full enforcement via trigger; SQL CHECK can't reach the FK row)
    delta_kind IS NOT NULL
  ),
  CHECK (
    -- Reason text must meet adjustment_reason_text_policy
    length(reason_text) >= 10 AND length(reason_text) <= 4000
  )
);
```

## ENUM rationale

### `delta_kind` (8 values, combined OUT + IN)

Per the Block 13 scan fix: a single combined enum across both directions, with a CHECK constraint enforcing direction-correctness at INSERT time (the engine checks the parent `workflow_runs.workflow_type` matches the delta kind).

| `delta_kind` | Applicable workflow type | Effect |
| --- | --- | --- |
| `CORRECT_VAT_TREATMENT` | OUT_ADJUSTMENT | Block 11 recomputes VAT for the target transaction; ledger entries re-emit |
| `ADD_EVIDENCE` | OUT_ADJUSTMENT | Late-arrived document attaches to a finalized transaction |
| `RECLASSIFY_TYPE` | OUT_ADJUSTMENT | Transaction type changes; cascades through Block 11 dispatcher |
| `CORRECT_MATCH` | OUT_ADJUSTMENT | Match correction (rejected match replaced) |
| `CONVERT_TO_TAX_INVOICE` | IN_ADJUSTMENT | Pro-forma → tax invoice retroactive conversion (Stage 2+ deferred case) |
| `ISSUE_CREDIT_NOTE` | IN_ADJUSTMENT | Credit-note flow for a finalized invoice |
| `WRITE_OFF_INVOICE` | IN_ADJUSTMENT | Bad-debt write-off for a finalized invoice |
| `OTHER` | Either | Catch-all; **always sets `requires_accountant_review = true`** per Block 12 Phase 09 |

### `target_record_kind` (6 values)

The kinds of records adjustments can target. `target_record_id` is a UUID; the kind discriminates which table the FK logically points to (polymorphic — Postgres won't enforce the FK, but `adjustment_record_target_fk_validator` triggers do).

## Direction enforcement

Trigger on INSERT validates that `delta_kind` matches `workflow_runs.workflow_type` for the parent run:

```sql
CREATE OR REPLACE FUNCTION enforce_delta_kind_direction() RETURNS TRIGGER AS $$
DECLARE
  parent_type workflow_type_enum;
BEGIN
  SELECT workflow_type INTO parent_type
  FROM workflow_runs
  WHERE workflow_run_id = NEW.adjustment_run_id;

  IF parent_type = 'OUT_ADJUSTMENT' AND NEW.delta_kind IN
       ('CONVERT_TO_TAX_INVOICE', 'ISSUE_CREDIT_NOTE', 'WRITE_OFF_INVOICE') THEN
    RAISE EXCEPTION 'delta_kind % invalid for OUT_ADJUSTMENT', NEW.delta_kind;
  END IF;

  IF parent_type = 'IN_ADJUSTMENT' AND NEW.delta_kind IN
       ('CORRECT_VAT_TREATMENT', 'ADD_EVIDENCE', 'RECLASSIFY_TYPE', 'CORRECT_MATCH') THEN
    RAISE EXCEPTION 'delta_kind % invalid for IN_ADJUSTMENT', NEW.delta_kind;
  END IF;

  -- OTHER allowed for both
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

## `delta_payload` shape

The JSONB carries the actual change. Per-kind shapes are defined in `adjustment_delta_payload_schema` (sibling sub-doc, Block 04). General shape:

```json
{
  "old_value": { ... },
  "new_value": { ... },
  "fields_changed": ["..."],
  "additional_context": { ... }
}
```

Each `delta_kind` constrains the JSONB further — e.g., `CORRECT_VAT_TREATMENT` requires `old_value.vat_treatment` and `new_value.vat_treatment` both from `vat_treatment_enum`.

## `requires_accountant_review`

Set true automatically when:
- `delta_kind = OTHER`
- (post-MVP) per-business policy escalates other kinds

When true, the IN_ADJUSTMENT or OUT_ADJUSTMENT run holds at `ADJUSTMENT_HUMAN_REVIEW` per Block 12 Phase 09 / Block 13 Phase 11.

## Indexes

```sql
CREATE INDEX idx_adjustment_records_run ON adjustment_records(adjustment_run_id);
CREATE INDEX idx_adjustment_records_target ON adjustment_records(business_id, target_record_kind, target_record_id);
CREATE INDEX idx_adjustment_records_review ON adjustment_records(business_id, requires_accountant_review)
  WHERE requires_accountant_review = true;
```

The `target` index supports the audit-history slice for a specific finalized record (Block 16 Phase 02 / 08 drill-down).

## RLS

Standard tenant isolation. Visibility scoped to roles per `permission_matrix`. Adjustment records are part of the audit trail — the per-role audit-log RLS per `audit_log_policies` applies in spirit (Reviewer can see records; only specific roles can create them).

```sql
CREATE POLICY adjustment_records_business_isolation ON adjustment_records
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

## Audit events

| Event | When |
| --- | --- |
| `OUT_ADJUSTMENT_RECORD_CREATED` | INSERT in an OUT_ADJUSTMENT run |
| `IN_ADJUSTMENT_RECORD_CREATED` | INSERT in an IN_ADJUSTMENT run |

Aggregated per `audit_log_policies` aggregation rule when batch-applying.

## Multiple adjustments per period

Per Stage 1 decision: "An open adjustment does not block the next monthly run." Multiple concurrent OUT_ADJUSTMENT runs against the same parent run are allowed — each gets its own `adjustment_run_id` referencing the same `parent_run_id` on `workflow_runs`.

Per `multiple_adjustments_per_period_policy` (now part of `out_adjustment_policies` after compression): ordering of multiple-adjustment effects follows commit order. Conflicts (two adjustments touching the same target field) are caught at finalization-precondition time.

## Cross-references

- `data_layer_conventions_policy` — UUID v7, SHA-256, canonical JSON for `delta_payload`
- `workflow_run_schema` — parent `workflow_runs` table
- `adjustment_delta_payload_schema` (Block 04) — per-kind JSONB shapes
- `out_adjustment_policies` — OUT-side adjustment behavior
- `audit_log_policies` — `*_ADJUSTMENT_RECORD_CREATED` events
- `permission_matrix` — adjustment-creating surface (`WORKFLOW_TRIGGER`)
- Block 03 Phase 01 — table ownership home
- Block 12 Phase 01 — schema migration adding paired_run_id + this table's ownership transfer
- Block 13 Phase 11 — IN_ADJUSTMENT workflow type
- 2026-05-08 decisions-log amendment — combined delta_kind enum
