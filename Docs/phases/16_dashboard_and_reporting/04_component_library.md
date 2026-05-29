# Block 16 — Phase 04: Component Library

## References

- Phase 03 (Design System MASTER — every component composes against tokens declared there)
- UI/UX skill: `ui-ux-pro-max:ui-ux-pro-max` Quick Reference §1 (Accessibility), §2 (Touch & Interaction), §6 (Typography & Color), §7 (Animation), §8 (Forms & Feedback)
- Block doc: `Docs/blocks/14_review_queue.md` (severity-coloured badges; card layout)

## Phase Goal

Build the reusable primitive set every dashboard surface composes against: Button, Input, Select, Combobox, DatePicker, Table, Card, Badge, Modal, Drawer, Popover, Tooltip, Toast, Skeleton, Empty State, Error State, Tabs, Pagination, Breadcrumbs, Command Palette. Every component ships with full state coverage, accessibility, light + dark variants, keyboard navigation, reduced-motion respect, and 44 px minimum touch targets. After this phase, Phases 05–08 compose dashboard surfaces from a stable component library.

## Dependencies

- Phase 03 (Design System MASTER tokens)
- Block 14 Phase 03 (issue-card structure — the Card component supports the per-bucket layouts)

## Deliverables

- **Button**:
  - **Variants:** `primary` (filled blue, white text), `secondary` (outlined neutral), `tertiary` (text-only with hover background), `danger` (red filled — destructive-emphasis per UX rule), `ghost` (transparent with hover).
  - **Sizes:** `sm` (32 px height, 14 px text), `md` (40 px, 14 px), `lg` (48 px, 16 px). Icon-only buttons honor 44 px minimum tap area via padding (per `touch-target-size`).
  - **States:** default, hover (subtle background-tone shift, 150 ms transition), focus-visible (2 px ring), pressed (scale 0.98 + ripple-equivalent — `scale-feedback`), disabled (opacity 0.5, `aria-disabled`, no pointer events), loading (spinner replaces label, button stays at the same width).
  - **Slots:** `leading-icon`, `trailing-icon`. Icons from Lucide at 16 / 20 px depending on size.
  - **A11y:** `aria-label` required for icon-only variants (per UX rule `aria-labels`).
- **Input / Textarea**:
  - **Variants:** `default`, `with-leading-icon`, `with-trailing-action` (e.g., clear button, password toggle).
  - **States:** default, focus, error, disabled, read-only (visually distinct from disabled per UX rule `read-only-distinction`).
  - **Validation:** inline validation on blur (per `inline-validation`); error message renders below the input near the field (per `error-placement`); error states use `severity-high` token + icon (color-not-only); `aria-invalid` + `aria-describedby` on the error message.
  - **Helper text** persistent below the input when complex (per `input-helper-text`); not placeholder-only.
  - **Touch height:** ≥ 44 px on mobile (per `touch-friendly-input`).
  - **Semantic input types:** `email`, `tel`, `number`, `date` for correct mobile keyboards (per `input-type-keyboard`).
  - **Autofill:** `autocomplete` / `textContentType` set per field (per `autofill-support`).
- **Select / Combobox**:
  - Combobox is the searchable variant (Algolia-style). Both keyboard-navigable: arrows move highlight, enter selects, escape dismisses.
  - Multi-select supported via combobox with chips.
  - **A11y:** `aria-expanded`, `aria-controls`, `aria-activedescendant` on the listbox.
- **DatePicker**:
  - Single-date and date-range variants.
  - Cyprus locale defaults: EU date format (DD/MM/YYYY), week starts Monday, EUR-friendly.
  - Keyboard navigable: arrow keys move day; page up/down month; ctrl+arrow year.
  - Dark-mode parity.
- **Table**:
  - **Sortable columns** with visible sort indicator + `aria-sort` (per `sortable-table`).
  - **Filterable** via column header dropdowns; filter chips render above the table.
  - **Virtualized at 50+ rows** (per `virtualize-lists`).
  - **Cell density:** compact (32 px row height for transaction lists), comfortable (48 px for invoice / period lists).
  - **Numeric columns:** right-aligned, tabular figures, color-neutral until severity is meaningful.
  - **Sticky header** during scroll; sticky first column for wide tables (sub-doc tunes per surface).
  - **Selection:** row checkbox, header checkbox for select-all-on-page; bulk-action bar appears above table when ≥1 selected.
  - **Empty state:** when 0 rows, an Empty State component renders (see below).
  - **Loading state:** Skeleton rows during initial load; per-row spinner during inline-edit operations.
  - **Keyboard nav:** tab to row → arrows to cell → enter to drill down.
