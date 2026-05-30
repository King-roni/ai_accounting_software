"use client";
import { useEffect, type ReactNode } from "react";
import { ToastProvider } from "@/components/ui";
import { cn } from "@/lib/cn";
import { ShellProvider, useShell, type Business, type Period, type ShellUser } from "./ShellContext";
import { TopNav } from "./TopNav";
import { Sidebar } from "./Sidebar";
import { BottomNav } from "./BottomNav";
import { CommandPalette } from "./CommandPalette";
import { NotificationsDrawer } from "./NotificationsDrawer";
import { MobileReadOnlyBanner } from "./MobileReadOnlyBanner";
import { LocaleProvider } from "@/i18n/LocaleProvider";

function ShellChrome({ children }: { children: ReactNode }) {
  const { sidebarCollapsed, setPaletteOpen } = useShell();

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPaletteOpen(true);
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [setPaletteOpen]);

  return (
    <div className="min-h-dvh bg-bg-canvas">
      <a
        href="#main"
        className="sr-only rounded-md bg-bg-overlay px-3 py-2 shadow-2 focus:not-sr-only focus:fixed focus:left-3 focus:top-3 focus:z-[1000]"
      >
        Skip to main content
      </a>
      <TopNav />
      <Sidebar />
      <main
        id="main"
        tabIndex={-1}
        className={cn(
          "pb-16 pt-14 outline-none transition-[padding] duration-200 md:pb-0 motion-reduce:transition-none",
          sidebarCollapsed ? "md:pl-14" : "md:pl-60",
        )}
      >
        <div className="mx-auto max-w-[1440px] px-4 py-6 md:px-8">
          <MobileReadOnlyBanner />
          {children}
        </div>
      </main>
      <BottomNav />
      <CommandPalette />
      <NotificationsDrawer />
    </div>
  );
}

/**
 * AppShell — the persistent authenticated chrome (B16·P05). Receives server-
 * fetched user + accessible businesses, provides shell state (business, period,
 * sidebar, palette), and wraps content with the toast system.
 */
export function AppShell({
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
  return (
    <LocaleProvider userId={user.id}>
      <ShellProvider user={user} businesses={businesses} initialPeriod={initialPeriod}>
        <ToastProvider>
          <ShellChrome>{children}</ShellChrome>
        </ToastProvider>
      </ShellProvider>
    </LocaleProvider>
  );
}
