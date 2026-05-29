# Block 09 — Phase 10: End-to-End Intake Tests & Golden-File Regression

## References

- Block doc: `Docs/blocks/09_document_intake_and_extraction.md`
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 10 — invariant-test pattern)
- Block doc: `Docs/blocks/07_bank_statement_pipeline.md` (Phase 10 — golden-fixture pattern)
- Block doc: `Docs/blocks/08_transaction_classification_and_tagging.md` (Phase 10 — fixture format with recorded AI responses)

## Phase Goal

Build the regression-test layer for the full intake pipeline: email finder → Drive finder → manual upload → OCR → extraction → cross-source dedup. After this phase, every change to any intake phase runs against a fixture suite covering each source path, each OCR/extraction layer, and the key edge cases (allowlist, spam, non-convention Drive folders, cross-source duplicates).

## Dependencies

- All Block 09 phases (01–09)
- Block 02 Phase 10 (invariant-test fixture pattern)
- Block 07 Phase 10 + Block 08 Phase 10 (golden-fixture format conventions)

## Deliverables

- **Golden fixtures directory** — `Docs/phases/09_document_intake_and_extraction/fixtures/`:
  - Each fixture is a directory: `<fixture_name>/business_state.json`, `<fixture_name>/input_transactions.json`, plus source-specific inputs:
    - `input_emails.json` (synthetic Gmail messages with attachments)
    - `input_drive_files.json` (synthetic Drive folder listing)
    - `input_manual_uploads.json` (synthetic upload events)
  - Expected outputs: `expected_documents.json`, `expected_extraction_results.json`, `expected_review_issues.json`, `expected_audit_events.json`, `expected_source_links.json`.
  - **`recorded_ocr_responses.json`** — mocked Document AI responses for OCR fixtures.
  - **`recorded_ai_extraction_responses.json`** — mocked gateway responses for Tier 2 / Tier 3 extraction calls.
- **Initial fixture set:**
  - **Email finder paths:**
    - `email_finder_clean_match` — happy path with allowlisted sender.
    - `email_finder_spam_filter` — Gmail spam-labelled email skipped.
    - `email_finder_non_allowlisted_rejected` — sender not in allowlist or supplier registry → rejected.
    - `email_finder_known_supplier_bypass` — non-allowlisted but already-known supplier → allowed.
    - `email_finder_idempotent_rerun` — same Gmail message id appears for two transactions → only one document created.
  - **Drive finder paths:**
    - `drive_finder_2_week_convention` — folder structure matches; date-scoped subfolder selection.
    - `drive_finder_cross_period_buffer` — file in adjacent subfolder (within buffer) discovered.
    - `drive_finder_non_convention_fallback` — folders don't match convention → flat search + warning issue.
  - **Manual upload paths:**
    - `manual_upload_clean_pdf` — happy path.
    - `manual_upload_docx_conversion` — DOCX → PDF conversion path.
    - `manual_upload_no_invoice_stub` — Document Stub for "no invoice available" with reason.
    - `manual_upload_internal_transfer_stub`.
    - `manual_upload_non_deductible_stub`.
  - **Cross-source dedup:**
    - `cross_source_email_then_drive` — same hash via email then Drive → one document, two source-links, confidence boosted.
    - `cross_source_three_sources` — three sources for the same hash; cap reached at two.
    - `cross_source_different_business_no_dedup` — same hash on different businesses → two distinct documents (correctly).
  - **OCR + extraction layers:**
    - `ocr_layer1_template_match` — clean Google Workspace invoice → deterministic template match.
    - `ocr_layer2_tier2` — non-templated invoice → Tier 2 LLM extraction.
    - `ocr_layer3_tier3_escalation` — Tier 2 confidence below threshold → Tier 3 explicit invocation.
    - `ocr_vat_validation_failure` — bad VAT format → field validation review issue.
    - `ocr_amount_arithmetic_failure` — total ≠ subtotal + vat → flagged with rounding tolerance applied.
    - `ocr_all_layers_failed` — every layer fails → flagged-failure document state with review issue.
- **Test runner** — `runIntakeFixture(fixture_name) → FixtureResult`:
  - Sets up the test business per `business_state.json` (including OAuth token mocks for Gmail and Drive).
  - Loads `input_transactions.json` into the run's `transactions`.
  - Loads source-specific inputs into mocked Gmail / Drive / upload services.
  - Loads recorded responses into the gateway's recorded-response cache.
  - Runs `EVIDENCE_DISCOVERY_EMAIL` and `EVIDENCE_DISCOVERY_DRIVE` end-to-end.
  - Captures actual documents, source links, extraction results, review issues, audit events.
  - Compares to `expected_*.json` exactly.
- **Mocking strategy:**
  - Gmail and Drive APIs are mocked with synthetic data — never hits live APIs in CI.
  - Document AI responses are recorded once per fixture and replayed; re-recording requires a documented PR.
  - A separate "live integration" suite runs on a cadence to catch drift.
- **CI integration:**
  - Runs on every PR touching Block 09 phase code, fixtures, or any of Block 09's dependencies in Blocks 02/03/04/05/06/07/08.
  - Failure blocks merge.
  - Performance budget: total fixture run time under 90 seconds in CI.
- **Audit events** (test-runner runtime events only — fixture-removal is a repo-governance concern, not a runtime audit, and is tracked in PR documentation): `INTAKE_FIXTURE_RAN`, `INTAKE_FIXTURE_PASSED`, `INTAKE_FIXTURE_FAILED`. Fixture removal requires a documented PR entry per Block 06 Phase 04's prompt-corpus rule but does not emit to the audit log.

## Definition of Done

- All listed fixtures exist with input + expected files + recorded responses.
- Running the test runner against any fixture produces the expected output exactly.
- A deliberate change that breaks one phase makes the right fixtures fail with clear diffs.
- All AI calls in CI use recorded responses; no live API hits.
- CI is wired so PR merges are blocked on fixture failures.
- Performance budget is met.
- Adding a fixture is easy; removing one requires a documented reason.

## Sub-doc Hooks (Stage 4)

- **Fixture format sub-doc** — directory structure, file naming, JSON shapes, mock-service seeding rules.
- **OCR + AI response recording sub-doc** — capture procedure, version pinning, when to re-record.
- **Per-source fixture content sub-doc** — what each per-source fixture covers, why it's representative.
- **Live integration test cadence sub-doc** — schedule, scope, alerting on drift.
- **Performance budget sub-doc** — measurement, alerting on regression.
