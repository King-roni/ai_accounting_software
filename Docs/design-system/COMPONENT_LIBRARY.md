# Component Library

Canonical primitive set every dashboard surface composes against. All components consume tokens from `Docs/design-system/MASTER.md` (B16·P03) — never raw hex or arbitrary spacing.

**Phase**: B16·P04 (BOOK-151) · **Source spec**: `Docs/phases/16_dashboard_and_reporting/04_component_library.md`

## Per-component contract template

Every component below documents:

- **Variants** — visual or functional sub-types
- **Sizes** — discrete size tokens
- **States** — default / hover / focus / active / disabled / loading / error (where applicable)
- **Slots** — composable areas
- **ARIA** — required attributes
- **Keyboard** — supported keys
- **Tokens consumed** — explicit list of MASTER tokens
- **Touch target** — confirms ≥ 44 × 44 px
- **Reduced motion** — what changes when `prefers-reduced-motion: reduce`

## Component-level UX invariants (apply to ALL components)

1. All clickable elements have `cursor: pointer`.
2. Hover-only is never the sole interaction — every hover-revealed action has a touch parity.
3. Disabled buttons during async ops show a spinner; button width stays stable.
4. Touch targets ≥ 44 × 44 px on mobile.
5. 8 px minimum gap between adjacent touch targets.
6. State changes animate 150–300 ms; never instant.
7. Animations are interruptible.

---

## Button

- **Variants**: `primary` (filled blue, white text), `secondary` (outlined neutral), `tertiary` (text-only with hover background), `danger` (red filled — destructive emphasis), `ghost` (transparent with hover).
- **Sizes**: `sm` (32 px tall, 14 px text), `md` (40 px, 14 px), `lg` (48 px, 16 px). Icon-only buttons honor ≥ 44 × 44 px tap area via padding.
- **States**: default, hover (subtle background tone shift, 150 ms), focus-visible (2 px ring), pressed (scale 0.98 + ripple-equivalent), disabled (opacity 0.5, `aria-disabled`, pointer-events none), loading (spinner replaces label; button width stays stable).
- **Slots**: `leading-icon`, `trailing-icon` (Lucide, 16/20 px per size).
- **ARIA**: `aria-label` required for icon-only variants; `aria-disabled` on disabled state; `aria-busy` on loading.
- **Keyboard**: Enter / Space triggers.
- **Tokens**: `color-primary`, `text-on-primary`, `border-default`, `severity-high` (danger), `radius-md`, `motion-duration-fast`, `motion-easing-enter`.
- **Touch target**: ≥ 44 px (sm at 32 px must be padded externally to meet this when adjacent to other tap targets).
- **Reduced motion**: scale + ripple disabled; instant state transitions.

## Input

- **Variants**: `default`, `with-leading-icon`, `with-trailing-action` (clear button, password toggle).
- **States**: default, focus, error, disabled, read-only (visually distinct from disabled).
- **Validation**: inline-validation on blur; error message renders below the input near the field; error states use `severity-high` token + `AlertOctagon` icon (color-not-only); `aria-invalid="true"` + `aria-describedby` pointing at the error message id.
- **Helper text**: persistent below the input when complex; never placeholder-only.
- **Touch height**: ≥ 44 px on mobile.
- **Semantic types**: `email`, `tel`, `number`, `date`, `password` (correct mobile keyboards).
- **Autofill**: `autocomplete` / `textContentType` per field.
- **ARIA**: `aria-invalid`, `aria-describedby`, `aria-required` when required.
- **Keyboard**: standard text-input.
- **Tokens**: `surface-1`, `border-default`, `border-strong` (focus), `severity-high` (error), `text-primary`, `text-tertiary` (placeholder), `radius-sm`.

## Textarea

- Same contract as Input plus auto-grow + max-rows. Min 3 rows, max 12 rows; scrolls beyond max.
- **Tokens**: same as Input.
- **ARIA**: same as Input; multi-line.

## Select

