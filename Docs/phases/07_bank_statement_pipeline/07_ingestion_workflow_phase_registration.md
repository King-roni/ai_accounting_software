# Block 07 — Phase 07: INGESTION Workflow Phase Registration

## References

- Block doc: `Docs/blocks/07_bank_statement_pipeline.md` (Phase 7.1–7.5 — the full pipeline as workflow phase)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 03 tool registration; Phase 05 gate evaluation; Phase 06 phase execution)
- Block doc: `Docs/blocks/12_out_workflow.md` and `Docs/blocks/13_in_workflow_and_invoice_generator.md` (consumers — `INGESTION` is phase 1 of both `OUT_MONTHLY` and `IN_MONTHLY`)

## Phase Goal

Wire Block 07's parser, normalizer, dedup engine, and evidence generator into the workflow engine as the `INGESTION` phase that both `OUT_MONTHLY` and `IN_MONTHLY` run first. After this phase, the engine knows how to invoke each step, what gates govern advancement, and how the phase advances `statement_uploads` from `UPLOADED` through to `ACCEPTED`.

## Dependencies

- Phase 02 (CSV parser tool)
- Phase 03 (PDF parser tool)
- Phase 04 (normalization tool)
- Phase 05 (dedup tool)
- Phase 06 (evidence PDF generation tool)
- Block 03 Phase 03 (tool registration framework)
- Block 03 Phase 04 (state machine — phase advances via `transitionRun`)
- Block 03 Phase 05 (gate evaluation framework)
- Block 03 Phase 06 (phase execution loop)

## Deliverables

- **Tool registrations** with `engine.registerTool` (per Block 03 Phase 03):
  - `bank_pipeline.parse_csv` — `(REVOLUT, CSV)` → `ParsedRow[]`. Side-effect: `READ_ONLY` (reads from Raw Upload). AI tier: `NONE`.
  - `bank_pipeline.parse_pdf` — `(REVOLUT, PDF)` → `ParsedRow[]`. Side-effect: `CALLS_EXTERNAL_API` (Document AI). AI tier: `EXTERNAL_LLM` (Tier 3 — Document AI is dispatched through Block 06's gateway).
  - `bank_pipeline.normalize` — `ParsedRow[]` → `NormalizedTransaction[]`. Side-effect: `READ_ONLY` (returns in-memory `NormalizedTransaction[]`; **does not insert** into `transactions` — that's owned by `dedupe`). AI tier: `NONE` for the deterministic path; `LOCAL_LLM` for the counterparty-extraction fallback (dispatched through Block 06 Phase 02's gateway).
  - `bank_pipeline.dedupe` — `NormalizedTransaction[]` → `DedupResult[]`. Side-effect: `WRITES_RUN_STATE` (inserts `NEW` rows into `transactions`; raises `review_issues` for `DUPLICATE_POSSIBLE` / `NEEDS_REVIEW`; silently rejects `DUPLICATE_EXACT` rows with audit). AI tier: `NONE`.
  - `bank_pipeline.generate_evidence_pdfs` — `Transaction[]` → `EvidencePDF[]`. Side-effect: `WRITES_RUN_STATE`. AI tier: `NONE`.
  - Each declaration carries its `input_schema`, `output_schema`, `failure_semantics` (`RETRYABLE` for parsers, `RETRYABLE` for normalize, `RETRYABLE` for dedupe, `RETRYABLE` for evidence-generation), and a `dedup_key_generator` keyed on `statement_upload_id` + tool name.
- **`INGESTION` phase definition** for both `OUT_MONTHLY` and `IN_MONTHLY` (registered via Block 12/13 once those are decomposed; this phase declares the contract):
  - Sequenced tools: `parse_csv` OR `parse_pdf` (selected by `statement_uploads.file_format`) → `normalize` → `dedupe` → `generate_evidence_pdfs`.
  - The shared INGESTION between OUT and IN runs once per upload (Block 03 Phase 10's shared-phase coordination).
- **Status-transition ownership** — every `statement_uploads.upload_status` transition is driven by the engine's tool invocations under this phase:
  - `bank_pipeline.parse_csv` / `parse_pdf` move `UPLOADED → PARSING` on entry and to `PARSED` on success.
  - `bank_pipeline.dedupe` followed by `bank_pipeline.generate_evidence_pdfs` together move `PARSED → ACCEPTED` once dedup is complete and every `NEW` row has its evidence PDF.
  - On failure at any step, the tool emits `MODEL_ERROR` per Block 03 Phase 08 and the upload moves to `FAILED` if the failure is unrecoverable.
- **Partial-upload detection (Phase 08) is co-located inside the registered tools.** The `parse_csv`, `parse_pdf`, and `normalize` tools all detect partial-upload signals as part of their work and write them to `parse_warnings` / produce review issues. There is no separate `bank_pipeline.detect_partial_upload` tool — partial behaviour is woven into the four primary tools.
- **Entry gate** for INGESTION:
  - `statement_uploads.upload_status = UPLOADED` for the upload referenced by the run.
- **Exit gate** for INGESTION (per Block 03 Phase 05):
  - `statement_uploads.upload_status = ACCEPTED`.
  - All rows from the upload have a `dedup_status` set (`NEW`, `DUPLICATE_EXACT`, `DUPLICATE_POSSIBLE`, `NEEDS_REVIEW`).
  - All `NEW` transactions have an `evidence_pdfs` row.
  - Any `DUPLICATE_POSSIBLE` or `NEEDS_REVIEW` rows have produced their review issues — they do not block exit; they're flagged for review in the existing queue.
  - On gate failure, the phase holds at the failed step per Block 03 Phase 05's `HOLD` semantics; user action via Block 14 advances it.
- **Failure paths** (consumed by Block 03 Phase 08):
  - Parse failure → phase `HOLDING`; review issue raised.
  - Normalization or evidence-generation failure on individual rows → continues, raises HIGH review issues for the affected rows; the phase still exits if the gate is otherwise satisfied.
  - Catastrophic failure (e.g., Storage outage during evidence write) → `MODEL_ERROR transient: true`; Block 03 Phase 08's bounded retry applies.
- **Audit events:** `INGESTION_PHASE_STARTED`, `INGESTION_PHASE_COMPLETED`, `INGESTION_PHASE_HOLDING` (with reason).

## Definition of Done

- The five tools are registered at engine startup and are invokable through `engine.invokeTool` with the right schemas.
- A statement upload triggers the `INGESTION` phase; the phase runs the tools in sequence and exits when the gate passes.
- A statement with mixed `NEW` + `DUPLICATE_*` rows exits cleanly (the duplicates are flagged but don't block exit).
- A parse failure holds the phase and raises a review issue.
- An evidence-PDF failure on one row continues the batch and raises a HIGH review issue for that row.
- Replaying the phase (after a process kill mid-execution) produces identical results — the dedup-key generators on each tool prevent double-write.
- The shared-phase coordination between OUT and IN (Block 03 Phase 10) means INGESTION runs once even when both workflows are triggered from the same upload.

## Sub-doc Hooks (Stage 4)

- **Tool registration declarations sub-doc** — exact JSON schemas for inputs and outputs of each of the five tools.
- **`INGESTION` phase definition sub-doc** — the canonical phase definition shared between Block 12 and Block 13.
- **Entry/exit gate functions sub-doc** — the SQL queries that back each gate, edge cases (empty statements, all-duplicate uploads).
- **Failure-mode mapping sub-doc** — full table of failure types per tool → review-issue templates and severities.
- **Shared-phase coordination sub-doc** — how the OUT/IN deduplication of INGESTION work plays out at the tool-invocation level.
