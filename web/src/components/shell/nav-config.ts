import {
  ArrowLeftRight, BarChart3, BookText, CalendarDays, CircleHelp, Contact, Files, GitCompareArrows,
  LayoutDashboard, ListChecks, Receipt, Repeat, Settings, Users, type LucideIcon,
} from "lucide-react";
import type { MessageKey } from "@/i18n/messages";

export interface NavItem {
  /** English label — fallback + accessible name when no translation is active. */
  label: string;
  /** i18n message key; render via t(i18nKey) for localized labels. */
  i18nKey: MessageKey;
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
  { id: "primary", items: [{ label: "Dashboard", i18nKey: "nav.dashboard", href: "/dashboard", icon: LayoutDashboard }] },
  {
    id: "domain",
    items: [
      { label: "Transactions", i18nKey: "nav.transactions", href: "/transactions", icon: ArrowLeftRight },
      { label: "Invoices", i18nKey: "nav.invoices", href: "/invoices", icon: Receipt },
      { label: "Documents", i18nKey: "nav.documents", href: "/documents", icon: Files },
      { label: "Matching", i18nKey: "nav.matching", href: "/matching", icon: GitCompareArrows },
      { label: "Ledger", i18nKey: "nav.ledger", href: "/ledger", icon: BookText },
      { label: "Reviews", i18nKey: "nav.reviews", href: "/reviews", icon: ListChecks },
      { label: "Periods", i18nKey: "nav.periods", href: "/periods", icon: CalendarDays },
      { label: "Reports", i18nKey: "nav.reports", href: "/reports", icon: BarChart3 },
      { label: "Subscriptions", i18nKey: "nav.subscriptions", href: "/subscriptions", icon: Repeat },
      { label: "Team", i18nKey: "nav.team", href: "/team", icon: Users },
      { label: "Clients", i18nKey: "nav.clients", href: "/clients", icon: Contact },
    ],
  },
  {
    id: "account",
    items: [
      { label: "Settings", i18nKey: "nav.settings", href: "/account", icon: Settings },
      { label: "Help", i18nKey: "nav.help", href: "/help", icon: CircleHelp },
    ],
  },
];

/** Flat list of navigable destinations (for the command palette). */
export const ALL_NAV: NavItem[] = NAV_SECTIONS.flatMap((s) => s.items);
