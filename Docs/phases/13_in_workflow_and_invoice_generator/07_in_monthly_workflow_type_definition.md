# Block 13 — Phase 07: `IN_MONTHLY` Workflow Type Definition + Per-Business IN Config

## References

- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (Phase Sequence; Workflow Type Registration; Triggers)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 02 — workflow type registry; Phase 03 — tool registration; Phase 06 — phase execution)
- Block doc: `Docs/blocks/12_out_workflow.md` (parallel structure — symmetric `OUT_MONTHLY` definition)

## Phase Goal

Register the canonical `IN_MONTHLY` static workflow type with the engine, plus the per-business IN config that toggles optional behavior. After this phase, calling `engine.startWorkflowRun({ type: 'IN_MONTHLY', business_id, period })` produces a fully-typed run; the paired-trigger linkage with `OUT_MONTHLY` (Block 12 Phase 04) is honored; the per-business `auto_start_on_statement_upload` toggle works symmetrically with the OUT-side.

## Dependencies

- Phase 01 (`invoices` — IN matching reads from this table)
- Phase 03 (lifecycle named functions)
- Phase 08 (`IN_FILTER` phase + tool — sequenced at position 3)
- Phase 09 (gate-function library + `HUMAN_REVIEW_HOLD` for IN — sequenced at position 8)
- Phase 10 (income matching integration — sequenced at position 4)
- Block 03 Phase 02 (workflow type registry)
- Block 07 Phase 09 (event-driven trigger surface — `STATEMENT_UPLOAD_COMPLETED`)
- Block 12 Phase 04 (OUT/IN parallel coordination — owns the paired-trigger contract)
- Block 11 Phase 09 (`LEDGER_PREPARATION` consolidation note — applies symmetrically here)
- Block 06 Phase 11 (`AI_END_SCAN`)
- Block 15 (`FINALIZATION` phase — phase docs not yet written; durable contract is the phase name)

## Deliverables

