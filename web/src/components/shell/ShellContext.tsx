"use client";
import { createContext, useCallback, useContext, useState, useSyncExternalStore, type ReactNode } from "react";

export interface Business {
  id: string;
  display_name: string;
  organization_id: string;
}
export interface ShellUser {
  /** public.users.id — the actor id RPCs expect (not auth.users.id). */
  id: string;
  email: string;
  displayName: string | null;
}
/** Accounting period; month is 1-12. The period is shell-state (not per-card)
 *  so changing it updates every consumer without a page reload (B16·P05). */
export interface Period {
  year: number;
  month: number;
}

const LS_BUSINESS = "cb.currentBusinessId";
const LS_SIDEBAR = "cb.sidebarCollapsed";
const MULTI = "__all__";
const LS_EVENT = "cb:ls-change";

export function formatPeriod(p: Period): string {
  return new Intl.DateTimeFormat("en-GB", { month: "long", year: "numeric" }).format(new Date(p.year, p.month - 1, 1));
}
export function stepPeriod(p: Period, dir: 1 | -1): Period {
  const idx = p.year * 12 + (p.month - 1) + dir;
  return { year: Math.floor(idx / 12), month: (idx % 12) + 1 };
}

// localStorage-backed prefs, read hydration-safely via useSyncExternalStore.
function lsSubscribe(cb: () => void) {
  window.addEventListener("storage", cb);
  window.addEventListener(LS_EVENT, cb);
  return () => {
    window.removeEventListener("storage", cb);
    window.removeEventListener(LS_EVENT, cb);
  };
}
function lsWrite(key: string, value: string | null) {
  if (value === null) localStorage.removeItem(key);
  else localStorage.setItem(key, value);
  window.dispatchEvent(new Event(LS_EVENT));
}
function useLS(key: string): string | null {
  return useSyncExternalStore(lsSubscribe, () => localStorage.getItem(key), () => null);
}

interface ShellContextValue {
  user: ShellUser;
  businesses: Business[];
  currentBusiness: Business | null;
  setCurrentBusinessId: (id: string | null) => void;
  /** null selection = multi-business overview (offered only when >= 2 businesses). */
  isMultiBusiness: boolean;
  period: Period;
  setPeriod: (p: Period) => void;
  sidebarCollapsed: boolean;
  toggleSidebar: () => void;
  paletteOpen: boolean;
  setPaletteOpen: (b: boolean) => void;
  notifOpen: boolean;
  setNotifOpen: (b: boolean) => void;
}

const ShellContext = createContext<ShellContextValue | null>(null);

export function useShell(): ShellContextValue {
  const ctx = useContext(ShellContext);
  if (!ctx) throw new Error("useShell must be used within <ShellProvider>");
  return ctx;
}

export function ShellProvider({
  user,
  businesses,
  initialPeriod,
  children,
}: {
  user: ShellUser;
  businesses: Business[];
  initialPeriod: Period;
  children: ReactNode;
}) {
  const [period, setPeriod] = useState<Period>(initialPeriod);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [notifOpen, setNotifOpen] = useState(false);

  const rawBiz = useLS(LS_BUSINESS);
  const sidebarCollapsed = useLS(LS_SIDEBAR) === "1";

  const isMultiBusiness = rawBiz === MULTI && businesses.length >= 2;
  const currentBusinessId = isMultiBusiness
    ? null
    : rawBiz && rawBiz !== MULTI && businesses.some((b) => b.id === rawBiz)
      ? rawBiz
      : businesses[0]?.id ?? null;
  const currentBusiness = businesses.find((b) => b.id === currentBusinessId) ?? null;

  const setCurrentBusinessId = useCallback((id: string | null) => {
    lsWrite(LS_BUSINESS, id === null ? MULTI : id);
  }, []);
  const toggleSidebar = useCallback(() => {
    lsWrite(LS_SIDEBAR, localStorage.getItem(LS_SIDEBAR) === "1" ? "0" : "1");
  }, []);

  return (
    <ShellContext.Provider
      value={{
        user,
        businesses,
        currentBusiness,
        setCurrentBusinessId,
        isMultiBusiness,
        period,
        setPeriod,
        sidebarCollapsed,
        toggleSidebar,
        paletteOpen,
        setPaletteOpen,
        notifOpen,
        setNotifOpen,
      }}
    >
      {children}
    </ShellContext.Provider>
  );
}
