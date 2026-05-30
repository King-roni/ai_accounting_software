import type { CSSProperties, HTMLAttributes, ReactNode } from "react";
import { cn } from "@/lib/cn";

export type CardAccent =
  | "default" | "severity-low" | "severity-medium" | "severity-high" | "severity-blocking" | "status-success";

const ACCENT_VAR: Record<Exclude<CardAccent, "default">, string> = {
  "severity-low": "var(--severity-low-border)",
  "severity-medium": "var(--severity-medium-border)",
  "severity-high": "var(--severity-high-border)",
  "severity-blocking": "var(--severity-blocking-border)",
  "status-success": "var(--color-status-success)",
};

export interface CardProps extends HTMLAttributes<HTMLDivElement> {
  /** Left-border accent. severity-* map to severity tokens; status-success for completion. */
  accent?: CardAccent;
  /** Clickable cards lift to elev-2 on hover. */
  interactive?: boolean;
  children: ReactNode;
}

/**
 * Card — surface container at elev-1 (elev-2 hover when interactive). Optional
 * left-border accent for severity / completed states. Pair with CardHeader/
 * CardBody/CardFooter; set aria-labelledby on the Card pointing at the title.
 */
export function Card({ accent = "default", interactive = false, className, children, style, ...props }: CardProps) {
  const accentStyle: CSSProperties =
    accent === "default"
      ? {}
      : { borderLeftWidth: 4, borderLeftColor: ACCENT_VAR[accent], borderLeftStyle: "solid" };
  return (
    <div
      role="region"
      data-component="card"
      className={cn(
        "rounded-xl border border-border-subtle bg-surface-default shadow-1",
        interactive && "cursor-pointer transition-shadow duration-150 hover:shadow-2",
        className,
      )}
      style={{ ...accentStyle, ...style }}
      {...props}
    >
      {children}
    </div>
  );
}

export function CardHeader({ className, children, ...props }: HTMLAttributes<HTMLDivElement>) {
  return (
    <div className={cn("flex items-start justify-between gap-3 p-5 pb-3", className)} {...props}>
      {children}
    </div>
  );
}

export function CardTitle({ className, children, ...props }: HTMLAttributes<HTMLHeadingElement>) {
  return (
    <h3 className={cn("text-lg font-semibold text-text-primary", className)} {...props}>
      {children}
    </h3>
  );
}

export function CardBody({ className, children, ...props }: HTMLAttributes<HTMLDivElement>) {
  return (
    <div className={cn("px-5 pb-5 text-sm text-text-secondary", className)} {...props}>
      {children}
    </div>
  );
}

export function CardFooter({ className, children, ...props }: HTMLAttributes<HTMLDivElement>) {
  return (
    <div className={cn("flex items-center gap-2 border-t border-border-subtle px-5 py-3", className)} {...props}>
      {children}
    </div>
  );
}
