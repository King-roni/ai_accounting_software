# Block 12 — Phase 09: `OUT_ADJUSTMENT` Workflow Type

## References

- Block doc: `Docs/blocks/12_out_workflow.md` (OUT_ADJUSTMENT Variant)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 11 — adjustment runs)
- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (additive interleaved adjustments; reopen-period semantics)
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 10 — retention; the 6-year window)
- Decisions log: `Docs/decisions_log.md` (adjustments interleaved with explicit reason + delta; 6-year retention cap; concurrency with monthly runs is allowed)

## Phase Goal

Register the `OUT_ADJUSTMENT` static workflow type for corrections to a finalized OUT period: a separate 6-phase sequence with its own state machine, an explicit reason + structured delta on every adjustment record (Stage 1), no auto-modification of the original finalized records (additive only), concurrency with `OUT_MONTHLY` (does not block forward progress per Stage 1), and a 6-year retention cap.

## Dependencies

- Phase 01 (registration entry point — `registerOutAdjustmentType()`)
- Phase 02 (alignment with `OUT_MONTHLY`'s phase-name conventions)
- Phase 05 (gate-function library — `OUT_ADJUSTMENT` reuses the LEDGER_PREPARATION and AI_END_SCAN gates with adjustment variants)
- Phase 07 (`HUMAN_REVIEW_HOLD` is reused by `ADJUSTMENT_HUMAN_REVIEW`; permission gate may differ — sub-doc)
- Block 03 Phase 11 (adjustment runs framework — `parent_run_id`, additive-only enforcement)
- Block 04 Phase 10 (retention engine — owns the 6-year window enforcement)
- Block 11 Phase 09 (`LEDGER_PREPARATION` is reused for adjustment ledger preparation; the architecture-doc note "Adjustment records carry an explicit reason and a structured delta against the original" requires Block 11's adjustment-entry schema sub-doc)
- Block 15 (`FINALIZATION` for adjustments — phase docs not yet written; the contract is `ADJUSTMENT_FINALIZATION` is a named phase that interleaves into the existing archive additively)

## Deliverables

- **`OUT_ADJUSTMENT` workflow type definition** — registered via `engine.registerWorkflowType(...)`:
  - **`type` = `'OUT_ADJUSTMENT'`**
  - **Phase sequence** (5 registered positions; consolidated from architecture-doc 6-phase mental model):
    1. `ADJUSTMENT_INTAKE` — user specifies what to amend; uploads new evidence if needed.
    2. `ADJUSTMENT_LEDGER_PREP` — Block 11 produces adjustment ledger entries AND reapplies VAT classification (consolidated phase; uses Block 11 Phase 09's full LEDGER_PREPARATION tool sequence narrowed to the adjustment scope).
    3. `ADJUSTMENT_AI_REVIEW` — Block 06 Phase 11's end-scan over the adjustment scope.
    4. `ADJUSTMENT_HUMAN_REVIEW` — same shape as `HUMAN_REVIEW_HOLD` (Phase 07) — recorded user approval required.
    5. `ADJUSTMENT_FINALIZATION` — Block 15 interleaves the adjustment entries into the existing finalized archive additively.
  - **Phase mapping note (consumer-facing):** the architecture doc lists 6 phases (`ADJUSTMENT_VAT` separate from `ADJUSTMENT_LEDGER_PREP`). Block 11 Phase 09's consolidation makes them one phase at runtime (parallel to Phase 02's `OUT_MONTHLY` consolidation). Downstream consumers (Block 14 review queue, Block 16 dashboard) MUST query `ADJUSTMENT_LEDGER_PREP` only — there is no `ADJUSTMENT_VAT_PHASE_*` event series.
  - **Gate references** — reuse Phase 05's gates with adjustment-variant wrappers (e.g., `gate.out.adjustment_ledger_prep_complete` wraps `gate.out.ledger_preparation_complete` but scopes the row set to the adjustment entries only).
- **`ADJUSTMENT_INTAKE` phase** — declared here:
  - Tool registration: `out_workflow.adjustment_intake`. Side-effect: `WRITES_RUN_STATE` (creates an `adjustment_records` row; optionally writes new `documents` rows when evidence is uploaded). AI tier: `NONE`.
  - **Required input** (Stage 1; non-negotiable):
    - `parent_run_id` (FK to the `OUT_MONTHLY` run that finalized the period being amended; resolves to the finalized period via `workflow_runs.period_start` / `period_end`)
    - `reason` (free text — mandatory; minimum length enforced; sub-doc owns the threshold)
    - `delta` (structured — what's being changed; see "Adjustment delta shape" below)
    - `requesting_user_id` (the user initiating the adjustment)
  - **Permission gate:** Owner, Admin, Bookkeeper. Same as monthly-run start.
- **`adjustment_records` table** — declared in Phase 01; this phase is the consumer / writer (`out_workflow.adjustment_intake` writes the row).
- **Adjustment delta shape** (Stage 1 representative; sub-doc owns the full per-kind schema):
  - `RECLASSIFY_TRANSACTION` — `{ transaction_id, old_type, new_type, expected_impact: 'ledger_recompute' }`
  - `ADD_EVIDENCE` — `{ transaction_id, new_document_id, old_match_status, expected_new_match_status }`
  - `CORRECT_VAT_TREATMENT` — `{ ledger_entry_id, old_treatment, new_treatment }` (this triggers Block 11's manual-override path on the entry; sub-doc tracks the relationship)
  - `ADJUST_AMOUNT` — `{ ledger_entry_id, old_amount, new_amount, currency }` (rare — most amount changes route through `RECLASSIFY` or `ADD_EVIDENCE`)
  - `OTHER` — free-form `{ description, structured_payload }`. **`OTHER` always sets `requires_accountant_review = true` on every produced adjustment ledger entry**, and `ADJUSTMENT_HUMAN_REVIEW` is mandatory (the gate cannot fast-path through). This guarantees that ambiguous adjustments don't slip past human review even if downstream phases find no other reason to flag them.
- **Additive-only enforcement (Block 03 Phase 11 owns the mechanism; restated for clarity):**
  - The original finalized `draft_ledger_entries` rows are **never modified** by an adjustment run. Block 11's adjustment-entry schema produces new rows with `parent_transaction_id` (or null for adjustment-only entries) carrying a delta-style payload.
  - Block 15's `ADJUSTMENT_FINALIZATION` interleaves the new rows into the archive without touching the original locked rows. The finalized archive's bundle gains a new manifest entry for the adjustment run.
- **Retention-cap enforcement:**
  - `out_workflow.adjustment_intake` checks `parent_period_start >= now() - interval '6 years'` (Block 04 Phase 10's canonical 6-year-legal-retention-window phrasing). Periods outside the window are rejected with `OUT_ADJUSTMENT_REJECTED_RETENTION_EXPIRED`.
  - The cap is computed per period (not per-original-finalization-date) — what matters is the period's bookkeeping date.
- **Concurrency with monthly runs (Stage 1 — explicit decision):**
  - An open `OUT_ADJUSTMENT` does NOT block the next `OUT_MONTHLY`. Block 03 Phase 10's per-business concurrency rule is scoped per `(business_id, period_start, period_end, type)` — `OUT_MONTHLY` and `OUT_ADJUSTMENT` for the same period can both be active, AND `OUT_ADJUSTMENT` for an old period and `OUT_MONTHLY` for the current period can both be active.
  - The audit trail records both `run_id`s on every adjustment-touched ledger entry so amendments and forward progress remain traceable.
  - **Cross-run consistency:** if `OUT_ADJUSTMENT` finalizes after a downstream `OUT_MONTHLY` already started, the adjustment is interleaved into the older period's archive only — it does NOT affect the newer period's draft entries.
- **Triggers:**
  - **Manual only** for Stage 1. No event-driven adjustment triggers. The user must explicitly initiate from the dashboard's "Adjust this period" surface (Block 16 owns the surface).
  - The architecture-doc's allowance for monthly auto-triggers does not extend to adjustments.
- **Adjustment progress on a finalized period:**
  - Block 16's dashboard shows finalized periods with a "pending adjustment" indicator when an `OUT_ADJUSTMENT` is active for that period. Sub-doc owns the indicator's visual treatment.
  - The indicator is informational only — it doesn't block any user action on the period (e.g., starting another adjustment, viewing the finalized archive).
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `OUT_ADJUSTMENT`):
  - `OUT_ADJUSTMENT_RUN_CREATED`
  - `OUT_ADJUSTMENT_INTAKE_COMPLETED` (with `delta_kind`)
  - `OUT_ADJUSTMENT_REJECTED_RETENTION_EXPIRED`
  - `OUT_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED` (when the parent run isn't `FINALIZED` — adjustments are only valid against finalized periods)
  - `OUT_ADJUSTMENT_INTERLEAVED_INTO_ARCHIVE` (emitted by Block 15 on `ADJUSTMENT_FINALIZATION`; declared here for contract closure)

## Definition of Done

- `OUT_ADJUSTMENT` is registered at engine boot with the 6-phase sequence.
- A user with appropriate role calls `out_workflow.adjustment_intake` against a finalized 3-year-old period; the run starts; the adjustment records are persisted; `OUT_ADJUSTMENT_RUN_CREATED` and `OUT_ADJUSTMENT_INTAKE_COMPLETED` fire.
- A call against a 7-year-old period is rejected with `OUT_ADJUSTMENT_REJECTED_RETENTION_EXPIRED`.
- A call against a period that was never finalized is rejected with `OUT_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED`.
- An open `OUT_ADJUSTMENT` does not block `OUT_MONTHLY` for the next period; both can run concurrently; both run ids are recorded.
- The original finalized `draft_ledger_entries` rows are NEVER modified — verified by a test inserting an adjustment and confirming the original rows have unchanged `LOCKED` status and identical content.
- `ADJUSTMENT_FINALIZATION` produces an additive archive-bundle entry without touching the prior bundle's locked entries.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Adjustment delta schema sub-doc** — full per-kind JSONB shape, validation rules.
- **Adjustment-intake UX sub-doc** — dashboard surface, period picker, evidence-upload flow.
- **Concurrency audit sub-doc** — exact dual-run-id record on adjustment-touched entries.
- **`pending adjustment` indicator UX sub-doc (Block 16)** — visual treatment, click-through.
- **Multiple-adjustments-per-period sub-doc** — what happens when the user initiates two adjustments against the same period; ordering rules.
- **Adjustment-vs-recompute boundary sub-doc** — when a `CORRECT_VAT_TREATMENT` adjustment defers to Block 11's manual-override vs creating a new adjustment record.
