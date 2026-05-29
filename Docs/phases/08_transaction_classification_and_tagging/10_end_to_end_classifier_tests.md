# Block 08 — Phase 10: End-to-End Classifier Tests & Golden-File Regression

## References

- Block doc: `Docs/blocks/08_transaction_classification_and_tagging.md`
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 10 — invariant-test pattern)
- Block doc: `Docs/blocks/07_bank_statement_pipeline.md` (Phase 10 — golden-fixture pattern this phase mirrors)

## Phase Goal

Build the regression-test layer that proves the full classifier pipeline (Layer 1 → Layer 2 → Layer 3 → merge → tag → status) produces deterministic output for a curated set of inputs covering every transaction type, every layer-interaction edge case, and every Stage 1-locked behaviour. After this phase, every change to any classifier phase runs against a fixture suite that catches drift before merge.

## Dependencies

- All Block 08 phases (01–09)
- Block 02 Phase 10 (invariant-test fixture pattern)
- Block 07 Phase 10 (golden-fixture format reused here)

## Deliverables

- **Golden fixtures directory** — `Docs/phases/08_transaction_classification_and_tagging/fixtures/`:
  - Each fixture is a directory: `<fixture_name>/input_transactions.json`, `<fixture_name>/business_state.json`, `<fixture_name>/prior_finalized_runs.json` (optional — seeds historical runs for cross-run fixtures like `tag_taxonomy_versioning`), `<fixture_name>/expected_classifications.json`, `<fixture_name>/expected_review_issues.json`, `<fixture_name>/expected_vendor_memory_changes.json`, `<fixture_name>/expected_audit_events.json`, `<fixture_name>/recorded_ai_responses.json` (when AI fallback is exercised).
  - **`business_state.json`** seeds the test business: rules, vendor memory state, custom tags, taxonomy assignment.
  - **`prior_finalized_runs.json`** (when present) seeds a finalized run with its `classification_taxonomy_snapshot` so cross-run fixtures can verify historical rendering against an older taxonomy.
  - **`expected_*.json`** files use the same precision rules as Block 07 Phase 10 (canonical-JSON normalization, exact severity matches, exact `issue_group` matches against Block 14's six buckets).
- **Initial fixture set** — at least one per transaction type plus the layer-interaction edge cases:
  - Per type: `type_internal_transfer`, `type_bank_fee`, `type_fx_exchange`, `type_out_expense`, `type_in_income`, `type_refund_in`, `type_refund_out`, `type_chargeback`, `type_payroll_team_payment`, `type_tax_payment`, `type_loan_shareholder_movement`, `type_unknown`.
  - **Layer interactions:**
    - `vendor_memory_promotion_path` — three confirmations of the same supplier → `VENDOR_MEMORY_PROMOTED_TO_HIGH` audit event on the third.
    - `ai_fallback_tier3_escalation` — Tier 2 returns confidence 0.55 → `AI_CLASSIFICATION_TIER2_LOW_CONFIDENCE` → explicit Tier 3 invocation produces 0.92.
    - `rule_conflict` — two rules disagree on type → no type assigned → `classification.rule_conflict` review issue.
    - `layer_disagreement` — Layer 1 says `OUT_EXPENSE` at 0.85, Layer 2 says `PAYROLL_OR_TEAM_PAYMENT` at 0.72 → Layer 1 wins, LOW disagreement issue raised.
    - `multi_layer_agreement_boost` — Layer 1 and Layer 2 both say `OUT_EXPENSE` → boosted confidence applied; capped at 0.95.
  - **Tag system:**
    - `default_tag_fallback` — type assigned, no tag suggested by any layer → falls back to type's default tag with `TAG_DEFAULT_FALLBACK_USED` audit event.
    - `custom_tag_round_trip` — custom tag created, used, retired; mid-run reference still works; post-run reference shows retired.
    - `tag_taxonomy_versioning` — finalized period under v1 + new run under v2 with split tag → finalized period renders v1 names; new run renders v2 names.
  - **Confidence:**
    - `threshold_just_met` — confidence exactly at the type's auto-confirm threshold → `AUTO_CONFIRMED`.
    - `threshold_just_below` — confidence 0.01 below → `NEEDS_CONFIRMATION` with severity `LOW`.
    - `confidence_far_below` — confidence 0.30 → `NEEDS_CONFIRMATION` with severity `HIGH`.
- **Pipeline test runner** — `runClassifierFixture(fixture_name) → FixtureResult`:
  - Sets up the test business per `business_state.json`.
  - Loads `input_transactions.json` into the run's `transactions` rows (skipping INGESTION since this phase tests the classifier, not the full pipeline).
  - Loads `recorded_ai_responses.json` into the gateway's recorded-response cache for any Layer 3 calls in the fixture.
  - Runs `CLASSIFICATION` phase end-to-end.
  - Captures actual classifications, review issues, vendor-memory deltas, audit events.
  - Compares to `expected_*.json` exactly. Failure produces a clear diff.
- **AI mocking:**
  - Recorded responses for Layer 3 prompts captured once and replayed in CI. Re-recording requires a documented PR with reason.
  - A separate "live integration" suite runs on a cadence (not on every PR) to catch drift between recordings and current Anthropic behavior.
- **CI integration:**
  - Runs on every PR touching Block 08 phase code, fixture directory, or any of Block 08's dependencies in Blocks 02/03/04/06.
  - Failure blocks merge.
  - Performance budget under 60 seconds in CI for the full fixture suite.
- **Audit events:** `CLASSIFIER_FIXTURE_RAN`, `CLASSIFIER_FIXTURE_PASSED`, `CLASSIFIER_FIXTURE_FAILED`, `CLASSIFIER_FIXTURE_REMOVED` (requires documented entry like Block 06 Phase 04's prompt-corpus rule).

## Definition of Done

- All listed fixtures exist with input + expected files.
- Running the test runner against any fixture produces the expected output exactly.
- A deliberate change that breaks one phase (e.g., changing a threshold value) makes the right fixtures fail with clear diffs.
- AI fixtures use recorded responses; live integration is documented but not on the PR path.
- CI is wired so PR merges are blocked on fixture failures.
- Performance budget is met.
- Adding a fixture is easy; removing one requires a documented reason.

## Sub-doc Hooks (Stage 4)

- **Fixture format sub-doc** — directory structure, file naming, JSON shapes, `business_state.json` seeder rules.
- **AI recording sub-doc** — how recordings are captured, versioned, and replayed; when a live re-record is required.
- **Per-type fixture content sub-doc** — what each per-type fixture covers, why it's representative.
- **Live integration test cadence sub-doc** — schedule, scope, alerting on drift.
- **Performance budget sub-doc** — measurement methodology, alerting on regression.
