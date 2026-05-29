# Design System MASTER

Canonical design tokens for every user-facing surface in the Cyprus Bookkeeping SaaS product. This file is the **single source of truth**; components reference tokens by name (`var(--token)`), never raw hex.

Product positioning: **Stripe / Linear / Mercury / Pleo** SaaS polish — clean, dense, trust-conveying — not Notion-cute, not consumer-AI, not playful.

**Phase**: B16·P03 (BOOK-150) · **Source spec**: `Docs/phases/16_dashboard_and_reporting/03_design_system_master.md`

---

## Spacing scale (4 / 8 px-rooted)

| Token | Value | Typical use |
|---|---|---|
| `space-0` | 0 | flush |
| `space-1` | 4 px | hair-line gaps, badge padding |
| `space-2` | 8 px | inline element separation |
| `space-3` | 12 px | input internal padding |
| `space-4` | 16 px | card internal padding, between sibling fields |
| `space-5` | 20 px | section sub-block gap |
| `space-6` | 24 px | card-to-card on canvas, modal padding |
| `space-8` | 32 px | section gap |
| `space-10` | 40 px | hero / page-header gap |
| `space-12` | 48 px | marketing surfaces |
| `space-16` | 64 px | marketing surfaces |

**Density rule.** Dashboard surfaces use the tighter side (4 / 8 / 16 dominate). Marketing / landing surfaces use the wider side (24 / 32 / 48). Whitespace reinforces grouping — never padding for padding's sake.

---

## Color palette (light + dark, independently calibrated)

Dark mode is NOT a mathematical inversion. Each token's dark-mode value is independently picked to meet WCAG AA on its own pair.

### Primary brand

| Token | Light | Dark |
|---|---|---|
| `color-primary` | `#2563EB` | `#3B82F6` |
| `color-primary-hover` | `#1D4ED8` | `#60A5FA` |
| `color-primary-active` | `#1E40AF` | `#93C5FD` |

### Surface scale

| Token | Light | Dark |
|---|---|---|
| `surface-0` | `#FFFFFF` | `#0B0F17` |
| `surface-1` | `#F8FAFC` | `#11151E` |
| `surface-2` | `#F1F5F9` | `#1A2030` |
| `surface-3` | `#E2E8F0` | `#252D40` |

### Text scale

| Token | Light | Dark |
|---|---|---|
| `text-primary` | `#0F172A` | `#F1F5F9` |
| `text-secondary` | `#475569` | `#94A3B8` |
| `text-tertiary` | `#94A3B8` | `#64748B` |
| `text-on-primary` | `#FFFFFF` | `#FFFFFF` |
| `text-link` | `#2563EB` | `#60A5FA` |

### Borders / dividers

| Token | Light | Dark |
|---|---|---|
| `border-subtle` | `#E2E8F0` | `#1F2937` |
| `border-default` | `#CBD5E1` | `#334155` |
| `border-strong` | `#94A3B8` | `#475569` |

### Severity tokens (maps ONLY to Block 14 P02 enum)

| Token | Light | Dark | Maps to | Icon (Lucide) |
|---|---|---|---|---|
| `severity-low` | `#94A3B8` | `#64748B` | `LOW` | `Info` |
| `severity-medium` | `#F59E0B` | `#FBBF24` | `MEDIUM` | `AlertTriangle` |
| `severity-high` | `#DC2626` | `#EF4444` | `HIGH` | `AlertOctagon` |
| `severity-blocking` | `#B91C1C` | `#DC2626` | `BLOCKING` | `ShieldAlert` |

There is **NO** `severity-success`. Positive completion uses `status-success` (see next table). This separation is non-negotiable — see Severity-vs-status separation rule below.

### Status tokens (separate family for completion / health states)

| Token | Light | Dark | Typical use |
|---|---|---|---|
| `status-success` | `#16A34A` | `#22C55E` | Finalized periods, paid invoices, completed runs, healthy archive verification |
| `status-info` | `#2563EB` | `#3B82F6` | In-progress / informational badges (aliased to primary) |
| `status-neutral` | `#94A3B8` | `#64748B` | Default state |

### Focus ring

2 px solid `#2563EB` (light) / `#3B82F6` (dark) with 2 px offset against background. Visible on all interactive elements via `:focus-visible`.

