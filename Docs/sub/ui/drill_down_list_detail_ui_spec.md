# Drill-Down List and Detail View UI Spec

**Category:** UI · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

This document specifies the drill-down panel that opens when a user interacts with a dashboard card metric or selects "View details" from a card's actions menu. It defines the panel layout, list view pagination, column specifications per record kind, detail view structure, keyboard shortcuts, sorting behaviour, and mobile adaptation.

---

## Purpose

The drill-down panel provides read access to the underlying records behind any dashboard card metric. It is not a data-entry surface. No writes, edits, or status changes originate from the drill-down panel — those actions are handled by dedicated workflow UI screens. The panel's scope is display and navigation only.

---

## Entry points

Two entry points open the drill-down panel:

1. **Card metric click** — clicking the primary metric value or secondary metric value on any dashboard card opens the drill-down panel pre-filtered to the relevant record set. The filter applied corresponds to the metric clicked (e.g., clicking the OVERDUE count on `invoice_pipeline` filters the list to invoices with status OVERDUE).

2. **"View details" card action** — selecting "View details" from the card's `⋯` actions menu opens the drill-down panel with no pre-filter applied, showing the full record set for the card's domain.

---

## Panel layout

The drill-down panel is a slide-over panel anchored to the right edge of the viewport.

- **Desktop:** 600px wide. The main content area remains visible and dimmed behind a backdrop. Clicking the backdrop closes the panel.
- **Mobile:** full-screen. See Mobile section.

The panel has a fixed header containing: the record kind label (e.g., "Invoices", "Transactions"), the active filter description (e.g., "Status: OVERDUE"), and a close button (`×`). The header does not scroll with the list.

A panel footer shows the total record count for the current filter and the cursor position (`Showing 1–50 of 247`).

---

## List view

### Pagination

Pagination is cursor-based. Offset-based pagination is not used. The API returns a `next_cursor` token with each page response. Requesting the next page passes `cursor=<next_cursor>` to the data source. There is no `prev_cursor` — navigation is forward-only within a session. Scrolling to the bottom of the list automatically loads the next page (infinite scroll). A loading indicator is shown at the bottom of the list while the next page is being fetched.

Default page size: 50 records per page. This is not configurable from the UI.

### Column specifications

Columns are fixed per record kind. The columns below are the full set for each kind. No column picker or hide/show toggle is provided in the drill-down panel.

#### Transactions

| Column | Source field | Format |
|---|---|---|
| Date | `transactions.date` | ISO date, displayed as `DD MMM YYYY` |
| Counterparty | `counterparties.normalised_name` | Plain text, truncated at 32 chars with tooltip |
| Amount | `transactions.amount_signed_eur` | EUR with two decimal places; negative values in red |
| Match status | `transactions.match_status` | Pill badge: MATCHED (green), UNMATCHED (red), EXCEPTION (amber) |
| Category | `transactions.transaction_type` | Plain text |
| Effective match status | `match_records.effective_match_status` | Pill badge |

#### Invoices

| Column | Source field | Format |
|---|---|---|
| Invoice number | `invoices.invoice_number` | Plain text, monospace |
| Client name | `clients.canonical_name` | Plain text, truncated at 32 chars |
| Status | `invoices.status` | Pill badge: DRAFT (grey), SENT (blue), PAID (green), OVERDUE (red) |
| Total amount | `invoices.total_amount_eur` | EUR with two decimal places |
| Due date | `invoices.due_date` | ISO date, displayed as `DD MMM YYYY`; past dates in red |
| Days overdue | Computed: `today − due_date` if status = OVERDUE | Integer; `—` for non-overdue invoices |

#### Review issues

| Column | Source field | Format |
|---|---|---|
| Issue type | `review_issues.issue_type` | Plain text |
| Severity | `review_issues.severity` | Pill badge: LOW (grey), MEDIUM (amber), HIGH (orange), BLOCKING (red) |
| Status | `review_issues.status` | Pill badge: OPEN (blue), RESOLVED (green), SNOOZED (grey), DISMISSED (grey) |
| Assigned to | `users.display_name` via `review_issues.assigned_to_user_id` | Plain text; `Unassigned` if null |
| Created at | `review_issues.created_at` | ISO 8601, displayed as relative time (e.g., "3 days ago") with full timestamp on hover |

