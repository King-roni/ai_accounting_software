# Design System Tokens

**Category:** UI specs · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 1 convention)

The single source of truth for color, typography, spacing, radii, elevation, motion, and breakpoints. Stripe / Linear / Mercury / Pleo polish bar — clean, dense, trust-conveying. Two themes (light + dark) calibrated independently, not just inverted. Inter / Inter Display / JetBrains Mono fonts.

This sub-doc defines the token names, scales, and indicative values. Final calibration of specific hex values happens during Stage 7 implementation against component compositions; this sub-doc commits to the structure and the anti-patterns.

`design_token_lint_policy` enforces token usage; this sub-doc defines the tokens.

---

## Foundation principles

1. **Two themes, separately calibrated.** Light and dark are not inversions. Each has its own raw color ramp, its own elevation recipe (light shadows in light theme, no shadows + subtle borders in dark), its own contrast accents.
2. **Semantic tokens over raw tokens at component sites.** Components consume `--color-text-primary`, not `--color-neutral-900`. Raw tokens exist as the implementation layer; semantic tokens are the consumed surface.
3. **Hue alone never carries severity meaning.** Severity is always paired with an icon (per `severity_color_tokens` and Block 14 Phase 09). Color-blind safety is mandatory.
4. **No purple/pink AI gradients.** No emojis as icons. No raw hex outside token files. No removing focus rings. (These are also enforced by lint per `design_token_lint_policy`.)
5. **Tabular figures default for numeric columns.** Currency, dates, IDs, counts all use `font-variant-numeric: tabular-nums`.

## Color tokens

### Raw ramps

Six ramps. Each runs `50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950`.

| Ramp | Purpose | Indicative anchor |
| --- | --- | --- |
| `--color-neutral-*` | Backgrounds, borders, text, surfaces | Cool gray, slight blue cast — calibrated for clean financial UI |
| `--color-brand-*` | Primary brand — actions, focus, links | Trustworthy blue, NOT purple-leaning. Mercury / Stripe-light blue territory |
| `--color-success-*` | Status-success only (NOT severity) | Forest green, calibrated for legibility on neutral surfaces |
| `--color-warning-*` | Status-warning only (NOT severity) | Amber, calibrated to be distinct from severity-amber |
| `--color-danger-*` | Status-danger only (NOT severity) | Crimson, calibrated to be distinct from severity-blocking-red |
| `--color-info-*` | Informational, non-actionable accents | Cyan-leaning blue, distinct from brand-blue |

Severity has its own ramps in `severity_color_tokens` — explicitly separated from the status ramps above per the 2026-05-09 fix to avoid the `severity-success` ↔ `status-success` collision.

### Semantic tokens

Component code consumes semantic tokens, not raw ramps:

| Semantic token | Light theme references | Dark theme references |
| --- | --- | --- |
| `--color-text-primary` | `--color-neutral-900` | `--color-neutral-50` |
| `--color-text-secondary` | `--color-neutral-700` | `--color-neutral-200` |
| `--color-text-muted` | `--color-neutral-500` | `--color-neutral-400` |
| `--color-text-on-primary` | white | `--color-neutral-50` |
| `--color-bg-base` | white | `--color-neutral-950` |
| `--color-bg-raised` | `--color-neutral-50` | `--color-neutral-900` |
| `--color-bg-overlay` | white | `--color-neutral-800` |
| `--color-bg-canvas` | `--color-neutral-100` | `--color-neutral-950` |
| `--color-border-subtle` | `--color-neutral-200` | `--color-neutral-800` |
| `--color-border-strong` | `--color-neutral-400` | `--color-neutral-600` |
| `--color-border-focus` | `--color-brand-500` | `--color-brand-400` |
| `--color-action-primary` | `--color-brand-600` | `--color-brand-500` |
| `--color-action-hover` | `--color-brand-700` | `--color-brand-400` |
| `--color-action-active` | `--color-brand-800` | `--color-brand-300` |
| `--color-action-disabled` | `--color-neutral-300` | `--color-neutral-700` |
| `--color-status-success` | `--color-success-700` | `--color-success-300` |
| `--color-status-warning` | `--color-warning-700` | `--color-warning-300` |
| `--color-status-danger` | `--color-danger-700` | `--color-danger-300` |

### Anti-patterns (binding)

- No raw hex outside `theme/tokens/**`
- No purple/pink AI-style gradients
- No neon, fluorescent, or "playful" colors
- No emojis as icons (Lucide icons only — see `lucide_icon_usage_ui_spec`)
- No removing focus rings
- No conditional removal of borders to "clean up" (use `--color-border-subtle` set to `transparent` if needed)

## Typography

### Font families

```
--font-ui:      "Inter", system-ui, -apple-system, sans-serif;
--font-display: "Inter Display", "Inter", system-ui, sans-serif;
--font-mono:    "JetBrains Mono", ui-monospace, "SF Mono", monospace;
```

Inter and Inter Display are pinned by SHA in `pdf_generation_policies` for PDF generation (and the same SHAs are used in the web UI for visual consistency between web and exported PDFs).

### Type scale

| Token | Size | Line height | Use |
| --- | --- | --- | --- |
| `--text-xs` | 12px | 16px | Microcopy, captions, table headers |
| `--text-sm` | 14px | 20px | Body small, labels, table cells |
| `--text-md` | 16px | 24px | Body default |
| `--text-lg` | 18px | 28px | Section subtitles, card titles |
| `--text-xl` | 20px | 28px | Card titles, modal headers |
| `--text-2xl` | 24px | 32px | Page section headers |
| `--text-3xl` | 30px | 36px | Page titles |
| `--text-display` | 48px | 56px | Dashboard hero numbers, PDF cover headlines |

