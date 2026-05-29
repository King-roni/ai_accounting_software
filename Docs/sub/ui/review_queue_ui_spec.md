# Review Queue UI Spec

**Block:** 08 — Review Queue  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The Review Queue page is the centralised view of all open, snoozed, and in-progress issues across every run for a business. Accountants use this page as their primary triage surface: they see all issues that require human judgment, filter by the dimensions most relevant to their current task, and take resolution actions without navigating away to individual run pages. The page is designed for high-volume workdays where an accountant may need to process dozens of issues across multiple clients.

---

## Page Purpose

- Provide a single list of all non-resolved, non-void issues for the authenticated business context.
- Surface severity distribution at a glance so accountants can prioritise BLOCKING issues first.
- Allow batch actions to reduce repetitive single-issue operations.
- Serve as the entry point for escalating issues to supervisors or senior accountants.

---

## Layout

The page uses a three-panel layout at viewport widths >= 1024 px.

### Left Sidebar — Filters

Width: 260 px, fixed. Contains all filter controls. Filters apply immediately on change (no submit button). Active filter count shown as a badge on the sidebar header.

### Main Panel — Issue List

Fills remaining width minus the detail panel. Shows a paginated, sortable table of issues. Default sort: severity descending, then created_at ascending (oldest BLOCKING issues first).

### Right Detail Panel

Width: 400 px, slides in when an issue row is selected. Overlays on viewports 1024–1280 px; is a fixed split at >= 1280 px. Closes with the Escape key or by clicking outside the panel.

---

## Filter Options

All filters are applied server-side via `review_queue.list_issues`. Multiple values within the same filter dimension are OR-combined. Different dimensions are AND-combined.

| Filter | Type | Options / Notes |
|---|---|---|
| Severity | Multi-select checkbox | INFO, WARNING, BLOCKING |
| Issue Group | Multi-select checkbox | Missing Documents, Needs Confirmation, Possible Wrong Match, Possible Tax-VAT Issue, Unusual Transaction (values from `issue_group_enum`) |
| Run ID | Searchable select | Lists all run IDs for the business, labelled with period and run status |
| Date Range | Date picker — from/to | Filters on `created_at`. Presets: Today, Last 7 days, This month, Last month, Custom |
| Assignee | Multi-select | Lists all workspace members. Includes an "Unassigned" option |
| Status | Multi-select checkbox | OPEN, SNOOZED, IN_PROGRESS, ESCALATED |

A "Clear all filters" link appears above the filter panel when any filter is active.

---

## Issue List Columns

| Column | Source field | Notes |
|---|---|---|
| Issue ID | `id` (truncated UUID v7) | Monospace, first 8 chars, full ID in tooltip |
| Run ID | `run_id` | Truncated, links to run detail page |
| Created | `created_at` | Relative time (e.g. "3 hours ago") with absolute date in tooltip |
| Severity | `severity` | Badge using severity color tokens: BLOCKING = red, WARNING = amber, INFO = grey |
| Issue Group | `issue_group` | Text label from `issue_group_enum` |
| Description | `description` | Max 80 characters, truncated with ellipsis; full text in detail panel |
| Assignee | `assigned_to` | Avatar + name; "—" if unassigned |
| Status | `status` | Pill: OPEN (blue), IN_PROGRESS (purple), SNOOZED (grey), ESCALATED (orange) |
| Snooze Expiry | `snooze_until` | Only shown when status = SNOOZED; displays countdown ("Wakes in 2 days") |

Row click opens the right detail panel. Row hover shows a quick-action toolbar (Resolve, Snooze, Escalate icons).

---

## Issue Detail Panel

### Header

- Issue ID (full UUID v7)
- Severity badge
- Status pill
- Issue group label
- Created timestamp (absolute)

### Body

- Full `description` text, untruncated
- Affected entity: entity_type label + link to entity detail page (e.g. "Transaction -> TXN-2024-001")
- Run context: run ID link, run period, run status badge
- Assignee picker: dropdown of workspace members; updates via `review_queue.update_issue`
- Snooze expiry (if snoozed): countdown and exact datetime

### Resolution Options

Three action buttons, displayed as a button group:

**Resolve**

Opens an inline form: Resolution Note (textarea, required, min 10 characters). Confirm button calls `review_queue.resolve_issue`. On success: issue status updates to RESOLVED, row is removed from the list (or greyed out if the "Show resolved" toggle is active). Audit event: REVIEW_ISSUE_RESOLVED (LOW).

**Snooze**

Opens a snooze duration picker (see Snooze Duration Picker section). Calls `review_queue.snooze_issue` with `snooze_until` timestamp. Audit event: REVIEW_ISSUE_SNOOZED (LOW).

**Escalate**

Opens an inline form: escalation reason (textarea, required) + assignee selector. Calls `review_queue.escalate_issue`. Status transitions to ESCALATED. Audit event: REVIEW_ISSUE_ESCALATED (MEDIUM).

### Activity Log

Below the resolution options: a chronological list of status transitions and comments for this issue. Each entry shows: timestamp, actor, action taken, and any notes. Sourced from `review_issue_history` joined on `issue_id`. Displayed in descending order (newest first). Maximum 50 entries shown; "Load older" pagination link at bottom.

