# Expense List UI Spec

**Category:** UI · **Owning block:** 12 — OUT Workflow · **Stage:** 4 sub-doc (Layer 2)

UI specification for the Expense list page. This is the primary entry point for viewing and
managing business expenditure (OUT workflow). It covers all expense records created via manual
entry or document intake.

---

## Access control

| Role | View | Create | Classify | Approve | Bulk Actions |
| --- | --- | --- | --- | --- | --- |
| OWNER | Yes | Yes | Yes | Yes | Yes |
| ADMIN | Yes | Yes | Yes | Yes | Yes |
| ACCOUNTANT | Yes | Yes | Yes | No | Classify only |
| BOOKKEEPER | Yes | Yes | No | No | No |
| READ_ONLY | Yes | No | No | No | No |

ACCOUNTANT may not approve expenses. Attempting to approve renders:
"You do not have permission to approve expenses."

---

## Page structure

The Expense list page is accessible at `/expenses`. It consists of:

1. Page header — title "Expenses", "Add Expense" button (top-right, shown for roles with
   create permission).
2. Filter bar — below the header.
3. Bulk action bar — appears when one or more rows are selected.
4. Paginated table.

---

## Table columns

| Column | Content | Width | Notes |
| --- | --- | --- | --- |
| Date | `expense_date` | 110px | Local date format, tabular-nums |
| Supplier | `supplier_name` | 200px | Truncated with ellipsis; tooltip on hover |
| Description | `description` | 240px | Truncated at 60 chars; tooltip on hover |
| Amount | `total_amount` with currency | 120px | Right-aligned, tabular-nums |
| VAT Category | `vat_category` badge | 130px | See badge spec below |
| Status | `expense_status` badge | 120px | See badge spec below |
| File | Intake file preview icon | 48px | Paperclip icon; clicking opens inline document preview |
| Actions | Icon buttons | 100px | View, Edit, Delete (role-gated) |

Default sort: `expense_date` DESC. All columns are sortable except File and Actions.

The File column shows a filled paperclip icon when a source document is attached. An empty
paperclip (unfilled) indicates a manually entered expense with no uploaded document. Hovering
the filled icon shows a tooltip with the original filename.

---

## Status badges (expense_status_enum)

Badges use pill shape (`--radius-sm`, `--text-xs`). Label text is always present.

| Status | Background | Text | Notes |
| --- | --- | --- | --- |
| DRAFT | `--color-neutral-200` | `--color-neutral-700` | Awaiting classification |
| PENDING_REVIEW | `--color-warning-100` | `--color-warning-800` | In the review queue |
| CLASSIFIED | `--color-info-200` | `--color-info-800` | Classification applied, awaiting approval |
| APPROVED | `--color-success-200` | `--color-success-800` | Approved for posting |
| REJECTED | `--color-danger-200` | `--color-danger-800` | Rejected — requires correction |
| POSTED | `--color-neutral-800` | `--color-neutral-50` | Posted to ledger — read-only |
| VOID | `--color-neutral-200` | `--color-neutral-500` | Voided; excluded from reports |

---

## VAT category badges

| vat_category | Label | Badge colour |
| --- | --- | --- |
| STANDARD_RATE | 19% Standard | `--color-info-200` / `--color-info-800` |
| REDUCED_RATE | 9% Reduced | `--color-warning-100` / `--color-warning-800` |
| ZERO_RATE | 0% Zero | `--color-neutral-200` / `--color-neutral-700` |
| EXEMPT | Exempt | `--color-neutral-100` / `--color-neutral-600` |
| REVERSE_CHARGE | Reverse Charge | `--color-purple-100` / `--color-purple-800` |
| UNCLASSIFIED | Unclassified | `--color-danger-100` / `--color-danger-700` |

---

## Filter bar

| Filter | Control | Field |
| --- | --- | --- |
| Status | Multi-select chip group | `expense_status` |
| VAT Category | Multi-select chip group | `vat_category` |
| Date Range | Date range picker (start / end) | `expense_date` |
| Amount Range | Two numeric inputs (min / max) | `total_amount` |
| Supplier | Text search input | `supplier_name` (ILIKE) |

Active filters render as dismissible chips below the filter bar. "Clear all filters" link
appears when any filter is active. Filter state persists in the URL query string.

---

## Bulk actions

