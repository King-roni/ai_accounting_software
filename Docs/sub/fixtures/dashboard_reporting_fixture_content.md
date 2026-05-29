# Dashboard Reporting Fixture Content

**Category:** Fixtures · **Owning block:** 16 — Dashboard & Reporting · **Block reference:** Block 16 § Phase 01 (Dashboard Architecture), Phase 02–12 (Per-Card Data Sources) · **Stage:** 4 sub-doc (Layer 2 fixture corpus)

**Purpose:** Defines one seed-data fixture per dashboard card type from `dashboard_card_definitions_ui_spec.md`. These fixtures are used by dashboard live integration tests to assert correct metric computation and card state, and are the canonical development seed data for local environments. Any engineer adding a new card must register a fixture here. Any engineer modifying a card's metric logic must update the corresponding fixture's `expected_metric_value`.

All fixture files live at `fixtures/report/` per the `fixture_format_spec.md` block-short-name convention.

---

## Fixture format

| Field | Type | Description |
|---|---|---|
| `fixture_id` | string | Stable identifier; never renamed after creation |
| `card_id` | string | Matches `card_id` in `dashboard_card_definitions_ui_spec.md` |
| `seed_data_description` | string | Plain-language description of the seed data state |
| `expected_metric_value` | string | The exact value the card must display after seed load |
| `expected_card_state` | `normal` / `warning` / `error` | The card's visual state |

---

## Fixture 1 — `period_status`

**Fixture ID:** `dashboard_period_status_finalized_v1`
**Card ID:** `period_status`
**Seed data description:** One workflow run for period 2026-03 in `run_status = FINALIZED`. No other run for the period.
**Expected metric value:** `FINALIZED` badge
**Expected card state:** `normal`

Seed:
- Insert `workflow_runs` row: `run_status = FINALIZED`, `period_start = 2026-03-01`, `period_end = 2026-03-31`.
- Insert `period_lock_status` row: `manifest_version = 1`, `is_current = true`.

Assertions:
- Card renders `FINALIZED` badge in the green status colour.
- Secondary metric shows `locked_at` timestamp from `period_lock_status`.
- No animated dot is present (the run is terminal).

---

## Fixture 2 — `vat_liability`

**Fixture ID:** `dashboard_vat_liability_standard_v1`
**Card ID:** `vat_liability`
**Seed data description:** Period 2026-03 with output VAT of €4,200 and input VAT of €1,800 across classified ledger entries.
**Expected metric value:** `€4,200.00` (output VAT primary); `€2,400.00` net liability (secondary)
**Expected card state:** `normal`

Seed:
- Insert 6 `draft_ledger_entries` rows with `vat_treatment = STANDARD_RATED_19`, total output VAT summing to €4,200.00.
- Insert 3 `draft_ledger_entries` rows for input VAT summing to €1,800.00.
- All rows scoped to `period_start = 2026-03-01`, `period_end = 2026-03-31`.

Assertions:
- Primary metric: `€4,200.00`.
- Secondary metric: `€2,400.00` (net = output minus input).
- No warning banner (net VAT below €50,000 threshold).

---

## Fixture 3 — `income_total`

**Fixture ID:** `dashboard_income_total_three_invoices_v1`
**Card ID:** `income_total`
**Seed data description:** Three invoices in `SENT` status with totals €4,000, €5,000, and €3,500 for period 2026-03.
**Expected metric value:** `€12,500.00`
**Expected card state:** `normal`

Seed:
- Insert 3 invoice rows: `status = SENT`, amounts €4,000.00, €5,000.00, €3,500.00 (tax-inclusive), all with `period_start = 2026-03-01`.

Assertions:
- Primary metric: `€12,500.00`.
- Secondary metric: signed delta vs prior period (prior period has no invoices in this fixture → delta = `+€12,500.00`).
- Bar chart shows a single bar (single-month period).

---

## Fixture 4 — `expense_total`

