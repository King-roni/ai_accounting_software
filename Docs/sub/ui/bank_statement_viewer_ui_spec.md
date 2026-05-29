# Bank Statement Viewer UI Spec

**Category:** UI · **Owning block:** 07 — Bank Statement Pipeline · **Stage:** 4 sub-doc (Layer 2)

UI specification for the bank statement row viewer. This screen is used to inspect parsed
statement rows during an IN workflow run, specifically during the IMPORT and CLASSIFY phases.
It is not a standalone page — it is accessible from the IN workflow run detail page.

---

## Access control

| Role | Access |
| --- | --- |
| OWNER | Full access — view, filter, export |
| ADMIN | Full access — view, filter, export |
| ACCOUNTANT | View and filter; no export |
| BOOKKEEPER | View and filter; no export |
| READ_ONLY | View only; no filter changes persisted; no export |

Export is restricted to ADMIN and OWNER.

---

## Entry point

The bank statement row viewer is accessible from:
- The IN workflow run detail page, during the IMPORT phase — "View Statement Rows" button.
- The IN workflow run detail page, during the CLASSIFY phase — "Review Classifications" button.

The viewer is not accessible from other contexts. Navigating to the viewer URL directly without a
valid run_id in scope redirects to the run detail page.

---

## Layout

The viewer is a full-width overlay or embedded panel within the run detail page. It consists of:

1. Section header — "Statement Rows", row count, phase indicator (IMPORT / CLASSIFY), export
   button (ADMIN / OWNER only).
2. Filter bar — horizontal row of filter controls.
3. Paginated table — main content area.
4. Row expansion panel — inline detail panel that appears below the selected row.

---

## Table columns

| Column | Content | Width | Notes |
| --- | --- | --- | --- |
| Date | transaction_date | 110px | Local date format, tabular-nums |
| Description | raw_description from bank | Auto | Truncated to 80 chars; full text in row expansion |
| Amount | amount numeric | 120px | Positive = credit (green text); negative = debit (red text); tabular-nums |
| Counterparty | resolved_counterparty_name or raw_counterparty | 180px | Truncated with tooltip |
| Dedup Status | Dedup status badge | 110px | See badge spec below |
| Match Status | Match status badge | 130px | See badge spec below |
| Classification | Classification badge | 140px | Shows winning tag or "Unclassified" |

Amount display: positive values shown in `--color-success-700`; negative values shown in
`--color-danger-700`. Currency symbol prepended. All amounts use `font-variant-numeric: tabular-nums`.

---

## Dedup status badges

Values from deduplication_fingerprint_schema.md dedup_status_enum.

| Status | Background | Text label |
| --- | --- | --- |
| NEW | `--color-success-200` (green) | NEW |
| DUPLICATE_EXACT | `--color-danger-200` (red) | DUPLICATE_EXACT |
| DUPLICATE_PROBABLE | `--color-warning-200` (yellow) | DUPLICATE_PROBABLE |

All badges use `--radius-sm`, `--text-xs`.

---

## Match status badges

Values correspond to match_level_enum values from match_level_enum.md.

| match_level_enum value | Background | Text label |
| --- | --- | --- |
| EXACT | `--color-success-200` (green) | EXACT |
| STRONG_PROBABLE | `--color-info-200` (blue) | STRONG_PROBABLE |
| WEAK_POSSIBLE | `--color-warning-200` (yellow) | WEAK_POSSIBLE |
| NO_MATCH | `--color-neutral-200` (grey) | NO_MATCH |

---

## Classification badge

The classification badge shows the winning classification tag string if one has been assigned. If
no classification has been determined, the badge shows "Unclassified" with `--color-neutral-200`
background and `--color-neutral-600` text.

Classified rows show the tag string (e.g. "OFFICE_SUPPLIES") in `--color-brand-100` background,
`--color-brand-800` text.

---

## Row expansion panel

Clicking a table row expands an inline detail panel below that row (accordion behaviour). Clicking
the same row again collapses it. Only one row is expanded at a time.

Panel contents:

1. Raw bank description — full untruncated raw_description string, monospace font.
2. Parsed counterparty — resolved counterparty name, IBAN if present, resolution source.
3. Match signals — a table of all applied match signals with columns: Signal Name, Score (0.00–1.00),
   Weight, Weighted Contribution. Scores use tabular-nums. Composite score shown as a total row.
4. Classification detail — classification source (RULE / AI / MANUAL), rule_id if applicable,
   confidence score (0.00–1.00), winning tag, runner-up tag if applicable.
5. Dedup fingerprint — fingerprint string shown in monospace, truncated to 32 chars with a "Copy"
   icon button.
6. Row metadata — bank_statement_row_id (UUID, copyable), statement upload file name, row index.

Panel background: `--color-bg-raised`. Padding: `--space-5`. Border-top: `--color-border-subtle`.

---

## Filter bar

| Filter | Control | Notes |
| --- | --- | --- |
| Dedup status | Multi-select chip group | NEW, DUPLICATE_EXACT, DUPLICATE_PROBABLE |
| Match status | Multi-select chip group | EXACT, STRONG_PROBABLE, WEAK_POSSIBLE, NO_MATCH |
| Classification status | Single-select | All / Classified / Unclassified |
| Date range | Two date pickers (from / to) | Filters on transaction_date |

All filters are additive (AND logic). "Clear filters" link appears when any filter is active.

---

## Pagination

50 rows per page. Pagination controls: previous / next, current page, total row count.

Total count format: "Showing 1–50 of 842 rows."

---

## Export

ADMIN and OWNER may export the currently visible (filtered) rows as CSV.

Export button label: "Export CSV". Clicking calls the export endpoint with the active filter
parameters and the current run_id.

CSV columns: Date, Description, Amount, Counterparty, Dedup Status, Match Status, Classification.

Mobile clients cannot trigger export (see Mobile section).

---

## Mobile

On mobile viewports (< `--bp-md`) and for `client_form_factor = MOBILE`, the table is replaced
with a condensed card view. Each card shows: Date, Description (truncated), Amount, Dedup Status
icon badge, Match Status icon badge, Classification label.

Icon badges on mobile use Lucide icons paired with colour per design_system_tokens.md foundation
principle 3 (hue never carries meaning alone).

Row expansion is available on mobile via a tap; the expansion panel renders as a full-width
section below the card.

Export is not available on mobile. The export button is hidden. Attempting export via direct API
call with `client_form_factor = MOBILE` is rejected per mobile_write_rejection_endpoints.md.

Filter and sort controls are available via a "Filter" button opening a bottom sheet.

---

## Empty state

No rows after filtering:
  "No statement rows match the current filters."

No rows in the statement at all (empty upload):
  "No rows were parsed from this statement file."

---

## Cross-references

- bank_statement_rows_schema.md — row table structure
- deduplication_fingerprint_schema.md — dedup_status_enum, fingerprint field
- match_record_schema.md — match record structure
- match_level_enum.md — match_level values
- classification_rule_schema.md — classification source, confidence fields
- mobile_write_rejection_endpoints.md — mobile write rejection
- design_system_tokens.md — colour, spacing, typography tokens
