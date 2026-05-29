# VAT Period Overview UI Spec

**Block:** report / ledger  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The VAT Period Overview page provides a full list of all VAT periods associated with the authenticated business entity. It surfaces each period's lock status, total VAT payable, filing deadline, and the number of runs associated with the period. It is the primary navigation point for period-level operations: generating reports, initiating VAT return submissions, and locking periods after all runs are finalized. Route: `/vat-periods`.

---

## Page Header

| Element | Content |
|---|---|
| Page title | "VAT Periods" |
| Sub-label | Business legal name from `business_entities.legal_name` |
| Action button | "New Run" — navigates to the new-run creation flow (out of scope for this spec) |

---

## Period List

The period list is the primary content. Each row represents one VAT period. Periods are sorted by `period_start` descending (most recent first).

### Columns

| Column | Source | Notes |
|---|---|---|
| Period label | Derived from `period_start` / `period_end` | Format: `Q1 2026` for quarterly, `Jan 2026` for monthly |
| Period dates | `period_start` – `period_end` | ISO dates, formatted as locale short date |
| Status | `vat_period.status` | Badge (see below) |
| VAT payable | `vat_period.vat_payable_total` | Currency formatted; `--` if not yet calculated |
| Filing deadline | `vat_period.filing_deadline` | Date + days indicator (see deadline colours below) |
| Runs | `vat_period.run_count` | Integer; link to runs filtered to this period |
| Actions | — | Button group: Generate Report, Submit VAT Return, View Ledger |

### Status Badge Values

| Status | Background | Text |
|---|---|---|
| OPEN | `--color-blue-100` | `--color-blue-700` |
| LOCKED | `--color-green-100` | `--color-green-700` |
| AMENDED | `--color-amber-100` | `--color-amber-700` |

---

## Filing Deadline Indicator

The deadline column renders in two parts: the date, and a secondary line showing days remaining or overdue state.

| Condition | Indicator text | Colour |
|---|---|---|
| > 14 days until deadline | `{n} days left` | `--color-green-600` |
| 7–14 days until deadline | `{n} days left` | `--color-amber-600` |
| < 7 days until deadline | `{n} days left` | `--color-red-600` |
| Past deadline, period OPEN | `Overdue by {n} days` + warning icon | `--color-red-700`, bold |
| Past deadline, period LOCKED or AMENDED | `Filed` | `--color-neutral-500` |

When a period is overdue and OPEN, the entire row has a left border accent of `--color-red-400` (2px solid).

---

## Row Actions

Each row has an actions column with a button group. Buttons are conditionally enabled.

| Button | Available when | Tooltip if disabled |
|---|---|---|
| Generate Report | Any status | — |
| Submit VAT Return | Status = OPEN; all runs finalized | "Lock period first, or ensure all runs are finalized." |
| View Ledger | Any status | — |

"Generate Report" calls `report.generate_vat_period_report({ period_id })` and opens the PDF in a new tab (uses `pdf_generation` integration).

"Submit VAT Return" navigates to the VAT return submission flow (see `vies_submission_ui_spec.md`).

"View Ledger" navigates to `/ledger?period_id={period_id}`.

---

## Lock Period Button

A "Lock Period" button is available per row when:

- `vat_period.status` = OPEN
- All runs associated with the period have `run_status` = FINALIZED
- User role is ADMIN or ACCOUNTANT

If conditions are not met, the button is replaced with a tooltip-enabled disabled state: "All runs must be finalized before locking this period."

### Lock Confirmation Modal

- Title: "Lock VAT period {label}?"
- Body: "Locking this period will prevent further modifications to its ledger entries. The VAT payable figure will be frozen. This action can only be reversed by an amendment run."
- Warning if VAT return not yet submitted: "You have not submitted a VAT return for this period. Lock anyway?"
- Primary action: "Lock Period" (primary, not destructive styling)
- Secondary: "Cancel"
- On confirm: `ledger.lock_period({ period_id })`
- On success: row status badge updates to LOCKED; Lock button disappears.

---

## Period Detail Drawer

Clicking a period row (not an action button) opens a slide-in drawer from the right (480px wide on desktop, full-screen bottom sheet on mobile).

### Drawer Sections

**1. Period Summary**
- Period label, dates, status badge, filing deadline.
- VAT payable total (large font).
- VIES value (from `vies_records` aggregate for the period).

**2. Runs List**
Table of runs associated with this period.

| Column | Value |
|---|---|
| Run ID | Link to Run Detail page |
| Status badge | `run_status` |
| Phase | Current phase name |
| Transactions | `run.transaction_count` |
| VAT contribution | `run.vat_payable_amount` |

**3. Ledger Summary**
- Total debits, total credits, net balance for the period.
- Balance indicator: green checkmark if balanced, red warning if not.

**4. VAT Return History**
List of submission attempts for this period.

| Column | Value |
|---|---|
| Submitted at | Timestamp |
| Submitted by | User email |
| Status | ACCEPTED / REJECTED / PENDING |
| Reference | Tax authority reference number |

Empty state: "No VAT return submissions yet for this period."

Drawer close: X button top-right, or click outside drawer on desktop.

---

## Empty State

When no VAT periods exist for the business:

- Illustration (empty calendar icon, 64px, `--color-neutral-300`).
- Heading: "No VAT periods yet."
- Body: "Create your first run to generate a VAT period automatically. Periods are created based on your business's VAT filing frequency."
- CTA button: "Create First Run" → navigates to new-run flow.

---

## Filtering and Search

A search bar above the table filters periods by period label (client-side filter on loaded data). Placeholder: "Search periods...".

A status filter dropdown (All / OPEN / LOCKED / AMENDED) is placed to the right of the search bar.

Results update immediately on input; no server round-trip for filtering (all periods for the business are loaded on page mount).

---

## Pagination

- If `vat_period_count` > 20, paginate with 20 rows per page.
- Most businesses will have < 20 periods at any given time; pagination is unlikely to activate in the first 5 years of operation.

---

## Mobile

The VAT Period Overview page is read-only on mobile.

- The period list renders with reduced columns: Period label, Status badge, Filing deadline indicator, and an Actions chevron.
- Tapping the chevron opens the Period Detail Drawer as a full-screen bottom sheet.
- The Lock Period button is hidden on mobile. A note in the drawer reads: "Period locking is only available on desktop."
- "Generate Report" and "View Ledger" are available on mobile.
- "Submit VAT Return" is hidden on mobile with a note directing users to desktop.

---

## API Calls

| Action | Tool | Params |
|---|---|---|
| Load periods | `data.list_vat_periods` | `{ business_id, page, per_page }` |
| Lock period | `ledger.lock_period` | `{ period_id }` |
| Generate report | `report.generate_vat_period_report` | `{ period_id }` |
| Load drawer runs | `data.list_runs` | `{ period_id }` |
| Load ledger summary | `ledger.get_period_summary` | `{ period_id }` |

---

## Error States

- **Load failure:** Inline error card with "Failed to load VAT periods. Retry" button.
- **Lock failure:** Toast with error code from `error_code_catalog.md`; row reverts to OPEN status.
- **Report generation failure:** Toast with error; no PDF opened.

---

## Related Documents

- `vies_submission_ui_spec.md`
- `period_navigation_ui_spec.md`
- `period_report_ui_spec.md`
- `finalization_approval_ui_spec.md`
- `vat_rate_table_reference.md`
- `cyprus_vat_rule_catalog.md`
- `run_phase_enum.md`
