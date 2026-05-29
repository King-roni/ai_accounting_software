# Block 08 — Phase 09: CLASSIFICATION Workflow Phase Registration

## References

- Block doc: `Docs/blocks/08_transaction_classification_and_tagging.md`
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 03 tool registration; Phase 05 gates; Phase 06 execution)
- Block doc: `Docs/blocks/12_out_workflow.md` and `Docs/blocks/13_in_workflow_and_invoice_generator.md` (CLASSIFICATION runs as phase 2 of OUT_MONTHLY / IN_MONTHLY)

## Phase Goal

Wire all the classifier tools (Phases 02–07 + the snapshot from Phase 08) into the workflow engine as the `CLASSIFICATION` phase that runs immediately after INGESTION in both `OUT_MONTHLY` and `IN_MONTHLY`. After this phase, the engine knows how to invoke each step in order, what gates govern advancement, and how the phase advances every transaction from `PENDING` classification to either `AUTO_CONFIRMED` or `NEEDS_CONFIRMATION`.

## Dependencies

- Phase 02 (Layer 1 — deterministic rules)
- Phase 03 (Layer 2 — vendor memory)
- Phase 04 (Layer 3 — AI fallback)
- Phase 05 (tag system)
- Phase 06 (custom tags)
- Phase 07 (confidence merging + auto-confirm)
- Phase 08 (taxonomy snapshot)
- Block 03 Phase 03 (tool registration framework)
- Block 03 Phase 04 (state machine — phase advances via `transitionRun`)
- Block 03 Phase 05 (gate evaluation)
- Block 03 Phase 06 (phase execution loop)

## Deliverables

- **Tool registrations** with `engine.registerTool`:
  - `classification.snapshot_taxonomy` — captures the taxonomy snapshot on `workflow_runs`. Side-effect: `WRITES_RUN_STATE`. AI tier: `NONE`.
  - `classification.apply_layer1` — runs deterministic rules over the run's transactions. Side-effect: `READ_ONLY` (returns proposed classifications in memory; nothing written to `transactions` yet). AI tier: `NONE`.
  - `classification.apply_layer2` — runs vendor-memory lookup for transactions Layer 1 didn't resolve cleanly. Side-effect: `READ_ONLY`. AI tier: `NONE`.
  - `classification.apply_layer3` — runs AI fallback through Block 06's gateway for transactions Layers 1 + 2 didn't resolve. Side-effect: `READ_ONLY` from this tool's perspective on `transactions` (it produces in-memory `Layer3Result`); the gateway separately writes `ai_usage_records` per Block 06 Phase 07. AI tier: `EXTERNAL_LLM` — declared at the maximum tier the tool can reach so the gateway's cost ceiling, redaction policy, and authorization scope cover both Tier 2 and the explicit Tier 3 escalation. **Tier 2 → Tier 3 is not a retry**: when Tier 2 confidence is below threshold, an explicit second gateway invocation is made at Tier 3 (audit-distinct), per Phase 04 and Block 06 Phase 01's "explicit, not silent" rule.
  - `classification.merge_and_score` — combines per-layer outputs, applies the multi-layer agreement boost / disagreement penalty (Phase 07), assigns the primary tag from the active snapshot (Phase 05/08), falls back to the type's default tag if no tag was pinned. Side-effect: `READ_ONLY`.
  - `classification.assign_status` — writes the final `transaction_type`, `system_tag`, `secondary_tags`, `classification_status`, `classification_confidence`, `classification_method` columns; raises `NEEDS_CONFIRMATION` review issues for below-threshold rows; updates `recurring_vendor_memory.confirmations_count` for AUTO_CONFIRMED rows. Side-effect: `WRITES_RUN_STATE` (writes `transactions`, `recurring_vendor_memory`, `review_issues`). AI tier: `NONE`.
- **`CLASSIFICATION` phase definition** for both `OUT_MONTHLY` and `IN_MONTHLY` (the same phase definition is referenced by both — Block 12/13 will declare phase 2 = `CLASSIFICATION` when those are decomposed):
  - Sequenced tools: `snapshot_taxonomy` → `apply_layer1` → `apply_layer2` → `apply_layer3` → `merge_and_score` → `assign_status`.
- **Entry gate** for CLASSIFICATION:
  - All transactions for the run exist in `transactions` (from INGESTION) with `classification_status = PENDING` or null.
  - **Snapshot freshness rule:** if `workflow_runs.classification_taxonomy_snapshot` is non-null (re-entry case after a hold), it is reused; if null, `snapshot_taxonomy` runs first and captures it. The snapshot is captured exactly once per run.
- **Exit gate** for CLASSIFICATION (per Block 03 Phase 05):
  - Every transaction has `classification_status` either `AUTO_CONFIRMED` or `NEEDS_CONFIRMATION`. No transaction remains `PENDING` or null.
  - Every transaction has a non-null `transaction_type` (`UNKNOWN` is acceptable but `null` is not).
  - All `NEEDS_CONFIRMATION` rows have produced their review issues.
  - On gate failure, the phase holds at the failed step per Block 03 Phase 05's `HOLD` semantics.
- **Per-business config interaction:**
  - A business may disable `apply_layer3` (the AI fallback) via `business_workflow_config` (Block 03 Phase 02). When disabled, transactions Layers 1 + 2 didn't resolve are routed directly to `NEEDS_CONFIRMATION` with `classification_method = NO_AI_AVAILABLE`. This honors the per-business Tier 3 opt-out chain.
- **Audit events:** `CLASSIFICATION_PHASE_STARTED`, `CLASSIFICATION_PHASE_COMPLETED` (with per-status counts), `CLASSIFICATION_PHASE_HOLDING` (with reason).

## Definition of Done

- All six tools register at engine startup with the right schemas, side-effects, and AI tiers.
- A test workflow run with mixed transactions completes the CLASSIFICATION phase with every transaction in `AUTO_CONFIRMED` or `NEEDS_CONFIRMATION`.
- Disabling `apply_layer3` for a business causes unresolved transactions to fall through to `NEEDS_CONFIRMATION` with `classification_method = NO_AI_AVAILABLE`.
- A simulated AI gateway failure on `apply_layer3` triggers Block 03 Phase 08's retry policy; on persistent failure the phase enters `HOLDING` with a HIGH review issue.
- Replaying the phase (after a process kill) produces identical results — every tool's dedup-key generator prevents double-write.
- The shared-phase coordination between OUT and IN (Block 03 Phase 10) means CLASSIFICATION runs once even when both workflows are triggered from the same upload.

## Sub-doc Hooks (Stage 4)

- **Tool input/output schema sub-doc** — exact JSON schemas per tool, including the in-memory `LayerResult` types passed between layers.
- **`CLASSIFICATION` phase definition sub-doc** — the canonical phase definition shared between Block 12 and Block 13.
- **Entry/exit gate functions sub-doc** — the SQL queries that back each gate.
- **Per-business config interaction sub-doc** — exact behaviour when `apply_layer3` is disabled.
- **Failure-mode mapping sub-doc** — full table of failure types per tool → review-issue templates and severities.
