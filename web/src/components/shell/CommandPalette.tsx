"use client";
import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useRouter } from "next/navigation";
import { Building2, CornerDownLeft, RefreshCw, Search, type LucideIcon } from "lucide-react";
import { Z_INDEX } from "@/theme/tokens";
import { cn } from "@/lib/cn";
import { useMounted } from "@/components/ui/overlay-utils";
import { useShell } from "./ShellContext";
import { ALL_NAV } from "./nav-config";

interface Cmd {
  id: string;
  label: string;
  category: "Navigate" | "Switch business" | "Actions";
  icon: LucideIcon;
  run: () => void;
}

/** Subsequence fuzzy score; null = no match, lower = better. */
function score(query: string, text: string): number | null {
  if (!query) return 0;
  const q = query.toLowerCase();
  const t = text.toLowerCase();
  const sub = t.indexOf(q);
  if (sub >= 0) return sub; // substring beats scattered
  let ti = 0;
  let last = -1;
  let spread = 0;
  for (const ch of q) {
    const next = t.indexOf(ch, ti);
    if (next < 0) return null;
    if (last >= 0) spread += next - last;
    last = next;
    ti = next + 1;
  }
  return 100 + spread;
}

export function CommandPalette() {
  const router = useRouter();
  const { businesses, setCurrentBusinessId, paletteOpen, setPaletteOpen } = useShell();
  const mounted = useMounted();
  const [query, setQuery] = useState("");
  const [sel, setSel] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);

  const close = () => { setPaletteOpen(false); setQuery(""); setSel(0); };

  const commands = useMemo<Cmd[]>(() => {
    const nav: Cmd[] = ALL_NAV.map((n) => ({
      id: `nav:${n.href}`,
      label: n.label,
      category: "Navigate",
      icon: n.icon,
      run: () => { close(); router.push(n.href); },
    }));
    const biz: Cmd[] = businesses.map((b) => ({
      id: `biz:${b.id}`,
      label: `Switch to ${b.display_name}`,
      category: "Switch business",
      icon: Building2,
      run: () => { close(); setCurrentBusinessId(b.id); },
    }));
    if (businesses.length >= 2) {
      biz.unshift({
        id: "biz:all",
        label: "Multi-business overview",
        category: "Switch business",
        icon: Building2,
        run: () => { close(); setCurrentBusinessId(null); },
      });
    }
    const actions: Cmd[] = [
      { id: "act:refresh", label: "Refresh dashboard now", category: "Actions", icon: RefreshCw, run: () => { close(); router.refresh(); } },
    ];
    return [...nav, ...biz, ...actions];
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [businesses, router]);

  const filtered = useMemo(() => {
    return commands
      .map((c) => ({ c, s: score(query, c.label) }))
      .filter((x): x is { c: Cmd; s: number } => x.s !== null)
      .sort((a, b) => a.s - b.s)
      .map((x) => x.c);
  }, [commands, query]);

  useEffect(() => { if (paletteOpen) inputRef.current?.focus(); }, [paletteOpen]);

  if (!mounted || !paletteOpen) return null;

  const safeSel = filtered.length ? Math.min(sel, filtered.length - 1) : 0;
  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowDown") { e.preventDefault(); setSel(Math.min(safeSel + 1, filtered.length - 1)); }
    else if (e.key === "ArrowUp") { e.preventDefault(); setSel(Math.max(safeSel - 1, 0)); }
    else if (e.key === "Enter") { e.preventDefault(); filtered[safeSel]?.run(); }
    else if (e.key === "Escape") { e.preventDefault(); close(); }
  };

  // Group preserving sorted order.
  let flatIndex = -1;
  const cats: Cmd["category"][] = ["Navigate", "Switch business", "Actions"];

  return createPortal(
    <div className="fixed inset-0" style={{ zIndex: Z_INDEX.modalBackdrop }}>
      <div className="fixed inset-0 bg-black/40" onClick={close} aria-hidden="true" />
      <div className="fixed inset-x-0 top-[12vh] flex justify-center px-4" style={{ zIndex: Z_INDEX.modal }}>
        <div
          role="dialog"
          aria-modal="true"
          aria-label="Command palette"
          className="w-full max-w-xl overflow-hidden rounded-lg border border-border-subtle bg-bg-overlay shadow-3"
        >
          <div className="flex items-center gap-2 border-b border-border-subtle px-3">
            <Search size={18} strokeWidth={1.5} className="text-text-muted" aria-hidden="true" />
            <input
              ref={inputRef}
              value={query}
              onChange={(e) => { setQuery(e.target.value); setSel(0); }}
              onKeyDown={onKeyDown}
              role="combobox"
              aria-expanded="true"
              aria-controls="cmdk-list"
              aria-activedescendant={filtered[safeSel] ? `cmdk-${filtered[safeSel].id}` : undefined}
              placeholder="Search pages, businesses, actions…"
              className="h-12 flex-1 bg-transparent text-sm text-text-primary outline-none placeholder:text-text-muted"
            />
            <kbd className="rounded border border-border-subtle px-1.5 py-0.5 text-xs text-text-muted">Esc</kbd>
          </div>
          <ul id="cmdk-list" role="listbox" className="max-h-[50vh] overflow-y-auto p-1">
            {filtered.length === 0 && <li className="px-3 py-6 text-center text-sm text-text-muted">No results</li>}
            {cats.map((cat) => {
              const inCat = filtered.filter((c) => c.category === cat);
              if (!inCat.length) return null;
              return (
                <li key={cat}>
                  <div className="px-2 pb-1 pt-2 text-xs font-medium uppercase tracking-wide text-text-muted">{cat}</div>
                  <ul>
                    {inCat.map((c) => {
                      flatIndex += 1;
                      const idx = flatIndex;
                      const Icon = c.icon;
                      const selected = idx === safeSel;
                      return (
                        <li
                          key={c.id}
                          id={`cmdk-${c.id}`}
                          role="option"
                          aria-selected={selected}
                          onMouseEnter={() => setSel(idx)}
                          onClick={() => c.run()}
                          className={cn(
                            "flex cursor-pointer items-center gap-2.5 rounded-sm px-2.5 py-2 text-sm",
                            selected ? "bg-bg-raised text-text-primary" : "text-text-secondary",
                          )}
                        >
                          <Icon size={16} strokeWidth={1.5} aria-hidden="true" className="text-text-muted" />
                          <span className="flex-1">{c.label}</span>
                          {selected && <CornerDownLeft size={14} strokeWidth={1.5} className="text-text-muted" aria-hidden="true" />}
                        </li>
                      );
                    })}
                  </ul>
                </li>
              );
            })}
          </ul>
        </div>
      </div>
    </div>,
    document.body,
  );
}