---

## Bulk Actions

Bulk actions are triggered from the table header toolbar that appears when one or more rows are checked.

| Action | Behaviour |
|---|---|
| Resolve all INFO | Resolves all currently visible (filtered) issues with severity = INFO. Requires confirmation modal: "You are about to resolve N INFO issues. This cannot be undone. Confirm?" Calls `review_queue.bulk_resolve` with `severity_filter: INFO`. |
| Snooze selected | Opens the snooze duration picker for the selected issue IDs. Calls `review_queue.bulk_snooze`. |
| Assign selected | Opens assignee picker. Bulk-updates `assigned_to` on selected issues. |

Maximum bulk selection: 200 issues. If the filtered list exceeds 200 items, the "Select all" checkbox selects the page only (25 items default page size) and shows a notice.

---

## Snooze Duration Picker

A dropdown with exactly four options. No custom duration input is exposed in the UI.

| Label | Value |
|---|---|
| Snooze for 1 day | NOW() + INTERVAL '1 day' |
| Snooze for 3 days | NOW() + INTERVAL '3 days' |
| Snooze for 7 days | NOW() + INTERVAL '7 days' |
| Snooze for 30 days | NOW() + INTERVAL '30 days' |

On selection, `snooze_until` is computed server-side at the time the `review_queue.snooze_issue` call is processed. The client sends the duration label as `snooze_days: 1 | 3 | 7 | 30`; the server converts to timestamp. This prevents clock-skew issues.

---

## Empty State

When no issues match the current filters:

- Illustration: simple checkmark icon (SVG, no animation)
- Heading: "No issues found"
- Body: "All issues matching your current filters have been resolved or do not exist yet."
- If filters are active: "Try clearing some filters to see more results." with a "Clear filters" link.

---

## Loading Skeleton

On initial load and on filter change, the issue list renders skeleton rows:

- 8 skeleton rows, each matching the column layout of a real row
- Shimmer animation at 1.4 s cycle
- The sidebar filters remain interactive during load (debounced 300 ms)
- The detail panel shows a spinner if an issue was selected and its data is reloading

---

## Keyboard Shortcuts

These shortcuts are active when the main issue list has focus. They are listed in a keyboard shortcut legend accessible from the `?` button in the page header.

| Key | Action |
|---|---|
| J | Navigate to the next issue in the list |
| K | Navigate to the previous issue in the list |
| R | Open the Resolve form for the focused issue |
| S | Open the Snooze picker for the focused issue |
| E | Open the Escalate form for the focused issue |
| Escape | Close the detail panel / dismiss any open inline form |
| / | Focus the search input in the filter sidebar |

Shortcuts are disabled when focus is inside a form element (textarea, input, select) to prevent conflicts with typing.

---

## API Calls

| Action | Tool | Notes |
|---|---|---|
| Load issue list | `review_queue.list_issues` | Params: filters, page, page_size, sort_field, sort_direction |
| Resolve issue | `review_queue.resolve_issue` | Params: issue_id, resolution_note |
| Snooze issue | `review_queue.snooze_issue` | Params: issue_id, snooze_days |
| Escalate issue | `review_queue.escalate_issue` | Params: issue_id, reason, assigned_to |
| Bulk resolve INFO | `review_queue.bulk_resolve` | Params: run_id (optional), severity_filter |
| Bulk snooze | `review_queue.bulk_snooze` | Params: issue_ids[], snooze_days |
| Update assignee | `review_queue.update_issue` | Params: issue_id, assigned_to |
| Load activity log | `review_queue.list_issue_history` | Params: issue_id, page |

All write calls require the actor to have `REVIEW_QUEUE_WRITE` permission (see `permission_matrix.md`).

---

## Mobile

The Review Queue mobile view is **read-only**. Any write operation (resolve, snooze, escalate, bulk actions, assignee update) initiated from a mobile device is rejected with HTTP 403 and error code `REVIEW_QUEUE_MOBILE_WRITE_REJECTED`.

Mobile layout:

- Single-column list, no sidebar. Filters exposed via a "Filter" button that opens a bottom sheet.
- Issue list cards show: severity badge, issue group, truncated description, status pill, created date.
- Tapping a card opens a full-screen detail view with all read-only fields and the activity log.
- The Resolve, Snooze, and Escalate buttons are rendered but disabled. A banner reads: "Write actions are not available on mobile. Use the desktop app to resolve issues."
- Keyboard shortcuts are not available on mobile.

This aligns with the `mobile_write_rejection_endpoints.md` policy for all tools with `WRITES_RUN_STATE` or `WRITES_AUDIT` side effects.

---

## Related Documents

- `reference/issue_group_enum.md` — issue_group_enum values
- `reference/issue_status_enum.md` — issue_status_enum values
- `reference/severity_enum.md` — severity levels
- `reference/permission_matrix.md` — permission requirements
- `reference/mobile_write_rejection_endpoints.md` — mobile rejection policy
- `schemas/review_queue_schema.md` — underlying data model
- `ui/review_queue_card_layout_ui_spec.md` — card component details
- `ui/review_queue_mobile_ui_spec.md` — extended mobile spec
- `tools/tool_review_queue_create_issue.md` — issue creation tool
