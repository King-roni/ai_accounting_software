# Block 07 — Phase 10: End-to-End Pipeline Tests & Golden-File Regression

## References

- Block doc: `Docs/blocks/07_bank_statement_pipeline.md` (the whole pipeline as a coherent flow)
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 10 — invariant-test pattern this phase mirrors)

## Phase Goal

Build the regression-test layer that proves the whole pipeline (intake → parse → normalize → dedupe → evidence) produces deterministic output for a curated set of golden inputs. After this phase, every change to any pipeline phase runs against a fixture suite that catches drift before merge — the same protection Block 02 has for tenant isolation.

## Dependencies

- All previous Block 07 phases (01–09)
- Block 02 Phase 10 (the invariant-test fixture pattern this phase reuses)

## Deliverables

- **Golden fixtures directory** — `Docs/phases/07_bank_statement_pipeline/fixtures/`:
  - Each fixture is a directory: `<fixture_name>/input.csv` (or `.pdf`), `<fixture_name>/declared_period.json`, `<fixture_name>/expected_transactions.json`, `<fixture_name>/expected_dedup_statuses.json`, `<fixture_name>/expected_evidence_pdf_hashes.json`, `<fixture_name>/expected_review_issues.json`.
  - **`expected_review_issues.json` precision:** each issue lists `issue_type`, `issue_group`, `severity`, and `recommended_action_set`. Severity matches must be exact — a fixture that produces a HIGH issue when MEDIUM is expected fails. Group must match Block 14's six-bucket taxonomy.
  - Initial fixture set:
    - `revolut_csv_clean_month` — typical 80-row month with mixed types.
    - `revolut_csv_with_fx` — includes FX exchange paired-leg cases.
    - `revolut_csv_truncated` — partial upload (Phase 08 path).
    - `revolut_csv_overlap_with_prior` — re-import of overlapping date range (dedup path).
    - `revolut_csv_within_batch_duplicate` — same row twice in one CSV.
    - `revolut_csv_outside_period` — rows outside declared period.
    - `revolut_csv_all_outside_period` — every row outside declared period.
    - `revolut_csv_zero_amount_rows` — rejected rows.
    - `revolut_pdf_clean_month` — PDF path through Document AI (uses a recorded mock response — see sub-doc).
    - `revolut_pdf_low_confidence` — Document AI returns low-confidence rows.
- **Pipeline test runner:**
  - `runPipelineFixture(fixture_name) → FixtureResult` — sets up a test business + bank account, runs the full INGESTION phase against the fixture's input + declared period, captures the actual `transactions` rows, dedup statuses, evidence-PDF hashes, and review-issue list.
  - Compares to the fixture's `expected_*.json` — exact match for structured fields (after canonical-JSON normalization), hash match for evidence PDFs.
  - Failure: produces a clear diff showing actual vs expected.
- **Document AI mocking:**
  - PDF fixtures don't hit live Document AI in CI. A recorded response per fixture is used; the recordings are versioned alongside the fixture.
  - A separate "live integration" test suite (run on a cadence, not on every PR) does hit live Document AI with a small canary corpus.
- **Determinism guarantees:**
  - Every fixture's expected output is deterministic from the input — no random IDs in the comparison (UUIDs are normalized away in canonicalisation), no clock-dependent values (the test fixture pins `generated_at` for evidence PDFs).
  - Hash inputs (Block 04 Phase 01) are deterministic by contract; this test layer relies on that.
- **CI integration:**
  - Runs on every PR that touches Block 07 phase code, the fixture directory, or any of Block 07's dependencies in Blocks 02/03/04/05/06.
  - Failure blocks merge.
  - Performance budget: total fixture run time under 90 seconds in CI.
- **Updating fixtures:**
  - When a phase change requires updating an expected output, the fixture update is part of the same PR with a documented reason — never a silent regen.
  - A fixture removal requires a documented entry (mirrors Block 06 Phase 04's prompt-test corpus rule).
- **Audit events:** `PIPELINE_FIXTURE_RAN`, `PIPELINE_FIXTURE_PASSED`, `PIPELINE_FIXTURE_FAILED`, `PIPELINE_FIXTURE_REMOVED`.

## Definition of Done

- All ten fixtures listed above exist with input + expected files.
- Running the test runner against any fixture produces the expected output exactly.
- A deliberate change that breaks one phase (e.g., flipping the dedup pass to off) makes at least one fixture fail with a clear diff.
- PDF fixtures use recorded Document AI responses; the live integration suite is documented but not on the PR path.
- CI is wired so PR merges are blocked on fixture failures.
- Performance budget is met.
- Adding a new fixture is easy; removing one requires a documented reason.

## Sub-doc Hooks (Stage 4)

- **Fixture format sub-doc** — directory structure, file naming, JSON shapes, canonicalisation rules for comparison.
- **Document AI mocking sub-doc** — how recordings are captured, versioned, and replayed; when a live re-record is required.
- **Live integration test cadence sub-doc** — schedule, scope, alerts on failure.
- **Determinism rules sub-doc** — what's normalized away in comparisons (UUIDs, timestamps, file paths), what isn't.
- **Performance budget sub-doc** — measurement methodology, alerting on regression.
