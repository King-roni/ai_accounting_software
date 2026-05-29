# Run List UI Spec

**Block:** engine  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The Runs list page is the primary dashboard for accountants and admins. It shows all `workflow_runs` rows that the authenticated user has permission to see, with filtering, sorting, pagination, and bulk actions. It is the default landing page for users with the `accountant` and `admin` roles, accessible at `/runs`.

---

## Page Layout

Two-column layout on desktop (sidebar filter panel + main list area). On mobile and viewports < 1024px, the filter panel collapses to a top filter bar with a "Filters" drawer toggle.

```
┌──────────────────────────────────────────────────────────────┐
│  Runs                                        [+ New Run]     │
├──────────────┬───────────────────────────────────────────────┤
│ Filter panel │  Filter bar (active chips)  [Sort ▾] [Search]│
│              ├───────────────────────────────────────────────┤
│ Status       │  Run list table                               │
│ Assignee     │  ...rows...                                   │
│ Period       │                                               │
│ Date range   │  [Pagination]                                 │
└──────────────┴───────────────────────────────────────────────┘
```

---

## Run List Table

### Columns

| Column | Source | Notes |
|---|---|---|
| Run ID | `workflow_runs.run_code` | `RUN-{YYYY}-{NNNN}` monospace; click copies to clipboard |
| Client | `business_entities.legal_name` | Links to `/clients/{client_id}` |
| Period | `workflow_runs.period_start` / `period_end` | Rendered as `Q1 2026` or `Jan 2026` depending on filing frequency |
| Status | `workflow_runs.run_status` | Status badge (see Status Badge Colours) |
| Assignee | `workflow_runs.assignee_id` | Avatar (24px circle, initials fallback) + display name; "Unassigned" if null |
| Created | `workflow_runs.created_at` | Relative time (e.g. "3 days ago") with absolute tooltip |
| Last activity | `workflow_runs.updated_at` | Relative time with absolute tooltip |

Columns are non-editable inline. All columns are sortable by clicking the column header. Active sort column shows an up/down caret.

### Row Behaviour

- Clicking any row navigates to `/runs/{run_id}` (the Run Detail page).
- Hovering a row applies `background: --color-neutral-50`.
- Rows that have `run_status = REVIEW_HOLD` or `run_status = AWAITING_APPROVAL` are highlighted with a left border: `4px solid --color-orange-400` and `4px solid --color-purple-400` respectively.
- Rows that have `run_status = FAILED` show a left border `4px solid --color-red-400`.

---

## Status Badge Colours

Identical to the run detail badge palette.

| run_status | Background | Text |
|---|---|---|
| CREATED | `--color-neutral-100` | `--color-neutral-700` |
| RUNNING | `--color-blue-100` | `--color-blue-700` |
| PAUSED | `--color-amber-100` | `--color-amber-700` |
| REVIEW_HOLD | `--color-orange-100` | `--color-orange-700` |
| AWAITING_APPROVAL | `--color-purple-100` | `--color-purple-700` |
| FINALIZING | `--color-teal-100` | `--color-teal-700` |
| FINALIZED | `--color-green-100` | `--color-green-700` |
| FAILED | `--color-red-100` | `--color-red-700` |
| CANCELLED | `--color-neutral-200` | `--color-neutral-500` |
| COMPENSATING | `--color-red-50` | `--color-red-600` |

Badges are pill-shaped (`border-radius: 9999px`), `font-size: 12px`, `font-weight: 500`, `padding: 2px 8px`.

---

## Filter Bar

The filter bar appears above the list table. Active filters render as dismissible chips.

### Filter Controls

| Filter | Type | Options |
|---|---|---|
| Status | Multi-select dropdown | All 10 `run_status_enum` values; default: all |
| Assignee | Single-select with avatar | List of team members + "Unassigned"; default: all |
| Period | Select | Quarters (Q1–Q4) and months; or "All periods" |
| Date range | Date range picker | `created_at` range; supports preset ranges (Last 7 days, Last 30 days, This quarter, Custom) |

