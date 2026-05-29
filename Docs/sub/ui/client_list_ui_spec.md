# Client List UI Spec

**Block:** out_workflow
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

The Clients list page is the primary entry point for managing the business entity's
client records. It provides search, filtering, tabular display of key account metrics,
and navigation to the client detail page. It is accessible from the main navigation
sidebar under "Clients".

This page is read-heavy. The most common workflow is: search by name or VAT number →
click row → view client detail. Create and import actions are secondary.

---

## Page Header

```
[Clients]  [23]                                      [Import Clients]  [+ New Client]
```

- **Title**: "Clients" — H1, 24px, font-weight 600.
- **Count badge**: integer count of active clients for the current business entity.
  Updates reactively when filters change. Shows total matching count, not page count.
  Badge style: neutral chip, 14px, background `--color-surface-2`.
- **Import Clients button**: secondary button, left of New Client. Opens CSV import
  modal. See Import Clients section below.
- **New Client button**: primary button. Navigates to `/clients/new` (inline form or
  dedicated page — TBD in interaction spec).

---

## Search Bar

Displayed full-width below the page header, above filter chips.

- **Placeholder text**: "Search by name, email, or VAT number"
- **Behavior**: debounced (300ms) client-side-then-server-side search.
  - Matches against: `clients.name`, `clients.legal_name`, `clients.email`,
    `clients.vat_number`.
  - Case-insensitive. Partial match supported (ILIKE `%query%`).
- **Clear button**: appears inside field when query is non-empty. Clears search and
  resets results to full list.
- **Empty query**: shows full client list (subject to active filters).
- **No results**: shows empty state (see Empty State section).

---

## Filter Panel

Displayed as a horizontal row of filter chips below the search bar.

### Filter: Client Type

Multi-select chip group. Options:

| Value          | Display Label     |
|----------------|-------------------|
| INDIVIDUAL     | Individual        |
| COMPANY        | Company           |
| EU_COMPANY     | EU Company        |
| NON_EU_COMPANY | Non-EU Company    |

Selecting multiple values applies OR logic (show any of the selected types).
Default: all types shown (no filter chip active).

### Filter: Country

Single-select dropdown chip. Shows ISO 3166-1 alpha-2 codes with country names.
Default: "All countries". Selecting a country filters to clients where
`clients.country_code = <selected>`.

### Filter: Status

Toggle chip: "Active only" (default) / "All" / "Inactive only".
- Active only: `clients.is_active = true`
- Inactive only: `clients.is_active = false`
- All: no filter on `is_active`

### Filter State Persistence

Active filters persist in URL query parameters so the user can share or bookmark a
filtered view. Example: `/clients?type=INDIVIDUAL,COMPANY&country=CY&status=active`.

### Clear All Filters

"Clear filters" text link appears to the right of filter chips when any filter is
active. Resets all filters to defaults and removes query params.

---

## Client List Table

Displayed below the filter panel. Columns:

| Column              | Source Field                          | Notes                                        |
|---------------------|---------------------------------------|----------------------------------------------|
| Name                | `clients.name`                        | Primary display name. Bold.                  |
| Legal Name          | `clients.legal_name`                  | Shown only if different from name. Italics, muted. |
| Country             | `clients.country_code`                | Country flag emoji + ISO code. E.g., 🇨🇾 CY  |
| VAT Number          | `clients.vat_number`                  | With VIES validation badge (see below).      |
| Outstanding Balance | Computed: sum of SENT + OVERDUE invoices | Formatted with currency symbol. Red if > 0. |
| Invoiced YTD        | Sum of all invoices in current calendar year | Currency formatted.                    |
| Status              | `clients.is_active`                   | "Active" (green badge) / "Inactive" (grey).  |
| Actions             | —                                     | View · Edit · Deactivate                     |

### VIES Validation Badge

Shown inline next to the VAT number:

| State        | Badge Label    | Color   | Tooltip                                           |
|--------------|----------------|---------|---------------------------------------------------|
| VALID        | Valid          | Green   | "VIES verified — [last_checked_at]"               |
| INVALID      | Invalid        | Red     | "VAT number not found in VIES — [last_checked_at]"|
| UNVALIDATED  | Not checked    | Grey    | "VAT number has not been validated against VIES"  |

Clicking the badge triggers an inline VIES re-check for that client (calls
`ledger.validate_vies`) and updates the badge state without leaving the list.

### Actions Column

Three text links separated by `·`:

- **View**: navigates to `/clients/<id>`.
- **Edit**: navigates to `/clients/<id>/edit` or opens inline edit mode.
- **Deactivate** (if `is_active = true`): opens confirmation dialog. On confirm, sets
  `clients.is_active = false`. Shows "Activate" link instead if client is already
  inactive.

### Row Click

Clicking anywhere on a row (outside the actions column) navigates to the client detail
page at `/clients/<id>`.

### Hover State

Row background: `--color-surface-hover` on hover. Cursor: pointer.

---

## Sorting

Sortable columns: Name, Outstanding Balance, Invoiced YTD.

- Default sort: Name ascending (A → Z).
- Click column header to sort ascending; click again to sort descending.
- Sort indicator: small caret icon (▲ / ▼) in column header.
- Sort state persists in URL query parameter: `?sort=outstanding_balance&dir=desc`.

---

## Pagination

- 50 records per page (fixed, no per-page selector in v1).
- Pagination controls displayed below table: Previous · [1] [2] [3] · Next.
- Current page shown with filled background.
- Total record count displayed: "Showing 1–50 of 127 clients."
- Page state persists in URL: `?page=2`.

---

## Empty State

Displayed when the table has no results to show.

### No Clients Created Yet

```
[Icon: person with plus]
No clients yet
Add your first client to start creating invoices.
[+ New Client]  [Import Clients]
```

### No Results for Search/Filter

```
[Icon: magnifying glass]
No clients match your search
Try a different name, email, or VAT number, or clear your filters.
[Clear filters]
```

---

## Import Clients

Triggered by the "Import Clients" button. Opens a modal with:

1. **Download Template** link — CSV template with headers:
   `name, legal_name, email, vat_number, country_code, client_type, payment_terms_days`
2. **File upload area** — drag-and-drop or click to upload. Accepts `.csv` only.
3. **Preview table** — shows first 5 rows parsed from the uploaded CSV with validation
   feedback (invalid VAT format, missing required fields highlighted in red).
4. **Import button** — disabled until CSV passes validation. On click, submits import
   job and shows progress.
5. **Result summary** — "47 clients imported. 3 skipped (see errors)."

Duplicate detection: if a client with the same `vat_number` or `email` already exists,
the row is flagged as a duplicate and skipped by default (user can override).

---

## Mobile

The client list on mobile is read-only. Creating and editing clients requires desktop.

- Table is replaced by a single-column card list.
- Each card shows: name, country code, VAT number (truncated), outstanding balance,
  active/inactive badge.
- Tap card to navigate to client detail (also read-only on mobile).
- Search bar is present and functional on mobile.
- Filters are accessible via a "Filter" button that opens a bottom sheet.
- New Client and Import buttons are hidden on mobile.
- Cards are paginated (50 per page, same as desktop).

---

## Related Documents

- `/Docs/sub/ui/client_detail_ui_spec.md`
- `/Docs/sub/ui/invoice_list_ui_spec.md`
- `/Docs/sub/reference/vat_rate_table_reference.md`
- `/Docs/sub/reference/cyprus_vat_rule_catalog.md`
