# Design Token Z-Index Reference

**Category:** Reference · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

This document is the single authoritative source for the z-index token system. It defines all valid z-index values, their intended usage, stacking context parent relationships, and the lint rules that enforce token usage at the call site. No z-index value outside this catalogue is valid without a justified exception comment.

---

## Purpose

Uncontrolled z-index values are a class of UI defect that causes modal overlap, tooltip occlusion, and drill-down panel display failures — all of which are particularly harmful in the finalization approval flow where the step-up MFA modal must always render above all other content. This catalogue locks the z-index surface and makes stacking order predictable across the entire application.

---

## Token catalogue

| token_name | value | usage | stacking_context_parent |
|---|---|---|---|
| `z-base` | 0 | Normal document flow; all non-positioned elements | none |
| `z-sticky` | 100 | Sticky table headers, sticky sidebar navigation | none |
| `z-dropdown` | 200 | Select dropdowns, comboboxes, date pickers | none |
| `z-tooltip` | 300 | Hover tooltips | none |
| `z-slide-over` | 400 | Drill-down slide-over panel | none |
| `z-modal-backdrop` | 500 | Modal overlay backdrop (the dimming layer behind modals) | none |
| `z-modal` | 600 | Modal dialogs — finalization approval modal, bulk action confirm | `z-modal-backdrop` |
| `z-toast` | 700 | Toast notifications (success, error, info) | none |
| `z-step-up-modal` | 800 | Step-up MFA challenge modal; always renders above all other modals | `z-modal` |
| `z-debug-bar` | 900 | Development debug overlay; never rendered in production | none |

---

## Token definitions

### `z-base` (0)

The default stacking level. Elements at this level participate in normal document flow. Using `z-index: 0` explicitly is only necessary when resetting a stacking context created by a parent. In all other cases, elements at `z-base` are simply non-positioned (no `position` property set) or positioned with no explicit z-index.

### `z-sticky` (100)

Applied to elements that use `position: sticky`. Sticky table column headers must be at this level to scroll correctly over body rows without being occluded by dropdowns opened from within a cell. Sticky sidebar navigation uses this level to remain above scrolling content.

Note: sticky elements must not create a new stacking context (no `transform`, no `filter`, no `opacity < 1` on the sticky element itself) or they will fail to remain sticky in some browsers.

### `z-dropdown` (200)

Applied to dropdown menus, combobox option lists, and date picker calendar panels. These are always rendered relative to their trigger element, which sits within the normal document flow. The value 200 ensures dropdowns render above sticky headers (100) but below modals (600).

Dropdowns that are rendered in a portal (appended to `document.body`) rather than inline must still use this token. Portal rendering does not exempt an element from the token system.

### `z-tooltip` (300)

Applied to hover tooltips. Tooltips must render above dropdowns (in case a tooltip is triggered from within a dropdown option), hence the value 300. Tooltips are never interactive; they carry `pointer-events: none`.

### `z-slide-over` (400)

Applied to the drill-down slide-over panel and its internal components. The slide-over panel renders at 400 so it appears above all navigation and interactive elements (sticky headers, dropdowns, tooltips) but below modal backdrops. This is intentional: if a modal is opened while the slide-over is visible (e.g., the finalization modal is triggered from the workflow run detail page), the modal backdrop correctly dims the slide-over.

The slide-over's internal detail panel (720px width state) uses the same `z-slide-over` token — it does not create a separate stacking context.

### `z-modal-backdrop` (500)

Applied to the semi-transparent backdrop overlay that dims the content behind a modal. The backdrop must render above the slide-over panel (400) so the slide-over is included in the dimmed region when a modal is open.

The backdrop element is a full-viewport `position: fixed` div with `background: rgba(0,0,0,0.4)`. It is inserted as a sibling of the modal, not a parent, because making it a parent would require the modal to use a z-index of 1 within its own stacking context, which would break the absolute positioning of the step-up modal above it.

### `z-modal` (600)

Applied to modal dialog containers: the finalization approval modal, the bulk action confirmation modal, and any other blocking dialog. The modal renders above its backdrop (500).

All modals use the same token value. Stacking order between two simultaneously open modals is determined by DOM insertion order — the later-inserted modal renders on top. In normal application flow, only one standard modal should be open at a time. If a second modal must open above an existing modal (e.g., a confirmation prompt within a modal), use `z-step-up-modal` (800) for the inner modal.

### `z-toast` (700)

Applied to toast notification containers. Toasts appear in a fixed position (top-right or bottom-right of the viewport, per the design system configuration) above modals. This is intentional: a success toast confirming an action should be visible even if the triggering modal is still transitioning to its SUCCESS state.

