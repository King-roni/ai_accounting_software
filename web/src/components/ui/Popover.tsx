"use client";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { Z_INDEX } from "@/theme/tokens";
import { cn } from "@/lib/cn";

export interface PopoverProps {
  /** Content inside the trigger button (the button wrapper is provided). */
  trigger: ReactNode;
  /** Menu content; receives a close() callback. */
  children: ReactNode | ((close: () => void) => ReactNode);
  align?: "start" | "end";
  /** aria-label for the trigger button (recommended when trigger is icon-only). */
  label?: string;
  triggerClassName?: string;
  menuClassName?: string;
  /** role of the floating content; default "menu". */
  role?: "menu" | "dialog" | "listbox";
}

/**
 * Popover — anchored floating panel. Click-outside and Escape close; NO
 * focus-trap (lighter than Modal/Drawer). Trigger is wrapped in a real button
 * with aria-haspopup/aria-expanded.
 */
export function Popover({ trigger, children, align = "end", label, triggerClassName, menuClassName, role = "menu" }: PopoverProps) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onDoc = (e: MouseEvent) => {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", onDoc);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDoc);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  return (
    <div className="relative" ref={rootRef}>
      <button
        type="button"
        aria-haspopup={role}
        aria-expanded={open}
        aria-label={label}
        onClick={() => setOpen((o) => !o)}
        className={cn("cursor-pointer", triggerClassName)}
      >
        {trigger}
      </button>
      {open && (
        <div
          role={role}
          className={cn(
            "absolute top-full mt-1 min-w-[12rem] overflow-hidden rounded-md border border-border-subtle bg-bg-overlay p-1 shadow-2",
            align === "end" ? "right-0" : "left-0",
            menuClassName,
          )}
          style={{ zIndex: Z_INDEX.dropdown }}
        >
          {typeof children === "function" ? children(() => setOpen(false)) : children}
        </div>
      )}
    </div>
  );
}

/** A menu row inside a Popover (role=menu). */
export function MenuItem({
  onSelect,
  children,
  className,
  destructive,
}: {
  onSelect?: () => void;
  children: ReactNode;
  className?: string;
  destructive?: boolean;
}) {
  return (
    <button
      type="button"
      role="menuitem"
      onClick={onSelect}
      className={cn(
        "flex w-full cursor-pointer items-center gap-2 rounded-sm px-2.5 py-1.5 text-left text-sm hover:bg-bg-raised",
        destructive ? "text-[var(--color-status-danger)]" : "text-text-primary",
        className,
      )}
    >
      {children}
    </button>
  );
}
