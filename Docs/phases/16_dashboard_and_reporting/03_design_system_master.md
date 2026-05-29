# Block 16 — Phase 03: Design System MASTER

## References

- Block doc: `Docs/blocks/16_dashboard_and_reporting.md` (Default Dashboard Views; Permission-Aware Rendering)
- Block doc: `Docs/blocks/01_core_principles.md` (Principle 5 — Simple Interface, Advanced Backend)
- UI/UX skill: `ui-ux-pro-max:ui-ux-pro-max` design system recommendation (Minimalism & Swiss Style; data-dense SaaS; no AI-purple/pink gradients)

## Phase Goal

Pin the canonical design tokens that every dashboard surface in Block 16 (and by extension every user-facing surface across the product) consumes: spacing scale, color palette (light + dark calibrated independently), typography system, elevation, radius, motion timing, focus states, severity colour-coding. Persist as `design-system/MASTER.md` per the UI/UX skill's hierarchical-retrieval pattern. After this phase, Phase 04's component library has a stable token foundation; Phases 05–08 can compose against it.

The product positioning is **Stripe / Linear / Mercury / Pleo** SaaS polish — clean, dense, trust-conveying — not Notion-cute, not consumer-AI, not playful.

## Dependencies

- Phase 01 (`dashboard_card_definitions.severity_rule_ref` references the severity tokens declared here)
- Block 14 Phase 02 (severity enum `{LOW, MEDIUM, HIGH, BLOCKING}` — the design tokens map to these four levels)
- Block 14 Phase 03 (card-content rendering — consumes severity colours from here)

## Deliverables

- **Persisted artefact:** `design-system/MASTER.md` in the project root, generated via the UI/UX skill's `--persist` flag and edited to reflect the Stage 1 decisions below. Per-page overrides land in `design-system/pages/<page-name>.md`.
- **Spacing scale (4 / 8 px-rooted system):**
  - Tokens: `space-0` (0), `space-1` (4 px), `space-2` (8 px), `space-3` (12 px), `space-4` (16 px), `space-5` (20 px), `space-6` (24 px), `space-8` (32 px), `space-10` (40 px), `space-12` (48 px), `space-16` (64 px).
  - **Density rule:** dashboard surfaces use the tighter side of the scale (4 / 8 / 16 dominate). Marketing / landing surfaces use the wider side (24 / 32 / 48). Per the UX rule `whitespace-balance`, each section's spacing reinforces grouping rather than padding for padding's sake.
- **Color palette (light + dark calibrated independently per the UX rule `color-dark-mode`):**
  - **Primary brand:** `#2563EB` (light primary; trust-conveying blue per the design-system search; close to Stripe / Linear). Dark-mode variant: `#3B82F6` (slightly lifted for contrast on dark surfaces).
  - **Surface scale (light):** `surface-0` (`#FFFFFF` page background), `surface-1` (`#F8FAFC` subtle elevation, sidebar), `surface-2` (`#F1F5F9` cards on canvas), `surface-3` (`#E2E8F0` table rows zebra-striping).
  - **Surface scale (dark):** `surface-0` (`#0B0F17` near-black with a hint of blue), `surface-1` (`#11151E`), `surface-2` (`#1A2030`), `surface-3` (`#252D40`). Independently contrast-tested against text tokens (NOT inverted from light mode).
  - **Text scale (light):** `text-primary` (`#0F172A`), `text-secondary` (`#475569`), `text-tertiary` (`#94A3B8`), `text-on-primary` (`#FFFFFF`), `text-link` (`#2563EB`).
  - **Text scale (dark):** `text-primary` (`#F1F5F9`), `text-secondary` (`#94A3B8`), `text-tertiary` (`#64748B`), `text-on-primary` (`#FFFFFF`), `text-link` (`#60A5FA`).
  - **Border / divider:** `border-subtle` (`#E2E8F0` light; `#1F2937` dark), `border-default` (`#CBD5E1` light; `#334155` dark), `border-strong` (`#94A3B8` light; `#475569` dark).
  - **Semantic colours (severity colour-coding for the dashboard cards per architecture):**
    - **`severity-low`** — gray (`#94A3B8` light; `#64748B` dark). Informational only.
    - **`severity-medium`** — amber (`#F59E0B` light; `#FBBF24` dark). Warns without alarm.
    - **`severity-high`** — red (`#DC2626` light; `#EF4444` dark). Action needed.
    - **`severity-blocking`** — red with bolder treatment + bordered badge (`#B91C1C` light; `#DC2626` dark). Cannot proceed.
  - **Severity tokens map ONLY to Block 14 Phase 02's four-value enum** `{LOW, MEDIUM, HIGH, BLOCKING}`. There is NO `severity-success` — positive completion states use a separate token family below.
  - **Status tokens (separate from severity; for confirmation / completion / health states):**
    - **`status-success`** — green (`#16A34A` light; `#22C55E` dark). Used for finalized periods, paid invoices, completed runs, healthy archive verification — anything that is "done well", not a severity level.
    - **`status-info`** — blue (matches `primary`). Used for in-progress / informational badges.
    - **`status-neutral`** — gray (`#94A3B8` light; `#64748B` dark). Default state.
  - **Focus ring:** 2 px solid `#2563EB` light / `#3B82F6` dark with 2 px offset against background. Visible on all interactive elements per the UX rule `focus-states`.
  - **Anti-patterns enforced:** no AI purple/pink gradients (per the design-system search); no neon; no playful color use; semantic colors for state only — never decorative.