PDF cover pages use an extended display scale (`--text-display-lg`, `--text-display-xl`) defined in `extended_display_type_scale_ui_spec` (Layer 2, Block 16).

### Letter-spacing

| Token | Value | Use |
| --- | --- | --- |
| `--tracking-tight` | -0.02em | Display headers |
| `--tracking-normal` | 0 | Body |
| `--tracking-wide` | 0.05em | Uppercase labels |

### Tabular figures

Numeric columns and currency cells use `font-variant-numeric: tabular-nums` — pinned in `tabular_figures_column_width_ui_spec` (Layer 2, Block 16).

## Spacing

4px base unit. Scale (in 4px multiples):

| Token | px | Use |
| --- | --- | --- |
| `--space-0` | 0 | — |
| `--space-1` | 4 | Hair gap |
| `--space-2` | 8 | Tight stack |
| `--space-3` | 12 | Default stack |
| `--space-4` | 16 | Comfortable stack, icon+text gap |
| `--space-5` | 20 | Card internal padding |
| `--space-6` | 24 | Page section gap |
| `--space-8` | 32 | Page content margin |
| `--space-10` | 40 | Major section break |
| `--space-12` | 48 | — |
| `--space-16` | 64 | Page header / hero spacing |
| `--space-20` | 80 | — |
| `--space-24` | 96 | — |
| `--space-32` | 128 | Top-of-page hero pad on dashboards |

Off-scale values are not allowed. If a layout needs `14px`, the answer is to use `--space-3` (12) or `--space-4` (16) and adjust the layout.

## Radii

| Token | px | Use |
| --- | --- | --- |
| `--radius-none` | 0 | Tables, lists |
| `--radius-sm` | 4 | Tags, chips |
| `--radius-md` | 6 | Inputs, buttons |
| `--radius-lg` | 8 | Cards |
| `--radius-xl` | 12 | Modal, drawer |
| `--radius-full` | 9999 | Avatars, pill buttons |

## Elevation (shadows)

Stripe-style multi-layer shadows. Light theme uses subtle shadow; dark theme uses subtle inner glow + border emphasis instead of cast shadow.

| Token | Light theme | Dark theme |
| --- | --- | --- |
| `--shadow-0` | none | none |
| `--shadow-1` | hairline border + 1px subtle drop | border-only emphasis |
| `--shadow-2` | 0 1px 3px rgba — raised surface | 1px inner glow + border |
| `--shadow-3` | 0 4px 12px rgba — modal/drawer | 0 4px 12px deeper rgba + border |
| `--shadow-4` | 0 8px 24px rgba — popover/menu | matching deeper recipe |
| `--shadow-5` | 0 12px 32px rgba — toast | matching deeper recipe |

Specific rgba calibrations are deferred to Stage 7 implementation; this sub-doc commits to the structure and per-theme asymmetry.

## Motion

| Token | Duration | Easing | Use |
| --- | --- | --- | --- |
| `--motion-instant` | 0ms | — | State changes that should feel immediate |
| `--motion-fast` | 100ms | `--easing-standard` | Hover, focus, micro-interactions |
| `--motion-medium` | 200ms | `--easing-standard` | Tabs, popovers, drawer slides |
| `--motion-slow` | 300ms | `--easing-decelerate` | Modal entrance, large surface swaps |

Easing curves:

```
--easing-linear:     linear;
--easing-standard:   cubic-bezier(0.4, 0.0, 0.2, 1);
--easing-decelerate: cubic-bezier(0.0, 0.0, 0.2, 1);
--easing-accelerate: cubic-bezier(0.4, 0.0, 1, 1);
```

### Reduced motion

`@media (prefers-reduced-motion: reduce)` overrides every motion token to `0ms`. Component code never branches on reduced-motion explicitly; the token system handles it.

## Breakpoints

| Token | px | Use |
| --- | --- | --- |
| `--bp-sm` | 640 | Mobile-large boundary |
| `--bp-md` | 768 | Tablet boundary |
| `--bp-lg` | 1024 | Small desktop |
| `--bp-xl` | 1280 | Standard desktop |
| `--bp-2xl` | 1536 | Wide desktop |

Mobile is read-only per Stage 1 decision; settings, exports, and resolution actions reject `client_form_factor = MOBILE` (per `mobile_write_rejection_endpoints`).

## Z-index

Defined in `z_index_canonical_reference` (Reference data, Block 16). Components reference `var(--z-modal)`, `var(--z-toast)`, `var(--z-popover)`, etc.

## Cross-references

- `design_token_lint_policy` — enforcement
- `component_library_ui_spec` — components consuming these tokens
- `severity_color_tokens` — specialized severity ramps
- `z_index_canonical_reference` — z-index scale
- `lucide_icon_usage_ui_spec` — icon convention
- `pdf_generation_policies` — Inter / Inter Display / JetBrains Mono SHAs
- `tabular_figures_column_width_ui_spec` — tabular-num enforcement
- `extended_display_type_scale_ui_spec` — PDF cover-page extended scale
- Block 16 Phase 03 — design system MASTER (architecture)

## Open items deferred to later sub-docs

- Specific calibrated hex values per theme (light + dark) — Stage 7 implementation
- Per-theme shadow rgba calibrations — Stage 7 implementation
- Storybook stories per token — `storybook_axe_accessibility_fixtures` (Layer 2, Block 16)
- Color-blind safe palette validation — `color_blind_safe_palette_fixtures` (Layer 2, Block 16)
