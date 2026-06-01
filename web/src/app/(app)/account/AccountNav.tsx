"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";

const TABS = [
  { href: "/account", label: "Profile" },
  { href: "/account/mfa", label: "Multi-factor" },
  { href: "/account/sessions", label: "Sessions" },
];

export function AccountNav() {
  const pathname = usePathname();
  return (
    <nav className="flex gap-1 border-b border-border-subtle" aria-label="Account sections">
      {TABS.map((t) => {
        const active = pathname === t.href;
        return (
          <Link
            key={t.href}
            href={t.href}
            aria-current={active ? "page" : undefined}
            className={`-mb-px border-b-2 px-3 py-2 text-sm font-medium transition-colors ${
              active
                ? "border-accent-bronze text-text-primary"
                : "border-transparent text-text-secondary hover:text-text-primary"
            }`}
          >
            {t.label}
          </Link>
        );
      })}
    </nav>
  );
}
