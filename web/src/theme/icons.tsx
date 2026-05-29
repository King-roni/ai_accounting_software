/**
 * Lucide icon convention (R1.1, impl of B16·P03 icon system).
 *
 * - Library: Lucide outline, stroke-width 1.5 across the product.
 * - Standard sizes: 16 (table), 20 (nav), 24 (kpi) — see ICON_SIZE.
 * - No emojis as structural icons. Icon-only controls require an aria-label.
 * - Severity color is ALWAYS paired with its icon + a screen-reader label
 *   (color is never the only signal — color-blind safety).
 */
import { AlertCircle, AlertTriangle, Info, Octagon, type LucideIcon } from "lucide-react";
import { ICON_SIZE, SEVERITY_META, type Severity } from "./tokens";

export { ICON_SIZE };
export const ICON_STROKE_WIDTH = 1.5;

/** Severity → Lucide component. Mirrors SEVERITY_META[].icon. */
export const SEVERITY_ICON: Record<Severity, LucideIcon> = {
  BLOCKING: Octagon,
  HIGH: AlertTriangle,
  MEDIUM: AlertCircle,
  LOW: Info,
};

export interface SeverityIconProps {
  severity: Severity;
  /** px; defaults to table size (16). */
  size?: number;
  className?: string;
}

/**
 * Renders the severity's icon in its `--severity-<v>-icon` token color with the
 * mandatory aria-label. Use inside review-issue cards, severity pills, etc.
 */
export function SeverityIcon({ severity, size = ICON_SIZE.table, className }: SeverityIconProps) {
  const Icon = SEVERITY_ICON[severity];
  const meta = SEVERITY_META[severity];
  return (
    <Icon
      size={size}
      strokeWidth={ICON_STROKE_WIDTH}
      className={className}
      role="img"
      aria-label={meta.ariaLabel}
      style={{ color: `var(${meta.tokenPrefix}-icon)` }}
    />
  );
}
