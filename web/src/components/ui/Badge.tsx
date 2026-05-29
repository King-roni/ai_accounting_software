import type { CSSProperties, ReactNode } from "react";
import { AlertCircle, AlertTriangle, CheckCircle2, Circle, Info, Octagon, type LucideIcon } from "lucide-react";
import { cn } from "@/lib/cn";

export type BadgeVariant =
  | "severity-blocking" | "severity-high" | "severity-medium" | "severity-low"
  | "status-success" | "status-info" | "status-neutral";
export type BadgeSize = "sm" | "md";

const SEVERITY: Record<string, { icon: LucideIcon; prefix: string }> = {
  "severity-blocking": { icon: Octagon, prefix: "--severity-blocking" },
  "severity-high": { icon: AlertTriangle, prefix: "--severity-high" },
  "severity-medium": { icon: AlertCircle, prefix: "--severity-medium" },
  "severity-low": { icon: Info, prefix: "--severity-low" },
};

const STATUS: Record<string, { icon: LucideIcon; token: string }> = {
  "status-success": { icon: CheckCircle2, token: "--color-status-success" },
  "status-info": { icon: Info, token: "--color-status-info" },
  "status-neutral": { icon: Circle, token: "--color-text-muted" },
};

const SIZE: Record<BadgeSize, { box: string; icon: number }> = {
  sm: { box: "h-5 px-2 text-xs gap-1", icon: 12 },
  md: { box: "h-6 px-2.5 text-sm gap-1.5", icon: 14 },
};

export interface BadgeProps {
  variant: BadgeVariant;
  size?: BadgeSize;
  /** Visible label. Always paired with the icon (colour is never the only signal). */
  children: ReactNode;
  className?: string;
}

/**
 * Badge — severity variants (Block 14 four-value enum) consume the severity
 * quartet tokens; status variants (success/info/neutral) are a separate family
 * and tint the semantic status token. Icon + text label always render together.
 */
export function Badge({ variant, size = "md", children, className }: BadgeProps) {
  const sz = SIZE[size];
  const isSeverity = variant.startsWith("severity-");
  const cfg = isSeverity ? SEVERITY[variant] : STATUS[variant];
  const Icon = cfg.icon;

  const style: CSSProperties = isSeverity
    ? {
        background: `var(${(cfg as { prefix: string }).prefix}-bg)`,
        borderColor: `var(${(cfg as { prefix: string }).prefix}-border)`,
        color: `var(${(cfg as { prefix: string }).prefix}-text)`,
      }
    : (() => {
        const t = (cfg as { token: string }).token;
        return {
          color: `var(${t})`,
          borderColor: `color-mix(in srgb, var(${t}) 35%, transparent)`,
          background: `color-mix(in srgb, var(${t}) 12%, transparent)`,
        };
      })();

  const iconColor = isSeverity ? `var(${(cfg as { prefix: string }).prefix}-icon)` : undefined;

  return (
    <span
      className={cn("inline-flex items-center rounded-full border font-medium align-middle", sz.box, className)}
      style={style}
      data-component="badge"
    >
      <Icon size={sz.icon} strokeWidth={1.5} aria-hidden="true" style={iconColor ? { color: iconColor } : undefined} />
      {children}
    </span>
  );
}
