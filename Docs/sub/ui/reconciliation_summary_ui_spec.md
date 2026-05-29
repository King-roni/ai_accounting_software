# Reconciliation Summary UI Spec

**Category:** UI · Block 10/11 — Matching Engine / Ledger
**Status:** Authoritative
**Cross-ref:** transaction_schema.md, match_record_schema.md, matching_policy.md, review_issues_schema.md, transaction_detail_ui_spec.md, report_output_schema.md

---

## 1. Overview

The reconciliation summary screen gives ACCOUNTANT, OWNER, and ADMIN users a complete picture of the matching results for a given accounting period after the OUT workflow matching phase completes. It serves as the primary workspace for reviewing, confirming, and resolving unmatched or uncertain transactions before a period is locked.

---

## 2. Access

- **Roles:** ACCOUNTANT, OWNER, ADMIN.
- VIEWER role does not have access to this screen.

---

## 3. Entry Points

### 3.1 OUT Workflow Run Detail Page

- After the matching phase of an OUT workflow run completes (phase status transitions to COMPLETE), a "View Reconciliation Summary" button appears on the run detail page.
- The button is disabled while the matching phase is in progress; it activates when the phase completes.

### 3.2 Dashboard Period Card

- Each period card on the dashboard (Block 16) shows a "Reconciliation" link when a completed matching run exists for the period.
- Clicking the link navigates directly to the reconciliation summary for that period.

---

## 4. Screen Layout

The screen is a full-width dashboard layout. No sidebar is hidden; the primary nav remains visible.

### 4.1 Page Header

- **Title:** "Reconciliation — {period_label}" (e.g., "Reconciliation — April 2025").
- **Subtitle:** "OUT Workflow Run #{run_id} · Matching completed {relative_timestamp}."
- **Actions (right-aligned):**
  - "Export Reconciliation Report" button (see Section 10).
  - "Back to Run" text link — returns to the workflow run detail page.

---

## 5. KPI Cards

Four KPI cards are displayed in a horizontal row below the page header. On mobile, they stack vertically (see Section 11).

### 5.1 Total Transactions

- **Value:** The total count of transactions in scope for the period.
- **Label:** "Total Transactions"
- **Colour:** Neutral; `--color-surface-default`.

### 5.2 Matched

- **Value:** Count of transactions with `match_level IN (EXACT, STRONG_PROBABLE)`.
- **Label:** "Matched"
- **Colour:** `--color-surface-success-subtle`.
- **Sub-label:** Shows the split: "X EXACT · Y STRONG_PROBABLE" in `--font-size-xs`, `--color-text-secondary`.

### 5.3 Needs Review

- **Value:** Count of transactions with `match_level IN (WEAK_POSSIBLE, NO_MATCH)` plus the count of open review issues linked to transactions in this period.
- **Label:** "Needs Review"
- **Colour:** `--color-surface-warning-subtle`.
- **Sub-label:** "X unmatched · Y open issues."

### 5.4 Unreconciled Amount

- **Value:** Sum of `amount` for all transactions with `match_level = NO_MATCH` or no match record, formatted in the business's base currency.
- **Label:** "Unreconciled Amount"
- **Colour:** `--color-surface-error-subtle` if value > 0; `--color-surface-success-subtle` if value = 0.

---

## 6. Reconciliation Completeness Indicator

Displayed below the KPI cards, above the transactions table.

- **Label:** "Period reconciliation progress"
- **Format:** A horizontal progress bar; `--color-surface-muted` background; filled portion based on `matched_amount / total_amount`.
- **Percentage label:** "X% reconciled" — displayed to the right of the bar.
- **Colour states:**
  - Green (`--color-surface-success`): percentage ≥ 95%.
  - Yellow (`--color-surface-warning`): percentage 80% to < 95%.
  - Red (`--color-surface-error`): percentage < 80%.
- **Target indicator:** A vertical tick mark at the 95% position on the bar labelled "Target" in `--font-size-xs`.
- **Calculation:** `matched_amount` = sum of amounts for transactions with `match_level IN (EXACT, STRONG_PROBABLE)`. `total_amount` = sum of all transaction amounts in the period.

---

## 7. Transactions Table

A paginated table of all transactions in the period.

### 7.1 Columns

| Column          | Source field                              | Sortable |
|-----------------|-------------------------------------------|----------|
| Date            | `transactions.value_date`                 | Yes      |
| Description     | `transactions.description` (truncated)    | No       |
| Amount          | `transactions.amount` + currency          | Yes      |
| Counterparty    | `transactions.counterparty_name`          | Yes      |
| Match Status    | `match_records.match_level` badge         | Yes      |
| Classification  | `transactions.classification_label`       | No       |
| Actions         | Row action menu                           | No       |