- **Typography system:**
  - **Body face:** **Inter** (variable, weights 300–700) — the canonical SaaS sans-serif (Stripe, Linear, Vercel). Loaded with `font-display: swap`.
  - **Heading face:** **Inter Display** (the tighter-tracked Inter variant) for the dashboard's heading hierarchy. The UI/UX-skill search returned Calistoga as a heading suggestion — rejected here as too boutique for a Cyprus accounting product. Sub-doc may revisit if branding adds a wordmark.
  - **Numeric / tabular face:** **JetBrains Mono** (per the design-system search) for transaction amounts, invoice numbers, hashes, IDs in tables. Tabular figures (`font-feature-settings: 'tnum'`) on every numeric column to prevent column-width jitter.
  - **Type scale (6 steps; per the UX rule `font-scale`):** 12 / 14 / 16 / 18 / 24 / 32 px. 16 px is the body baseline; 14 px is the table-cell default; 12 px is reserved for axis labels and compact metadata.
  - **Line-height:** 1.5 for body / table cells; 1.25 for headings; 1.4 for compact metadata. Per the UX rule `line-height`.
  - **Weight hierarchy:** 700 (page titles), 600 (card headings, table headers), 500 (labels, KPIs), 400 (body, table cells), 300 (rarely used; reserved for very large display text).
  - **Letter-spacing:** default Inter spacing; tighter (-0.01em) for headings ≥ 24 px; looser (+0.02em) for 12 px metadata to maintain readability.
- **Elevation scale (3 levels max per the UX rule `elevation-consistent`):**
  - `elev-0` — no shadow (page surface, table rows).
  - `elev-1` — `0 1px 3px rgba(15, 23, 42, 0.06), 0 1px 2px rgba(15, 23, 42, 0.04)` (cards, subtle hover).
  - `elev-2` — `0 4px 6px rgba(15, 23, 42, 0.05), 0 2px 4px rgba(15, 23, 42, 0.06)` (popovers, dropdowns).
  - `elev-3` — `0 20px 25px rgba(15, 23, 42, 0.10), 0 10px 10px rgba(15, 23, 42, 0.04)` (modals, drawers).
  - Dark mode uses higher-opacity black with cooler tone — sub-doc owns the exact dark-mode shadow tokens.
- **Radius scale:**
  - `radius-sm` (4 px — inputs, badges).
  - `radius-md` (8 px — buttons, cards, table rows in expanded states).
  - `radius-lg` (12 px — modals, drawers, command palette).
  - `radius-xl` (16 px — hero / marketing surfaces only; not used in dashboard).
  - `radius-full` (9999 px — avatars, status pills).
