import type { ReactNode } from "react";
import { AlertOctagon, Inbox, type LucideIcon } from "lucide-react";
import { cn } from "@/lib/cn";
import { Button } from "./Button";

export interface EmptyStateProps {
  icon?: LucideIcon;
  heading: string;
  body?: ReactNode;
  action?: ReactNode;
  className?: string;
}

/** EmptyState — shown for 0 rows / 0 issues / no data. */
export function EmptyState({ icon: Icon = Inbox, heading, body, action, className }: EmptyStateProps) {
  return (
    <div
      className={cn(
        "flex flex-col items-center justify-center gap-3 rounded-md bg-bg-raised px-6 py-12 text-center",
        className,
      )}
    >
      <Icon size={32} strokeWidth={1.5} className="text-text-muted" aria-hidden="true" />
      <h3 className="text-lg font-semibold text-text-primary">{heading}</h3>
      {body && <p className="max-w-sm text-sm text-text-secondary">{body}</p>}
      {action && <div className="mt-1">{action}</div>}
    </div>
  );
}

export interface ErrorStateProps {
  heading?: string;
  description?: ReactNode;
  onRetry?: () => void;
  className?: string;
}

/** ErrorState — a query failed or a non-recoverable error blocks the surface. */
export function ErrorState({
  heading = "Something went wrong",
  description = "We couldn't load this. Try again.",
  onRetry,
  className,
}: ErrorStateProps) {
  return (
    <div
      role="alert"
      className={cn("flex flex-col items-center justify-center gap-3 rounded-md px-6 py-12 text-center", className)}
    >
      <AlertOctagon size={32} strokeWidth={1.5} aria-hidden="true" style={{ color: "var(--color-status-danger)" }} />
      <h3 className="text-lg font-semibold text-text-primary">{heading}</h3>
      {description && <p className="max-w-sm text-sm text-text-secondary">{description}</p>}
      {onRetry && (
        <Button variant="secondary" size="sm" onClick={onRetry} className="mt-1">
          Try again
        </Button>
      )}
    </div>
  );
}
