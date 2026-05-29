import {
  ArrowLeftRight, BarChart3, BookText, CalendarDays, CircleHelp, Contact, Files, GitCompareArrows,
  LayoutDashboard, ListChecks, Receipt, Repeat, Settings, Users, type LucideIcon,
} from "lucide-react";

export interface NavItem {
  label: string;
  href: string;
  icon: LucideIcon;
  /** Permission surface required to see this item (hide-don't-show). Wired when
   *  the permission resolver lands; until then all items render. */
  permission?: string;
}

export interface NavSection {
  id: string;
  items: NavItem[];
}

/** Sidebar IA per B16·P05 (3 sections). */
export const NAV_SECTIONS: NavSection[] = [
  { id: "primary", items: [{ label: "Dashboard", href: "/dashboard", icon: LayoutDashboard }] },
  {
    id: "domain",
    items: [
      { label: "Transactions", href: "/transactions", icon: ArrowLeftRight },
      { label: "Invoices", href: "/invoices", icon: Receipt },
      { label: "Documents", href: "/documents", icon: Files },
      { label: "Matching", href: "/matching", icon: GitCompareArrows },
      { label: "Ledger", href: "/ledger", icon: BookText },
      { label: "Reviews", href: "/reviews", icon: ListChecks },
      { label: "Periods", href: "/periods", icon: CalendarDays },
      { label: "Reports", href: "/reports", icon: BarChart3 },
      { label: "Subscriptions", href: "/subscriptions", icon: Repeat },
      { label: "Team", href: "/team", icon: Users },
      { label: "Clients", href: "/clients", icon: Contact },
    ],
  },
  {
    id: "account",
    items: [
      { label: "Settings", href: "/account", icon: Settings },
      { label: "Help", href: "/help", icon: CircleHelp },
    ],
  },
];

/** Flat list of navigable destinations (for the command palette). */
export const ALL_NAV: NavItem[] = NAV_SECTIONS.flatMap((s) => s.items);
