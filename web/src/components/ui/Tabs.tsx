"use client";
import { useId, useRef, type KeyboardEvent, type ReactNode } from "react";
import { cn } from "@/lib/cn";

export interface TabItem {
  id: string;
  label: ReactNode;
  content?: ReactNode;
  disabled?: boolean;
}

export interface TabsProps {
  tabs: TabItem[];
  value: string;
  onValueChange: (id: string) => void;
  variant?: "underlined" | "pill";
  className?: string;
}

/**
 * Tabs — underlined (Linear/Mercury) or pill (settings) variants. Full ARIA
 * tablist/tab/tabpanel with roving tabindex; ArrowLeft/Right move + activate,
 * Home/End jump. Controlled (value + onValueChange) so the consumer can sync to
 * the URL for deep-linkable tabs.
 */
export function Tabs({ tabs, value, onValueChange, variant = "underlined", className }: TabsProps) {
  const base = useId();
  const refs = useRef<(HTMLButtonElement | null)[]>([]);

  const move = (from: number, dir: 1 | -1 | "home" | "end") => {
    const enabled = tabs.map((t, i) => (t.disabled ? -1 : i)).filter((i) => i >= 0);
    if (!enabled.length) return;
    let target: number;
    if (dir === "home") target = enabled[0];
    else if (dir === "end") target = enabled[enabled.length - 1];
    else {
      const pos = enabled.indexOf(from);
      target = enabled[(pos + (dir === 1 ? 1 : enabled.length - 1)) % enabled.length];
    }
    onValueChange(tabs[target].id);
    refs.current[target]?.focus();
  };

  const onKeyDown = (e: KeyboardEvent, i: number) => {
    if (e.key === "ArrowRight") { e.preventDefault(); move(i, 1); }
    else if (e.key === "ArrowLeft") { e.preventDefault(); move(i, -1); }
    else if (e.key === "Home") { e.preventDefault(); move(i, "home"); }
    else if (e.key === "End") { e.preventDefault(); move(i, "end"); }
  };

  const active = tabs.find((t) => t.id === value) ?? tabs[0];

  return (
    <div className={className}>
      <div
        role="tablist"
        className={cn("flex items-center", variant === "underlined" ? "gap-1 border-b border-border-subtle" : "gap-1 rounded-md bg-bg-raised p-1")}
      >
        {tabs.map((t, i) => {
          const selected = t.id === value;
          return (
            <button
              key={t.id}
              ref={(el) => { refs.current[i] = el; }}
              role="tab"
              type="button"
              id={`${base}-tab-${t.id}`}
              aria-selected={selected}
              aria-controls={`${base}-panel-${t.id}`}
              tabIndex={selected ? 0 : -1}
              disabled={t.disabled}
              onClick={() => onValueChange(t.id)}
              onKeyDown={(e) => onKeyDown(e, i)}
              className={cn(
                "cursor-pointer whitespace-nowrap text-sm font-medium transition-colors duration-150 disabled:opacity-50 disabled:pointer-events-none",
                variant === "underlined"
                  ? cn("border-b-2 px-3 py-2 -mb-px", selected ? "border-action-primary text-text-primary" : "border-transparent text-text-secondary hover:text-text-primary")
                  : cn("rounded px-3 py-1.5", selected ? "bg-bg-base text-text-primary shadow-1" : "text-text-secondary hover:text-text-primary"),
              )}
            >
              {t.label}
            </button>
          );
        })}
      </div>
      {tabs.map((t) => (
        <div
          key={t.id}
          role="tabpanel"
          id={`${base}-panel-${t.id}`}
          aria-labelledby={`${base}-tab-${t.id}`}
          hidden={t.id !== active.id}
          tabIndex={0}
          className="pt-4 outline-none"
        >
          {t.id === active.id ? t.content : null}
        </div>
      ))}
    </div>
  );
}
