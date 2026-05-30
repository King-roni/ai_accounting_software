"use client";
import { createContext, useCallback, useContext, useEffect, useSyncExternalStore, type ReactNode } from "react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { LOCALES, translate, type Locale, type MessageKey } from "./messages";

const LS_KEY = "cb.locale";
const LS_EVENT = "cb:ls-change"; // shared with ShellContext's localStorage bus

function subscribe(cb: () => void) {
  window.addEventListener("storage", cb);
  window.addEventListener(LS_EVENT, cb);
  return () => {
    window.removeEventListener("storage", cb);
    window.removeEventListener(LS_EVENT, cb);
  };
}
function readLocale(): Locale {
  const v = localStorage.getItem(LS_KEY);
  return (LOCALES as readonly string[]).includes(v ?? "") ? (v as Locale) : "en";
}

interface LocaleCtx {
  locale: Locale;
  setLocale: (l: Locale) => void;
  t: (k: MessageKey) => string;
}
const LocaleContext = createContext<LocaleCtx | null>(null);

export function useLocale(): LocaleCtx {
  const c = useContext(LocaleContext);
  if (!c) throw new Error("useLocale must be used within <LocaleProvider>");
  return c;
}
/** Convenience: just the translate function. */
export function useT(): (k: MessageKey) => string {
  return useLocale().t;
}

export function LocaleProvider({ userId, children }: { userId: string; children: ReactNode }) {
  const locale = useSyncExternalStore(subscribe, readLocale, () => "en" as Locale);

  // Keep <html lang> in sync for assistive tech.
  useEffect(() => {
    document.documentElement.lang = locale;
  }, [locale]);

  const setLocale = useCallback(
    (l: Locale) => {
      localStorage.setItem(LS_KEY, l);
      window.dispatchEvent(new Event(LS_EVENT));
      // Persist to the user's dashboard locale (best-effort; UI already updated).
      if (userId) {
        createSupabaseBrowserClient()
          .rpc("update_user_dashboard_locale", { p_actor_user_id: userId, p_target_user_id: userId, p_new_locale: l, p_context: {} })
          .then(() => {}, () => {});
      }
    },
    [userId],
  );

  const t = useCallback((k: MessageKey) => translate(locale, k), [locale]);

  return <LocaleContext.Provider value={{ locale, setLocale, t }}>{children}</LocaleContext.Provider>;
}
