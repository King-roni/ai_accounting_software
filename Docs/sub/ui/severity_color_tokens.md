# Severity Color Tokens

**Category:** UI specs · **Owning block:** 16 — Dashboard & Reporting · **Co-owning block:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 1 convention)

The four-value severity ramp ({LOW, MEDIUM, HIGH, BLOCKING}) gets its own token set, separate from the generic status ramp (success / warning / danger). Conflating the two leads to subtle UI bugs — for example, a "MEDIUM" review issue rendering as a "warning" with the wrong shade of amber, or `severity-success` colliding with `status-success` and never being meaningful.

The 2026-05-09 Block 16 scan caught the collision (the original draft used `severity-success` as a token name); this sub-doc locks the separation.

---

## Why a separate ramp

The severity enum and the status enum carry different meanings and different mappings to user attention.

| Severity (Block 14 closed enum) | Status (UI generic) |
| --- | --- |
| BLOCKING — gates finalization, blocks the run | success — operation completed |
| HIGH — must be resolved before finalization | warning — non-blocking caution |
| MEDIUM — should be resolved this run | danger — destructive / failed |
| LOW — informational, can be snoozed | info — neutral notification |

A "warning" toast and a "MEDIUM" review issue use different shades by design — the toast says "this transient operation has a caveat", the issue says "this persistent record needs attention before close." Component code that conflates them produces UIs where users can't tell why a color appeared.

## Token structure

Four severity values × four token roles = sixteen tokens per theme.

| Severity | Background | Border | Text | Icon |
| --- | --- | --- | --- | --- |
| BLOCKING | `--severity-blocking-bg` | `--severity-blocking-border` | `--severity-blocking-text` | `--severity-blocking-icon` |
| HIGH | `--severity-high-bg` | `--severity-high-border` | `--severity-high-text` | `--severity-high-icon` |
| MEDIUM | `--severity-medium-bg` | `--severity-medium-border` | `--severity-medium-text` | `--severity-medium-icon` |
| LOW | `--severity-low-bg` | `--severity-low-border` | `--severity-low-text` | `--severity-low-icon` |

Each token resolves differently in light vs dark theme (per `design_system_tokens` two-theme principle).

## Hue palette

Indicative hue assignment, calibrated for distinction across the four values AND distinction from the status ramps.

| Severity | Hue | Rationale |
| --- | --- | --- |
| BLOCKING | red — saturated, calibrated darker than `--color-danger` | Most attention-demanding; must be visually unambiguous |
| HIGH | orange — distinct from BLOCKING red AND from status-warning amber | Second-most attention; "blocking is worse, this is high" gradient is readable |
| MEDIUM | amber — calibrated to be lighter than HIGH orange and distinct from status-warning | Moderate attention; visually softer |
| LOW | blue — informational; distinct from brand-blue | Lowest attention; "noted, will look at it" |

Specific hex calibrations are deferred to Stage 7 implementation. The structural commitment is: each severity has its own quartet, each quartet has light + dark theme calibrations, hues fall in the order red → orange → amber → blue (most to least attention).

## Severity-color usage rules

1. **Severity tokens are used exclusively for severity contexts.** Review issue cards, the queue's severity filter pills, the dashboard's severity-medium card warnings, severity-tagged audit-log entries — these all consume severity tokens.
2. **Status tokens are used exclusively for non-severity contexts.** Toasts, banners, button states, success/error inline messages — these consume status tokens.
3. **Conflation is a lint failure.** A `<Alert variant="severity-medium">` may use severity tokens; a `<Toast variant="warning">` may not use severity tokens.
4. **Component variants enforce the split.** The `Alert` component (per `component_library_ui_spec`) has both status variants AND severity variants — they're enumerated separately and don't share token references.

### Lint enforcement

Stylelint via `design_token_lint_policy` adds a rule:

```jsonc
"severity-token-context-check": {
  "context-properties": {
    "review-card": ["allowed: --severity-*", "denied: --color-status-*"],
    "toast": ["allowed: --color-status-*", "denied: --severity-*"]
  }
}
```

Detected at component-source level via the `data-component` attribute on the root element.

## Color-blind safety

Hue alone is never sufficient to convey severity. Every severity-colored element pairs the color with:

1. **A severity icon** (per `lucide_icon_usage_ui_spec` + Block 14 Phase 09 mobile read-only spec):
   - BLOCKING: `Octagon` (filled, alert-style)
   - HIGH: `AlertTriangle`
   - MEDIUM: `AlertCircle`
   - LOW: `Info`
2. **A severity label** in component code (`aria-label="severity-blocking"`) for screen readers
3. **Position / size** — BLOCKING items appear at the top of the review queue and use larger card surfaces

Color-blind-safe verification:
- Deuteranopia: red and green distinguishable; severity-blocking-red distinct from status-success-green by lightness
- Protanopia: similar — severity-blocking-red passes legibility against severity-medium-amber
- Tritanopia: blue/yellow channel; severity-low-blue distinct from severity-medium-amber

Validation lives in `color_blind_safe_palette_fixtures` (Layer 2, Block 16) — every severity quartet × every theme is rendered against a CB-simulator and checked.

## Component bindings

| Component | Severity binding |
| --- | --- |
| `Alert` | Variants: `severity-blocking`, `severity-high`, `severity-medium`, `severity-low`. Each maps to its quartet. |
| `Badge` | Same severity variants. Used as the severity pill in review-queue cards. |
| ReviewIssueCard (per `review_card_content_prompt` + `Docs/sub/ui/review_issue_card_ui_spec.md`) | Card border + accent uses severity tokens. |
| Dashboard severity-medium card warnings | Card status indicator uses severity tokens — never status tokens. |

