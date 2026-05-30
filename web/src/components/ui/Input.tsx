"use client";
import { forwardRef, useId, type InputHTMLAttributes, type ReactNode } from "react";
import type { LucideIcon } from "lucide-react";
import { cn } from "@/lib/cn";

export interface InputProps extends Omit<InputHTMLAttributes<HTMLInputElement>, "size"> {
  label?: string;
  /** When set, the field renders the error state + message and wires aria-invalid/describedby. */
  error?: string;
  /** Persistent helper text below the field (never placeholder-only for complex fields). */
  helperText?: string;
  leadingIcon?: LucideIcon;
  /** Trailing control (clear button, password toggle, etc.). */
  trailingAction?: ReactNode;
  containerClassName?: string;
}

/**
 * Input — default / leading-icon / trailing-action; states default/focus/error/
 * disabled/read-only (read-only is visually distinct from disabled). Inline-
 * validation contract: pass `error` to render the message near the field with
 * aria-invalid + aria-describedby. Use a semantic `type` for correct keyboards.
 */
export const Input = forwardRef<HTMLInputElement, InputProps>(function Input(
  { label, error, helperText, leadingIcon: Leading, trailingAction, className, containerClassName, id, required, disabled, readOnly, ...props },
  ref,
) {
  const autoId = useId();
  const inputId = id ?? autoId;
  const msgId = `${inputId}-msg`;
  const hasError = Boolean(error);

  return (
    <div className={cn("flex flex-col gap-1.5", containerClassName)}>
      {label && (
        <label htmlFor={inputId} className="text-sm font-medium text-text-primary">
          {label}
          {required && <span aria-hidden="true" className="ml-0.5" style={{ color: "var(--color-status-danger)" }}>*</span>}
        </label>
      )}
      <div className="relative flex items-center">
        {Leading && (
          <Leading size={16} strokeWidth={1.5} aria-hidden="true" className="pointer-events-none absolute left-3 text-text-muted" />
        )}
        <input
          ref={ref}
          id={inputId}
          required={required}
          disabled={disabled}
          readOnly={readOnly}
          aria-invalid={hasError || undefined}
          aria-describedby={error || helperText ? msgId : undefined}
          aria-required={required || undefined}
          className={cn(
            "h-9 w-full rounded-lg border bg-bg-base px-3 text-sm text-text-primary placeholder:text-text-muted",
            "transition-colors duration-150 outline-none",
            "focus:border-border-focus focus:ring-2 focus:ring-[var(--color-border-focus)]/35",
            Leading && "pl-9",
            trailingAction && "pr-9",
            hasError
              ? "border-[var(--color-status-danger)] focus:ring-[var(--color-status-danger)]/35"
              : "border-border-default",
            readOnly && "bg-bg-raised",
            disabled && "cursor-not-allowed bg-bg-raised opacity-50",
            className,
          )}
          {...props}
        />
        {trailingAction && <div className="absolute right-2 flex items-center">{trailingAction}</div>}
      </div>
      {(error || helperText) && (
        <p id={msgId} className={cn("text-xs", hasError ? "" : "text-text-muted")} style={hasError ? { color: "var(--color-status-danger)" } : undefined}>
          {error ?? helperText}
        </p>
      )}
    </div>
  );
});
