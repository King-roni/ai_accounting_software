"use client";
import { forwardRef, useId, type ReactNode, type SelectHTMLAttributes } from "react";
import { ChevronDown } from "lucide-react";
import { cn } from "@/lib/cn";

export interface SelectProps extends Omit<SelectHTMLAttributes<HTMLSelectElement>, "size"> {
  label?: string;
  error?: string;
  helperText?: string;
  containerClassName?: string;
  children: ReactNode;
}

/**
 * Select — single-select built on the native <select> for first-class keyboard
 * and screen-reader support (arrows/type-ahead/Enter/Escape come free). Styled
 * to match Input; same label/error/helper + aria wiring. Multi-select and
 * searchable combobox are separate components (deferred).
 */
export const Select = forwardRef<HTMLSelectElement, SelectProps>(function Select(
  { label, error, helperText, className, containerClassName, id, required, disabled, children, ...props },
  ref,
) {
  const autoId = useId();
  const selId = id ?? autoId;
  const msgId = `${selId}-msg`;
  const hasError = Boolean(error);

  return (
    <div className={cn("flex flex-col gap-1.5", containerClassName)}>
      {label && (
        <label htmlFor={selId} className="text-sm font-medium text-text-primary">
          {label}
          {required && <span aria-hidden="true" className="ml-0.5" style={{ color: "var(--color-status-danger)" }}>*</span>}
        </label>
      )}
      <div className="relative flex items-center">
        <select
          ref={ref}
          id={selId}
          required={required}
          disabled={disabled}
          aria-invalid={hasError || undefined}
          aria-describedby={error || helperText ? msgId : undefined}
          className={cn(
            "h-10 w-full appearance-none rounded-sm border bg-bg-base pl-3 pr-9 text-sm text-text-primary",
            "transition-colors duration-150 outline-none",
            "focus:border-border-focus focus:ring-2 focus:ring-[var(--color-border-focus)]/35",
            hasError ? "border-[var(--color-status-danger)] focus:ring-[var(--color-status-danger)]/35" : "border-border-default",
            disabled && "cursor-not-allowed bg-bg-raised opacity-50",
            className,
          )}
          {...props}
        >
          {children}
        </select>
        <ChevronDown size={16} strokeWidth={1.5} aria-hidden="true" className="pointer-events-none absolute right-3 text-text-muted" />
      </div>
      {(error || helperText) && (
        <p id={msgId} className={cn("text-xs", hasError ? "" : "text-text-muted")} style={hasError ? { color: "var(--color-status-danger)" } : undefined}>
          {error ?? helperText}
        </p>
      )}
    </div>
  );
});
