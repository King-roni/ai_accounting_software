"use client";
import { useEffect, useSyncExternalStore } from "react";
import { Monitor, Moon, Sun, type LucideIcon } from "lucide-react";
import { cn } from "@/lib/cn";

type ThemeChoice = "light" | "dark" | "system";
const LS_THEME = "theme";
const THEME_EVENT = "cb:theme-change";

const OPTIONS: { value: ThemeChoice; icon: LucideIcon; label: string }[] = [
  { value: "light", icon: Sun, label: "Light theme" },
  { value: "system", icon: Monitor, label: "System theme" },
  { value: "dark", icon: Moon, label: "Dark theme" },
];

function resolve(choice: ThemeChoice): "light" | "dark" {
  if (choice === "system") return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  return choice;
}
function apply(choice: ThemeChoice) {
  document.documentElement.setAttribute("data-theme", resolve(choice));
}

// External store: the persisted theme choice. Reading via useSyncExternalStore
// keeps it hydration-safe and avoids setState-in-effect.
function subscribe(cb: () => void) {
  window.addEventListener("storage", cb);
  window.addEventListener(THEME_EVENT, cb);
  return () => {
    window.removeEventListener("storage", cb);
    window.removeEventListener(THEME_EVENT, cb);
  };
}
function getSnapshot(): ThemeChoice {
  const v = localStorage.getItem(LS_THEME);
  return v === "light" || v === "dark" ? v : "system";
}

/**
 * ThemeToggle — 3-state segmented control (light / system / dark). Persists to
 * localStorage("theme"); the no-flash script in layout.tsx reads it on next
 * load. (users.theme_preference column is deferred per B16·P05.)
 */
export function ThemeToggle() {
  const choice = useSyncExternalStore(subscribe, getSnapshot, () => "system" as ThemeChoice);

  // Re-resolve when in system mode and the OS preference flips.
  useEffect(() => {
    if (choice !== "system") return;
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const onChange = () => apply("system");
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, [choice]);

  const select = (value: ThemeChoice) => {
    localStorage.setItem(LS_THEME, value);
    apply(value);
    window.dispatchEvent(new Event(THEME_EVENT));
  };

  return (
    <div role="radiogroup" aria-label="Theme" className="hidden items-center gap-0.5 rounded-md border border-border-subtle bg-bg-raised p-0.5 sm:inline-flex">
      {OPTIONS.map((o) => {
        const Icon = o.icon;
        const active = choice === o.value;
        return (
          <button
            key={o.value}
            type="button"
            role="radio"
            aria-checked={active}
            aria-label={o.label}
            onClick={() => select(o.value)}
            className={cn(
              "flex h-7 w-7 cursor-pointer items-center justify-center rounded-sm transition-colors",
              active ? "bg-bg-base text-text-primary shadow-1" : "text-text-muted hover:text-text-primary",
            )}
          >
            <Icon size={15} strokeWidth={1.5} aria-hidden="true" />
          </button>
        );
      })}
    </div>
  );
}
