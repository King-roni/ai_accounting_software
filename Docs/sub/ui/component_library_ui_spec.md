# Component Library UI Spec

**Category:** UI specs · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 1 convention)

The component inventory and the conventions every component binds to. Token-first composition (see `design_system_tokens`); headless-where-possible foundations; data-state-driven styling; accessibility baked in. Stripe / Linear / Mercury polish bar.

This sub-doc is the index + conventions. Per-component detailed specs (props, variants, state matrix, code examples) live as Layer 2 sub-docs at `Docs/sub/ui/component_<name>_ui_spec.md`.

---

## Composition principles

1. **Built from token primitives.** Every component consumes tokens via `design_system_tokens`. No raw values inside components (see `design_token_lint_policy`).
2. **Headless-first where possible.** Radix primitives or equivalent (HeadlessUI) provide unstyled, accessible foundations. Tailwind + token-bound CSS adds the visual layer. The composition pattern is: headless primitive → token-styled wrapper → consumer.
3. **`data-state="..."` attributes for state-driven styling.** Avoid className gymnastics for state. Components expose `data-state` (`default`, `hover`, `active`, `focus`, `disabled`, `loading`, `selected`, `expanded`, `collapsed`, `error`, etc.) and CSS targets these attributes.
4. **Polymorphic refs / forwardRef.** Every component supports ref-forwarding for composability (focus management, automation, testing).
5. **Slot composition over prop explosion.** Cards, drawers, modals expose `children` and slot props (`headerSlot`, `footerSlot`); they do not accept dozens of structural props. The layout is composed at the consumer site, not configured.
6. **No required props beyond data.** Every component renders with sensible defaults — explicit configuration is opt-in.

## Component inventory

### Forms

| Component | Notes |
| --- | --- |
| `Input` | Text input. Variants: default, with-leading-icon, with-trailing-button. States: default, focus, error, disabled. |
| `NumberInput` | Currency-aware number input. Tabular figures. Locale-aware separators per `localized_number_date_format_policy`. |
| `Select` | Single-select dropdown. Headless via Radix. Searchable variant exists. |
| `Combobox` | Searchable multi-select with async loading. Used in business switcher, client picker. |
| `Textarea` | Multi-line text. Auto-grow variant. |
| `Switch` | Boolean toggle. Use for binary options where state-on / state-off are equally valid. |
| `Checkbox` | Multi-select primitive. Indeterminate state for bulk-select-all-page UX. |
| `RadioGroup` | One-of-N selection where all options are visible. |
| `DatePicker` | Single date or range. EU calendar (week starts Monday). Tabular figures in cells. |
| `FileDrop` | Drag-and-drop file upload zone for statement / document upload. |

### Buttons

| Component | Notes |
| --- | --- |
| `Button` | Variants: `primary`, `secondary`, `ghost`, `danger`, `link`. Sizes: `sm`, `md`, `lg`. Loading state with spinner. |
| `IconButton` | Square button with icon only. 44×44 minimum touch target per `touch_target_audit_policy`. |
| `ButtonGroup` | Connected button cluster (e.g., view toggle: List / Grid). |
| `SplitButton` | Primary action + dropdown for related actions. Used in resolution-actions menus. |

### Display

| Component | Notes |
| --- | --- |
| `Card` | Content container. Slots: header, body, footer. `--shadow-1` rest, raised variant uses `--shadow-2`. |
| `Stat` | Single metric — large number + label + delta indicator. Used in dashboard cards. Tabular figures. |
| `Badge` | Small status pill. Color from status / severity tokens (never both). |
| `Tag` | Removable pill for tag picker UX. |
| `Avatar` | Circular user avatar with fallback initials. |
| `Tooltip` | Headless via Radix. Delay 300ms default. |
| `Banner` | Page-level alert. Variants: info, success, warning, danger. |

### Navigation

| Component | Notes |
| --- | --- |
| `Tabs` | Headless via Radix. Underline + pill variants. |
| `Breadcrumb` | Trail with truncation rules per `document_title_format_policy`. |
| `Sidebar` | Collapsible main nav. State persisted via `sidebar_persistence_schema`. |
| `CommandMenu` | cmd+k command palette. Inventory in `keyboard_shortcuts_inventory`. |
| `Pagination` | Cursor-based per `drill_down_schemas`. Page numbers OR cursor mode. |

### Feedback

| Component | Notes |
| --- | --- |
| `Toast` | Transient notification. Z-index `--z-toast`. Auto-dismiss 5s default; sticky variant for errors. |
| `Alert` | Inline alert. Variants: info / success / warning / danger / severity-blocking / severity-high / severity-medium / severity-low. |
| `Modal` | Centered overlay. Headless via Radix. Trap focus; close on Escape; backdrop click closes (configurable). |
| `Drawer` | Side overlay (right by default). Used for record detail views per `drawer_vs_full_page_preference_schema`. |
| `Popover` | Floating panel anchored to a trigger. Used for context menus, filters. |
| `Spinner` | Loading indicator. Variants: inline, button-loading, page-skeleton. |
| `ProgressBar` | Determinate or indeterminate. Used in workflow run progress. |
| `Skeleton` | Content placeholder during initial load. Per-screen skeletons match the eventual layout. |

### Data

