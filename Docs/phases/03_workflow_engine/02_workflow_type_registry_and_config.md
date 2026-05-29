# Block 03 — Phase 02: Workflow Type Registry & Per-Business Config

## References

- Block doc: `Docs/blocks/03_workflow_engine.md` (Workflow Type section)
- Decisions log: `Docs/decisions_log.md` (static + per-business config registry)

## Phase Goal

Define every workflow type as a static, code-resident object whose phase sequence is fixed in source. Layer a per-business config table on top that can enable or disable specific phases or tools per business — without changing any workflow type definition. After this phase, the engine knows which phases run for a given `(business, workflow_type)` pair.

## Dependencies

- Phase 01 (schema; the registry references phase names that exist in `workflow_phase_states`)

## Deliverables

- **Workflow type definitions** (in code, compiled in):
  - `OUT_MONTHLY` — full phase sequence per Block 12.
  - `IN_MONTHLY` — full phase sequence per Block 13.
  - `OUT_ADJUSTMENT` — adjustment phase sequence per Block 12.
  - `IN_ADJUSTMENT` — adjustment phase sequence per Block 13.
  - Each type carries: `name`, `phases[]` (ordered), `default_trigger_modes` (`MANUAL`, `EVENT`, or both), `requires_parent_run` (true for adjustments).
- **`business_workflow_config` table:**
  - `business_id`, `workflow_type`, `enabled_phases` (JSON array of phase names to include — defaults to all), `enabled_tools` (JSON array — defaults to all), `created_at`, `updated_at`.
  - Allows per-business enable/disable of phases (e.g., a business that doesn't use Drive can disable `EVIDENCE_DISCOVERY_DRIVE`).
  - Cannot add phases that aren't in the type's static sequence — config is subtractive, not additive.
- **Effective-sequence resolver** — given `(business_id, workflow_type)`, returns the resolved phase sequence after applying per-business config.
- **Validation:** a config that disables a non-optional phase is rejected. Each phase declaration in the workflow type carries an `optional` flag; only optional phases can be disabled.
- **Audit events:** `WORKFLOW_CONFIG_UPDATED` (when a business changes its phase or tool toggles).

## Definition of Done

- All four workflow types are registered at engine startup.
- Engine can query `getEffectivePhaseSequence(business_id, workflow_type)` and get the right phases back, with disabled phases excluded.
- A business can disable an optional phase (e.g., Drive finder); subsequent runs for that business skip the phase.
- Disabling a non-optional phase fails fast with a structured error.
- Reading the registry is read-only — runtime cannot mutate workflow type definitions.

## Sub-doc Hooks (Stage 4)

- **Workflow type definition sub-doc** — declarative format, naming conventions, how new types are added (always a code change, never config).
- **Per-business config schema sub-doc** — exact column types, validation rules, default-on-create behaviour.
- **Optional vs mandatory phase sub-doc** — which phases each workflow type marks optional, with rationale per phase.