- **Card**:
  - **Variants:** `default` (no border accent), severity variants (left-border accents per Phase 03's severity tokens).
  - Elevation: `elev-1` default; `elev-2` on hover for clickable cards.
  - **Slots:** header (title + optional severity badge + optional action menu), body (chart / KPI / list), footer (optional metadata or links).
  - **Click-through:** entire card is the click target when the card represents a single entity; explicit "View details" link when multiple actions are possible.
- **Badge**:
  - **Variants:** `severity-low / medium / high / blocking` (mapped to Block 14 Phase 02's four-value severity enum) AND `status-success / status-info / status-neutral` (Phase 03's status token family for non-severity states like finalized periods, paid invoices, completed runs).
  - **Sizes:** `sm` (20 px tall, 12 px text), `md` (24 px, 14 px).
  - Always include the textual label adjacent to the icon (color-not-only).
- **Modal / Drawer / Popover / Tooltip**:
  - **Modal:** centered overlay with scrim (40–60% black per Phase 03's elev-3 + scrim guidance). Animated entrance from trigger source per `modal-motion`. Escape closes; click-outside-scrim closes; focus-trapped while open. Has a clearly labelled close button + `aria-labelledby` / `aria-describedby`.
  - **Drawer:** right-side or bottom-side slide-in. Same focus-trap + close affordance. Mobile uses bottom-sheet variant with swipe-down-to-dismiss + drag handle (per `swipe-clarity`).
  - **Popover:** anchored to a trigger; closes on click-outside; no focus-trap (lighter-weight than modal). Supports keyboard escape.
  - **Tooltip:** hover (desktop) / long-press (mobile); short text only; respects `prefers-reduced-motion`. Tooltip content is also keyboard-reachable (per `tooltip-keyboard`).
- **Toast**:
  - **Variants:** `success`, `error`, `info`, `warning`.
  - Auto-dismiss in 4 seconds (`toast-dismiss`); user-dismissable manually.
  - **A11y:** `aria-live="polite"` for non-error; `role="alert"` for errors; never steals focus (per `toast-accessibility`).
  - Stacks bottom-right (desktop) or top-of-screen (mobile, slide-down). Max 3 stacked; older ones fade out.
- **Skeleton / Empty State / Error State**:
  - **Skeleton:** shimmer placeholder for loading >300 ms (per `loading-states`). Honors `prefers-reduced-motion` (static gray bar instead of shimmer).
  - **Empty State:** illustration + heading + body copy + primary action when applicable. Used when 0 rows / 0 issues / no data (per `empty-states`).
  - **Error State:** error icon + error heading + error description + retry button (per `error-recovery`).
- **Tabs**:
  - **Variants:** `underlined` (Linear / Mercury style), `pill` (settings-style).
  - Keyboard nav: arrow keys move; enter activates; tab leaves the tablist.
  - `aria-selected`, `role="tablist"` / `"tab"` / `"tabpanel"`.
  - URL-synced (the active tab reflects in the URL for deep linking per `deep-linking`).
- **Pagination**:
  - **Variants:** numbered (≤ 100 pages), prev/next-only (cursor-based, large datasets).
  - Always shows current position context (e.g., "Showing 21–40 of 1,200").
  - Keyboard navigable.
- **Breadcrumbs**:
  - For 3+ level deep hierarchies (per `breadcrumb-web` — applies on the desktop dashboard).
  - Last segment is non-clickable (current page).
  - Truncates middle segments on narrow widths with a "..." menu.
- **Command Palette**:
  - Cmd+K opens; fuzzy search across navigation destinations, transactions, invoices, issues, settings.
  - Recent / suggested entries (per `search-accessible`).
  - Keyboard-only operable.
  - Respects business-switcher context — searches scope to the active business (or all, with a toggle).
- **Top Nav (component, used by Phase 05's shell)**:
  - Logo, business switcher, period switcher (current period centered), search trigger (Cmd+K), notifications bell, user menu.
  - Persistent across all dashboard pages (per `persistent-nav`).
- **Sidebar / Navigation rail**:
  - Collapsible (icon-only mode).
  - Active-state indicator (per `nav-state-active`).
  - Icon + text labels (per `nav-label-icon`); never icon-only without label in expanded mode.
- **Component-level UX invariants enforced (the do-not list applied at component layer):**
  - All clickable elements have `cursor: pointer` (per `cursor-pointer`).
  - Hover-only is never the sole interaction (per `hover-vs-tap`).
  - Disabled buttons during async ops show a spinner (per `loading-buttons`).
  - Touch targets ≥ 44 × 44 px (per `touch-target-size`).
  - 8 px minimum gap between adjacent touch targets (per `touch-spacing`).
  - State changes animate 150–300 ms; never instant (per `state-transition`).
  - Animations are interruptible (per `interruptible`).
- **Component documentation:** every component ships with a Storybook-equivalent doc page showing all variants × all states + accessibility notes + keyboard shortcuts. Sub-doc tracks the doc-site framework (Stage 1 default — Storybook).

## Definition of Done

- Every component listed above exists with full state coverage (the list spans Button / Input / Textarea / Select / Combobox / DatePicker / Table / Card / Badge / Modal / Drawer / Popover / Tooltip / Toast / Skeleton / Empty State / Error State / Tabs / Pagination / Breadcrumbs / Command Palette / Top Nav / Sidebar — count varies depending on whether you treat Modal/Drawer/Popover/Tooltip as one family or four separate, and Skeleton/Empty/Error as one or three; either way, the deliverables list is the source of truth).
- Every component passes a checklist: light + dark mode parity, focus-visible state, keyboard navigation, ARIA attributes, `prefers-reduced-motion` respect, touch-target minimum.
- Form components (Input, Select, DatePicker) ship with the inline-validation contract: error on blur, error message near field, `aria-invalid` + `aria-describedby`.
- Table virtualizes at 50+ rows with stable scroll performance.
- Modal / Drawer focus-trap correctly; escape key closes; scrim click closes (modals).
- Toasts use `aria-live` correctly; never steal focus.
- Component documentation (Storybook) covers every variant.
- Lint rule blocks raw hex / spacing values in component files.

## Sub-doc Hooks (Stage 4)

- **Per-component variant sub-doc** — exact prop API, default values, per-variant token mapping.
- **Storybook configuration sub-doc** — story structure, addon list (a11y, viewport, dark-mode toggle).
- **Touch-target audit sub-doc** — automated check enforcing 44 × 44 px on all interactive components.
- **Keyboard-shortcut sub-doc** — the full set across components + the global Cmd+K palette.
- **Focus-trap implementation sub-doc** — Modal / Drawer details.
- **Animation-token application sub-doc** — exact motion durations per component interaction.
- **Storybook accessibility tests sub-doc** — automated axe-core checks per story.
