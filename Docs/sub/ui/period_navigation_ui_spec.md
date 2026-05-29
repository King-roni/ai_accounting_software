# Period Navigation UI Spec

**Category:** UI · **Owning block:** 16 — Dashboard & Reporting · **Block reference:** Block 16 § Phase 01 (Dashboard Architecture), Phase 02 (Period Picker) · **Stage:** 4 sub-doc (Layer 2 UI spec)

**Purpose:** Defines the period picker and period navigation UX for the dashboard and workflow run views. This spec is the binding reference for front-end implementation of the period selector, URL routing, keyboard navigation, status indicators, and mobile layout. Design tokens and run_status_enum badge colours are sourced from `severity_color_tokens.md` and `dashboard_card_definitions_ui_spec.md`.

---

## Period picker

### Placement

The period picker is a month/year selector rendered in the top header of:
- The dashboard (all views)
- The workflow run detail page

It does not appear in the review queue, invoice list, or settings views.

### Display format

The selected period is rendered as `MMM YYYY` — three-letter abbreviated month, four-digit year, space-separated. Examples: `Apr 2026`, `Jan 2025`, `Dec 2025`.

The label is rendered in medium-weight body text with a downward-pointing chevron icon to its right, indicating it is interactive. The label and chevron are a single tap/click target.

### Popover

Clicking the period picker label opens a calendar popover showing the last 24 months, including the current month. The popover:

- Is anchored below the period picker label, aligned to the left edge of the label.
- Contains a 6-column grid of month chips (4 rows of 6 months = 24 months).
- Months are ordered most-recent at top-left, oldest at bottom-right.
- The currently selected period has a filled background in the primary colour.
- The current calendar month has a dotted border if not selected.
- The popover closes on outside click or Escape key.

---

## Period availability indicators

Each month chip in the popover shows a status indicator dot if at least one workflow run exists for that business + period combination.

### Dot colour mapping

The dot colour maps to the `run_status_enum` badge colour for the most recent run in that period:

| run_status_enum | Dot colour |
|---|---|
| `FINALIZED` | Green (`--status-finalized-bg`) |
| `RUNNING` | Primary animated dot (see Active run indicator) |
| `REVIEW_HOLD` | Amber (`--status-review-hold-bg`) |
| `AWAITING_APPROVAL` | Amber (`--status-awaiting-approval-bg`) |
| `PAUSED` | Grey (`--status-paused-bg`) |
| `FAILED` | Red (`--status-failed-bg`) |
| `CANCELLED` | Grey (`--status-cancelled-bg`) |
| `COMPENSATING` | Orange (`--status-compensating-bg`) |
| `CREATED` | Light grey (`--status-created-bg`) |
| `FINALIZING` | Animated amber dot |

Months with no workflow run show no dot — the chip label alone is rendered.

If a period has both a `FINALIZED` run and a subsequent adjustment run in a non-terminal state, the dot reflects the most recent non-terminal run's status.

---

## Navigation

### Chevron buttons

Left and right chevron buttons flank the period picker label in the header. The left chevron moves to the previous month; the right chevron moves to the next month.

- The right chevron is disabled (greyed, `cursor: not-allowed`) when the currently selected period is the current calendar month.
- The left chevron is disabled when the currently selected period is older than 24 months from today.
- Chevron clicks trigger a URL update (see URL routing).

### Keyboard shortcuts

| Key | Action |
|---|---|
| `[` | Navigate one month backward |
| `]` | Navigate one month forward |
| `Left arrow` | Navigate one month backward (when focus is on the period picker label) |
| `Right arrow` | Navigate one month forward (when focus is on the period picker label) |

`[` and `]` shortcuts are active when the period picker label has focus or when the popover is open. They are not active when focus is inside a text input or other keyboard-consuming element.

Keyboard navigation respects the same boundary constraints as chevron navigation — backward stops at 24 months ago, forward stops at the current calendar month.

---

## Locked period visual

A period with a `FINALIZED` run shows a lock icon to the left of the period label in the header. The lock icon:

- Is 16×16 px, rendered in the secondary text colour.
- Is not a clickable affordance — it is a status indicator only.
- Shows a tooltip on hover: `Period locked — [date finalized]`, where `[date finalized]` is formatted as `DD MMM YYYY HH:MM UTC` from the `period_lock_status.locked_at` value.

The lock icon is removed when the selected period changes to a non-finalized period.

---

## Active run indicator

A period with a non-terminal run (any `run_status_enum` value that is not `FINALIZED`, `FAILED`, `CANCELLED`) shows an animated dot in the primary colour to the left of the period label in the header.

- The animated dot pulses at a 2-second interval.
- Clicking the animated dot navigates to the run detail page for the active run (`/runs/<workflow_run_id>`).
- The animated dot and the lock icon are mutually exclusive — a period cannot be both locked and have an active run simultaneously.

---

## URL routing

The selected period is reflected in the URL query parameter:

```
?period=2026-04
```

Format: `YYYY-MM`. Leading zeros are required (e.g., `2026-04`, not `2026-4`).

### Direct navigation

Navigating to a URL with a valid `?period=YYYY-MM` parameter loads the dashboard for that period directly. The period picker label updates to reflect the URL parameter on load.

### Invalid period handling

A `?period` value is invalid if:
- It cannot be parsed as `YYYY-MM`.
- The year is in the future relative to the current calendar month.
- The month is beyond the 24-month backward limit.

On an invalid `?period` value, the router redirects to the most recent period that has an active or recent run. If no run exists in the last 24 months, the redirect targets the current calendar month.

### Future period

Navigating to a future period (a month after the current calendar month) is not supported. The URL is treated as invalid and redirects per the invalid period handling rule above. The right chevron does not allow forward navigation past the current month.

### Shareable URLs

Period URLs are shareable within the same business. A URL containing `?period=2026-04` opened by a different authenticated user of the same business resolves to the same period view for that user. Cross-business period URLs redirect to the recipient's default period.

---

## Mobile layout

On `client_form_factor = MOBILE`:

- The period picker renders as a full-width tap target below the top header bar, not inline with the header.
- The `MMM YYYY` label is centred within the full-width tap area with the chevron icon to the right.
- Tapping the label opens the calendar popover as a **bottom sheet** (full-width, slides up) rather than an anchored popover.
- The bottom sheet calendar grid uses 4 columns instead of 6 (3 rows × 4 columns for 12 months visible; scroll down for older months).
- Left/right chevron buttons are placed to the left and right of the centred label within the tap area.
- Keyboard shortcuts (`[` and `]`) are not applicable on mobile (software keyboard present).

---

## Cross-references

- `dashboard_card_definitions_ui_spec.md` — card refresh cadence and run_status_enum badge colour definitions
- `workflow_run_schema.md` — `run_status_enum` values and `workflow_run_id` for active run navigation
- `period_lock_status_schema.md` — `locked_at` timestamp source for the locked period tooltip