The bulk action bar appears when at least one row checkbox is selected. A "Select all on
page" checkbox is available in the table header.

| Action | Minimum selection | Availability | Notes |
| --- | --- | --- | --- |
| Bulk Classify | ≥1 row with status DRAFT or UNCLASSIFIED vat_category | OWNER, ADMIN, ACCOUNTANT | Opens classification modal |
| Bulk Approve | ≥1 row with status CLASSIFIED | OWNER, ADMIN only | Requires confirmation dialog |
| Bulk Delete | ≥1 row with status DRAFT | OWNER, ADMIN only | Soft-delete; confirmation required |

Bulk classify opens a modal with a VAT category selector and a recovery percentage input. The
same values are applied to all selected expenses. Partially-matching selections show a warning:
"X of the selected expenses already have a classification. This action will overwrite them."

Bulk approve shows: "Approve N expense(s) totalling EUR {sum}? This will post them to the
ledger." Confirming calls `expenses.bulk_approve` with `expense_ids[]`.

---

## Row click — expense detail drawer

Clicking a table row (outside the checkbox and action icons) opens the Expense detail drawer
from the right side at 480px width. The drawer overlays the list; the list remains scrollable.

The drawer contains:
- Expense header: supplier name, total amount, expense date.
- Status badge and last-modified timestamp.
- Classification section: vat_category, vat_amount, recoverable_amount, recovery_percentage.
- Document preview (if file attached): inline PDF viewer at reduced height (320px). Full-screen
  toggle available.
- Audit trail: last 5 events for this expense record, with timestamp and actor.
- Action buttons: Edit, Approve, Reject, Void — all role-gated.

Pressing Escape or clicking outside the drawer closes it. The URL updates to
`/expenses?detail={expense_id}` when the drawer is open; this URL is shareable.

---

## Add Expense CTA

The "Add Expense" button (top-right) opens a split modal with two tabs:

### Tab 1 — Manual Entry

Form fields:
- Supplier name (text, required)
- Description (text, optional)
- Expense date (date picker, required, defaults to today)
- Total amount (numeric, required, EUR)
- VAT category (dropdown, required)
- Recovery percentage (numeric, defaults from VAT category)
- Notes (textarea, optional)

On submit: creates an `expenses` row with `status = DRAFT`. Emits
`EXPENSE_CREATED` audit event (LOW).

### Tab 2 — File Upload

Drag-and-drop zone accepting PDF, JPG, PNG (max 10 MB). Multiple files may be dropped; each
creates a separate expense record. After upload, OCR runs asynchronously. The list refreshes
when OCR completes and the record transitions from DRAFT with extracted fields pre-populated.

File upload errors (unsupported format, size exceeded) surface as inline error messages within
the upload zone. The record is not created for rejected files.

---

## Pagination

Page size: 25 rows. Pagination controls: previous / next buttons, current page indicator, total
count. Keyboard navigation: Left/Right arrow keys when focus is on pagination controls.

---

## Mobile layout

On viewports below 768px:
- Table collapses to a card list. Each card shows: supplier, amount, expense date, status badge.
- VAT category and file icon move to the card detail row (smaller text).
- Row tap opens the full-screen expense detail view (not a drawer).
- Filter and sort controls collapse behind a "Filter" button (bottom sheet).
- Bulk actions are not available on mobile. Attempting bulk operations returns:
  "Bulk actions are not available on mobile."
- The Add Expense button remains visible. File upload is supported from the device camera or
  file system.

---

## Empty states

No expenses and no active filters:
  "No expenses yet. Add your first expense or upload a receipt to get started."

No expenses match active filters:
  "No expenses match the current filters. Try adjusting your filter criteria."

---

## Related Documents

- `out_workflow_per_fixture_content.md` — OUT workflow fixture shape and test data
- `expense_classification_fixture_content.md` — classification test scenarios
- `classification_review_ui_spec.md` — classification review panel
- `document_viewer_ui_spec.md` — in-app document preview
- `bulk_classification_runbook.md` — bulk classification operating procedures
- `audit_event_taxonomy.md` — `EXPENSE_CREATED`, `CLASSIFICATION_USER_CONFIRMED`,
  `CLASSIFICATION_USER_RECLASSIFIED`
- `design_system_tokens.md` — colour, spacing, typography tokens
- `mobile_write_rejection_endpoints.md` — mobile write restrictions
