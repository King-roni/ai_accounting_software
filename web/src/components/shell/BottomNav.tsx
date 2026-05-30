"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { BarChart3, CalendarDays, LayoutDashboard, ListChecks, MoreHorizontal } from "lucide-react";
import { Z_INDEX } from "@/theme/tokens";
import { cn } from "@/lib/cn";
import { useShell } from "./ShellContext";
import { useT } from "@/i18n/LocaleProvider";
import type { MessageKey } from "@/i18n/messages";

const ITEMS: { i18nKey: MessageKey; href: string; icon: typeof LayoutDashboard }[] = [
  { i18nKey: "nav.dashboard", href: "/dashboard", icon: LayoutDashboard },
  { i18nKey: "nav.reviews", href: "/reviews", icon: ListChecks },
  { i18nKey: "nav.periods", href: "/periods", icon: CalendarDays },
  { i18nKey: "nav.reports", href: "/reports", icon: BarChart3 },
];

/** Mobile bottom navigation (≤ md). 5-item max; "More" opens the command palette. */
export function BottomNav() {
  const pathname = usePathname();
  const { setPaletteOpen } = useShell();
  const t = useT();
  return (
    <nav
      aria-label="Primary"
      style={{ zIndex: Z_INDEX.sticky }}
      className="fixed inset-x-0 bottom-0 flex h-14 items-stretch border-t border-border-subtle bg-bg-raised md:hidden"
    >
      {ITEMS.map((it) => {
        const active = pathname === it.href || pathname.startsWith(it.href + "/");
        const Icon = it.icon;
        return (
          <Link
            key={it.href}
            href={it.href}
            aria-current={active ? "page" : undefined}
            className={cn("flex flex-1 flex-col items-center justify-center gap-0.5 text-xs", active ? "text-action-primary" : "text-text-muted")}
          >
            <Icon size={20} strokeWidth={1.5} aria-hidden="true" />
            {t(it.i18nKey)}
          </Link>
        );
      })}
      <button
        type="button"
        onClick={() => setPaletteOpen(true)}
        className="flex flex-1 flex-col items-center justify-center gap-0.5 text-xs text-text-muted"
      >
        <MoreHorizontal size={20} strokeWidth={1.5} aria-hidden="true" />
        {t("common.more")}
      </button>
    </nav>
  );
}
