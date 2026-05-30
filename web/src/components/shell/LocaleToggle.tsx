"use client";
import { Languages } from "lucide-react";
import { useLocale } from "@/i18n/LocaleProvider";
import { LOCALES, LOCALE_LABEL, type Locale } from "@/i18n/messages";

/** Compact language switcher for the top nav. Native <select> for a11y. */
export function LocaleToggle() {
  const { locale, setLocale, t } = useLocale();
  return (
    <div className="relative flex items-center">
      <Languages size={16} strokeWidth={1.5} aria-hidden="true" className="pointer-events-none absolute left-2 text-text-muted" />
      <select
        aria-label={t("common.language")}
        value={locale}
        onChange={(e) => setLocale(e.target.value as Locale)}
        className="h-8 cursor-pointer appearance-none rounded-md border border-border-default bg-bg-base pl-7 pr-2 text-xs text-text-primary outline-none focus:border-border-focus focus:ring-2 focus:ring-[var(--color-border-focus)]/35"
      >
        {LOCALES.map((l) => (
          <option key={l} value={l}>{LOCALE_LABEL[l]}</option>
        ))}
      </select>
    </div>
  );
}