- **`in_workflow_business_config` table** (parallel to Block 12 Phase 01's OUT config):
  - `id` (UUID v7), `organization_id`, `business_id`
  - `auto_start_on_statement_upload` (boolean; default `true`) — when `false`, event triggers do NOT create a run; user must invoke manual trigger.
  - `created_at`, `updated_at`, `last_updated_by`
  - **Unique constraint** on `(business_id)` — exactly one config row per business; created on business provisioning.
  - **Indexes:** `(business_id)`.
- **Bootstrap loader** — `loadInWorkflowConfigForBusiness(business_id) → void`:
  - Idempotent; called by Block 02 Phase 01's business-provisioning flow.
  - Inserts the default config row at business creation time.
  - Emits `IN_WORKFLOW_CONFIG_INITIALIZED`.
- **Settings API:**
  - `inConfig.update({ business_id, ...patch })` and `inConfig.get({ business_id })` — Owner / Admin only via `WORKFLOW_CONFIG_MANAGE` permission surface (Block 02 Phase 04).
- **Triggers — manual + event** (symmetric with Block 12 Phase 08):
  - **Manual trigger** — `in_workflow.start_run_manually({ business_id, period_start, period_end, started_by, manual_trigger_note? }) → { run_id }`:
    - Tool registration: side-effect `WRITES_RUN_STATE`; AI tier `NONE`.
    - Permission gate: `WORKFLOW_TRIGGER` surface (Block 02 Phase 04 — same as Block 12).
    - Active-run dedup: Block 03 Phase 10's per-business concurrency lock scoped to `(business_id, period_start, period_end, 'IN_MONTHLY')`.
    - Period validation: 6-year retention window (same as Block 12 Phase 08).
    - Period-already-finalized rejection (`IN_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED`).
  - **Event-driven trigger** — subscribed to `STATEMENT_UPLOAD_COMPLETED`:
    - `in_workflow.handle_statement_upload_event(...)` — symmetric with the OUT handler.
    - Per-business gate: `auto_start_on_statement_upload = false` → emits `IN_WORKFLOW_AUTO_START_SUPPRESSED`.
    - Event-replay dedup: Block 03 Phase 09's `event_id`-based mechanism.
    - **Pair with OUT trigger:** Block 12 Phase 04's `OUT_WORKFLOW_PAIRED_RUN_LINKED` event captures the linkage. If OUT's auto-start is suppressed, IN still proceeds (independent).
- **`IN_MONTHLY` workflow type definition** — registered via `engine.registerWorkflowType(...)`:
  - **`type` = `'IN_MONTHLY'`**
  - **Phase sequence** (8 registered positions, consolidated from architecture doc's 9-phase mental model — `LEDGER_PREPARATION` covers both ledger and VAT per Block 11 Phase 09's consolidation, parallel to Block 12 Phase 02's note):
    1. `INGESTION` (Block 07; shared with OUT — Block 12 Phase 04 owns the dedup contract)
    2. `CLASSIFICATION` (Block 08; shared with OUT)
    3. `IN_FILTER` (Phase 08)
    4. `INCOME_MATCHING` (Block 10 Phase 08; the IN-side matching variant)
    5. `LEDGER_PREPARATION` (Block 11 Phase 09; consolidates `INCOME_LEDGER_PREPARATION` + `VAT_CLASSIFICATION` from the architecture doc)
    6. `AI_END_SCAN` (Block 06 Phase 11)
    7. `HUMAN_REVIEW_HOLD` (Phase 09; **side phase** — entered conditionally per the gate)
    8. `FINALIZATION` (Block 15)
  - **Phase mapping note (consumer-facing):** the architecture doc lists 9 phases (positions 5 + 6 = `INCOME_LEDGER_PREPARATION` + `VAT_CLASSIFICATION`). Block 11 Phase 09's consolidation makes them one runtime phase (`LEDGER_PREPARATION`). Block 14 / Block 16 consumers MUST query `LEDGER_PREPARATION` only — there is no separate `VAT_CLASSIFICATION_PHASE_*` event series. Same pattern as Block 12 Phase 02.
  - **Cross-block durable contract** — `IN_MONTHLY` does **not** invoke Block 09's `EVIDENCE_DISCOVERY_*` phases. Income matching consumes structured `Invoice` records (Phase 01), not externally discovered documents. Block 09 is not a dependency of `IN_MONTHLY`.
- **Audit-event domain split for Block 13:**
  - **Domain `INVOICE`** — Invoice Generator events (Phases 01, 03, 04, 06).
  - **Domain `RECURRING_INVOICE`** — Phase 05.
  - **Domain `CLIENT`** — Phase 02.
  - **Domain `CREDIT_NOTE`** — Phase 06's credit-note path.
  - **Domain `IN_WORKFLOW`** — `IN_MONTHLY` events (Phases 07, 08, 09, 10).
  - **Domain `IN_ADJUSTMENT`** — Phase 11's adjustment events.
  - The split is documented in the audit-taxonomy sub-doc owned by Block 05 Phase 02.
- **Side-phase semantics** — `HUMAN_REVIEW_HOLD` is the only side phase in `IN_MONTHLY`'s sequence (parallel to Block 12 Phase 02 — Block 12 has both `MANUAL_UPLOAD_HOLD` and `HUMAN_REVIEW_HOLD`; Block 13 has only `HUMAN_REVIEW_HOLD` because IN has no manual-upload analog — invoices are produced by the generator, not uploaded).
- **Audit events** (declared in Phase 01 of this block; emitted at boot and on type-instance progression):
  - `IN_WORKFLOW_TYPE_REGISTERED` (boot — emitted on `registerInMonthlyType()`)
  - `IN_WORKFLOW_CONFIG_INITIALIZED`
  - `IN_WORKFLOW_CONFIG_UPDATED`
  - `IN_WORKFLOW_RUN_STARTED_MANUALLY`
  - `IN_WORKFLOW_RUN_STARTED_BY_EVENT`
  - `IN_WORKFLOW_AUTO_START_SUPPRESSED`
  - `IN_WORKFLOW_EVENT_TRIGGER_DEDUPLICATED`
  - `IN_WORKFLOW_RUN_ALREADY_ACTIVE_REJECTED`
  - `IN_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED`
  - `IN_WORKFLOW_RUN_REJECTED_RETENTION_EXPIRED` — fires only when a manual-trigger attempts to start `IN_MONTHLY` for a period ending more than 6 years ago (rare backfill scenario for a long-dormant business that was never finalized for that period). Adjustments to already-finalized old periods route through Phase 11 (`IN_ADJUSTMENT_REJECTED_RETENTION_EXPIRED` is the parallel event); the two events are not redundant — they cover the never-finalized-old-period case (here) and the finalized-but-old-adjustment case (Phase 11) respectively.
  - `IN_WORKFLOW_PHASE_SKIPPED_BY_CONFIG`

## Definition of Done

- `IN_MONTHLY` is registered at engine boot with the 8-position phase sequence.
- A user manually starts an `IN_MONTHLY` run; the engine creates a `workflow_runs` row; phases progress in sequence.
- A `STATEMENT_UPLOAD_COMPLETED` event triggers both `OUT_MONTHLY` and `IN_MONTHLY`; the pair is linked via Block 12 Phase 04's `paired_run_id`.
- Disabling `auto_start_on_statement_upload` suppresses the IN run on event arrival; the user must manually trigger.
- A start for an already-finalized period is rejected with the right audit event.
- `IN_MONTHLY` does not invoke Block 09's evidence-discovery phases — verified by inspecting the registered phase sequence.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **`IN_MONTHLY` type-definition sub-doc** — exact JSON / TypeScript registration shape.
- **Per-business toggle sub-doc** — symmetric with Block 12 Phase 01's hooks.
- **Pair-trigger sequencing sub-doc** — exact ordering of OUT vs IN run creation in the event handler; sub-doc owns Stage 1 default.
- **Phase-renumbering migration sub-doc** — what to do if the architecture-doc consolidation is later split.