Toast containers use `pointer-events: none` on the container itself; individual toast items use `pointer-events: auto` so they can be dismissed.

### `z-step-up-modal` (800)

Applied exclusively to the step-up MFA challenge modal. This is the highest interactive z-index in the system (excluding the debug bar). The step-up modal must always be visible above all other content because it is a security gate — it must never be obscured by another UI element.

The step-up modal renders above standard modals (600) and toasts (700). If a toast fires during the step-up challenge flow, the toast renders below the step-up modal.

The stacking context parent is `z-modal` — the step-up modal is always triggered from within a standard modal (the finalization approval modal or hold-resolution modal). The `z-step-up-modal` value is set on the step-up modal's own container, which is rendered as a child of the triggering modal. Because the triggering modal has no `transform` or `opacity` applied (it would break positioning), the step-up modal's `position: fixed` positioning escapes the triggering modal's stacking context correctly.

### `z-debug-bar` (900)

Applied to the development debug overlay. This token is defined in the production token set but the debug bar component is excluded from production builds via a build-time flag. If the debug bar is accidentally included in a production build, it renders above all other content, which serves as a visible signal that the build is incorrect.

---

## CSS export

Tokens are exported as CSS custom properties on `:root` in `design_tokens.css`:

```css
:root {
  --z-base: 0;
  --z-sticky: 100;
  --z-dropdown: 200;
  --z-tooltip: 300;
  --z-slide-over: 400;
  --z-modal-backdrop: 500;
  --z-modal: 600;
  --z-toast: 700;
  --z-step-up-modal: 800;
  --z-debug-bar: 900;
}
```

All z-index declarations in CSS and styled-component expressions must reference these custom properties (e.g., `z-index: var(--z-modal)`), not literal integer values.

---

## TypeScript export

Tokens are exported as a typed constant object from `design_tokens.ts`:

```ts
export const Z_INDEX = {
  base: 0,
  sticky: 100,
  dropdown: 200,
  tooltip: 300,
  slideOver: 400,
  modalBackdrop: 500,
  modal: 600,
  toast: 700,
  stepUpModal: 800,
  debugBar: 900,
} as const;

export type ZIndexToken = keyof typeof Z_INDEX;
```

Inline z-index values in TypeScript (e.g., in `style` props or CSS-in-JS) must reference `Z_INDEX.<key>`, not literal integers.

---

## Token lint rules

An ESLint rule `no-hardcoded-zindex` is applied to all `.ts`, `.tsx`, `.css`, and `.scss` files in the repository. The rule:

- Blocks any literal integer z-index value that does not reference a token (e.g., `zIndex: 999`, `z-index: 9999`).
- Blocks CSS custom property references that are not in the `--z-*` namespace.
- Blocks TypeScript references to integer z-index values that are not `Z_INDEX.<key>`.

**Exception:** a hardcoded z-index value is permitted only when accompanied by a `// z-index: justified` comment on the same line (TypeScript) or `/* z-index: justified */` inline comment (CSS). The comment must be followed by a brief reason. Example:

```ts
// z-index: justified — third-party map library forces inline style; cannot use token
style={{ zIndex: 1000 }}
```

Exception usage is tracked by the lint rule and reported in the weekly tech-debt summary. More than five active exceptions triggers a review item.

---

## Stacking context rules

Any component that creates a new stacking context must document which z-index tokens its children rely on. A stacking context is created by any of:

- `position` other than `static` combined with a `z-index` value other than `auto`
- `opacity` less than 1
- `transform` with a non-`none` value
- `will-change: transform` or `will-change: opacity`
- `filter` with a non-`none` value
- `isolation: isolate`

The documentation requirement is a JSDoc comment on the component's exported function or class:

```ts
/**
 * Creates a stacking context via `transform`.
 * Children using z-index tokens: z-dropdown, z-tooltip.
 * Do not apply z-modal or higher within this component.
 */
```

If a component creates a stacking context and contains a child that uses `z-step-up-modal`, a code review must verify that the `position: fixed` children escape the stacking context correctly (they will not if the parent has `transform` or `filter`).

---

## Cross-references

- `dashboard_widget_config_schema.md` — dashboard card component structure; cards use `z-dropdown` for their actions menu
- `drill_down_list_detail_ui_spec.md` — slide-over panel uses `z-slide-over`; detail bottom sheet on mobile uses `z-modal`
- `severity_color_tokens.md` — colour tokens used alongside z-index tokens in issue severity badges and card error states
- `finalization_approval_ui_spec.md` — step-up modal uses `z-step-up-modal`; finalization modal uses `z-modal`
