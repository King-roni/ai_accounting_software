"use client";
import { forwardRef, type ButtonHTMLAttributes, type ReactNode } from "react";
import { Loader2, type LucideIcon } from "lucide-react";
import { cn } from "@/lib/cn";

export type ButtonVariant = "primary" | "secondary" | "tertiary" | "danger" | "ghost";
export type ButtonSize = "sm" | "md" | "lg";

const VARIANT: Record<ButtonVariant, string> = {
  primary: "bg-action-primary text-text-on-primary hover:bg-action-hover active:bg-action-active",
  secondary: "bg-bg-base text-text-primary border border-border-default hover:bg-bg-raised",
  tertiary: "bg-transparent text-text-primary hover:bg-bg-raised",
  danger: "bg-danger-600 text-white hover:bg-danger-700 active:bg-danger-800",
  ghost: "bg-transparent text-text-secondary hover:bg-bg-raised hover:text-text-primary",
};

const SIZE: Record<ButtonSize, string> = {
  sm: "h-8 px-3 text-sm",
  md: "h-10 px-4 text-sm",
  lg: "h-12 px-5 text-md",
};

const SPAN_GAP: Record<ButtonSize, string> = { sm: "gap-1.5", md: "gap-2", lg: "gap-2" };

const ICON_PX: Record<ButtonSize, number> = { sm: 16, md: 16, lg: 20 };

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  size?: ButtonSize;
  /** Renders a spinner in place of the label; width stays stable. Sets aria-busy. */
  loading?: boolean;
  leadingIcon?: LucideIcon;
  trailingIcon?: LucideIcon;
  /** Icon-only: pass an aria-label (enforced via TS below) and omit children. */
  children?: ReactNode;
}

/**
 * Button — variants primary/secondary/tertiary/danger/ghost; sizes sm/md/lg.
 * Native <button> (Enter/Space). Focus-visible ring is global. Disabled and
 * loading both block interaction; loading keeps width stable and sets aria-busy.
 * Icon-only buttons MUST pass aria-label (no visible text).
 */
export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  {
    variant = "primary",
    size = "md",
    loading = false,
    leadingIcon: Leading,
    trailingIcon: Trailing,
    disabled,
    className,
    children,
    type = "button",
    ...props
  },
  ref,
) {
  const isDisabled = disabled || loading;
  const icon = ICON_PX[size];
  return (
    <button
      ref={ref}
      type={type}
      disabled={isDisabled}
      aria-disabled={isDisabled || undefined}
      aria-busy={loading || undefined}
      className={cn(
        "relative inline-flex items-center justify-center rounded-md font-medium whitespace-nowrap select-none cursor-pointer",
        "transition-colors duration-150 ease-[var(--ease-standard)]",
        "active:scale-[0.98] motion-reduce:active:scale-100",
        "disabled:opacity-50 disabled:pointer-events-none disabled:cursor-not-allowed",
        VARIANT[variant],
        SIZE[size],
        className,
      )}
      {...props}
    >
      {loading && (
        <Loader2 size={icon} strokeWidth={1.5} className="absolute animate-spin" aria-hidden="true" />
      )}
      <span className={cn("inline-flex items-center", SPAN_GAP[size], loading && "invisible")}>
        {Leading && <Leading size={icon} strokeWidth={1.5} aria-hidden="true" />}
        {children}
        {Trailing && <Trailing size={icon} strokeWidth={1.5} aria-hidden="true" />}
      </span>
    </button>
  );
});
