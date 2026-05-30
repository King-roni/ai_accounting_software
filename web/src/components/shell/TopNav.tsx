"use client";
import { useState } from "react";
import Link from "next/link";
import {
  Bell, BookOpenCheck, Check, ChevronDown, ChevronLeft, ChevronRight, CircleHelp,
  LayoutGrid, LogOut, Search, Settings,
} from "lucide-react";
import { MenuItem, Popover } from "@/components/ui";
import { formatPeriod, stepPeriod, useShell, type Period } from "./ShellContext";
import { ThemeToggle } from "./ThemeToggle";
import { LocaleToggle } from "./LocaleToggle";

function BusinessSwitcher() {
  const { businesses, currentBusiness, isMultiBusiness, setCurrentBusinessId } = useShell();
  const [q, setQ] = useState("");
  const showSearch = businesses.length > 7;
  const label = isMultiBusiness ? "All businesses" : currentBusiness?.display_name ?? "Select business";
  const initial = (isMultiBusiness ? "∗" : currentBusiness?.display_name?.[0] ?? "?").toUpperCase();
  const filtered = showSearch ? businesses.filter((b) => b.display_name.toLowerCase().includes(q.toLowerCase())) : businesses;

  return (
    <Popover
      align="start"
      label="Switch business"
      triggerClassName="rounded-lg"
      menuClassName="w-72"
      trigger={
        <span className="flex h-9 items-center gap-2.5 rounded-lg border border-border-default bg-bg-base px-2.5 transition-colors hover:border-border-strong hover:bg-bg-raised">
          <span className="flex h-6 w-6 items-center justify-center rounded-md bg-action-primary text-[11px] font-bold text-text-on-primary">{initial}</span>
          <span className="max-w-[12rem] truncate text-[13.5px] font-semibold text-text-primary">{label}</span>
          <ChevronDown size={14} strokeWidth={1.75} className="text-text-muted" aria-hidden="true" />
        </span>
      }
    >
      {(close) => (
        <div>
          {showSearch && (
            <input
              autoFocus
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder="Find business…"
              className="mb-1 h-8 w-full rounded-md border border-border-subtle bg-bg-base px-2 text-sm outline-none focus:border-border-focus"
            />
          )}
          {businesses.length >= 2 && (
            <MenuItem onSelect={() => { setCurrentBusinessId(null); close(); }}>
              <LayoutGrid size={16} strokeWidth={1.5} className="text-text-muted" />
              <span className="flex-1">All businesses</span>
              {isMultiBusiness && <Check size={15} strokeWidth={2} className="text-action-primary" />}
            </MenuItem>
          )}
          <div className="max-h-72 overflow-y-auto">
            {filtered.map((b) => (
              <MenuItem key={b.id} onSelect={() => { setCurrentBusinessId(b.id); close(); }}>
                <span className="flex h-5 w-5 items-center justify-center rounded bg-bg-raised text-[10px] font-semibold">{b.display_name[0]?.toUpperCase()}</span>
                <span className="flex-1 truncate">{b.display_name}</span>
                {currentBusiness?.id === b.id && <Check size={15} strokeWidth={2} className="text-action-primary" />}
              </MenuItem>
            ))}
            {filtered.length === 0 && <p className="px-2.5 py-3 text-sm text-text-muted">No businesses</p>}
          </div>
        </div>
      )}
    </Popover>
  );
}

function PeriodSwitcher() {
  const { period, setPeriod } = useShell();
  const months: Period[] = [];
  let p = period;
  for (let i = 0; i < 12; i++) { months.push(p); p = stepPeriod(p, -1); }

  return (
    <div className="hidden h-9 items-center overflow-hidden rounded-lg border border-border-default bg-bg-base sm:flex">
      <button type="button" aria-label="Previous period" onClick={() => setPeriod(stepPeriod(period, -1))} className="flex h-full w-8 cursor-pointer items-center justify-center text-text-secondary hover:bg-bg-raised hover:text-text-primary">
        <ChevronLeft size={15} strokeWidth={1.75} aria-hidden="true" />
      </button>
      <Popover
        align="start"
        label="Select period"
        triggerClassName="h-full border-x border-border-subtle"
        menuClassName="w-48"
        trigger={
          <span className="flex h-full cursor-pointer flex-col items-center justify-center px-3 py-1 hover:bg-bg-raised">
            <span className="text-[13.5px] font-semibold leading-none tabular-nums text-text-primary">
              <span className="border-b-2 border-accent-bronze pb-[3px]">{formatPeriod(period)}</span>
            </span>
            <span className="mt-1 text-[9px] font-medium uppercase tracking-[0.07em] text-text-muted">Accounting period</span>
          </span>
        }
      >
        {(close) => (
          <div className="max-h-72 overflow-y-auto">
            {months.map((m) => (
              <MenuItem key={`${m.year}-${m.month}`} onSelect={() => { setPeriod(m); close(); }}>
                <span className="flex-1 tabular-nums">{formatPeriod(m)}</span>
                {m.year === period.year && m.month === period.month && <Check size={15} strokeWidth={2} className="text-action-primary" />}
              </MenuItem>
            ))}
          </div>
        )}
      </Popover>
      <button type="button" aria-label="Next period" onClick={() => setPeriod(stepPeriod(period, 1))} className="flex h-full w-8 cursor-pointer items-center justify-center text-text-secondary hover:bg-bg-raised hover:text-text-primary">
        <ChevronRight size={15} strokeWidth={1.75} aria-hidden="true" />
      </button>
    </div>
  );
}

