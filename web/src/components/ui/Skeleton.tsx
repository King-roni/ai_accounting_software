import type { CSSProperties } from "react";
import { cn } from "@/lib/cn";

export interface SkeletonProps {
  className?: string;
  width?: number | string;
  height?: number | string;
  /** Pill shape (avatars, chips). */
  rounded?: boolean;
}

/**
 * Skeleton — placeholder for loads > 300ms. Pulses by default; collapses to a
 * static bar under prefers-reduced-motion. Wrap a loading region and set
 * aria-busy on the container so completion announces via aria-live.
 */
export function Skeleton({ className, width, height, rounded }: SkeletonProps) {
  const style: CSSProperties = { width, height };
  return (
    <span
      aria-hidden="true"
      className={cn(
        "block animate-pulse bg-border-subtle motion-reduce:animate-none",
        rounded ? "rounded-full" : "rounded-md",
        className,
      )}
      style={style}
    />
  );
}

/** Convenience: N stacked text-line skeletons. */
export function SkeletonText({ lines = 3, className }: { lines?: number; className?: string }) {
  return (
    <div className={cn("flex flex-col gap-2", className)} aria-hidden="true">
      {Array.from({ length: lines }).map((_, i) => (
        <Skeleton key={i} height={12} className={i === lines - 1 ? "w-2/3" : "w-full"} />
      ))}
    </div>
  );
}