| Component | Notes |
| --- | --- |
| `Table` | Sortable, selectable, virtualizable. Bulk actions header bar. Empty / error / loading states. |
| `DataGrid` | Heavier-feature table for export and drill-down lists. Column resize + reorder. |
| `Timeline` | Vertical timeline for workflow run history, audit history slice. |
| `AuditLogViewer` | Specialised viewer for `audit_history_slice_query_schema` results. |

### Charts

| Component | Notes |
| --- | --- |
| `ChartCard` | Wrapper around `chart_library_integration` choices. Bar / line / area / sparkline. Tabular figures in tooltips. |

## Component-to-token bindings (representative)

| Component | Background | Border | Text | Radius | Elevation |
| --- | --- | --- | --- | --- | --- |
| Button (primary) | `--color-action-primary` | none | `--color-text-on-primary` | `--radius-md` | `--shadow-1` rest, `--shadow-2` hover |
| Button (secondary) | `--color-bg-raised` | `--color-border-subtle` | `--color-text-primary` | `--radius-md` | `--shadow-0` rest, `--shadow-1` hover |
| Card | `--color-bg-raised` | `--color-border-subtle` | `--color-text-primary` | `--radius-lg` | `--shadow-1` |
| Modal | `--color-bg-overlay` | `--color-border-subtle` | `--color-text-primary` | `--radius-xl` | `--shadow-3` |
| Input | `--color-bg-base` | `--color-border-subtle` | `--color-text-primary` | `--radius-md` | `--shadow-0` |
| Input (focus) | `--color-bg-base` | `--color-border-focus` (with focus ring) | `--color-text-primary` | `--radius-md` | `--shadow-0` |
| Toast | `--color-bg-overlay` | `--color-border-subtle` | `--color-text-primary` | `--radius-lg` | `--shadow-5` |

Full per-component binding tables live in each component's Layer 2 sub-doc.

## State variants

Every interactive component supports the following data-state values where applicable:

| State | Selector | Use |
| --- | --- | --- |
| default | `[data-state="default"]` | Rest |
| hover | `[data-state="hover"]` | Pointer over (also via `:hover` for non-touch) |
| active | `[data-state="active"]` | Pointer down, button press |
| focus | `[data-state="focus"]` | Keyboard focus (also via `:focus-visible`) |
| disabled | `[data-state="disabled"]` | Non-interactable |
| loading | `[data-state="loading"]` | In-flight async action |
| selected | `[data-state="selected"]` | Selected within a group |
| expanded | `[data-state="expanded"]` | Disclosure widget open |
| collapsed | `[data-state="collapsed"]` | Disclosure widget closed |
| error | `[data-state="error"]` | Validation / error state |

The shared focus-ring is `box-shadow: 0 0 0 3px var(--color-border-focus)`. Never removed. Never replaced with `outline: 0`.

## Accessibility baseline

1. **WCAG 2.1 AA** — every component has minimum 4.5:1 contrast for text against its background, 3:1 for non-text (borders, focus rings, large text).
2. **Keyboard navigation** — every interactive component reachable + operable via keyboard. Tab order is logical. No keyboard traps except in modals (where trap is correct).
3. **Focus rings preserved** — never `outline: none` without a visible alternative. The token-driven focus ring is the alternative when present.
4. **Touch targets** — minimum 44×44 CSS pixels for any tap target on mobile per `touch_target_audit_policy`. IconButtons enforce this even when their visual icon is smaller (transparent padding).
5. **ARIA** — Radix primitives provide ARIA out of the box; custom components add explicit `role`, `aria-*` attributes per WAI-ARIA 1.2.
6. **Reduced motion** — every animation respects `prefers-reduced-motion` (token-level handling per `design_system_tokens`).
7. **Screen-reader text** — visually-hidden but screen-reader-announced text uses `.sr-only` utility class consistently.

Storybook a11y tests run on every component in CI via `storybook_axe_accessibility_fixtures`.

## Animation defaults

- Component show/hide: `--motion-medium` with `--easing-standard`
- Drawer slide: `--motion-medium` with `--easing-decelerate`
- Modal entrance: `--motion-slow` with `--easing-decelerate`
- Hover/focus state changes: `--motion-fast` with `--easing-standard`
- Reduced-motion: zero duration (token system handles)

## Per-component sub-doc map

Each component above has a Layer 2 sub-doc at `Docs/sub/ui/component_<snake_case_name>_ui_spec.md` covering:

- Props API (TypeScript signature)
- Variants matrix
- State variants matrix
- Token bindings (full table)
- Storybook stories enumerated
- Test fixture references
- Cross-component composition examples

This sub-doc is the index. Layer 2 produces per-component depth.

## Cross-references

- `design_system_tokens` — every token consumed
- `design_token_lint_policy` — enforcement
- `severity_color_tokens` — severity-specific Alert/Badge variants
- `lucide_icon_usage_ui_spec` — icon library binding
- `keyboard_shortcuts_inventory` — Command Menu inventory
- `tabular_figures_column_width_ui_spec` — Stat / Table / NumberInput tabular-num use
- `touch_target_audit_policy` — minimum-target enforcement
- `storybook_integration` + `storybook_axe_accessibility_fixtures` — Storybook + a11y tests
- `chart_library_integration` — ChartCard wrapper target
- Block 16 Phase 04 — Component library (architecture)

## Open items deferred to later sub-docs

- Per-component depth specs — Layer 2 (Block 16 + per-block UI consumers)
- Specific Radix vs HeadlessUI library selection — Stage 7 implementation
- Per-component test fixtures — Layer 2
