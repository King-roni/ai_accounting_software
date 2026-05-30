/**
 * Lightweight i18n catalog (R3c). English is the source of truth; other locales
 * override a subset and fall back to English for anything missing. Keys are flat
 * dot-paths for a simple, type-safe `t()`. Locales match dashboard_locale_enum.
 */
export const LOCALES = ["en", "el"] as const;
export type Locale = (typeof LOCALES)[number];

export const LOCALE_LABEL: Record<Locale, string> = {
  en: "English",
  el: "Ελληνικά",
};

const en = {
  // Sidebar navigation
  "nav.dashboard": "Dashboard",
  "nav.transactions": "Transactions",
  "nav.invoices": "Invoices",
  "nav.documents": "Documents",
  "nav.matching": "Matching",
  "nav.ledger": "Ledger",
  "nav.reviews": "Reviews",
  "nav.periods": "Periods",
  "nav.reports": "Reports",
  "nav.subscriptions": "Subscriptions",
  "nav.team": "Team",
  "nav.clients": "Clients",
  "nav.settings": "Settings",
  "nav.help": "Help",
  // Shell chrome
  "common.search": "Search",
  "common.notifications": "Notifications",
  "common.language": "Language",
  "common.signOut": "Sign out",
  "common.more": "More",
  // Representative screen headings
  "clients.title": "Clients",
  "dashboard.title": "Dashboard",
} satisfies Record<string, string>;

export type MessageKey = keyof typeof en;

/** Greek (Cyprus). Only the subset that's translated; the rest falls back to EN. */
const el: Partial<Record<MessageKey, string>> = {
  "nav.dashboard": "Πίνακας",
  "nav.transactions": "Συναλλαγές",
  "nav.invoices": "Τιμολόγια",
  "nav.documents": "Έγγραφα",
  "nav.matching": "Αντιστοίχιση",
  "nav.ledger": "Καθολικό",
  "nav.reviews": "Έλεγχοι",
  "nav.periods": "Περίοδοι",
  "nav.reports": "Αναφορές",
  "nav.subscriptions": "Συνδρομές",
  "nav.team": "Ομάδα",
  "nav.clients": "Πελάτες",
  "nav.settings": "Ρυθμίσεις",
  "nav.help": "Βοήθεια",
  "common.search": "Αναζήτηση",
  "common.notifications": "Ειδοποιήσεις",
  "common.language": "Γλώσσα",
  "common.signOut": "Αποσύνδεση",
  "common.more": "Περισσότερα",
  "clients.title": "Πελάτες",
  "dashboard.title": "Πίνακας",
};

export const messages: Record<Locale, Partial<Record<MessageKey, string>>> = { en, el };

/** Resolve a message for a locale, falling back to English then the key. */
export function translate(locale: Locale, key: MessageKey): string {
  return messages[locale]?.[key] ?? en[key] ?? key;
}