---

## Typography system

| Role | Family | Weights | Notes |
|---|---|---|---|
| Body | **Inter** | 300–700 (variable) | `font-display: swap`; default for prose, labels, table cells |
| Headings | **Inter Display** | 500–700 | Tighter-tracked Inter variant; dashboard heading hierarchy |
| Tabular / numeric | **JetBrains Mono** | 400–600 | Transaction amounts, invoice numbers, hashes, IDs; `font-feature-settings: 'tnum'` on every numeric column |

### Type scale (6 steps)

| Token | Size | Typical use |
|---|---|---|
| `type-12` | 12 px | Axis labels, compact metadata |
| `type-14` | 14 px | Table-cell default |
| `type-16` | 16 px | **Body baseline** |
| `type-18` | 18 px | Card title |
| `type-24` | 24 px | Section heading |
| `type-32` | 32 px | Page title |

### Line-height & weight

- `line-height-body`: 1.5 (body, table cells)
- `line-height-heading`: 1.25 (headings)
- `line-height-compact`: 1.4 (compact metadata)

Weight hierarchy: **700** (page titles) · **600** (card headings, table headers) · **500** (labels, KPIs) · **400** (body, table cells) · **300** (rarely used; very large display only).

Letter-spacing: default Inter. **Tighter** (-0.01em) for headings ≥ 24 px; **looser** (+0.02em) for 12 px metadata.

---

## Elevation scale (3 levels max; `elev-0` = no shadow)

| Token | Light shadow | Dark shadow | Use |
|---|---|---|---|
| `elev-0` | (none) | (none) | Page surface, table rows |
| `elev-1` | `0 1px 3px rgba(15, 23, 42, 0.06), 0 1px 2px rgba(15, 23, 42, 0.04)` | cooler-toned darker variant (sub-doc) | Cards, subtle hover |
| `elev-2` | `0 4px 6px rgba(15, 23, 42, 0.05), 0 2px 4px rgba(15, 23, 42, 0.06)` | cooler-toned darker variant (sub-doc) | Popovers, dropdowns |
| `elev-3` | `0 20px 25px rgba(15, 23, 42, 0.10), 0 10px 10px rgba(15, 23, 42, 0.04)` | cooler-toned darker variant (sub-doc) | Modals, drawers |

Dark mode uses higher-opacity black with cooler tone. Sub-doc owns the exact dark-mode shadow tokens.

---

## Radius scale

| Token | Value | Use |
|---|---|---|
| `radius-sm` | 4 px | Inputs, badges |
| `radius-md` | 8 px | Buttons, cards, expanded table rows |
| `radius-lg` | 12 px | Modals, drawers, command palette |
| `radius-xl` | 16 px | Hero / marketing surfaces only (NOT dashboard) |
| `radius-full` | 9999 px | Avatars, status pills |

---

## Motion tokens

| Token | Value | Use |
|---|---|---|
| `motion-duration-instant` | 0 ms | State-only changes that don't move |
| `motion-duration-fast` | 150 ms | Micro-interactions, hover, focus |
| `motion-duration-normal` | 200 ms | Most state transitions |
| `motion-duration-slow` | 300 ms | Modal enter, drawer slide |

| Token | Value | Use |
|---|---|---|
| `motion-easing-enter` | `cubic-bezier(0, 0, 0.2, 1)` | Ease-out (enter) |
| `motion-easing-exit` | `cubic-bezier(0.4, 0, 1, 1)` | Ease-in (exit; ~70% of enter duration) |
| `motion-easing-spring` | CSS `linear()` polyfill or framer-motion spring physics | Press feedback only |

**`prefers-reduced-motion`** respected: all durations collapse to `motion-duration-instant`; spring physics disabled.

---

## Severity colour-coding rules

Severity color appears **with** an icon — never on its own. Per the UX rule `color-not-only`.

| Open issue severity | Card treatment |
|---|---|
| (none) | Neutral surface, no badge |
| `LOW` / `MEDIUM` | `severity-medium` left-border accent (4 px), small severity badge top-right |
| `HIGH` | `severity-high` left-border accent + count badge |
| `BLOCKING` | `severity-blocking` full bordered card with bold severity label |