### 7.2 Match Status Badge

Match level is displayed as a coloured badge using severity_color_tokens.md:

| match_level       | Badge label        | Badge colour                    |
|-------------------|--------------------|---------------------------------|
| EXACT             | "Exact"            | `--color-badge-success`         |
| STRONG_PROBABLE   | "Strong"           | `--color-badge-info`            |
| WEAK_POSSIBLE     | "Weak"             | `--color-badge-warning`         |
| NO_MATCH          | "No Match"         | `--color-badge-error`           |

### 7.3 Row Drill-Down

Clicking any row opens the transaction detail drawer (transaction_detail_ui_spec.md) as a right-side slide-over, without navigating away from the reconciliation summary screen.

### 7.4 Pagination

- 50 rows per page (default). User can change to 25 or 100 via a per-page selector.
- Standard pagination controls: Previous / Next / page number buttons.
- Total row count is displayed: "Showing X–Y of Z transactions."

---

## 8. Match Status Filter Tabs

Above the transactions table, a tab bar filters the visible rows:

| Tab label     | Filter logic                                           |
|---------------|--------------------------------------------------------|
| All           | No filter; all transactions shown                      |
| Matched       | `match_level IN (EXACT, STRONG_PROBABLE)`              |
| Needs Review  | `match_level IN (WEAK_POSSIBLE, NO_MATCH)` or open review issue |
| Unmatched     | `match_level = NO_MATCH` only                          |

The tab label includes the count in parentheses: "Needs Review (14)". Counts update in real time when bulk actions are applied.

---

## 9. Bulk Actions

Bulk actions are available to ACCOUNTANT, OWNER, and ADMIN. VIEWER cannot perform bulk actions.

### 9.1 Bulk Confirm EXACT Matches

- **Trigger:** A "Confirm all EXACT matches" button is shown in the table action bar (above the table, below the tabs).
- **Scope:** All transactions with `match_level = EXACT` and `is_confirmed = false` in the current period.
- **Behaviour:** Calls `match.bulk_confirm` with the list of transaction IDs. Sets `is_confirmed = true` on each match record. No individual review is required for EXACT matches.
- **Confirmation modal:** A modal asks: "Confirm X EXACT matches for {period_label}? This marks them as reviewed." Two buttons: "Confirm All" (primary) and "Cancel".
- **Result:** Success toast: "X transactions confirmed." Counts and the completeness indicator update.
- **Audit event:** `MATCH_BULK_CONFIRMED`; severity LOW.

### 9.2 Bulk Dismiss WEAK_POSSIBLE as NO_MATCH_CONFIRMED

- **Trigger:** A "Dismiss weak matches" button in the table action bar. Only visible when the "Needs Review" or "All" tab is active and at least one WEAK_POSSIBLE match exists.
- **Scope:** All selected rows with `match_level = WEAK_POSSIBLE` (user must select rows via checkboxes first; "Select all on page" checkbox available).
- **Behaviour:** Calls `match.bulk_dismiss` with the selected transaction IDs. Sets `match_level = NO_MATCH` and `is_dismissed = true` on the match records.
- **Confirmation modal:** "Dismiss X weak matches as unmatched? They will be moved to the Unmatched tab." Two buttons: "Dismiss" (destructive primary) and "Cancel".
- **Audit event:** `MATCH_BULK_DISMISSED`; severity MEDIUM.

---

## 10. Export

- **Button:** "Export Reconciliation Report" — in the page header.
- **Trigger:** Calls `report.generate` with `report_type = PERIOD_SUMMARY` and `period_id = {current_period_id}`.
- **Behaviour:** A report generation job is created asynchronously. A toast confirms: "Report is being generated. You'll be notified when it's ready." The notification (WORKFLOW_EVENT type) links to the report download when complete.
- **Output format:** Defined in report_output_schema.md.

---

## 11. Mobile Behaviour

| Feature                        | Desktop                               | Mobile                                       |
|--------------------------------|---------------------------------------|----------------------------------------------|
| KPI cards                      | Horizontal row of 4                   | Vertical stack of 4                          |
| Completeness indicator         | Below KPI cards                       | Below KPI cards (full width)                 |
| Transactions table             | Full table with columns               | Card list: one card per transaction          |
| Sortable columns               | Column header click                   | Sort picker sheet (bottom sheet)             |
| Bulk actions                   | Available                             | Not available on mobile                      |
| Drill-down drawer              | Right-side slide-over                 | Full-screen bottom sheet                     |
| Export button                  | In page header                        | In overflow menu (three-dot icon)            |

The mobile card list shows: Date, Description (truncated), Amount, and Match Status badge per card. Tapping a card opens the transaction detail.
