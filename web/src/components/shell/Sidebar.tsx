"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { PanelLeftClose, PanelLeftOpen } from "lucide-react";
import { Z_INDEX } from "@/theme/tokens";
import { cn } from "@/lib/cn";
import { useShell } from "./ShellContext";
import { NAV_SECTIONS } from "./nav-config";

function isActive(pathname: string, href: string) {
  return pathname === href || pathname.startsWith(href + "/");
}

export function Sidebar() {
  const { sidebarCollapsed, toggleSidebar } = useShell();
  const pathname = usePathname();

  return (
    <nav
      aria-label="Primary"
      style={{ zIndex: Z_INDEX.sticky }}
      className={cn(
        "fixed bottom-0 left-0 top-14 hidden flex-col border-r border-border-subtle bg-bg-raised transition-[width] duration-200 md:flex motion-reduce:transition-none",
        sidebarCollapsed ? "w-14" : "w-60",
      )}
    >
      <div className="flex flex-1 flex-col gap-6 overflow-y-auto py-4">
        {NAV_SECTIONS.map((section, si) => (
          <ul key={section.id} className={cn("flex flex-col gap-0.5 px-2", si === NAV_SECTIONS.length - 1 && "mt-auto")}>
            {section.items.map((item) => {
              const active = isActive(pathname, item.href);
              const Icon = item.icon;
              return (
                <li key={item.href}>
                  <Link
                    href={item.href}
                    aria-current={active ? "page" : undefined}
                    title={sidebarCollapsed ? item.label : undefined}
                    className={cn(
                      "relative flex h-9 items-center gap-3 rounded-md px-3 text-sm transition-colors",
                      sidebarCollapsed && "justify-center px-0",
                      active
                        ? "bg-[color-mix(in_srgb,var(--color-action-primary)_10%,transparent)] font-medium text-text-primary"
                        : "text-text-secondary hover:bg-bg-base hover:text-text-primary",
                    )}
                  >
                    {active && <span aria-hidden="true" className="absolute left-0 top-1.5 bottom-1.5 w-1 rounded-r bg-action-primary" />}
                    <Icon size={20} strokeWidth={1.5} aria-hidden="true" className="shrink-0" />
                    {!sidebarCollapsed && <span className="truncate">{item.label}</span>}
                  </Link>
                </li>
              );
            })}
          </ul>
        ))}
      </div>
      <button
        type="button"
        onClick={toggleSidebar}
        aria-label={sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar"}
        aria-expanded={!sidebarCollapsed}
        className="flex h-10 items-center gap-3 border-t border-border-subtle px-3 text-text-muted hover:text-text-primary"
      >
        {sidebarCollapsed ? <PanelLeftOpen size={20} strokeWidth={1.5} /> : <><PanelLeftClose size={20} strokeWidth={1.5} /><span className="text-sm">Collapse</span></>}
      </button>
    </nav>
  );
}
