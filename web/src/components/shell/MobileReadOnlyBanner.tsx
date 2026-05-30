"use client";
import { Smartphone } from "lucide-react";
import { useIsMobile } from "./use-is-mobile";

/**
 * Mobile read-only notice (B16·P12). On phones the app is browse-only; create
 * and edit entry points are hidden. This explains why and is announced politely.
 */
export function MobileReadOnlyBanner() {
  const isMobile = useIsMobile();
  if (!isMobile) return null;
  return (
    <div
      role="status"
      className="mb-4 flex items-center gap-2 rounded-md border border-border-subtle bg-bg-raised px-3 py-2 text-xs text-text-secondary"
    >
      <Smartphone size={14} aria-hidden="true" className="shrink-0" />
      <span>Viewing only on mobile. Switch to a larger screen to create or edit.</span>
    </div>
  );
}
