"use client";
import { useLocale } from "@/i18n/LocaleProvider";
import { LOCALES } from "@/i18n/messages";

const SHORT: Record<string, string> = { en: "EN", el: "ΕΛ" };

/** Compact segmented language switcher for the top nav. */
export function LocaleToggle() {
  const { locale, setLocale, t } = useLocale();
  return (
    <div role="group" aria-label={t("common.language")} className="hidden h-[34px] items-center overflow-hidden rounded-lg border border-border-default sm:inline-flex">
      {LOCALES.map((l) => {
        const on = l === locale;
        return (
          <button
            key={l}
            type="button"
            aria-pressed={on}
            onClick={() => setLocale(l)}
            className={`h-full cursor-pointer px-2.5 text-[12px] font-semibold transition-colors ${on ? "bg-brand-50 text-action-primary" : "text-text-muted hover:text-text-primary"}`}
          >
            {SHORT[l] ?? l.toUpperCase()}
          </button>
        );
      })}
    </div>
  );
}
