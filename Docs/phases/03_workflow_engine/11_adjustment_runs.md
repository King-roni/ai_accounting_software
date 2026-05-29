# Block 03 — Phase 11: Adjustment Runs

## References

- Block doc: `Docs/blocks/03_workflow_engine.md` (Adjustment runs section)
- Block doc: `Docs/blocks/12_out_workflow.md` (OUT_ADJUSTMENT phase sequence)
- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (IN_ADJUSTMENT phase sequence)
- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (additive archive entries)
- Decisions log: `Docs/decisions_log.md` (explicit reason + structured delta; 6-year amendment cap; concurrent with monthly runs)

## Phase Goal

Implement the adjustment workflow types end-to-end at the engine level: registration, the parent-run linkage, the explicit-reason-plus-structured-delta data model, and the 6-year cap. After this phase, the engine knows how to run an adjustment, link its records to a finalized period, and refuse adjustments outside the legal retention window.

The adjustment phase sequences themselves are owned by Blocks 12 and 13; this phase wires up the engine's side of the contract.

## Dependencies

- Phase 02 (workflow type registry — `OUT_ADJUSTMENT` and `IN_ADJUSTMENT` registered here)
- Phase 04 (state machine — adjustments use the same lifecycle)
- Phase 06 (execution engine — adjustments run through the same loop)
- Phase 09 (trigger engine — adjustments are manual-trigger only)
- Phase 10 (concurrency — adjustments allowed alongside monthly runs)
- Block 15 (additive archive entries — finalization of an adjustment writes new records to the existing archive)

## Deliverables

- **`OUT_ADJUSTMENT` and `IN_ADJUSTMENT` registered** in Phase 02's registry. Each declares:
  - The phase sequence per Blocks 12/13 (`ADJUSTMENT_INTAKE`, `ADJUSTMENT_LEDGER_PREP`, `ADJUSTMENT_VAT`, `ADJUSTMENT_AI_REVIEW`, `ADJUSTMENT_HUMAN_REVIEW`, `ADJUSTMENT_FINALIZATION`).
  - `requires_parent_run = true`.
  - `default_trigger_modes = [MANUAL]` only — adjustments are never event-triggered.
- **Parent run linkage** — `workflow_runs.parent_run_id` is required on adjustment runs. The trigger validates that:
  - The parent run exists.
  - The parent run is in `FINALIZED` state.
  - The parent run's `workflow_type` matches the adjustment type's target (`OUT_ADJUSTMENT` → `OUT_MONTHLY`, `IN_ADJUSTMENT` → `IN_MONTHLY`).
- **Adjustment record schema** (used by `ADJUSTMENT_LEDGER_PREP` in Block 11 and stored in the operational DB until finalization):
  - `id`, `workflow_run_id`, `target_record_id` (FK to the original record being amended), `target_record_type` (e.g., `LEDGER_ENTRY`, `MATCH_RECORD`).
  - `reason` (non-empty free text — required at intake).
  - `delta` (structured JSONB: `{ field_name: { old_value, new_value }, ... }`).
  - `created_at`, `created_by`.
- **6-year amendment cap enforcement:**
  - At trigger time, validate `parent_run.finalized_at` is within the last 6 years.
  - Reject older targets with `WORKFLOW_ADJUSTMENT_REJECTED_OUTSIDE_RETENTION` and a clear user message.
  - The cap is anchored on `parent_run.finalized_at`, not on the period the run covers.
- **Reason and delta required at intake:**
  - `ADJUSTMENT_INTAKE` phase's exit gate refuses to advance until at least one adjustment record with a non-empty reason and a non-empty delta has been created.
- **Finalization handoff:**
  - `ADJUSTMENT_FINALIZATION` calls Block 15's archive-additive path. The original archive's manifest is bumped to a new version (`manifest_v2.json`, etc.) and the adjustment records are written as new files within the same archive bundle (per the Stage 1 archive format — single sealed zip with versioned manifests).
- **Audit events:** `WORKFLOW_ADJUSTMENT_CREATED`, `WORKFLOW_ADJUSTMENT_RECORD_ADDED`, `WORKFLOW_ADJUSTMENT_FINALIZED`, `WORKFLOW_ADJUSTMENT_REJECTED_OUTSIDE_RETENTION`, `WORKFLOW_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED`.

## Definition of Done

- A user can start an `OUT_ADJUSTMENT` against a finalized `OUT_MONTHLY` run; the adjustment proceeds through its phase sequence.
- An adjustment without a `parent_run_id` is rejected at trigger.
- An adjustment whose parent isn't `FINALIZED` is rejected.
- An adjustment whose parent finalized > 6 years ago is rejected with the right audit event.
- An adjustment cannot finalize without at least one adjustment record carrying a non-empty reason and delta.
- Adjustment finalization writes additive records to the parent's archive without modifying any original record (Block 15 contract).
- Adjustments run concurrently with active monthly runs (Phase 10's concurrency rule honoured).
- Tests cover: happy path, missing parent, non-finalized parent, outside-retention parent, missing reason, finalization handoff to Block 15.

## Sub-doc Hooks (Stage 4)

- **Adjustment record schema sub-doc** — exact column types, JSONB shape for `delta`, validation rules.
- **Reason text requirements sub-doc** — minimum length, prohibited content (e.g., empty whitespace), localisation considerations.
- **6-year cap sub-doc** — exact date arithmetic (calendar years vs 365 days, time zones), legal-hold interaction (a business under legal hold may have its cap extended).
- **Archive-additive handoff sub-doc** — the contract between Block 03's `ADJUSTMENT_FINALIZATION` and Block 15's manifest-versioning path.
