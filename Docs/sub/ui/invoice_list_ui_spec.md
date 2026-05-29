# Invoice List UI Spec

**Category:** UI · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

UI specification for the invoice management list view. This screen is the primary entry point for
viewing, creating, and managing invoices across all series (standard invoices, pro-forma invoices,
and credit notes).

---

## Access control

| Role | View | Create / Edit | Void | Download PDF |
| --- | --- | --- | --- | --- |
| OWNER | Yes | Yes | Yes | Yes |
| ADMIN | Yes | Yes | Yes | Yes |
| ACCOUNTANT | Yes | Yes | No | Yes |
| BOOKKEEPER | Yes | No | No | Yes |
| READ_ONLY | Yes | No | No | Yes |

"Void" is an irreversible transition and is restricted to OWNER and ADMIN. ACCOUNTANT attempting
to void an invoice receives: "You do not have permission to void invoices."

---

## Page structure

The invoice list page is accessible at `/invoices`. It consists of:

1. Page header — title "Invoices", "New Invoice" button (top-right, shown for roles with create
   permission).
2. Tab bar — three tabs: Invoices (INV series), Pro-Forma (PRO series), Credit Notes (CN series).
3. Filter bar — below the tab bar.
4. Bulk action bar — appears when one or more rows are selected.
5. Paginated table.

The active tab determines the invoice series shown. Each tab maintains its own independent filter
state and pagination position.

---

## Table columns

| Column | Content | Width | Notes |
| --- | --- | --- | --- |
| Invoice Number | invoice_number string | 140px | Monospace, tabular-nums |
| Client | client display name | 200px | Truncated with ellipsis; tooltip on hover |
| Issue Date | issue_date | 120px | Local date format, tabular-nums |
| Due Date | due_date | 120px | Local date format; overdue rows highlight due date in `--color-danger-600` |
| Amount | total_amount with currency symbol | 120px | Right-aligned, tabular-nums |
| Status | Status badge | 100px | See badge spec below |
| Actions | Icon buttons | 120px | View, Edit, Send, Void, Download PDF |

Columns are sortable. Clicking a column header toggles ascending / descending. Active sort is
indicated by an arrow icon next to the column header label.

Default sort: issue_date DESC.

---

## Status badge colours

Badges use pill shape (`--radius-sm`, `--text-xs`). Label text is always present for accessibility.

| Status | Background | Text | Notes |
| --- | --- | --- | --- |
| DRAFT | `--color-neutral-200` (grey) | `--color-neutral-700` | Editable |
| SENT | `--color-info-200` (blue) | `--color-info-800` | Awaiting payment |
| PAID | `--color-success-200` (green) | `--color-success-800` | Fully matched |
| OVERDUE | `--color-warning-200` (orange) | `--color-warning-800` | Past due_date, unpaid |
| VOID | `--color-danger-200` (red) | `--color-danger-800` | Voided — no further action |
| PARTIALLY_PAID | `--color-warning-100` (yellow) | `--color-warning-800` | Partial match exists |

---

## Filter bar

| Filter | Control | Notes |
| --- | --- | --- |
| Status | Multi-select chip group | Options match the status set for the active tab |
| Client | Searchable dropdown | Populated from the clients registry |
| Date range | Two date pickers (from / to) | Filters on issue_date |
| Invoice series | Single-select | Locks to the active tab's series; not editable here |
| Search | Free-text input | Matches invoice_number or client name with ILIKE |

All filters are additive (AND logic). Filter state persists in URL query parameters.

"Clear filters" link appears when any filter is active.

---

## Row actions

Each row shows icon buttons in the Actions column. Visible actions depend on the row's status and
the user's role.

| Action | Status precondition | Role restriction | Behaviour |
| --- | --- | --- | --- |
| View | Any | All roles | Opens invoice detail view |
| Edit | DRAFT only | ACCOUNTANT / OWNER / ADMIN | Opens invoice editor |
| Send | DRAFT only | ACCOUNTANT / OWNER / ADMIN | Transitions DRAFT → SENT; triggers send email flow |
| Void | SENT, PAID, PARTIALLY_PAID | OWNER / ADMIN only | Requires confirm dialog; transitions to VOID |
| Download PDF | Any | All roles | Downloads the invoice PDF |

Actions not available for the row's current status or the user's role are hidden, not disabled.

The "Send" action opens a confirmation modal showing the recipient email and invoice summary before
dispatching. On confirm, calls the invoice send tool.

The "Void" action opens a confirmation dialog: "Voiding an invoice cannot be undone. Continue?"
Confirming calls the invoice void tool.

---

## Create flow

The "New Invoice" button is shown top-right for ACCOUNTANT, OWNER, and ADMIN roles.

Clicking opens the invoice creation flow. The creation flow is specified in
invoice_lifecycle_ui_spec.md. The list view navigates to the creation form; it does not open a
modal.

---

## Bulk actions

Selecting rows (via checkboxes in the leftmost column) shows the bulk action bar above the table.

Available bulk action: "Download PDFs" — downloads PDFs for all selected rows as a zip archive.
Maximum 50 invoices per bulk download. If the selection exceeds 50, the action button is disabled
with a tooltip: "Select 50 or fewer invoices to bulk download."

No bulk void or bulk send in the MVP.

The bulk action bar also shows: "X invoices selected" and a "Clear selection" link.

---

## Pro-forma tab

The Pro-Forma tab shows invoices in the PRO series. Layout is identical to the main Invoices tab.

Status set for pro-forma: DRAFT, SENT, ACCEPTED, EXPIRED, VOID.
Status badge colours: ACCEPTED = green, EXPIRED = `--color-neutral-400` (grey).

Pro-forma invoices do not appear in the main Invoices tab.

---

## Credit note tab

The Credit Notes tab shows invoices in the CN series. Layout is identical to the main Invoices tab.

Status set for credit notes: DRAFT, ISSUED, APPLIED, VOID.
Status badge colours: ISSUED = blue, APPLIED = green.

Credit notes do not appear in the main Invoices tab.

---

## Pagination

25 rows per page. Pagination controls: previous / next buttons, current page indicator, total
count label.

Total count format: "Showing 1–25 of 318 invoices."

Page navigation triggers a new server query.

---

## Mobile

On mobile viewports (< `--bp-md`) and for `client_form_factor = MOBILE`, the table is replaced
with a condensed card list. Each card shows: Invoice Number, Client, Amount, Status badge, Due
Date.

Sort control is available via a "Sort" button that opens a bottom sheet with sort options.
Filter control is available via a "Filter" button that opens a bottom sheet.

WRITE operations (create, edit, send, void) are blocked on mobile clients per
mobile_write_rejection_endpoints.md. The "New Invoice" button is hidden on mobile. Attempting
any write action on mobile returns: "This action is not available on mobile."

Download PDF is available on mobile.

---

## Empty state

No invoices and no active filters:
  "No invoices yet. Create your first invoice to get started."

No invoices match active filters:
  "No invoices match the current filters."

---

## Cross-references

- invoice_schema.md — invoice table structure, status enum, series enum
- invoice_lifecycle_ui_spec.md — creation and status transition flows
- invoice_lifecycle_policy.md — status transition rules
- invoice_numbering_sequence_policy.md — INV / PRO / CN sequence generation
- mobile_write_rejection_endpoints.md — mobile write rejection enforcement
- design_system_tokens.md — colour, spacing, typography tokens