Icon mapping: see Severity tokens table above. Screen-reader text echoes the severity name; color is never the only signal.

---

## Icon system

- **Library**: **Lucide** outline at 16 / 20 / 24 px standard sizes.
- **Stroke width**: 1.5 across the product.
- **Style discipline**: outline default. Filled only for active-state nav items and status pills.
- **No emojis as structural icons.** Anywhere in the dashboard. Period.

Size guidance (per surface):

| Context | Size |
|---|---|
| Nav (sidebar) | 20 px |
| Table inline | 16 px |
| KPI cards | 24 px |

---

## Focus state policy

- Every interactive element shows a 2 px solid ring on `:focus-visible`.
- Tab order matches visual order.
- Skip-to-main-content link on the dashboard shell (B16·P05).

---

## Dark-mode parity

- Every token has light AND dark values declared together.
- Dark-mode palette is desaturated / lifted — **never inverted**.
- Independent contrast testing: dark-mode `text-primary` on `surface-0` meets WCAG AA 4.5:1 **separately** from light mode.

---

## Token implementation

Tokens are exposed as CSS custom properties on `:root`, with dark mode toggled by `[data-theme="dark"]`:

```css
:root {
  /* spacing */
  --space-0: 0;
  --space-1: 4px;
  --space-2: 8px;
  /* ...etc */

  /* color (light) */
  --color-primary: #2563EB;
  --surface-0: #FFFFFF;
  --text-primary: #0F172A;
  --severity-low: #94A3B8;
  --severity-medium: #F59E0B;
  --severity-high: #DC2626;
  --severity-blocking: #B91C1C;
  --status-success: #16A34A;
  /* ...etc */
}

[data-theme="dark"] {
  --color-primary: #3B82F6;
  --surface-0: #0B0F17;
  --text-primary: #F1F5F9;
  --severity-low: #64748B;
  --severity-medium: #FBBF24;
  --severity-high: #EF4444;
  --severity-blocking: #DC2626;
  --status-success: #22C55E;
  /* ...etc */
}
```

Components reference tokens by name (`var(--surface-0)`), never raw hex. Sub-doc owns the exhaustive `:root` block + TypeScript export.

---

## Severity-vs-status separation rule

**Do NOT add `severity-success`.** Severity is a four-value enum from Block 14 P02: `{LOW, MEDIUM, HIGH, BLOCKING}`. Positive completion ("paid invoice", "finalized period", "healthy archive") uses the separate `status-success` family.

Reviewing engineers who feel the urge to add a green severity are conflating two orthogonal axes: severity (how urgent is this *problem*?) vs status (is this *thing* done?). They are different concepts and must use different tokens.

---

## Anti-patterns (the canonical "do not" list)

1. **No emojis as structural icons.** Use Lucide.
2. **No AI purple/pink gradients.** Cyprus accounting product, not consumer-AI.
3. **No playful color use.** Semantic colors for state only — never decorative.
4. **No mixing flat + skeuomorphic.** One visual language across the product.
5. **No removing focus rings.** Visible `:focus-visible` ring is non-negotiable.
6. **No icon-only buttons without `aria-label`.** Accessibility floor.
7. **No raw hex in components.** Always tokens (`var(--token-name)`).

Enforcement: Stage 1 — manual review checklist + a future Stylelint / ESLint "token-only-no-raw-hex" rule (sub-doc).

---

## Per-page overrides

`Docs/design-system/pages/` houses page-specific token overrides where a single surface (e.g., marketing landing, accountant export pack, invoice PDF cover) intentionally diverges from the dashboard baseline. The override file documents the divergence + the token-level diff + the rationale.

Stage 1: directory created; no overrides shipped yet.

---

## Sub-doc hooks (deferred Stage 4)

- CSS / TypeScript token export — exact `:root` block; framework integration
- Dark-mode shadow tokens — cooler-toned blacks; per-elevation values
- Lucide icon usage — sizing per context; stroke width discipline
- Tabular-figures column-width budget — preventing layout shift in tables
- Extended display type scale — PDF cover pages and marketing surfaces (36 / 48 / 64 pt)
- Token lint rules — Stylelint / ESLint enforcement
- Per-page override examples — Stripe / Linear / Mercury patterns
- Severity-icon mapping — per-severity icon + color combo with screen-reader text
