/**
 * Design tokens — TypeScript surface (R1.1, impl of B16·P03).
 *
 * The CSS custom properties in `app/globals.css` are the runtime source of
 * truth for *values*; this module exposes the *structural* tokens that JS/TS
 * needs at runtime (z-index ordering, breakpoint pixels, the severity enum and
 * its token/icon bindings). Component code references these constants instead
 * of hardcoding integers (enforced by `no-hardcoded-zindex`, see z-index ref).
 *
 * For colors/spacing/radii in component styles, prefer the CSS vars
 * (`var(--color-text-primary)`) or Tailwind utilities (`text-text-primary`),
 * not literals.
 */

/** Canonical z-index scale (z_index_canonical_reference). */
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

/** Breakpoint pixel boundaries (match --bp-* / Tailwind screens). */
export const BREAKPOINTS = {
  sm: 640,
  md: 768,
  lg: 1024,
  xl: 1280,
  "2xl": 1536,
} as const;
export type Breakpoint = keyof typeof BREAKPOINTS;

/** Spacing scale in px (4px base). Mirrors --space-*. */
export const SPACE = {
  0: 0, 1: 4, 2: 8, 3: 12, 4: 16, 5: 20, 6: 24, 8: 32,
  10: 40, 12: 48, 16: 64, 20: 80, 24: 96, 32: 128,
} as const;

/** Radii in px. Mirrors --radius-*. */
export const RADIUS = {
  none: 0, sm: 4, md: 6, lg: 8, xl: 12, full: 9999,
} as const;

/** Type scale: [font-size px, line-height px]. Mirrors --text-* / --leading-*. */
export const TYPE_SCALE = {
  xs: [12, 16], sm: [14, 20], md: [16, 24], lg: [18, 28],
  xl: [20, 28], "2xl": [24, 32], "3xl": [30, 36], display: [48, 56],
} as const;

/** Motion durations (ms) and easing curves. Mirrors --motion-* / --easing-*. */
export const MOTION = {
  duration: { instant: 0, fast: 100, medium: 200, slow: 300 },
  easing: {
    linear: "linear",
    standard: "cubic-bezier(0.4, 0, 0.2, 1)",
    decelerate: "cubic-bezier(0, 0, 0.2, 1)",
    accelerate: "cubic-bezier(0.4, 0, 1, 1)",
  },
} as const;

/**
 * Severity — the closed 4-value enum from Block 14 P02. Ordered most→least
 * attention (red → orange → amber → blue). Each value binds to its CSS token
 * quartet (--severity-<value>-{bg,border,text,icon}), a Lucide icon name, and
 * an aria-label. Hue alone NEVER conveys severity (color-blind safety) — the
 * icon + label are mandatory companions.
 */
export const SEVERITY_ORDER = ["BLOCKING", "HIGH", "MEDIUM", "LOW"] as const;
export type Severity = (typeof SEVERITY_ORDER)[number];

export const SEVERITY_META: Record<
  Severity,
  { icon: string; ariaLabel: string; tokenPrefix: string; rank: number }
> = {
  BLOCKING: { icon: "Octagon", ariaLabel: "severity-blocking", tokenPrefix: "--severity-blocking", rank: 0 },
  HIGH: { icon: "AlertTriangle", ariaLabel: "severity-high", tokenPrefix: "--severity-high", rank: 1 },
  MEDIUM: { icon: "AlertCircle", ariaLabel: "severity-medium", tokenPrefix: "--severity-medium", rank: 2 },
  LOW: { icon: "Info", ariaLabel: "severity-low", tokenPrefix: "--severity-low", rank: 3 },
} as const;

/** Status family — separate from severity (completion/health, not problems). */
export const STATUS = ["success", "warning", "danger", "info"] as const;
export type Status = (typeof STATUS)[number];

/** Standard Lucide icon sizes per surface (px). */
export const ICON_SIZE = { table: 16, nav: 20, kpi: 24 } as const;

export type Theme = "light" | "dark";