**Fixture ID:** `dashboard_expense_total_fifteen_transactions_v1`
**Card ID:** `expense_total`
**Seed data description:** 15 classified `OUT_EXPENSE` transactions totalling €8,300 for period 2026-03.
**Expected metric value:** `€8,300.00`
**Expected card state:** `normal`

Seed:
- Insert 15 `transactions` rows: `transaction_type = OUT_EXPENSE`, `classification_status = CLASSIFIED`, individual amounts summing to €8,300.00, all scoped to period 2026-03.
- No unclassified transactions in this fixture.

Assertions:
- Primary metric: `€8,300.00`.
- No unclassified footnote displayed (zero unclassified transactions).
- Secondary metric: signed delta vs prior period.

---

## Fixture 5 — `match_rate`

**Fixture ID:** `dashboard_match_rate_90pct_v1`
**Card ID:** `match_rate`
**Seed data description:** 20 total transactions: 16 matched, 2 exception-documented, 2 unmatched.
**Expected metric value:** `90%`
**Expected card state:** `normal`

Seed:
- Insert 20 `transactions` rows scoped to period 2026-03.
- 16 rows: `effective_match_status = MATCHED`.
- 2 rows: `effective_match_status = EXCEPTION_DOCUMENTED`.
- 2 rows: `effective_match_status = UNMATCHED`.

Assertions:
- Primary metric: `90%` (`(16 + 2) / 20 × 100`).
- Secondary metric: `2` unmatched with no documented exception.
- Donut chart: matched segment = 80%, exception-documented segment = 10%, unmatched segment = 10%.

---

## Fixture 6 — `open_issues`

**Fixture ID:** `dashboard_open_issues_blocking_present_v1`
**Card ID:** `open_issues`
**Seed data description:** Open review issues: 2 BLOCKING, 3 HIGH, 5 MEDIUM, 8 LOW.
**Expected metric value:** `2` BLOCKING (displayed prominently); total 18 open issues
**Expected card state:** `error`

Seed:
- Insert 2 `review_issues` rows: `severity = BLOCKING`, `status = OPEN`.
- Insert 3 `review_issues` rows: `severity = HIGH`, `status = OPEN`.
- Insert 5 `review_issues` rows: `severity = MEDIUM`, `status = OPEN`.
- Insert 8 `review_issues` rows: `severity = LOW`, `status = OPEN`.

Assertions:
- Card renders in error state: red card border, error icon in header.
- BLOCKING count badge shows `2` in bold red.
- Stacked bar segments: LOW (8, grey), MEDIUM (5, amber), HIGH (3, orange), BLOCKING (2, red).
- Error state is triggered by `BLOCKING count > 0` per `dashboard_card_definitions_ui_spec.md` threshold rule.

---

## Fixture 7 — `archive_status`

**Fixture ID:** `dashboard_archive_status_sealed_v1`
**Card ID:** `archive_status`
**Seed data description:** Period 2026-03 has a sealed archive bundle with `is_current = true`.
**Expected metric value:** `SEALED` badge
**Expected card state:** `normal`

Seed:
- Insert `archive.archive_packages` row: `bundle_hash` populated, `object_lock_retention_until` in the future.
- Insert `archive.archive_manifests` row: `manifest_version_number = 1`, `is_current = true`.
- Insert `period_lock_status` row: `manifest_version = 1`, `is_current = true`, `locked_at = 2026-04-01T09:00:00Z`.

Assertions:
- Card shows `SEALED` badge in green.
- Secondary metric shows `locked_at` timestamp: `2026-04-01T09:00:00Z`.

---

## Fixture 8 — `invoice_pipeline`

**Fixture ID:** `dashboard_invoice_pipeline_overdue_highlight_v1`
**Card ID:** `invoice_pipeline`
**Seed data description:** Invoice pipeline with 2 DRAFT, 5 SENT, 3 PAID, 1 OVERDUE.
**Expected metric value:** Funnel: DRAFT 2, SENT/ISSUED 5, PAID 3; OVERDUE count 1 highlighted
**Expected card state:** `warning`