- Keyboard-navigable dropdown.
- **Variants**: single, multi (chips).
- **States**: default, focus, error, disabled.
- **ARIA**: `aria-expanded`, `aria-controls`, `aria-activedescendant`, `role="listbox"` on the popover, `role="option"` on each item.
- **Keyboard**: arrows move highlight, Enter selects, Escape dismisses, Tab leaves.

## Combobox

- Searchable Select; Algolia-style fuzzy match.
- **Variants**: single, multi-with-chips.
- **States**: default, focus, error, disabled, loading (results loading).
- **ARIA**: `aria-expanded`, `aria-controls`, `aria-activedescendant`, `aria-autocomplete="list"`.
- **Keyboard**: type to filter, arrows move highlight, Enter selects, Escape dismisses.

## DatePicker

- Single-date and date-range variants.
- **Cyprus locale defaults**: EU format DD/MM/YYYY, week starts Monday.
- **Keyboard**: arrows move day; PageUp/Down month; Ctrl+arrows year; Enter selects; Escape dismisses.
- **ARIA**: `role="dialog"` on the calendar popover; `aria-label` on each day cell with full date.
- **Tokens**: `surface-2`, `severity-high` (invalid dates), `radius-md`.
- **Touch target**: each day cell ≥ 44 × 44 px on mobile.

## Table

- **Sortable columns**: visible sort indicator + `aria-sort="ascending|descending|none"` per column.
- **Filterable**: column header dropdowns; filter chips render above the table.
- **Virtualized at 50+ rows** with stable scroll performance.
- **Cell density**: `compact` (32 px row height for transaction lists), `comfortable` (48 px for invoice / period lists).
- **Numeric columns**: right-aligned, tabular figures (`font-feature-settings: 'tnum'`), color-neutral unless severity is meaningful.
- **Sticky header** during scroll; **sticky first column** for wide tables.
- **Selection**: row checkbox; header checkbox for select-all-on-page; bulk-action bar appears above the table when ≥ 1 selected.
- **Empty state**: when 0 rows, the Empty State component renders.
- **Loading state**: Skeleton rows during initial load; per-row spinner during inline-edit operations.
- **Keyboard nav**: Tab to row → Arrows to cell → Enter to drill down.
- **ARIA**: `role="table"`, `role="row"`, `role="columnheader"`, `aria-sort`, `aria-rowcount`.
- **Tokens**: `surface-0`, `surface-3` (zebra), `border-subtle`, `text-primary`, `text-secondary`, severity tokens for highlighted rows.

## Card

- **Variants**: `default` (no border accent), `severity-low`, `severity-medium`, `severity-high`, `severity-blocking` (each with left-border accent per the matching MASTER severity token), `status-success` (left-border accent for completed states).
- **Elevation**: `elev-1` default; `elev-2` on hover for clickable cards.
- **Slots**: header (title + optional severity badge + optional action menu), body (chart / KPI / list), footer (optional metadata or links).
- **Click-through**: entire card is the click target when the card represents a single entity; explicit "View details" link when multiple actions are possible.
- **ARIA**: `role="region"` with `aria-labelledby` pointing at the card title.
- **Tokens**: `surface-2`, `severity-*` (left border), `radius-md`, `elev-1` / `elev-2`.

## Badge

