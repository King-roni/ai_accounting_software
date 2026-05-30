"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { PanelLeftClose, PanelLeftOpen } from "lucide-react";
import { Z_INDEX } from "@/theme/tokens";
import { cn } from "@/lib/cn";
import { useShell } from "./ShellContext";
import { useT } from "@/i18n/LocaleProvider";
import { useNavCounts } from "./use-nav-counts";
import { NAV_SECTIONS } from "./nav-config";

function isActive(pathname: string, href: string) {
  return pathname === href || pathname.startsWith(href + "/");
}

/** Subtle group labels (the mockup's nav-group-label). */
const SECTION_LABEL: Record<string, string | undefined> = { domain: "Workspace", account: "Account" };

export function Sidebar() {
  const { sidebarCollapsed, toggleSidebar } = useShell();
  const t = useT();
  const counts = useNavCounts();
  const pathname = usePathname();

  return (
    <nav
      aria-label="Primary"
      style={{ zIndex: Z_INDEX.sticky }}
      className={cn(
        "fixed bottom-0 left-0 top-14 hidden flex-col overflow-y-auto overflow-x-hidden border-r border-border-default bg-bg-base px-3 pb-2.5 pt-2 transition-[width] duration-200 md:flex motion-reduce:transition-none",
        sidebarCollapsed ? "w-[60px]" : "w-[232px]",
      )}
    >
      <div className="flex flex-1 flex-col gap-1 overflow-y-auto">
        {NAV_SECTIONS.map((section, si) => {
          const groupLabel = SECTION_LABEL[section.id];
          return (
            <ul key={section.id} className={cn("flex flex-col gap-px", si === NAV_SECTIONS.length - 1 && "mt-auto")}>
              {groupLabel && !sidebarCollapsed && (
                <li className="px-2.5 pb-1.5 pt-4 text-[10px] font-bold uppercase tracking-[0.08em] text-text-muted">{groupLabel}</li>
              )}
              {section.items.map((item) => {
                const active = isActive(pathname, item.href);
                const Icon = item.icon;
                const label = t(item.i18nKey);
                const count = item.countKey ? counts[item.countKey] : undefined;
                return (
                  <li key={item.href}>
                    <Link
                      href={item.href}
                      aria-current={active ? "page" : undefined}
                      title={sidebarCollapsed ? label : undefined}
                      className={cn(
                        "flex h-[38px] items-center gap-3 rounded-lg text-[13.5px] transition-colors",
                        sidebarCollapsed ? "justify-center px-0" : "px-2.5",
                        active
                          ? "bg-brand-50 font-semibold text-action-primary"
                          : "font-medium text-text-secondary hover:bg-bg-raised hover:text-text-primary",
                      )}
                    >
                      <Icon size={18} strokeWidth={1.75} aria-hidden="true" className={cn("shrink-0", active && "text-action-primary")} />
                      {!sidebarCollapsed && <span className="flex-1 truncate">{label}</span>}
                      {!sidebarCollapsed && count != null && count > 0 && (
                        <span className={cn(
                          "rounded-md px-1.5 py-px font-mono text-[11px] tabular-nums",
                          active ? "bg-[color-mix(in_srgb,var(--color-action-primary)_14%,transparent)] text-action-primary" : "bg-bg-raised text-text-muted",
                        )}>{count}</span>
                      )}
                    </Link>
                  </li>
                );
              })}
            </ul>
          );
        })}
      </div>
      <button
        type="button"
        onClick={toggleSidebar}
        aria-label={sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar"}
        aria-expanded={!sidebarCollapsed}
        className="mt-1 flex h-9 items-center gap-3 rounded-lg px-2.5 text-[12.5px] text-text-muted hover:bg-bg-raised hover:text-text-primary"
      >
        {sidebarCollapsed ? <PanelLeftOpen size={17} strokeWidth={1.75} /> : <><PanelLeftClose size={17} strokeWidth={1.75} /><span>Collapse</span></>}
      </button>
    </nav>
  );
}
