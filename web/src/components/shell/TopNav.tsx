"use client";
import { useState } from "react";
import Link from "next/link";
import {
  Bell, Check, ChevronDown, ChevronLeft, ChevronRight, CircleHelp,
  LayoutGrid, LogOut, Search, Settings,
} from "lucide-react";
import { MenuItem, Popover } from "@/components/ui";
import { formatPeriod, stepPeriod, useShell, type Period } from "./ShellContext";
import { ThemeToggle } from "./ThemeToggle";

function BusinessSwitcher() {
  const { businesses, currentBusiness, isMultiBusiness, setCurrentBusinessId } = useShell();
  const [q, setQ] = useState("");
  const showSearch = businesses.length > 7;
  const label = isMultiBusiness ? "Multi-business overview" : currentBusiness?.display_name ?? "Select business";
  const initial = (isMultiBusiness ? "∗" : currentBusiness?.display_name?.[0] ?? "?").toUpperCase();
  const filtered = showSearch ? businesses.filter((b) => b.display_name.toLowerCase().includes(q.toLowerCase())) : businesses;

  return (
    <Popover
      align="start"
      label="Switch business"
      triggerClassName="rounded-md hover:bg-bg-raised"
      menuClassName="w-72"
      trigger={
        <span className="flex items-center gap-2 px-2 py-1.5">
          <span className="flex h-6 w-6 items-center justify-center rounded bg-action-primary text-xs font-semibold text-text-on-primary">{initial}</span>
          <span className="max-w-[12rem] truncate text-sm font-medium text-text-primary">{label}</span>
          <ChevronDown size={15} strokeWidth={1.5} className="text-text-muted" aria-hidden="true" />
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
              className="mb-1 h-8 w-full rounded-sm border border-border-subtle bg-bg-base px-2 text-sm outline-none focus:border-border-focus"
            />
          )}
          {businesses.length >= 2 && (
            <MenuItem onSelect={() => { setCurrentBusinessId(null); close(); }}>
              <LayoutGrid size={16} strokeWidth={1.5} className="text-text-muted" />
              <span className="flex-1">Multi-business overview</span>
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
    <div className="hidden items-center gap-0.5 sm:flex">
      <button type="button" aria-label="Previous period" onClick={() => setPeriod(stepPeriod(period, -1))} className="flex h-7 w-7 cursor-pointer items-center justify-center rounded-sm text-text-muted hover:bg-bg-raised hover:text-text-primary">
        <ChevronLeft size={16} strokeWidth={1.5} aria-hidden="true" />
      </button>
      <Popover
        align="start"
        label="Select period"
        triggerClassName="rounded-sm hover:bg-bg-raised"
        menuClassName="w-48"
        trigger={<span className="px-2 py-1 text-sm font-medium tabular-nums text-text-primary">{formatPeriod(period)}</span>}
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
      <button type="button" aria-label="Next period" onClick={() => setPeriod(stepPeriod(period, 1))} className="flex h-7 w-7 cursor-pointer items-center justify-center rounded-sm text-text-muted hover:bg-bg-raised hover:text-text-primary">
        <ChevronRight size={16} strokeWidth={1.5} aria-hidden="true" />
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
      trigger={<span className="flex h-8 w-8 items-center justify-center rounded-full bg-bg-raised text-sm font-semibold text-text-primary">{initial}</span>}
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
      className="fixed inset-x-0 top-0 z-20 flex h-14 items-center gap-2 border-b border-border-subtle bg-bg-raised px-3"
    >
      <Link href="/dashboard" className="flex items-center gap-2 px-1">
        <LayoutGrid size={20} strokeWidth={1.75} className="text-action-primary" aria-hidden="true" />
        <span className="hidden font-semibold text-text-primary sm:inline" style={{ fontFamily: "var(--font-display)" }}>Cyprus Bookkeeping</span>
      </Link>
      <span className="mx-1 hidden h-5 w-px bg-border-subtle sm:block" />
      <BusinessSwitcher />
      <PeriodSwitcher />
      <div className="ml-auto flex items-center gap-1.5">
        <button
          type="button"
          onClick={() => setPaletteOpen(true)}
          aria-label="Open command palette"
          className="flex h-8 cursor-pointer items-center gap-2 rounded-md border border-border-subtle px-2.5 text-sm text-text-muted hover:text-text-primary"
        >
          <Search size={15} strokeWidth={1.5} aria-hidden="true" />
          <span className="hidden md:inline">Search</span>
          <kbd className="hidden rounded border border-border-subtle px-1 text-xs md:inline">⌘K</kbd>
        </button>
        <button
          type="button"
          onClick={() => setNotifOpen(true)}
          aria-label="Notifications"
          className="flex h-8 w-8 cursor-pointer items-center justify-center rounded-md text-text-muted hover:bg-bg-base hover:text-text-primary"
        >
          <Bell size={18} strokeWidth={1.5} aria-hidden="true" />
        </button>
        <ThemeToggle />
        <UserMenu />
      </div>
    </header>
  );
}
