# Block 11 — Phase 10: End-to-End Ledger Tests & Golden-File Regression

## References

- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md`
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 10 — invariant-test pattern)
- Block doc: `Docs/blocks/07_bank_statement_pipeline.md`, `Docs/blocks/08_transaction_classification_and_tagging.md`, `Docs/blocks/09_document_intake_and_extraction.md`, `Docs/blocks/10_matching_engine.md` (Phase 10s — golden-fixture conventions)

## Phase Goal

Build the regression-test layer for the full LEDGER_PREPARATION phase. Cover every VAT treatment, every transaction type, the reverse-charge derived-entry shapes, the multi-line consolidation rule, the chart-version-pin replay invariant, accountant-review flag triggers, and AI-explanation fallback. After this phase, every change to any Block 11 phase runs against a fixture suite that catches drift before merge.

## Dependencies

- All Block 11 phases (01–09)
- Block 02 Phase 10 (invariant-test pattern)
- Block 07 / 08 / 09 / 10 Phase 10s (golden-fixture format conventions)

## Deliverables

- **Golden fixtures directory** — `Docs/phases/11_ledger_and_cyprus_vat_engine/fixtures/`:
  - Per-fixture files: `business_state.json` (chart of accounts, mapping rules, VAT registration profile, business country), `input_transactions.json` (typed + tagged transactions), `input_match_records.json` (with extracted document fields inline), `input_invoices.json` (for IN-side fixtures), `expected_draft_ledger_entries.json` (every column except `id` and `created_at`), `expected_review_issues.json`, `expected_audit_events.json`, `recorded_ai_responses.json` (for `ledger.generate_vat_explanations` calls).
- **Initial fixture set:**
  - **VAT treatments (one fixture per branch):**
    - `vat_domestic_cyprus_b2b_expense` — domestic CY supplier, valid CY VAT number, `OUT_EXPENSE` → `DOMESTIC_CYPRUS_VAT`; `input_vat_reclaimable_amount` from document.
    - `vat_eu_reverse_charge_service_out` — EU supplier (DE), valid VAT number, service tag, `OUT_EXPENSE` → `EU_REVERSE_CHARGE`; PRIMARY + paired `VAT_RECLAIM` + `VAT_OUTPUT` derived entries; net-VAT zero.
    - `vat_eu_reverse_charge_service_in` — EU customer (FR), valid VAT number, service tag, `IN_INCOME` → `EU_REVERSE_CHARGE`; `vies_relevant = true`; `vies_period`, `vies_value_basis` populated.
    - `vat_import_or_acquisition_eu_goods` — EU supplier, goods tag → `IMPORT_OR_ACQUISITION`.
    - `vat_non_eu_service` — US supplier, service tag → `NON_EU_SERVICE`.
    - `vat_exempt` — financial service category → `EXEMPT`; both VAT amounts `0`.
    - `vat_no_vat_business_not_registered` — business profile shows not VAT-registered → `NO_VAT` for OUT entries.
    - `vat_outside_scope_internal_transfer` — `INTERNAL_TRANSFER` → `OUTSIDE_SCOPE`.
    - `vat_unknown_unresolved_country` — Phase 04 returns null country → `UNKNOWN` + `requires_accountant_review` + `Possible Tax/VAT Issue` review issue. `expected_audit_events.json` explicitly verifies `LEDGER_COUNTERPARTY_UNRESOLVED` AND `LEDGER_VAT_TREATMENT_UNKNOWN_RAISED` AND `LEDGER_ACCOUNTANT_REVIEW_FLAGGED`.
  - **Per transaction type (the 12-type dispatcher):** one fixture each — `type_out_expense`, `type_in_income`, `type_internal_transfer`, `type_fx_exchange` (with `FX_DELTA` derived entry), `type_bank_fee`, `type_refund_in`, `type_refund_out`, `type_chargeback`, `type_loan_or_shareholder_movement` (with `requires_contract = true`), `type_payroll_contractor` (with `requires_invoice = true` AND `requires_contract = true`), `type_payroll_employee` (no evidence flags), `type_tax_payment`, `type_unknown_held` (no draft entries; held audit event; HIGH review issue).
  - **VIES export contract:**
    - `vies_export_two_eu_customers_consolidate` — three IN-side `EU_REVERSE_CHARGE` entries across two customers; verify per-entry flags only (rollup happens at export time in Block 16; not asserted here).
    - `vies_missing_vat_number_excludes_from_export` — IN-side `EU_REVERSE_CHARGE` with missing VAT number; `vies_relevant = false`; `LEDGER_VIES_VAT_NUMBER_MISSING_RAISED` audit event verified.
  - **Multi-line invoice consolidation:**
    - `multiline_consolidate_same_category` — AWS-style invoice with 12 lines all mapping to "IT & Software" → one consolidated PRIMARY entry; `LEDGER_MULTI_LINE_INVOICE_CONSOLIDATED` audit event with line-item count.
    - `multiline_split_by_category` — invoice with two lines mapping to different categories → two PRIMARY entries; `LEDGER_MULTI_LINE_INVOICE_SPLIT_BY_CATEGORY` audit event.
  - **Chart-version-pin replay (the critical invariant):**
    - `chart_version_replay` — finalize period 1 with chart version 1; user customizes the chart (creates version 2); re-render period 1 → identical output as the original finalization; verify `chart_mapping_version_id` on each entry remains version 1; verify the disabled account still resolves correctly for the locked entry.
    - `chart_version_recompute_in_draft` — period 2 still in DRAFT; user customizes the chart → version 3; recompute period 2 → uses version 3.
  - **Accountant-review flag triggers (one fixture per cause):**
    - `review_unknown_treatment` — `vat_treatment = UNKNOWN`; severity HIGH.
    - `review_tag_mismatch` — Phase 05 picked `NON_EU_SERVICE` but tag implies physical-goods-import; severity MEDIUM.
    - `review_cross_period_adjustment` — matched invoice in finalized period; severity HIGH; reason text references adjustment-run path.
    - `review_reverse_charge_plausible_no_vat_number` — EU country, missing VAT number; severity MEDIUM.
    - `review_disabled_account_in_mapping` — Phase 03's disabled-account semantics fire; reason mentions "successor".
    - `review_missing_required_evidence` — `OUT_EXPENSE` ≥ €15 with only a receipt; `MISSING_REQUIRED_EVIDENCE` issue in `Missing Documents` bucket.
  - **Manual override:**
    - `manual_override_owner_changes_treatment` — Owner overrides `UNKNOWN` to `EXEMPT`; audit event verified with before/after + reason; subsequent re-run of `ledger.classify_vat` honors the override.
    - `manual_override_admin_allowed` — Admin override succeeds.
    - `manual_override_bookkeeper_denied` — Bookkeeper override denied; right error returned.
    - `manual_override_cleared_then_classifier_decides` — Owner clears override; next classifier run produces the rules-derived result.
  - **AI explanation fallback:**
    - `vat_explanation_ai_failure_falls_back` — recorded AI response is a timeout; `vat_treatment_explanation` is the deterministic structured-fallback string; `LEDGER_VAT_EXPLANATION_FALLBACK_APPLIED` audit event verified with category `AI_TIMEOUT`; LOW review issue verified.
  - **VAT amount sources:**
    - `vat_amount_from_document` — invoice carries explicit VAT line; calculator uses it directly.
    - `vat_amount_from_rate_derivation` — invoice has no VAT line; calculator uses Cyprus standard rate per the pinned `vat_rate_table_version`.
    - `vat_amount_mixed_rate_invoice` — multi-rate invoice; per Phase 07's split-vs-consolidate rule, the breakdown is correct.
    - `vat_amount_rounding_paired_entries` — reverse-charge OUT-side; `ROUNDING` derived entry kicks in for a `±0.02` cumulative delta.
- **Test runner** — `runLedgerFixture(fixture_name) → FixtureResult`:
  - Sets up the test business per `business_state.json` (chart, mapping rules, VAT profile, country).
  - Loads transactions, match records, prior draft entries (when present).
  - Loads recorded AI responses for explanation calls.
  - Runs the `LEDGER_PREPARATION` phase end-to-end via Phase 09's tool sequence.
  - Captures actual draft entries, review issues, audit events.
  - Compares to expected JSON files exactly. Failure produces a clear diff highlighting which compliance field, audit event, or review issue diverged.
- **CI integration:**
  - Runs on every PR touching Block 11 phase code, fixtures, or any Block 11 dependency in Blocks 02 / 03 / 04 / 06 / 08 / 09 / 10.
  - Failure blocks merge.
  - Performance budget: total fixture run time under 90 seconds.
- **Audit events:** `LEDGER_FIXTURE_RAN`, `LEDGER_FIXTURE_PASSED`, `LEDGER_FIXTURE_FAILED`. Fixture removal is governance-only (PR documentation), not a runtime audit event.

## Definition of Done

- All listed fixtures exist with input + expected files + recorded responses.
- Running the test runner against any fixture produces the expected output exactly.
- A deliberate change that breaks any phase (e.g., shifting a VAT rate, flipping a treatment rule, removing a derived-entry shape) makes the right fixtures fail with clear diffs.
- The chart-version-pin replay fixtures pass: a finalized period continues to render identically across chart customizations.
- All AI calls in CI use recorded responses; no live API hits.
- CI is wired so PR merges are blocked on fixture failures.
- Performance budget is met.
- Adding a fixture is easy; removing one requires a documented PR entry.

## Sub-doc Hooks (Stage 4)

- **Fixture format sub-doc** — directory structure, file naming, JSON shapes, mock-service seeding rules.
- **AI response recording sub-doc** — capture procedure, version pinning, when to re-record.
- **Per-fixture content sub-doc** — what each fixture covers, why it's representative.
- **Live integration test cadence sub-doc** — schedule and scope (the deferred VIES-online and live VAT-rate-table checks).
- **Performance budget sub-doc** — measurement methodology.