- **Variants**: `severity-low`, `severity-medium`, `severity-high`, `severity-blocking` (mapped to Block 14 P02's four-value severity enum); `status-success`, `status-info`, `status-neutral` (separate family).
- **Sizes**: `sm` (20 px tall, 12 px text), `md` (24 px, 14 px).
- **Composition**: text label adjacent to icon ALWAYS (color-not-only). Icon from Lucide; text is the semantic name (LOW / HIGH / BLOCKING / Finalized / Paid / etc.).
- **ARIA**: visually-hidden text mirrors the icon meaning when icon-only variant is forced.
- **Tokens**: `severity-*`, `status-*`, `text-on-primary`, `radius-full`.

## Modal

- Centered overlay with scrim (40–60% black per MASTER's `elev-3` + scrim guidance).
- **Animated entrance** from trigger source per `modal-motion`.
- **Escape closes**, **click-outside-scrim closes**, **focus-trapped** while open.
- Clearly labelled close button + `aria-labelledby` + `aria-describedby`.
- **ARIA**: `role="dialog"`, `aria-modal="true"`.
- **Tokens**: `surface-0`, `elev-3`, `radius-lg`, `motion-duration-slow` (entrance), `motion-duration-fast` × 0.7 (exit).
- **Reduced motion**: enters instantly; no scale.

## Drawer

- Right-side (desktop) or bottom-sheet (mobile) slide-in.
- **Focus-trap** while open (same as Modal).
- **Close**: Escape, close button, click-outside.
- **Mobile bottom-sheet variant**: drag handle + swipe-down-to-dismiss.
- **ARIA**: `role="dialog"`, `aria-modal="true"`.
- **Tokens**: `surface-0`, `elev-3`, `radius-lg` (top corners on bottom-sheet), `motion-duration-slow`.

## Popover

- Anchored to a trigger; closes on click-outside; **no focus-trap** (lighter-weight than Modal).
- Supports Escape close.
- **ARIA**: `role="dialog"` or `role="menu"` per use case; `aria-labelledby` for the trigger.
- **Tokens**: `surface-0`, `elev-2`, `radius-md`.

## Tooltip

- Hover (desktop) / long-press (mobile); short text only.
- **Respects** `prefers-reduced-motion` — instant appearance under reduce.
- **Keyboard-reachable** — focus on the trigger reveals the tooltip.
- **ARIA**: `role="tooltip"`, `aria-describedby` on the trigger pointing at the tooltip id.
- **Tokens**: `surface-3` (dark variant for light mode), `text-on-primary`, `radius-sm`.

## Toast

- **Variants**: `success`, `error`, `info`, `warning`.
- Auto-dismiss in 4 seconds; user-dismissable manually via close button.
- **ARIA**: `aria-live="polite"` for non-error; `role="alert"` for errors; **never steals focus**.
- Stacks bottom-right (desktop) or top-of-screen (mobile, slide-down). **Max 3 stacked**; older ones fade out.
- **Tokens**: `surface-2`, `status-success` / `status-info` / `severity-medium` (warning) / `severity-high` (error), `radius-md`, `elev-2`.

## Skeleton

- Shimmer placeholder for loading > 300 ms.
- **Reduced motion**: static gray bar instead of shimmer.
- **ARIA**: `aria-busy="true"` on the container; the actual content's `aria-live` is `polite` so completion announces.
- **Tokens**: `surface-3`, `motion-duration-slow` (shimmer cycle).

## Empty State

- Illustration + heading + body copy + primary action when applicable.
- Used when 0 rows / 0 issues / no data.
- **ARIA**: heading is the main label; action button has `aria-label` if icon-only.
- **Tokens**: `text-primary`, `text-secondary`, `surface-1` (background of the centered block).

## Error State

- Error icon + error heading + error description + retry button.
- Used when a query fails or a non-recoverable error blocks the surface.
- **ARIA**: `role="alert"` on the container.
- **Tokens**: `severity-high`, `text-primary`, `text-secondary`.

## Tabs

- **Variants**: `underlined` (Linear / Mercury style), `pill` (settings-style).
- **Keyboard**: Arrow keys move; Enter activates; Tab leaves the tablist.
- **ARIA**: `role="tablist"` on the container, `role="tab"` on each tab, `role="tabpanel"` on the content; `aria-selected="true"` on the active tab; `aria-controls` pointing at the panel.
- **URL-synced**: the active tab reflects in the URL for deep linking.
- **Tokens**: `color-primary` (active underline / pill background), `text-primary`, `text-secondary` (inactive), `motion-duration-fast`.

## Pagination

- **Variants**: numbered (≤ 100 pages), prev/next-only (cursor-based, large datasets).
- Always shows current position context (e.g., "Showing 21–40 of 1,200").
- **Keyboard**: Tab navigable; Enter / Space activates page links.
- **ARIA**: `role="navigation"` with `aria-label="Pagination"`; current page has `aria-current="page"`.
- **Tokens**: `text-primary`, `text-secondary`, `color-primary` (current), `border-subtle`.

## Breadcrumbs

- For 3+ level deep hierarchies (desktop dashboard only).
- Last segment is non-clickable (current page).
- Truncates middle segments on narrow widths with a "…" menu.
- **ARIA**: `nav` with `aria-label="Breadcrumb"`; ordered list; last item has `aria-current="page"`.
- **Tokens**: `text-tertiary` (separators), `text-secondary` (links), `text-primary` (current).

## Command Palette

- **Cmd+K opens**; fuzzy search across navigation destinations, transactions, invoices, issues, settings.
- Recent / suggested entries shown when query is empty.
- Keyboard-only operable: arrows move selection, Enter activates, Escape closes.
- Respects business-switcher context — searches scope to the active business (or all, with a toggle).
- **ARIA**: `role="dialog"` + `aria-modal="true"`; results list is a `role="listbox"` with `aria-activedescendant`.
- **Tokens**: `surface-2`, `elev-3`, `radius-lg`, `color-primary` (active match).

## Top Nav

- Logo, business switcher, period switcher (current period centered), search trigger (Cmd+K), notifications bell, user menu.
- Persistent across all dashboard pages.
- **ARIA**: `role="banner"`; the business switcher is a labeled combobox.
- **Tokens**: `surface-1`, `border-subtle`, `text-primary`.

## Sidebar

- Collapsible (icon-only mode).
- Active-state indicator on the current route.
- Icon + text labels in expanded mode; **never icon-only without label** in expanded mode.
- Collapsed mode shows icons with tooltip-on-hover for the label.
- **ARIA**: `role="navigation"` with `aria-label="Primary"`; collapse button has `aria-expanded`.
- **Tokens**: `surface-1`, `color-primary` (active indicator), `text-primary`, `text-secondary`.

---

## Three tricky rules (engineering must honor)

- **Modal vs Popover focus-trap discipline**: Modal traps focus; Popover does NOT. Drawers behave like modals on mobile (bottom-sheet) and like popovers on desktop (right-side, no trap). Wrong call breaks keyboard users.
- **Toast accessibility**: `aria-live="polite"` for non-error so the screen reader announces after current content. Errors get `role="alert"` for interrupt. Never call `focus()` on a toast.
- **Tabs URL-sync**: the active tab reflects in the URL for deep linking. The contract is non-negotiable: shareable tab URLs.

## Definition of Done

- Every component above exists in the Storybook (or equivalent) implementation with full variant × state matrix.
- Every component passes the checklist: light + dark mode parity, focus-visible state, keyboard navigation, ARIA attributes, `prefers-reduced-motion` respect, touch-target minimum.
- Form components (Input, Select, DatePicker) ship the inline-validation contract: error on blur, error message near field, `aria-invalid` + `aria-describedby`.
- Table virtualizes at 50+ rows with stable scroll performance.
- Modal / Drawer focus-trap correctly; Escape closes; scrim click closes (modals).
- Toasts use `aria-live` correctly; never steal focus.
- Component documentation covers every variant.
- Lint rule blocks raw hex / spacing values in component files (deferred to a future repo-tooling phase).

## Sub-doc hooks (Stage 4)

- Per-component prop API + default values + per-variant token mapping
- Storybook configuration — story structure, addon list (a11y, viewport, dark-mode toggle)
- Touch-target audit — automated 44 × 44 px enforcement
- Keyboard-shortcut map — global Cmd+K palette + per-component shortcuts
- Focus-trap implementation — Modal / Drawer details
- Animation-token application — exact motion durations per component interaction
- Storybook accessibility tests — automated axe-core checks per story
