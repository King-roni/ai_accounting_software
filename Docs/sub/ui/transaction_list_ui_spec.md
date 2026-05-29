# Transaction List UI Spec

**Block:** data / classification / matching  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The Transaction List is the primary tab on the Run Detail page. It renders all transactions ingested for the current run, supports filtering and sorting across all key dimensions, and provides inline editing actions for classification and match confirmation. It is implemented as the `TransactionListTab` component and receives `run_id` as a prop. Data is fetched via `data.list_transactions`.

---

## Column Definitions

The table renders the following columns in order. All column headers are clickable for sort unless noted.

| Column | Source field | Sortable | Notes |
|---|---|---|---|
| Date | `transaction.date` | Yes | Display as locale date; sort default desc |
| Counterparty | `transaction.counterparty_name` | Yes | Truncated at 32 chars; tooltip on hover |
| Reference | `transaction.reference` | No | Monospace; truncated at 20 chars |
| Amount | `transaction.amount` | Yes | Right-aligned; formatted with currency symbol |
| Currency | `transaction.currency` | No | ISO 4217 code badge |
| Dedup status | `transaction.dedup_status` | No | Badge (see below) |
| Classification | `transaction.classification_category` | No | Category name + confidence % badge |
| Match level | `transaction.match_level` | No | Badge (see below) |
| Actions | — | No | Context-sensitive inline buttons |

### Dedup Status Badge Values

| Value | Badge colour |
|---|---|
| NEW | `--color-green-100` / `--color-green-700` |
| DUPLICATE_PROBABLE | `--color-amber-100` / `--color-amber-700` |
| DUPLICATE_EXACT | `--color-red-100` / `--color-red-700` |
| NEEDS_REVIEW | `--color-neutral-200` / `--color-neutral-500` |

### Classification Badge

Displays as two stacked elements in the cell:
- Category name (from `chart_of_accounts.name`), truncated at 24 chars, with tooltip.
- Confidence percentage: `{n}%` with colour: ≥85% green, 70–84% amber, <70% red.
- If unclassified: single badge "Unclassified" in `--color-neutral-200`.

### Match Level Badge Values

| Value | Badge colour |
|---|---|
| EXACT | `--color-green-100` / `--color-green-700` |
| FUZZY | `--color-blue-100` / `--color-blue-700` |
| UNMATCHED | `--color-red-100` / `--color-red-700` |
| PENDING | `--color-amber-100` / `--color-amber-700` |

---

## Sort Behaviour

- Default sort: `transaction.date` descending.
- Secondary sort: `transaction.amount` descending (applied when primary sort values are equal).
- Sort state is reflected in column header with up/down chevron icon.
- Sort is applied server-side; changes trigger a new `data.list_transactions` call with `sort_by` and `sort_dir` params.

---

## Filter Panel

The filter panel is collapsed by default. A "Filters" button in the toolbar expands it as a row below the toolbar. Active filter count is shown as a badge on the Filters button.

### Filter Controls

| Filter | Control type | Field |
|---|---|---|
| Dedup status | Multi-select dropdown | `dedup_status` |
| Classification status | Radio group: All / Classified / Unclassified | `classification_category IS NULL` |
| Match level | Multi-select dropdown | `match_level` |
| Amount range | Two numeric inputs: Min / Max | `amount` |
| Date range | Date picker: From / To | `transaction.date` |
| Currency | Single-select dropdown | `transaction.currency` |

- All filters are ANDed together.
- "Clear filters" button resets all filters and re-fetches.
- Active filters persist across tab navigation within the same run detail session (stored in component state, not URL).

---

## Bulk Actions

A bulk action toolbar appears above the table when one or more rows are selected via checkboxes.

| Action | Availability | API call |
|---|---|---|
| Bulk classify | ≥1 row selected; `run_status` = RUNNING or REVIEW_HOLD | `classification.apply` with `transaction_ids[]` |
| Bulk confirm match | ≥1 row selected with `match_level` = FUZZY or EXACT | `matching.confirm_match` with `transaction_ids[]` |
| Bulk reject match | ≥1 row selected with existing match proposals | `matching.reject_match` with `transaction_ids[]` |

Bulk classify opens a mini-modal to select the target category from `chart_of_accounts` before submitting.

Bulk actions are disabled if the user's role is VIEW_ONLY. Tooltip: "Your role does not allow bulk edits."

Select-all checkbox in the header selects all rows on the current page only. A secondary action "Select all {n} transactions" appears in the bulk toolbar to extend selection across all pages.

---

## Inline Classification Edit

Clicking the Classification cell opens an inline edit state for that row:

