"use client";
import { useSyncExternalStore } from "react";

/** Tailwind `sm` breakpoint — below this we treat the session as mobile. */
const QUERY = "(max-width: 639px)";

function subscribe(cb: () => void) {
  const mql = window.matchMedia(QUERY);
  mql.addEventListener("change", cb);
  return () => mql.removeEventListener("change", cb);
}

/**
 * Hydration-safe viewport check. Server + first client render return false
 * (desktop-first), then it syncs to the real media query. Drives the mobile
 * read-only enforcement (B16·P12): create/edit entry points hide on mobile.
 */
export function useIsMobile(): boolean {
  return useSyncExternalStore(
    subscribe,
    () => window.matchMedia(QUERY).matches,
    () => false,
  );
}