## Cross-references

- `design_system_tokens` — generic status ramp + raw color ramps (separate from this sub-doc)
- `design_token_lint_policy` — enforcement, including severity / status separation
- `component_library_ui_spec` — `Alert` and `Badge` variant inventory
- `lucide_icon_usage_ui_spec` — severity icon mapping
- `severity_enum` — the closed 4-value enum this ramp parallels
- `color_blind_safe_palette_fixtures` — CB validation
- Block 14 Phase 02 — severity routing and assignment (architecture)
- Block 14 Phase 09 — mobile read-only severity rendering with required icon
- Block 16 Phase 03 — design system MASTER (architecture)

## Open items deferred to later sub-docs

- Specific calibrated hex values per severity × theme — Stage 7 implementation
- Per-severity Storybook stories — `storybook_axe_accessibility_fixtures` (Layer 2, Block 16)
- Color-blind validation fixtures — `color_blind_safe_palette_fixtures` (Layer 2, Block 16)

---

## Dark-mode color variants

Each severity token resolves to a different value in dark mode. The structural convention:

| Severity | Light-mode hue direction | Dark-mode hue direction | Rationale |
| --- | --- | --- | --- |
| BLOCKING | Deep red background, light red border, dark red text | Dark red background (desaturated), bright red border and icon, off-white text | Dark UIs need higher-contrast border; background must not be full-saturated red (eye fatigue) |
| HIGH | Orange background, dark-orange border, dark-orange text | Dark orange background (desaturated), bright orange border, off-white text | Same logic as BLOCKING — reduce saturation on bg, raise contrast on border |
| MEDIUM | Amber background, dark-amber border, dark-amber text | Dark amber background, bright amber border, off-white text | Amber is already lower saturation; dark mode shifts bg dark, border bright |
| LOW | Blue-tinted background, blue border, blue text | Dark blue background, bright blue border, off-white text | Blue is readable at full saturation in dark mode; same contrast pattern |

Token naming convention for dark-mode variants — via CSS `prefers-color-scheme` override in the design-system token file:

```css
@media (prefers-color-scheme: dark) {
  :root {
    --severity-blocking-bg:     <dark-mode value>;
    --severity-blocking-border: <dark-mode value>;
    --severity-blocking-text:   <dark-mode value>;
    --severity-blocking-icon:   <dark-mode value>;
    /* ... repeated for high, medium, low */
  }
}
```

The same 16 token names are used in both themes. Components reference the token; the CSS media query handles the theme switch. No component-level theme conditional is needed.

Specific hex values are deferred to Stage 7 (`color_blind_safe_palette_fixtures`) — this section commits to the structural convention only.

---

## WCAG accessibility contrast ratios

Per WCAG 2.1 AA requirements: text on colored backgrounds must achieve a contrast ratio of at least 4.5:1 for normal-size text and 3:1 for large text (18pt+ or 14pt bold+). All severity tokens must pass AA. The project targets AAA (7:1) for BLOCKING and HIGH given their critical role in user attention.

| Severity | Token pair | Target contrast | Applies to |
| --- | --- | --- | --- |
| BLOCKING | `--severity-blocking-text` on `--severity-blocking-bg` | ≥ 7:1 (AAA target) | Review card body text |
| BLOCKING | `--severity-blocking-icon` on `--severity-blocking-bg` | ≥ 3:1 (AA, graphical) | Icon rendering inside card |
| HIGH | `--severity-high-text` on `--severity-high-bg` | ≥ 7:1 (AAA target) | Review card body text |
| HIGH | `--severity-high-icon` on `--severity-high-bg` | ≥ 3:1 (AA, graphical) | Icon rendering |
| MEDIUM | `--severity-medium-text` on `--severity-medium-bg` | ≥ 4.5:1 (AA) | Review card body text |
| MEDIUM | `--severity-medium-icon` on `--severity-medium-bg` | ≥ 3:1 (AA, graphical) | Icon rendering |
| LOW | `--severity-low-text` on `--severity-low-bg` | ≥ 4.5:1 (AA) | Review card body text |
| LOW | `--severity-low-icon` on `--severity-low-bg` | ≥ 3:1 (AA, graphical) | Icon rendering |

Additionally, each severity's border token must have ≥ 3:1 contrast against the surrounding neutral background (the card container background, not the severity-tinted card background) — this ensures the card boundary is visible without relying on color recognition alone.

These ratios apply to both light and dark themes independently. Each theme variant is tested separately in `storybook_axe_accessibility_fixtures`.

Border-on-neutral contrast check:

| Severity | Token | Checked against | Target |
| --- | --- | --- | --- |
| BLOCKING | `--severity-blocking-border` | `--color-surface-default` (neutral card container) | ≥ 3:1 |
| HIGH | `--severity-high-border` | `--color-surface-default` | ≥ 3:1 |
| MEDIUM | `--severity-medium-border` | `--color-surface-default` | ≥ 3:1 |
| LOW | `--severity-low-border` | `--color-surface-default` | ≥ 3:1 |

---

## Additional cross-references

- `design_system_tokens` — raw color ramps, neutral surface tokens, `--color-surface-default`
- `review_queue_filter_schema` — severity filter pills that consume severity tokens for their active state