1. Category cell transforms into a searchable dropdown populated from `chart_of_accounts` active categories.
2. Type-ahead filters the list; a maximum of 20 results shown.
3. Selecting a category and pressing Enter or clicking "Apply" calls `classification.apply({ transaction_id, category_id, source: "MANUAL" })`.
4. On success: cell updates to new category name + `100%` confidence badge (manual overrides show 100%).
5. On failure: cell reverts; error toast shown.
6. Pressing Escape cancels without saving.

The inline edit is only available if `run_status` is RUNNING or REVIEW_HOLD. In all other states the cell is read-only.

---

## Inline Match Actions

For rows with `match_level` of EXACT or FUZZY and `match_status` of PENDING, two icon buttons appear in the Actions column:

- Checkmark icon: "Confirm match" → `matching.confirm_match({ transaction_id, match_id })`
- X icon: "Reject match" → `matching.reject_match({ transaction_id, match_id })`

On confirm, the `match_level` badge updates to EXACT with `--color-green` styling and action buttons disappear.

On reject, the `match_level` updates to UNMATCHED and the row is flagged for review.

---

## Transaction Detail Drawer

Clicking anywhere on a row (except an action button or inline edit cell) opens the Transaction Detail Drawer — a slide-in panel from the right edge, 480px wide on desktop, full-width bottom sheet on mobile.

### Drawer Sections

**1. Transaction Details**
All raw fields: id, date, counterparty_name, counterparty_iban, reference, amount, currency, dedup_status, ingested_at, source (BANK_STATEMENT / MANUAL / API).

**2. AI Classification Reasoning**
- Chosen category name and code.
- Confidence score.
- Top 3 alternative categories considered (name, score).
- Model version used (`ai.model_version`).
- Reasoning text (plain prose, max 300 chars, truncated with expand link).

**3. Match Proposal Details**
- Match ID, match_level, score.
- Matched-against document: type (invoice / expense / journal), reference, amount, date.
- Match signals that fired (from `match_signal_weights.md`).
- Current match_status.

**4. Audit Trail**
Timeline of audit events for this transaction (filtered `data.list_audit_events?transaction_id={id}`). Columns: timestamp, event_type, actor, description.

**Drawer header:** transaction reference + date. Close button (X) top-right. On mobile: swipe down to close.

---

## Empty States

| Condition | Message |
|---|---|
| No transactions yet | "No transactions have been ingested for this run yet. Transactions appear after the INTAKE phase completes." |
| Filters return zero rows | "No transactions match the current filters." with "Clear filters" button. |
| Run is CANCELLED | "This run was cancelled. No transaction data is available." |

---

## Pagination

- 50 rows per page.
- Pagination controls: Previous / Next buttons; page number indicator `Page {n} of {total}`.
- Total transaction count displayed above the table: `{n} transactions`.
- Page resets to 1 when any filter or sort changes.

---

## API Calls

| Action | Tool | Params |
|---|---|---|
| Load transactions | `data.list_transactions` | `{ run_id, page, per_page, sort_by, sort_dir, filters }` |
| Apply classification | `classification.apply` | `{ transaction_id, category_id, source }` |
| Confirm match | `matching.confirm_match` | `{ transaction_id, match_id }` |
| Reject match | `matching.reject_match` | `{ transaction_id, match_id }` |
| Load audit trail | `data.list_audit_events` | `{ transaction_id, page, per_page }` |

All calls use the authenticated session token. Classification and match actions are blocked server-side if `run_status` does not permit writes.

---

## Accessibility

- Table supports keyboard navigation: Tab to focus rows, Enter to open drawer, Escape to close drawer.
- All badge elements have `aria-label` with full text value.
- Filter panel toggle announces expansion state via `aria-expanded`.
- Bulk action toolbar announces count of selected rows via live region.

---

## Mobile

The Transaction List tab is fully accessible on mobile:

- Columns collapse to: Date, Counterparty, Amount, Classification badge.
- Remaining columns accessible via the Transaction Detail Drawer (tap row to open).
- Filter panel renders as a bottom sheet modal on mobile.
- Bulk classify and bulk match actions are hidden on mobile (read-only mode enforced per `mobile_write_rejection_endpoints.md`).
- Inline edit is disabled on mobile; classification edits must be performed via the Drawer's "Edit Classification" button which routes to the desktop or flags for accountant.

---

## Related Documents

- `run_detail_ui_spec.md`
- `transaction_detail_ui_spec.md`
- `match_level_enum.md`
- `match_signal_weights.md`
- `classification_review_ui_spec.md`
- `mobile_write_rejection_endpoints.md`
- `error_code_catalog.md`