function UserMenu() {
  const { user } = useShell();
  const initial = (user.displayName?.[0] ?? user.email[0] ?? "?").toUpperCase();
  return (
    <Popover
      align="end"
      label="User menu"
      triggerClassName="rounded-full hover:opacity-90"
      menuClassName="w-60"
      trigger={<span className="flex h-[30px] w-[30px] items-center justify-center rounded-full bg-accent-bronze text-[12px] font-bold text-white">{initial}</span>}
    >
      <div className="border-b border-border-subtle px-2.5 py-2">
        <p className="truncate text-sm font-medium text-text-primary">{user.displayName ?? "Account"}</p>
        <p className="truncate text-xs text-text-muted">{user.email}</p>
      </div>
      <div className="py-1">
        <Link href="/account" className="flex items-center gap-2 rounded-sm px-2.5 py-1.5 text-sm text-text-primary hover:bg-bg-raised">
          <Settings size={16} strokeWidth={1.5} className="text-text-muted" /> Settings
        </Link>
        <Link href="/help" className="flex items-center gap-2 rounded-sm px-2.5 py-1.5 text-sm text-text-primary hover:bg-bg-raised">
          <CircleHelp size={16} strokeWidth={1.5} className="text-text-muted" /> Help
        </Link>
      </div>
      <form action="/auth/signout" method="post" className="border-t border-border-subtle pt-1">
        <button type="submit" className="flex w-full cursor-pointer items-center gap-2 rounded-sm px-2.5 py-1.5 text-left text-sm text-[var(--color-status-danger)] hover:bg-bg-raised">
          <LogOut size={16} strokeWidth={1.5} /> Sign out
        </button>
      </form>
    </Popover>
  );
}

export function TopNav() {
  const { setPaletteOpen, setNotifOpen } = useShell();
  return (
    <header
      role="banner"
      className="fixed inset-x-0 top-0 z-20 flex h-14 items-center gap-3 border-b border-border-default bg-bg-base px-4"
    >
      <Link href="/dashboard" className="flex shrink-0 items-center gap-2.5">
        <span className="flex h-7 w-7 items-center justify-center rounded-lg bg-action-primary text-white">
          <BookOpenCheck size={16} strokeWidth={2} aria-hidden="true" />
        </span>
        <span className="hidden text-[15px] font-bold tracking-tight text-text-primary sm:inline" style={{ fontFamily: "var(--font-display)" }}>
          TimeFuser<span className="text-accent-bronze-strong">Books</span>
        </span>
      </Link>
      <span className="mx-0.5 hidden h-[26px] w-px bg-border-default sm:block" />
      <BusinessSwitcher />
      <PeriodSwitcher />
      <div className="ml-auto flex items-center gap-1.5">
        <button
          type="button"
          onClick={() => setPaletteOpen(true)}
          aria-label="Open command palette"
          className="flex h-9 cursor-pointer items-center gap-2 rounded-lg border border-border-default bg-bg-raised px-3 text-text-muted transition-colors hover:border-border-strong"
        >
          <Search size={15} strokeWidth={1.75} aria-hidden="true" />
          <span className="hidden text-[13px] md:inline">Search</span>
          <kbd className="hidden rounded-md border border-border-default bg-bg-base px-1.5 py-px font-mono text-[11px] text-text-secondary md:inline">⌘K</kbd>
        </button>
        <button
          type="button"
          onClick={() => setNotifOpen(true)}
          aria-label="Notifications"
          className="flex h-9 w-9 cursor-pointer items-center justify-center rounded-lg text-text-secondary hover:bg-bg-raised hover:text-text-primary"
        >
          <Bell size={18} strokeWidth={1.5} aria-hidden="true" />
        </button>
        <LocaleToggle />
        <ThemeToggle />
        <UserMenu />
      </div>
    </header>
  );
}
