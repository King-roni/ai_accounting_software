# Workflow Type Registry Schema

**Block:** 03 — Workflow Engine
**Category:** Schemas
**Stage:** 4 sub-doc (Layer 2)

---

## Purpose

Documents the two tables that make up the workflow type registry: `workflow_type_registry`
(the global catalogue of workflow types) and `workflow_type_business_config` (per-business
enable/disable and override configuration). Together these tables are the source of truth
for which phases and gates a run of a given type executes, and which businesses have a
given type enabled.

---

## `workflow_type_registry` Table DDL

```sql
CREATE TABLE workflow_type_registry (
  id                   UUID        PRIMARY KEY DEFAULT gen_uuid_v7(),
  workflow_type        TEXT        NOT NULL UNIQUE,
  phase_sequence       JSONB       NOT NULL,
  gate_sequence        JSONB       NOT NULL,
  registered_by_block  TEXT        NOT NULL,
  registered_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX workflow_type_registry_type_idx
  ON workflow_type_registry (workflow_type);
```

`id` uses `gen_uuid_v7()` per `data_layer_conventions_policy`.

`workflow_type` is a short uppercase identifier with underscores; canonical values
include `OUT_MONTHLY`, `OUT_ADJUSTMENT`, `IN_MONTHLY`, `IN_ADJUSTMENT`. New type names
must be agreed in `Docs/decisions_log.md` before the registration call is added to
application boot.

`phase_sequence` and `gate_sequence` are immutable after the first successful
registration. See "Registration Mechanism" below.

---

## `workflow_type_business_config` Table DDL

```sql
CREATE TABLE workflow_type_business_config (
  id               UUID        PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id      UUID        NOT NULL REFERENCES business_entities(id),
  workflow_type    TEXT        NOT NULL
    REFERENCES workflow_type_registry(workflow_type),
  config_overrides JSONB,
  is_enabled       BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT workflow_type_business_config_unique
    UNIQUE (business_id, workflow_type)
);

CREATE INDEX workflow_type_business_config_business_idx
  ON workflow_type_business_config (business_id);
```

`config_overrides` is nullable. When null, the registered defaults apply.
The `JSONB` shape of `config_overrides` is workflow-type-specific and documented in
the workflow type's own sub-doc (e.g., `out_monthly_phase_sequence.md`). The engine
validates override keys against the registered type's schema at run-creation time.

`is_enabled = FALSE` prevents new runs of the type from being created for the
business. Runs already in progress are not affected; they run to completion or failure.

Audit event: `BUSINESS_WORKFLOW_CONFIG_TOGGLED` (existing event, Block 02 domain) is
emitted when `is_enabled` changes.

---

## Phase Sequence JSONB Shape

`phase_sequence` is a JSONB array. Each element:

```json
{
  "phase_number": 1,
  "phase_name": "INGESTION",
  "description": "Parse and normalise bank statement rows."
}
```

- `phase_number`: 1-indexed integer. Values must be contiguous (no gaps).
- `phase_name`: uppercase snake_case string. Must be unique within the array.
- `description`: human-readable, one sentence.

Validation is performed at registration time. A registration call with non-contiguous
`phase_number` values or duplicate `phase_name` values is rejected with an
`INVALID_PHASE_SEQUENCE` error and the boot fails.

Example — `OUT_MONTHLY` phase sequence (abbreviated):

```json
[
  { "phase_number": 1, "phase_name": "INGESTION",       "description": "Parse and normalise bank statement rows." },
  { "phase_number": 2, "phase_name": "CLASSIFICATION",  "description": "Classify each transaction by type and VAT treatment." },
  { "phase_number": 3, "phase_name": "MATCHING",        "description": "Match transactions against invoices." },
  { "phase_number": 4, "phase_name": "LEDGER_PREP",     "description": "Prepare double-entry ledger rows." },
  { "phase_number": 5, "phase_name": "REVIEW",          "description": "Human review of flagged items." },
  { "phase_number": 6, "phase_name": "FINALIZATION",    "description": "Lock entries and build archive bundle." }
]
```

---

## Gate Sequence JSONB Shape

`gate_sequence` is a JSONB array. Each element:

```json
{
  "gate_name": "engine.gate_classification_complete",
  "evaluated_after_phase": 2,
  "advance_action": "PROCEED_TO_MATCHING"
}
```

- `gate_name`: must follow the `engine.gate_<phase_descriptor>` naming convention per
  `tool_naming_convention_policy.md`. The gate name must resolve to a registered gate
  function in `gate_function_library_schema.md`.
- `evaluated_after_phase`: references the `phase_number` of the phase after which the
  gate fires. The phase number must exist in `phase_sequence`.
- `advance_action`: a short descriptor of the gate's advance outcome. Used in audit
  event payloads and operator tooling; does not affect execution logic.

Gates are evaluated by the phase execution engine immediately after the named phase
completes. A gate returning HOLD transitions the run to `REVIEW_HOLD`. A gate
returning PASS advances the run to the next phase.

---

## Registration Mechanism

Workflow types are registered at application boot by their owning block via a call to
the engine's type registry function. The call is idempotent:

```sql
INSERT INTO workflow_type_registry (
  workflow_type, phase_sequence, gate_sequence, registered_by_block
)
VALUES (
  $workflow_type, $phase_sequence::JSONB, $gate_sequence::JSONB, $registered_by_block
)
ON CONFLICT (workflow_type) DO NOTHING;
```

`ON CONFLICT DO NOTHING` means a type that is already registered is silently skipped.
This is the idempotency contract: the first boot that registers a type wins. Subsequent
boots do not overwrite it.

**Phase and gate sequences are immutable after first registration.** If a sequence
must change (e.g., a phase is added or reordered), a Postgres migration is required
that:
1. Deletes the existing `workflow_type_registry` row.
2. Inserts a new row with the updated sequences.
3. Emits `WORKFLOW_PHASE_SEQUENCE_MIGRATED` for audit traceability.

In-place updates to `phase_sequence` or `gate_sequence` via SQL UPDATE are blocked by
a row-level trigger that raises an error for any UPDATE on those columns.

Audit event on first registration: `ENGINE_WORKFLOW_TYPE_REGISTERED`.

---

## Audit Events

| Event | Severity | Trigger |
| --- | --- | --- |
| `ENGINE_WORKFLOW_TYPE_REGISTERED` | LOW | New `workflow_type_registry` row inserted at boot |
| `BUSINESS_WORKFLOW_CONFIG_TOGGLED` | LOW | `is_enabled` changed on `workflow_type_business_config` |
| `WORKFLOW_PHASE_SEQUENCE_MIGRATED` | MEDIUM | Phase or gate sequence updated via migration |

`ENGINE_WORKFLOW_TYPE_REGISTERED` payload: `workflow_type`, `registered_by_block`,
`phase_count`, `gate_count`, `registered_at`.

---

## Cross-references

- `gate_function_library_schema.md` — registered gate functions referenced by
  `gate_name` in `gate_sequence`
- `out_monthly_phase_sequence.md` — full phase and gate sequence for `OUT_MONTHLY`
- `in_monthly_phase_sequence.md` — full phase and gate sequence for `IN_MONTHLY`
- `data_layer_conventions_policy.md` — UUID v7 primary keys
- `tool_naming_convention_policy.md` — `engine.gate_*` naming convention
- `audit_event_taxonomy.md` — `ENGINE_WORKFLOW_TYPE_REGISTERED` entry
- Block 03 Phase 02 — Workflow type registry and config (phase doc)
