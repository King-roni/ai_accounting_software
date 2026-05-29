# Dashboard Card Definitions UI Spec

**Category:** UI · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

This document defines the 11 dashboard cards for the period dashboard. Each card definition specifies its data source tool, primary and secondary metrics, chart type, refresh cadence, threshold rules, and available actions. Implementations bind to these definitions; adding or removing a card requires an amendment to this document.

---

## Purpose

The dashboard presents the current state of a business period across 11 cards. Cards are not widgets with configurable layouts — their positions and definitions are fixed. The data source tool for each card is the single authoritative source for that card's data; the card must not query other tools or stitch data from multiple sources at render time.

---

## Card catalog

| card_id | card_title | primary_metric | secondary_metric | chart_type | data_source_tool | refresh_cadence |
|---|---|---|---|---|---|---|
| `period_status` | Current period run status | Badge (run_status_enum value) | Last updated timestamp | Status badge | `report.get_period_status` | On `ARCHIVE_PROMOTION_COMPLETED` |
| `vat_liability` | Estimated VAT liability | Total output VAT (EUR) | Net VAT (output minus input, EUR) | Number | `report.generate_period_report` | Hourly during active run |
| `income_total` | Total invoiced income | Sum of SENT invoice totals (EUR) | Delta vs prior period (EUR, signed) | Bar | `report.generate_period_report` | Hourly |
| `expense_total` | Total classified expenses | Sum of OUT transaction totals (EUR) | Delta vs prior period (EUR, signed) | Bar | `report.generate_period_report` | Hourly |
| `match_rate` | Transaction match rate | Percentage matched or exception-documented | Count of unmatched transactions | Donut | `report.generate_period_report` | On matching phase complete |
| `open_issues` | Open review issues | Count of open issues by severity | Count of BLOCKING issues | Stacked bar | `report.get_queue_summary` | On each issue state change |
| `archive_status` | Archive seal status | SEALED / PENDING / FAILED | Last sealed timestamp | Status badge | `report.get_archive_status` | On `ARCHIVE_PROMOTION_COMPLETED` |
| `invoice_pipeline` | Invoice pipeline | Count by status (DRAFT / SENT / PAID / OVERDUE) | Overdue total amount (EUR) | Funnel | `report.get_invoice_pipeline` | Hourly |
| `vies_compliance` | VIES compliance | Percentage of EU counterparties VIES-validated | Count of VIES validation failures | Donut | `report.get_vies_summary` | Daily |
| `spend_budget` | AI spend | Current month USD vs ceiling | Percentage of ceiling consumed | Gauge | `report.get_ai_spend` | On each AI invocation |
| `document_intake` | Documents processed | Count by source (PDF / EMAIL / MANUAL) | OCR confidence average (percentage) | Bar | `report.get_intake_summary` | Hourly |

---

## Card definitions

### `period_status`

Displays the current `run_status_enum` value of the active workflow run for the selected period, rendered as a coloured status badge. The badge label maps directly to the run_status_enum values: `CREATED`, `RUNNING`, `PAUSED`, `REVIEW_HOLD`, `AWAITING_APPROVAL`, `FINALIZING`, `FINALIZED`, `FAILED`, `CANCELLED`, `COMPENSATING`.

The secondary metric shows the ISO 8601 timestamp of the last run status change. This timestamp is derived from the `updated_at` field of the `workflow_runs` row.

The card refreshes when `ARCHIVE_PROMOTION_COMPLETED` is received via the dashboard event subscription. For intermediate run states, a background poll at 30-second intervals updates the badge while the run detail page is open.

### `vat_liability`

Displays the estimated total output VAT for the period in EUR, computed from ledger VAT entries. The secondary metric is the net VAT position (output VAT minus input VAT). Both values are formatted as EUR with two decimal places and a thousands separator.

This card is informational only — it does not constitute a tax filing. A warning banner is rendered below the primary metric when the net VAT liability exceeds 50,000 EUR (see Threshold tuning).

VAT rates applied: 19% standard, 9% and 5% reduced, 0%, exempt — per Cyprus VAT schedule.

### `income_total`

Displays the sum of totals for all SENT invoices in the period. Includes tax-inclusive totals. The secondary metric is the signed delta versus the same period in the prior year (positive = increase, negative = decrease), formatted as EUR with a leading `+` or `−` sign.

The bar chart shows monthly breakdowns within the period if the selected period spans more than one month. Single-month periods show a single bar.

### `expense_total`

Displays the sum of OUT transaction amounts for classified transactions in the period. The secondary metric is the signed delta versus the prior year same period.

Unclassified transactions are excluded from the primary metric. A footnote on the card shows the count of unclassified transactions if any exist, with a link to the review queue.

### `match_rate`

Displays the percentage of transactions that are either matched or have an exception documented. The formula is `(matched_count + exception_documented_count) / total_transaction_count × 100`. The secondary metric is the raw count of unmatched transactions with no documented exception.

The donut chart segments: matched (green), exception-documented (amber), unmatched (red).

### `open_issues`

