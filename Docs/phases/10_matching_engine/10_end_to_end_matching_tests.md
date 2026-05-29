# Block 10 — Phase 10: End-to-End Matching Tests & Golden-File Regression

## References

- Block doc: `Docs/blocks/10_matching_engine.md`
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 10 — invariant-test pattern)
- Block doc: `Docs/blocks/07_bank_statement_pipeline.md` and `Docs/blocks/08_transaction_classification_and_tagging.md` and `Docs/blocks/09_document_intake_and_extraction.md` (Phase 10s — golden-fixture conventions)

## Phase Goal

Build the regression-test layer for the full matching engine (OUT and IN), covering each match level, cross-period, cross-currency, split-payment combinatorial detection, duplicate detection, rejection memory, every IN-side outcome, and plain-language reason generation. After this phase, every change to any matching phase runs against a fixture suite that catches drift before merge.

## Dependencies

- All Block 10 phases (01–09)
- Block 02 Phase 10 (invariant-test pattern)
- Block 07/08/09 Phase 10s (golden-fixture format conventions)

## Deliverables

- **Golden fixtures directory** — `Docs/phases/10_matching_engine/fixtures/`:
  - Per-fixture files: `business_state.json`, `input_transactions.json`, `input_documents.json` (OUT side) or `input_invoices.json` (IN side), `expected_match_records.json`, `expected_review_issues.json`, `expected_split_payment_groups.json`, `expected_invoice_lifecycle_changes.json` (IN side), `expected_audit_events.json`, `recorded_ai_responses.json` (for plain-language calls).
- **Initial fixture set:**
  - **Match levels (OUT):**
    - `level_1_exact_match` — clean amount + currency + supplier + date.
    - `level_2_strong_with_recurring` — fuzzy supplier, but vendor-memory at 0.88 + amount-exact → auto-confirm.
    - `level_2_strong_without_recurring` — same fuzzy supplier, vendor-memory at 0.72 → `MATCHED_NEEDS_CONFIRMATION`.
    - `level_3_weak_possible` — some signals align → `POSSIBLE_MATCH` to review.
    - `level_4_no_match` — no candidate above threshold → `NO_MATCH` + `Missing Documents` review issue.
  - **Cross-period:**
    - `cross_period_invoice_one_month_old` — invoice issued in prior month, transaction in current month, within 60-day window.
    - `cross_period_outside_window_lookback` — invoice from 90 days ago, outside the −60-day look-back; should NOT be matched.
    - `cross_period_invoice_after_transaction_within_window` — invoice issued 15 days AFTER the transaction (within the +30-day forward side); SHOULD be matched (covers the document-upload-lag and advance-payment edge cases the asymmetric window is designed for).
    - `cross_period_invoice_after_transaction_outside_window` — invoice issued 45 days AFTER the transaction (outside the +30-day forward side); should NOT be matched.
  - **Cross-currency:**
    - `cross_currency_with_paired_leg` — transaction in EUR, invoice in USD, FX paired-leg present, conversion uses bank rate.
    - `cross_currency_with_ecb_fallback` — same but no paired leg → ECB rate used.
  - **Split-payment combinatorial:**
    - `split_payment_two_invoices_same_supplier` — high-confidence proposal.
    - `split_payment_three_invoices_mixed_suppliers` — lower-confidence proposal but still surfaces.
    - `split_payment_candidate_set_truncation` — 30 candidate invoices → narrowing to 20 → top 3 surfaced.
  - **Duplicate detection:**
    - `duplicate_pattern_a_one_doc_many_txns` — Pattern A raised.
    - `duplicate_pattern_b_one_txn_many_docs` — Pattern B raised.
    - `confirmed_split_payment_no_pattern_a` — confirmed split-payment group does NOT raise Pattern A.
  - **Rejection memory:**
    - `rejection_suppression` — pair previously rejected; second run skips it; `MATCHING_REJECTION_SUPPRESSED` audit event verified.
    - `rejection_pair_scoped` — `(txn1, doc1)` rejected; `(txn1, doc2)` and `(txn2, doc1)` still scored.
    - `rejection_privileged_override` — pair previously rejected; Owner privileged override removes the `match_rejection_memory` row; subsequent run re-scores the pair; `MATCHING_REJECTION_OVERRIDDEN_PRIVILEGED` audit event verified with reason text; step-up auth requirement verified; Admin attempt is denied.
  - **IN-side outcomes:**
    - `in_full_match` — exact amount + invoice number → auto-confirm; invoice → `PAID`.
    - `in_partial_payment` — amount < total → `PARTIALLY_PAID` on confirm.
    - `in_overpayment` — amount > total → `OVERPAID` + credit-note review issue.
    - `in_multiple_invoices_one_payment` — never silently allocated (Stage 1); user confirmation surfaces in review queue.
    - `in_one_invoice_multiple_payments` — running-total accumulation; invoice transitions to `PAID` only when total reaches invoice amount.
    - `in_possible_refund_or_transfer` — incoming payment matches a prior outgoing → reclassification suggestion.
    - `in_pro_forma_filtered_out` — pro-forma invoice not used as candidate.
  - **Match reason generation:**
    - `reason_level_1_simple` — Tier 2 produces concise reason.
    - `reason_cross_currency` — Tier 3 explicitly invoked because of complexity.
    - `reason_cross_period` — Tier 3 invoked to explain time gap.
- **Test runner** — `runMatchingFixture(fixture_name) → FixtureResult`:
  - Sets up the test business per `business_state.json` (rules, vendor memory, custom tags from earlier blocks).
  - Loads transactions, documents/invoices, prior match records, prior rejection-memory rows from the fixture.
  - Loads recorded AI responses for plain-language calls.
  - Runs the relevant phase (`MATCHING` or `INCOME_MATCHING`) end-to-end.
  - Captures actual match records, review issues, split-payment groups, invoice lifecycle changes, audit events.
  - Compares to expected JSON files exactly.
- **CI integration:**
  - Runs on every PR touching Block 10 phase code, fixtures, or any of Block 10's dependencies in Blocks 02/03/04/06/08/09.
  - Failure blocks merge.
  - Performance budget: total fixture run time under 90 seconds.
- **Audit events:** `MATCHING_FIXTURE_RAN`, `MATCHING_FIXTURE_PASSED`, `MATCHING_FIXTURE_FAILED`. Fixture removal is governance-only (PR documentation), not a runtime audit event.

## Definition of Done

- All listed fixtures exist with input + expected files + recorded responses.
- Running the test runner against any fixture produces the expected output exactly.
- A deliberate change that breaks a phase (e.g., shifting an auto-confirm threshold) makes the right fixtures fail with clear diffs.
- All AI calls in CI use recorded responses; no live API hits.
- CI is wired so PR merges are blocked on fixture failures.
- Performance budget is met.
- Adding a fixture is easy; removing one requires a documented PR entry.

## Sub-doc Hooks (Stage 4)

- **Fixture format sub-doc** — directory structure, file naming, JSON shapes, mock-service seeding rules for OUT side and IN side.
- **AI response recording sub-doc** — capture procedure, version pinning, when to re-record.
- **Per-fixture content sub-doc** — what each fixture covers, why it's representative.
- **Live integration test cadence sub-doc** — schedule, scope.
- **Performance budget sub-doc** — measurement methodology.
