# Block 09 — Phase 09: EVIDENCE_DISCOVERY Workflow Phase Registration

## References

- Block doc: `Docs/blocks/09_document_intake_and_extraction.md`
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 03 tool registration; Phase 05 gates; Phase 06 execution)
- Block doc: `Docs/blocks/12_out_workflow.md` (consumer — `EVIDENCE_DISCOVERY_EMAIL` and `EVIDENCE_DISCOVERY_DRIVE` register as phases of `OUT_MONTHLY`; the integer phase index is resolved at Block 12 decomposition)
- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (forward note: `IN_MONTHLY` does **not** consume `EVIDENCE_DISCOVERY_*` — confirmed in the Stage 1 fixes; this is not a dependency, just a non-consumption clarification)

## Phase Goal

Wire the email finder, Drive finder, manual-upload handler, OCR + extraction pipeline, and cross-source dedup into the workflow engine as the `EVIDENCE_DISCOVERY_EMAIL` and `EVIDENCE_DISCOVERY_DRIVE` phases of `OUT_MONTHLY`. After this phase, the engine knows how to discover, ingest, OCR, extract, and dedupe documents for OUT_EXPENSE transactions through the same registered-tool contract every other phase uses.

## Dependencies

- Phase 02 (state machine)
- Phase 03 (OCR pipeline)
- Phase 04 (field extraction)
- Phase 05 (email finder)
- Phase 06 (Drive finder)
- Phase 07 (manual upload path)
- Phase 08 (cross-source dedup)
- Block 03 Phase 03 (tool registration framework)
- Block 03 Phase 04 (state machine)
- Block 03 Phase 05 (gates)
- Block 03 Phase 06 (phase execution)

## Deliverables

- **Tool registrations:**
  - `intake.email_finder` — runs Phase 05's email finder for a set of OUT transactions. Side-effect: `WRITES_RUN_STATE` (creates `Document` rows + `document_source_links`). AI tier: `NONE` (Gmail API only — no AI in the search itself; OCR/extraction is a separate tool).
  - `intake.drive_finder` — runs Phase 06's Drive finder for OUT transactions still without candidates after email. Side-effect: `WRITES_RUN_STATE`. AI tier: `NONE`.
  - `intake.cross_source_dedupe` — runs Phase 08's content-hash dedup. Side-effect: `WRITES_RUN_STATE` (updates `documents.discovery_confidence`, inserts additional `document_source_links`). AI tier: `NONE`.
  - `intake.ocr_and_extract` — runs Phase 03's OCR + Phase 04's field extraction together as one tool invocation. Side-effect: `WRITES_RUN_STATE` (writes `documents.extracted_fields_json`, `documents.extraction_confidence_per_field`, persists the `document_extraction_results` row, and triggers the Phase 02 `INGESTED → EXTRACTED` transition). AI tier: `EXTERNAL_LLM` — declared at the maximum tier the tool can reach (Document AI is Tier 3, plus optional Tier 3 escalation for low-confidence extraction).
  - `intake.manual_upload_handler` — handles the post-confirm step of a manual upload (Phase 07): hashes the file, runs cross-source dedup, kicks off OCR + extraction. Side-effect: `WRITES_RUN_STATE`. AI tier: `NONE` for this handler itself — the AI calls happen inside the downstream `intake.ocr_and_extract` invocation, which carries the `EXTERNAL_LLM` declaration. Typically invoked from a user action (manual upload completion webhook) rather than as a scheduled phase step, but registered as a tool so re-runs and audits are uniform.
- **Phase definitions** — registered for `OUT_MONTHLY`:
  - **`EVIDENCE_DISCOVERY_EMAIL`** (registers under this name in OUT_MONTHLY; integer phase index resolved at Block 12 decomposition):
    - Sequenced tools: `intake.email_finder` → `intake.cross_source_dedupe` → `intake.ocr_and_extract` (for new, non-duplicate candidates only).
    - **Cross-source dedup runs BEFORE OCR + extraction** so the second-source case (when content was already discovered earlier) skips the expensive OCR step entirely — matching Phase 08's "skip OCR — they've already run" contract.
    - Entry gate: CLASSIFICATION phase complete; OUT_EXPENSE transactions identified.
    - Exit gate: every OUT_EXPENSE transaction has had email search executed (either resulting in candidates or a no-result audit event).
  - **`EVIDENCE_DISCOVERY_DRIVE`** (registers under this name in OUT_MONTHLY; integer phase index resolved at Block 12 decomposition):
    - Sequenced tools: `intake.drive_finder` → `intake.cross_source_dedupe` → `intake.ocr_and_extract` (for new, non-duplicate candidates only).
    - **Drive finder runs for every OUT_EXPENSE**, not only for those without email candidates — cross-source corroboration is one of its purposes (Phase 08's confidence boost requires Drive to potentially find the same content even when email already did).
    - Entry gate: `EVIDENCE_DISCOVERY_EMAIL` complete.
    - Exit gate: every OUT_EXPENSE transaction has had Drive search executed; cross-source dedup pass complete.
- **`IN_MONTHLY` does NOT register these phases.** Per the Block 07 scan and Block 13's correction, `IN_MONTHLY` matches against internal `Invoice` records produced by Block 13's Invoice Generator, not externally discovered documents.
- **Manual-upload re-entry path:**
  - When a user manually uploads a document after a `MANUAL_UPLOAD_HOLD` (Block 12 phase 7), `intake.manual_upload_handler` runs as a single-document tool invocation outside the normal phase sequence — it doesn't re-run the full EVIDENCE_DISCOVERY phases for the rest of the run.
- **Failure paths** (consumed by Block 03 Phase 08):
  - Gmail / Drive API outage on `intake.email_finder` / `intake.drive_finder` → `MODEL_ERROR transient: true`; bounded retry per Block 03 Phase 08.
  - Document AI outage on `intake.ocr_and_extract` → same.
  - Persistent failure → phase `HOLDING`; review issue raised; user takes action.
- **Audit events:** `EVIDENCE_DISCOVERY_PHASE_STARTED`, `EVIDENCE_DISCOVERY_PHASE_COMPLETED` (with discovered/dedup-collapsed/extraction-failed counts), `EVIDENCE_DISCOVERY_PHASE_HOLDING`.

## Definition of Done

- All five tools register at engine startup with the right schemas, side-effects, and AI tiers.
- `EVIDENCE_DISCOVERY_EMAIL` runs for OUT_MONTHLY, calling `intake.email_finder` then `intake.ocr_and_extract`; the phase exits when every OUT_EXPENSE has been searched.
- `EVIDENCE_DISCOVERY_DRIVE` runs only for transactions still without candidates after EMAIL; cross-source dedup runs at the end.
- Neither phase registers for `IN_MONTHLY`.
- A simulated Gmail API outage triggers Block 03 Phase 08's retry; persistent failure holds the phase.
- Manual upload completion correctly invokes `intake.manual_upload_handler` outside the normal phase sequence.
- Replaying a phase (after a process kill) produces identical results — every tool's dedup-key generator prevents double-write.

## Sub-doc Hooks (Stage 4)

- **Tool input/output schema sub-doc** — exact JSON schemas per tool.
- **`EVIDENCE_DISCOVERY_*` phase definition sub-doc** — the canonical phase definitions referenced by Block 12.
- **Entry/exit gate functions sub-doc** — SQL-backed gates.
- **Manual-upload re-entry sub-doc** — exact contract between Block 14's resolution action and `intake.manual_upload_handler`.
- **Failure-mode mapping sub-doc** — full table per tool → review-issue templates.
