"use client";
import type { CSSProperties, ReactNode } from "react";
import { AlertCircle, AlertTriangle, CheckCircle2, Info, Octagon, X, type LucideIcon } from "lucide-react";
import { cn } from "@/lib/cn";

export type AlertVariant =
  | "severity-blocking" | "severity-high" | "severity-medium" | "severity-low"
  | "status-success" | "status-info" | "status-danger";

const SEVERITY: Record<string, { icon: LucideIcon; prefix: string }> = {
  "severity-blocking": { icon: Octagon, prefix: "--severity-blocking" },
  "severity-high": { icon: AlertTriangle, prefix: "--severity-high" },
  "severity-medium": { icon: AlertCircle, prefix: "--severity-medium" },
  "severity-low": { icon: Info, prefix: "--severity-low" },
};
const STATUS: Record<string, { icon: LucideIcon; token: string }> = {
  "status-success": { icon: CheckCircle2, token: "--color-status-success" },
  "status-info": { icon: Info, token: "--color-status-info" },
  "status-danger": { icon: AlertCircle, token: "--color-status-danger" },
};

export interface AlertProps {
  variant: AlertVariant;
  title?: ReactNode;
  children?: ReactNode;
  /** Renders a dismiss button; calls back when clicked. */
  onDismiss?: () => void;
  className?: string;
}

/**
 * Alert — severity variants (consume the severity quartet) and status variants
 * (separate family) are enumerated separately and never share token references.
 * Icon + text always paired. blocking/high/danger announce as role="alert";
 * the rest as role="status".
 */
export function Alert({ variant, title, children, onDismiss, className }: AlertProps) {
  const isSeverity = variant.startsWith("severity-");
  const cfg = isSeverity ? SEVERITY[variant] : STATUS[variant];
  const Icon = cfg.icon;
  const assertive = variant === "severity-blocking" || variant === "severity-high" || variant === "status-danger";

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
          background: `color-mix(in srgb, var(${t}) 10%, transparent)`,
        };
      })();
  const iconColor = isSeverity ? `var(${(cfg as { prefix: string }).prefix}-icon)` : undefined;

  return (
    <div
      role={assertive ? "alert" : "status"}
      data-component="alert"
      className={cn("flex gap-3 rounded-md border p-4 text-sm", className)}
      style={style}
    >
      <Icon size={18} strokeWidth={1.5} aria-hidden="true" className="mt-0.5 shrink-0" style={iconColor ? { color: iconColor } : undefined} />
      <div className="min-w-0 flex-1">
        {title && <p className="font-medium">{title}</p>}
        {children && <div className={cn(title && "mt-1", "text-text-secondary")}>{children}</div>}
      </div>
      {onDismiss && (
        <button
          type="button"
          onClick={onDismiss}
          aria-label="Dismiss"
          className="shrink-0 cursor-pointer rounded-sm p-0.5 opacity-70 hover:opacity-100"
        >
          <X size={16} strokeWidth={1.5} aria-hidden="true" />
        </button>
      )}
    </div>
  );
}