Displays the count of open review issues grouped by severity (LOW, MEDIUM, HIGH, BLOCKING). The BLOCKING count is displayed prominently — in the card header, in a bold red count badge, separate from the stacked bar.

The stacked bar shows four segments: LOW (grey), MEDIUM (amber), HIGH (orange), BLOCKING (red).

When the BLOCKING count is greater than zero, the entire card renders in error state (red card border, error icon in the card header). This is the only card with an error-state visual override driven by data content (see Threshold tuning).

### `archive_status`

Displays one of three values: `SEALED` (bundle locked in Object Storage), `PENDING` (finalization in progress or not yet started), `FAILED` (archive promotion failed). The secondary metric is the timestamp of the last successful seal, or `—` if the period has never been sealed.

Badge colours: `SEALED` = green, `PENDING` = grey, `FAILED` = red.

### `invoice_pipeline`

Displays invoice counts grouped into funnel stages: DRAFT → SENT → PAID. OVERDUE invoices are a sub-category of SENT (a SENT invoice past its due date). The secondary metric is the total EUR amount of overdue invoices.

The funnel chart shows counts at each stage. Clicking a funnel stage opens the drill-down panel filtered to invoices in that status.

### `vies_compliance`

Displays the percentage of EU counterparties that have a valid VIES record on file. EU counterparties are those with `is_intraeu_supplier = true` on the `counterparties` row. The secondary metric is the count of counterparties that failed VIES validation or have no VIES record.

This card refreshes daily because VIES lookups are cached and re-queried daily rather than per-transaction.

### `spend_budget`

Displays the current month's AI spend in USD against the configured ceiling. The secondary metric is the percentage of the ceiling consumed, formatted as `XX%`. The gauge fill colour shifts from green to amber at 75% consumed and from amber to red at 90% consumed.

The ceiling value is sourced from the business's AI cost ceiling configuration (Block 06 Phase 08). If no ceiling is configured, the gauge is not rendered; the card shows `No ceiling configured` with a link to settings.

### `document_intake`

Displays the count of documents processed in the period, grouped by source type: PDF (direct upload), EMAIL (Gmail finder), MANUAL (manual upload). The secondary metric is the average OCR confidence score across all documents with a completed OCR pass, expressed as a percentage.

The bar chart shows three bars, one per source type. A tooltip on each bar shows the count and the average OCR confidence for that source type.

---

## Card actions menu

Each card has a actions menu (`⋯`) in the card header. The menu contains three items:

**View details** — opens the drill-down panel for the card's data domain. Behaviour and column specs are defined in `drill_down_list_detail_ui_spec.md`.

**Export card data** — triggers a CSV export of the underlying data for the card's current metric. The export is generated asynchronously via `report.queue_report_job`. A toast notification confirms when the export is ready. The signed download URL has a 24-hour TTL per the Export temp data zone.

**Refresh now** — triggers an immediate refresh of the card data by calling the card's `data_source_tool` directly. Rate-limited to one manual refresh per card per minute. If the rate limit is active, the menu item is disabled and shows a tooltip: `"Refresh available in Xs"` where X is the remaining cooldown in seconds.

---

## Threshold tuning

Two data-driven visual overrides apply across the card set:

**BLOCKING issue count > 0 — `open_issues` error state.** When `report.get_queue_summary` returns a BLOCKING issue count greater than zero, the `open_issues` card renders in error state: red card border (using `--color-error-border` token), error icon in the card header. The error state is cleared when the BLOCKING count returns to zero.

**VAT liability > 50,000 EUR — `vat_liability` warning banner.** When the net VAT liability from `report.generate_period_report` exceeds 50,000 EUR, a warning banner is rendered inside the card below the primary metric: `"Liability exceeds €50,000. Verify before filing."` The banner uses the `--color-warning-surface` token. This threshold is not configurable per business; it is a fixed system threshold.

---

## Refresh cadence notes

Cards with event-driven refresh (`period_status`, `archive_status`) listen to the `ARCHIVE_PROMOTION_COMPLETED` event via the dashboard event subscription channel. Cards with `on matching phase complete` cadence (`match_rate`) listen for `WORKFLOW_PHASE_STATE_TRANSITIONED` events where `phase_name = MATCHING`.

Hourly refresh is implemented via a background job that updates the analytics snapshot. Cards reading from `report.generate_period_report` read from the snapshot, not from live query. The snapshot timestamp is shown in the card footer: `"As of HH:MM"`.

---

## Cross-references

- `drill_down_list_detail_ui_spec.md` — drill-down panel behaviour for "View details" card action
- `drill_down_schemas.md` — data schemas returned by each card's drill-down endpoint
- `analytics_snapshot_schema.md` — snapshot table that hourly-refresh cards read from
- `report_job_schema.md` — async report job lifecycle for "Export card data" action
- `audit_event_taxonomy.md` — `DASHBOARD_VIEWED`, `DASHBOARD_REFRESH_REQUESTED`, `DASHBOARD_DRILL_DOWN_ACCESSED`
