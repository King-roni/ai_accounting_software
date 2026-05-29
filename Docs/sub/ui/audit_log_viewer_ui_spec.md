# Audit Log Viewer UI Spec

**Category:** UI · **Owning block:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

UI specification for the audit log viewer screen. This screen is a read-only forensic surface
for inspecting audit events emitted by all workflow blocks. It is not a live feed. Access is
restricted to ADMIN and OWNER roles.

---

## Access control

| Role | Access |
| --- | --- |
| OWNER | Full access — all events visible per audit_log_policies Section 2 |
| ADMIN | Full access except KEY_ROTATED, KEY_ROTATION_REQUESTED, BACKUP_KEY_ROTATED rows |
| ACCOUNTANT | No access — the audit log viewer is not available to ACCOUNTANT role |
| BOOKKEEPER | No access via this screen (direct table reads apply different RLS) |
| REVIEWER | No access via this screen |
| READ_ONLY | No access via this screen |

ACCOUNTANT attempting to navigate to `/audit-log` receives a 403 page with the message:
"You do not have permission to view the audit log."

---

## Layout

The viewer is a full-width desktop page under Settings > Security > Audit Log. It consists of:

1. Page header — title "Audit Log", "Refresh" button (top-right), "Export CSV" button (top-right,
   ADMIN only).
2. Filter bar — horizontal row of filter controls below the page header.
3. Paginated table — main content area.
4. Payload drawer — right-side overlay, opened on row click.

---

## Table columns

| Column | Content | Width | Notes |
| --- | --- | --- | --- |
| Timestamp | event_time converted to user's local timezone | 180px | ISO 8601 display, tabular-nums |
| Event | event_type string | 260px | Monospace font (--font-mono) |
| Severity | Severity badge | 100px | See badge spec below |
| User | actor display name + email tooltip | 200px | Truncate with ellipsis |
| Business | business display name | 160px | Truncate with ellipsis |
| Run ID | run_id UUID (clickable) | 140px | Deep link to workflow run detail view; null → em-dash |

Columns use `font-variant-numeric: tabular-nums` for Timestamp and Run ID columns per
design_system_tokens.md tabular figures convention.

Column headers are plain text, `--text-xs`, `--color-text-muted`. No bold headers.

---

## Severity badge colours

Badges are small pill-shaped labels (`--radius-sm`, `--text-xs`). Each severity level maps to a
fixed background colour. Hue is always paired with a text label for colour-blind safety per
design_system_tokens.md foundation principle 3.

| Severity | Background hex | Text colour | Label |
| --- | --- | --- | --- |
| LOW | `--color-neutral-200` (grey) | `--color-neutral-700` | LOW |
| MEDIUM | #F59E0B (amber) | white | MEDIUM |
| HIGH | #F97316 (orange) | white | HIGH |
| BLOCKING | #EF4444 (red) | white | BLOCKING |

Severity values are LOW, MEDIUM, HIGH, BLOCKING. The string CRITICAL does not appear in this UI.
Token references for MEDIUM, HIGH, BLOCKING map to `--color-severity-*` ramps defined in
severity_color_tokens.md.

---

## Filter bar

Filters are applied client-side on the current loaded page and server-side on the query. All
filters are additive (AND logic).

| Filter | Control type | Notes |
| --- | --- | --- |
| Event name | Free-text input | Matches event_type with ILIKE |
| Severity | Multi-select chip group | Options: LOW, MEDIUM, HIGH, BLOCKING |
| Date range | Two date pickers (from / to) | Maximum range: 30 days (enforced); see audit_log_policies Section 3 |
| User | Dropdown populated from members | Filters by actor_user_id |
| Run ID | UUID text input | Validates UUID format before sending; invalid UUID shows inline error |

Filters render in a single horizontal row on desktop. Filter state is preserved in URL query
parameters so the view is bookmarkable and shareable.

"Clear filters" link appears when any filter is active. Clicking it resets all filters and
reloads the table.

---

## Pagination

- 50 rows per page.
- Pagination controls: previous / next buttons, current page indicator, total count label.
- Total count format: "Showing 1–50 of 1,243 events".
- Total count uses the query's `count` estimate; exact count is used for ranges up to 10,000 rows.
- Page navigation triggers a new server query; rows are not cached across pages.

---

## Payload drawer

Clicking any table row opens a right-side drawer without navigating away.

Drawer width: 480px on screens >= `--bp-xl`; full-width overlay on narrower screens.
Animation: slides in from the right using `--motion-medium` / `--easing-standard`.

Drawer contents:

1. Event header — event_type in monospace, severity badge, timestamp in local TZ.
2. Full event payload — formatted JSON block using `--font-mono`, `--text-sm`.
   JSON is syntax-highlighted (keys in `--color-brand-600`, string values in `--color-success-700`,
   numbers in `--color-neutral-700`).
3. Run ID field — if run_id is present, rendered as a clickable link labelled "View run detail".
   Navigating to the run detail page closes the drawer first.
4. Actor section — actor_user_id, actor role, IP address (masked to first two octets: 192.168.x.x).
5. Business / chain metadata — business_id, chain_id, sequence_number, chain_hash (truncated to
   first 16 chars with a "Copy" icon button for the full value).

Drawer is closed by clicking the X button, pressing Escape, or clicking the backdrop overlay.

---

## Export

ADMIN and OWNER may export the currently filtered result set as CSV.

- Button label: "Export CSV".
- Export calls `report.generate_audit_csv` with the active filter parameters.
- Maximum export row count: 10,000 rows. If the filtered set exceeds 10,000, a warning is shown:
  "The filtered set contains more than 10,000 events. Only the first 10,000 will be exported.
  Narrow the date range to export a specific window."
- Export is asynchronous for large sets; a progress indicator replaces the button while the job
  runs. On completion, the browser downloads the CSV file.
- Mobile clients cannot trigger export (see Mobile section below).

CSV columns match the table columns: Timestamp (UTC ISO 8601), Event, Severity, User Email,
Business Name, Run ID.

---

## Real-time behaviour

The audit log viewer is not real-time. The table loads on page open using the active filter state.

A "Refresh" button is shown top-right. Clicking it re-executes the current query and replaces the
table content. No automatic polling or WebSocket subscription.

The page does not display a "last refreshed at" timestamp in the MVP.

---

## Empty state

When the query returns zero rows, the table body is replaced with a centred empty state block:

  "No events match the current filters."

If no filters are active and there are genuinely no events for the business, the message is:
  "No audit events have been recorded for this business yet."

---

## Mobile

The audit log viewer is desktop-only. Mobile clients (viewport < `--bp-md`, or
`client_form_factor = MOBILE`) see a full-page message in place of the viewer:

  "This screen is not available on mobile."

with a link "Open on desktop" that is a mailto-style deep link to the audit log URL.

No table, no filters, and no export are rendered on mobile.

---

## Error states

| Error condition | User-facing message |
| --- | --- |
| Query timeout (> 5s per audit_log_policies Section 3) | "The query took too long. Narrow the date range and try again." |
| Date range > 30 days | Inline validation: "Date range cannot exceed 30 days." |
| Run ID not found in run detail | Toast: "Run not found or you do not have access." |
| Export job failure | Toast: "Export failed. Try again or contact support." |

---

## Cross-references

- audit_event_taxonomy.md — canonical event names and severities
- audit_log_policies.md — RLS rules, query patterns, latency budgets
- severity_color_tokens.md — severity badge colour tokens
- dashboard_card_definitions_ui_spec.md — page layout conventions
- design_system_tokens.md — typography, spacing, motion tokens
- mobile_write_rejection_endpoints.md — mobile form factor enforcement