Active filter chips appear below the filter controls, each showing the filter name and value. Each chip has an "×" to remove that filter. A "Clear all" link removes all active filters.

### Search

A search input in the top-right of the filter bar searches across `run_code`, `business_entities.legal_name`, and `assignee display_name`. Debounced at 300ms, min 2 characters.

---

## Sort Options

Sort is applied via the dropdown "Sort ▾" in the filter bar.

| Option | Field | Default order |
|---|---|---|
| Newest first | `created_at DESC` | Default |
| Oldest first | `created_at ASC` | |
| Last activity | `updated_at DESC` | |
| Client A–Z | `business_entities.legal_name ASC` | |
| Status | `run_status ASC` | Alphabetical |
| Period | `period_start DESC` | |

Column header clicks override the sort dropdown selection and update the dropdown to match.

---

## Pagination

- Default page size: 25 rows.
- Page size selector: 25 / 50 / 100.
- Pagination controls at bottom of list: `< Previous  Page 2 of 14  Next >`.
- Total count label: "142 runs" rendered left of pagination controls.
- Navigating pages preserves active filters and sort.
- URL reflects page state: `?page=2&status=REVIEW_HOLD&sort=updated_at_desc`.

---

## Create New Run CTA

The "+ New Run" button is in the top-right of the page header. Clicking it opens the New Run modal.

### New Run Modal

Fields:
1. **Client** — searchable select from `business_entities`.
2. **Period** — select quarter or month; depends on `business_entities.filing_frequency`.
3. **Assignee** — optional; defaults to current user.
4. **Notes** — optional free-text field (max 500 characters).

On submit, a new `workflow_runs` row is created with `run_status = CREATED`. The modal closes and the new run row appears at the top of the list.

---

## Bulk Actions

Rows have a checkbox in a leftmost column that appears on hover. Checking any row shows the bulk action toolbar above the list:

```
[3 selected]  [Reassign ▾]  [Cancel]  [Clear selection]
```

| Action | Behaviour | Confirmation required |
|---|---|---|
| Reassign | Dropdown of team members; updates `assignee_id` on all selected runs | No |
| Cancel | Sets `run_status = CANCELLED` on all selected runs that are in CREATED or PAUSED | Yes — modal: "Cancel {N} runs? This cannot be undone." |

Bulk actions are disabled for FINALIZED or COMPENSATING runs (those rows show greyed-out checkboxes with a tooltip "Cannot modify finalized runs").

Selecting all rows on the current page: clicking the header checkbox selects all visible rows. A "Select all 142 runs" option appears in the bulk toolbar if the user wants to apply across all pages.

---

## Empty State

### No runs at all

```
[Document stack icon, 48px]
No runs yet

Create your first run to start processing a client's bookkeeping period.

[+ New Run]
```

### No results matching active filters

```
[Filter icon, 48px]
No runs match your filters

Try adjusting or clearing your filters.

[Clear all filters]
```

---

## Mobile Layout

On viewports < 768px:

- Table collapses to a card list. Each card shows: client name (bold), period, status badge, assignee avatar, and last activity.
- Run ID is hidden in the card view; visible in the run detail.
- Filter panel becomes a bottom sheet triggered by a "Filters" button in the top bar.
- Bulk selection is disabled on mobile; individual row actions are accessed via a "..." overflow menu on each card (Reassign, Cancel).
- Sort is accessed via a sort icon button in the top bar, opening a bottom sheet.

---

## Related Documents

- `/sub/ui/run_detail_ui_spec.md` — Run Detail page
- `/sub/schemas/workflow_run_schema.md` — `workflow_runs` table definition and `run_status_enum`
- `/sub/ui/review_queue_ui_spec.md` — Review Queue (accessed from runs in REVIEW_HOLD)
- `/sub/ui/finalization_approval_ui_spec.md` — Approval flow for AWAITING_APPROVAL runs
- `/sub/ui/team_members_ui_spec.md` — Assignee management
