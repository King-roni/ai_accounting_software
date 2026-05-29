# Design Token Lint Policy

**Category:** Policies · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 1 convention)

Lint rules that prevent raw values (hex colors, arbitrary spacing, raw font sizes, raw radii, raw shadows) from appearing in component code. Tokens — defined in `design_system_tokens` — are the single source of truth. The lint enforces the abstraction.

Without this lint, the design system erodes within weeks: developers reach for the "right" color from memory, drift accumulates, and the Stripe/Linear/Mercury polish bar collapses. The lint is non-optional; failure blocks merges.

---

## Stylelint rules

The project uses Stylelint for CSS / SCSS / styled-components / Tailwind `@apply` blocks.

### `declaration-property-value-disallowed-list`

Bans raw hex colors anywhere except files marked as token sources:

```jsonc
{
  "rules": {
    "declaration-property-value-disallowed-list": {
      "/.*/": [
        "/#[0-9a-fA-F]{3,8}/",   // raw hex
        "/rgb\\(/",              // raw rgb / rgba
        "/hsl\\(/",              // raw hsl / hsla
        "/oklch\\(/"             // raw oklch
      ]
    }
  }
}
```

Override only in files marked as token sources (see "Override mechanism" below).

### Spacing

Bans raw pixel / rem / em values for properties that should always go through tokens:

| Property | Use token | Anti-pattern |
| --- | --- | --- |
| `margin*`, `padding*` | `var(--space-N)` | `padding: 12px` |
| `gap` | `var(--space-N)` | `gap: 8px` |
| `top`, `right`, `bottom`, `left` (positioning) | `var(--space-N)` or layout tokens | `top: 4px` |

### Typography

Bans raw font sizes and line heights:

| Property | Use token | Anti-pattern |
| --- | --- | --- |
| `font-size` | `var(--text-N)` (xs / sm / md / lg / xl / 2xl / 3xl / display) | `font-size: 14px` |
| `line-height` | `var(--leading-N)` | `line-height: 1.4` |
| `letter-spacing` | `var(--tracking-N)` | `letter-spacing: -0.01em` |
| `font-family` | `var(--font-N)` (ui / display / mono) | `font-family: 'Inter'` |

### Radii

```
border-radius: var(--radius-N);   // OK
border-radius: 8px;               // ANTI
```

### Shadows

```
box-shadow: var(--shadow-N);                   // OK
box-shadow: 0 1px 2px rgba(0,0,0,0.1);         // ANTI
box-shadow: 0 1px 2px var(--color-overlay-1);  // ANTI — composed shadows belong in tokens
```

### Z-index

Bans raw z-index values:

```
z-index: var(--z-modal);   // OK
z-index: 100;              // ANTI
```

The canonical z-index scale is `z_index_canonical_reference` (Reference data, Block 16).

## ESLint rules (for inline styles)

For inline styles in JSX (`style={{ ... }}`), an ESLint rule mirrors the Stylelint disallowed list:

```jsonc
{
  "rules": {
    "no-restricted-syntax": [
      "error",
      {
        "selector": "JSXAttribute[name.name='style'] Property[key.name='backgroundColor'] Literal[value=/^#/]",
        "message": "Use color tokens (var(--color-...)) instead of raw hex"
      }
      // ... similar for each property
    ]
  }
}
```

The same set of properties as Stylelint applies (color, spacing, typography, radii, shadows, z-index).

Inline styles are discouraged generally — components should compose token-driven CSS classes — but where they're used, the lint enforces the token abstraction.

## TypeScript token guard

A typed `theme.ts` exports every token name. Components that consume the theme do so through this typed surface:

```ts
import { tokens } from "@/theme";

<div style={{ color: tokens.color.text.primary }} />
```

Free-form string colors (`<div style={{ color: "red" }} />`) fail TypeScript compilation against the typed `style` prop. The project uses `csstype` augmentation to narrow `style.color` to `${string} | TokenColorReference`.

## Override mechanism

Token files themselves are the only place raw values are allowed. A file is marked as a token source by including this comment in the first 5 lines:

```
/* design-token-source: true */
```

Files matching `theme/tokens/**` are auto-allowed without the comment. Outside this directory, the comment is required. Files with the comment are exempt from the disallowed-list rules but still must:

- Define every token through the canonical token schema
- Reference the master design_system_tokens spec for naming
- Not export raw values; export only token references

## CI integration

| Stage | Action |
| --- | --- |
| Pre-commit hook | Stylelint + ESLint run on staged files; block if any violation |
| PR CI | Full Stylelint + ESLint pass; block merge if any violation |
| Periodic (weekly) | Storybook visual regression runs through `visual_regression_baseline_runbook` to catch token drift not caught by lint |

A violation of these rules cannot be merged. Override requires an amendment with explicit rationale (rare — examples: a tightly-scoped third-party library wrapper that requires inline values).

## Migration path

When a new token is added (e.g., a new spacing value `--space-14`):

1. Token file updated, value added
2. Codemod runs over the codebase: `--space-14` is the closest token to any flagged raw value matching `12px`–`16px` not already using `--space-12` or `--space-16`
3. Flagged sites are reviewed manually before bulk replacement
4. PR for the codemod, separate from the token-add PR (clean attribution)

## Cross-references

- `design_system_tokens` — canonical token names and values
- `component_library_ui_spec` — components that consume the tokens
- `severity_color_tokens` — specialized severity ramp using the same lint
- `z_index_canonical_reference` — z-index token catalogue
- Block 16 Phase 03 — design system MASTER (architecture)
- Block 16 Phase 04 — component library

## Open items deferred to later sub-docs

- The codemod implementation — Stage 4 sub-doc / Stage 7 build
- Specific token names for newly-introduced properties (e.g., backdrop-filter blur scales) — added to `design_system_tokens` as needed