Seed:
- Insert 2 invoice rows: `status = DRAFT`.
- Insert 4 invoice rows: `status = SENT`.
- Insert 1 invoice row: `status = SENT`, `due_date = 2026-03-01` (past due — OVERDUE).
- Insert 3 invoice rows: `status = PAID`.

Assertions:
- Funnel stages: DRAFT = 2, ISSUED = 5 (4 SENT + 1 OVERDUE), PAID = 3.
- OVERDUE count badge shows `1` in the card secondary metric with amber highlight.
- Card renders in `warning` state due to OVERDUE count > 0.
- Clicking the ISSUED funnel stage opens the drill-down filtered to `status = SENT`.

---

## Fixture 9 — `vies_compliance`

**Fixture ID:** `dashboard_vies_compliance_75pct_v1`
**Card ID:** `vies_compliance`
**Seed data description:** 4 EU counterparties: 3 VIES-validated, 1 failed validation.
**Expected metric value:** `75%`
**Expected card state:** `warning`

Seed:
- Insert 4 `counterparties` rows: `is_intraeu_supplier = true`.
- 3 rows: `vies_status = VALIDATED`.
- 1 row: `vies_status = FAILED`.

Assertions:
- Primary metric: `75%` (`3 / 4 × 100`).
- Secondary metric: `1` counterparty with VIES failure.
- Card renders in `warning` state (failure count > 0).
- Donut chart: validated segment = 75%, failed segment = 25%.

---

## Fixture 10 — `spend_budget`

**Fixture ID:** `dashboard_spend_budget_70pct_v1`
**Card ID:** `spend_budget`
**Seed data description:** AI cost ceiling configured at $50.00 USD; current month spend is $35.00.
**Expected metric value:** `70%` gauge fill; `$35.00 / $50.00`
**Expected card state:** `normal`

Seed:
- Insert `business_ai_config` row: `cost_ceiling_usd = 50.00`.
- Insert `ai_usage_run_aggregation` row for the current month: `total_cost_usd = 35.00`.

Assertions:
- Gauge fill at 70%.
- Gauge colour: green (below 75% amber threshold).
- Primary metric text: `$35.00 / $50.00`.
- Secondary metric: `70%`.

---

## Fixture 11 — `document_intake`

**Fixture ID:** `dashboard_document_intake_mixed_sources_v1`
**Card ID:** `document_intake`
**Seed data description:** 12 processed documents: 8 PDF, 3 EMAIL, 1 MANUAL; average OCR confidence 0.87.
**Expected metric value:** Bar chart: PDF 8, EMAIL 3, MANUAL 1; OCR confidence `87%`
**Expected card state:** `normal`

Seed:
- Insert 8 `documents` rows: `source = PDF`, `document_state = PROCESSED`, `ocr_confidence` values averaging to 0.87.
- Insert 3 `documents` rows: `source = EMAIL`, `document_state = PROCESSED`, `ocr_confidence` values consistent with 0.87 overall average.
- Insert 1 `documents` row: `source = MANUAL`, `document_state = PROCESSED`, `ocr_confidence = null` (manual uploads have no OCR; excluded from confidence average denominator if null).

Note: The OCR confidence average is computed over documents where `ocr_confidence IS NOT NULL`. MANUAL-sourced documents without OCR are excluded from the average computation.

Assertions:
- Bar chart segments: PDF = 8, EMAIL = 3, MANUAL = 1.
- Secondary metric: `87%` average OCR confidence.
- Card renders in `normal` state (no threshold violation).

---

## Cross-references

- `dashboard_card_definitions_ui_spec.md` — card catalog, data source tools, threshold rules, and chart types for all 11 cards
- `analytics_snapshot_schema.md` — pre-computed metrics that back card data in non-live-query mode
- `period_comparison_schema.md` — prior-period delta computation used by `income_total` and `expense_total` secondary metrics