- **Motion tokens (per the UX rules `duration-timing`, `easing`, `exit-faster-than-enter`):**
  - `motion-duration-instant` (0 — for state-only changes that don't move).
  - `motion-duration-fast` (150 ms — micro-interactions, hover, focus).
  - `motion-duration-normal` (200 ms — most state transitions).
  - `motion-duration-slow` (300 ms — modal enter, drawer slide).
  - `motion-easing-enter` (`cubic-bezier(0, 0, 0.2, 1)` — ease-out).
  - `motion-easing-exit` (`cubic-bezier(0.4, 0, 1, 1)` — ease-in; exit ~70% of enter duration).
  - `motion-easing-spring` (CSS `linear()` polyfill or framer-motion spring physics for press feedback per the UX rule `spring-physics`).
  - **`prefers-reduced-motion`** respected: motion durations collapse to `motion-duration-instant`; spring physics disabled.
- **Severity colour-coding rules** (the dashboard-card highlighting from the architecture doc):
  - Card with no open issues → neutral surface, no badge.
  - Card with `LOW` / `MEDIUM` open → `severity-medium` left-border accent (4 px), small severity badge top-right.
  - Card with `HIGH` open → `severity-high` left-border accent + count badge.
  - Card with `BLOCKING` open → `severity-blocking` full bordered card with bold severity label.
  - Severity colours are NEVER the only signal — every severity carries an icon (Lucide `Info` / `AlertTriangle` / `AlertOctagon` / `ShieldAlert`) per the UX rule `color-not-only`.
- **Icon system:**
  - **Library:** **Lucide** (per the UX rule `no-emoji-icons`) at 16 / 20 / 24 px standard sizes. Stroke width 1.5 (per `stroke-consistency`). One filled-or-outline style across the product (outline default; filled only for active-state nav and status pills per `filled-vs-outline-discipline`).
  - **No emojis as structural icons.** Anywhere in the dashboard. Period.
- **Focus state policy:**
  - Every interactive element shows a 2 px solid ring on `:focus-visible` (per `focus-states`).
  - Tab order matches visual order (per `keyboard-nav`).
  - Skip-to-main-content link on the dashboard shell (Phase 05).
- **Dark-mode parity:**
  - Every token has a light AND dark value declared together (per `dark-mode-pairing`).
  - Dark-mode palette is desaturated / lifted — never inverted (per the UX rule `color-dark-mode`).
  - Independent contrast testing — the dark-mode `text-primary` on `surface-0` meets WCAG AA 4.5:1 separately from light-mode (per `color-accessible-pairs`).
- **Token implementation:**
  - Tokens exposed as CSS custom properties (`--space-4`, `--color-primary`, `--text-primary`, etc.) with a single `:root` block per theme. Dark mode toggled by `[data-theme="dark"]` on the root. Components reference tokens by name, never raw hex (per `color-semantic`).
  - Sub-doc owns the exact CSS / TypeScript token export.
- **Anti-patterns enforced (consolidated; the canonical "do not" list for this product):**
  - No emojis as icons.
  - No AI purple/pink gradients.
  - No playful color use.
  - No mixing flat + skeuomorphic.
  - No removing focus rings.
  - No icon-only buttons without `aria-label`.
  - No layout-shifting press feedback.
  - No raw hex in components — always tokens.

## Definition of Done

- `design-system/MASTER.md` exists at the project root with the canonical tokens above.
- Light + dark palettes are independently contrast-verified at WCAG AA.
- Severity tokens map to the four-value enum from Block 14 Phase 02 with icons attached (color-not-only).
- Inter + Inter Display + JetBrains Mono are loaded with `font-display: swap` and tabular-figures enabled on numeric columns.
- Motion respects `prefers-reduced-motion`.
- Every interactive token has a focus-ring style.
- Anti-pattern list is enforced via lint rules (sub-doc tracks; Stage 1 default — manual review checklist + a token-only-no-raw-hex linter).
- Per-page overrides folder `design-system/pages/` is created (empty).

## Sub-doc Hooks (Stage 4)

- **CSS / TypeScript token export sub-doc** — exact `:root` block; dark-theme block; framework integration.
- **Dark-mode shadow tokens sub-doc** — cooler-toned blacks; per-elevation values.
- **Lucide icon usage sub-doc** — sizing per context (nav 20 px, table inline 16 px, KPIs 24 px); stroke width.
- **Tabular-figures column-width budget sub-doc** — preventing layout shift in tables with currency / numeric data.
- **Extended display type scale sub-doc** — for PDF cover pages and marketing surfaces (36 / 48 / 64 pt), not part of the dashboard 6-step scale.
- **Token lint rules sub-doc** — enforcement mechanism (e.g., Stylelint / ESLint rule banning raw hex in component files).
- **Per-page override examples sub-doc** — reference Stripe / Linear / Mercury patterns for marketing vs dashboard vs settings pages.
- **Severity-icon mapping sub-doc** — per-severity icon + color combo with screen-reader text.
