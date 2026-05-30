"use client";
import { forwardRef, useId, type TextareaHTMLAttributes } from "react";
import { cn } from "@/lib/cn";

export interface TextareaProps extends TextareaHTMLAttributes<HTMLTextAreaElement> {
  label?: string;
  error?: string;
  helperText?: string;
  containerClassName?: string;
}

/**
 * Textarea — same inline-validation contract as Input. Min 3 rows; grows with
 * content up to the consumer's `rows`/CSS max, then scrolls.
 */
export const Textarea = forwardRef<HTMLTextAreaElement, TextareaProps>(function Textarea(
  { label, error, helperText, className, containerClassName, id, required, disabled, readOnly, rows = 3, ...props },
  ref,
) {
  const autoId = useId();
  const taId = id ?? autoId;
  const msgId = `${taId}-msg`;
  const hasError = Boolean(error);

  return (
    <div className={cn("flex flex-col gap-1.5", containerClassName)}>
      {label && (
        <label htmlFor={taId} className="text-sm font-medium text-text-primary">
          {label}
          {required && <span aria-hidden="true" className="ml-0.5" style={{ color: "var(--color-status-danger)" }}>*</span>}
        </label>
      )}
      <textarea
        ref={ref}
        id={taId}
        rows={rows}
        required={required}
        disabled={disabled}
        readOnly={readOnly}
        aria-invalid={hasError || undefined}
        aria-describedby={error || helperText ? msgId : undefined}
        aria-required={required || undefined}
        className={cn(
          "w-full resize-y rounded-lg border bg-bg-base px-3 py-2 text-sm text-text-primary placeholder:text-text-muted",
          "max-h-[18rem] min-h-[4.5rem] transition-colors duration-150 outline-none",
          "focus:border-border-focus focus:ring-2 focus:ring-[var(--color-border-focus)]/35",
          hasError ? "border-[var(--color-status-danger)] focus:ring-[var(--color-status-danger)]/35" : "border-border-default",
          readOnly && "bg-bg-raised",
          disabled && "cursor-not-allowed bg-bg-raised opacity-50",
          className,
        )}
        {...props}
      />
      {(error || helperText) && (
        <p id={msgId} className={cn("text-xs", hasError ? "" : "text-text-muted")} style={hasError ? { color: "var(--color-status-danger)" } : undefined}>
          {error ?? helperText}
        </p>
      )}
    </div>
  );
});