#### Ledger entries

| Column | Source field | Format |
|---|---|---|
| Date | `ledger_entries.entry_date` | ISO date, displayed as `DD MMM YYYY` |
| Description | `ledger_entries.description` | Plain text, truncated at 48 chars |
| Account code | `chart_of_accounts.account_code` | Monospace |
| Debit (EUR) | `ledger_entries.debit_amount_eur` | EUR with two decimal places; `—` if zero |
| Credit (EUR) | `ledger_entries.credit_amount_eur` | EUR with two decimal places; `—` if zero |
| VAT treatment | `ledger_entries.vat_treatment` | Plain text (e.g., `STANDARD_19`, `EXEMPT`, `EU_REVERSE_CHARGE`) |

---

## Detail view

Clicking any row in the list view opens the detail view panel. The detail view slides in on top of the list view, increasing the panel width from 600px to 720px. The list view remains visible and scrollable behind the detail panel. A back arrow (`←`) in the detail panel header returns to the list view at the same scroll position.

The detail view shows all fields for the record, including fields not present in the list columns. Fields are displayed in a two-column label/value layout.

Below the field display, the detail view shows an audit trail section: the last 10 audit events where `subject_id = <entity_id>` for the record's entity. Each audit event row shows: event type, actor display name, timestamp. Clicking an audit event row shows the full event payload in an expandable section.

The audit trail is read-only. Audit event payloads are shown as formatted JSON — no inline editing.

---

## Keyboard shortcuts

These shortcuts are active when the drill-down panel is open and focus is within the panel.

| Key | Action |
|---|---|
| `j` | Move focus to the next row in the list |
| `k` | Move focus to the previous row in the list |
| `Enter` | Open the detail view for the focused row |
| `Escape` | Close the detail view (if open) or close the panel |
| `c` | Copy the focused record's primary ID to clipboard |

`c` copies the entity's UUID (the primary key, e.g., `invoice_id`, `transaction_id`) as a plain UUID string. A toast notification confirms: `"ID copied to clipboard"`.

Keyboard shortcuts are documented in a tooltip accessible via a `?` icon in the panel header.

---

## Sorting

**Client-side sort** is available on all visible columns. Clicking a column header toggles between ascending and descending sort order. The sort is applied to the current in-memory page only; it does not re-fetch data.

**Server-side sort** is available on `date` (all record kinds) and `amount` (transactions, invoices). Server-side sort re-fetches from the first page with `sort_by` and `sort_dir` parameters. A loading indicator replaces the list during the re-fetch.

When a server-side sort column header is clicked, the client-side sort state is cleared and a server-side sort fetch is initiated.

---

## Mobile

On mobile, the drill-down panel renders as full-screen with no backdrop dimming.

The panel is **read-only on mobile** — the same constraint as all other write surfaces. No inline actions (resolve, assign, dismiss) are available in the mobile drill-down view even though those actions are not technically write operations in this panel (the panel is already read-only on desktop).

Detail view: on mobile, the detail view opens as a bottom sheet (slides up from the bottom of the screen) rather than a slide-in panel. The bottom sheet covers approximately 80% of the screen height. Dragging down dismisses it.

The audit trail section in the detail view is collapsed by default on mobile (expanded by default on desktop) to reduce scroll distance.

---

## Cross-references

- `drill_down_schemas.md` — API response schemas for each record kind; `next_cursor` token format
- `dashboard_card_definitions_ui_spec.md` — card definitions that link to this panel via "View details"
- `dashboard_widget_config_schema.md` — dashboard configuration schema including default filter states
- `review_queue_filter_schema.md` — filter schema for review issue drill-downs
- `audit_event_taxonomy.md` — `DASHBOARD_DRILL_DOWN_ACCESSED`, `DASHBOARD_DRILL_DOWN_DETAIL_ACCESSED`, `DASHBOARD_DRILL_DOWN_QUERIED`
