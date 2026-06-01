import type { ReactNode } from "react";
import { AccountNav } from "./AccountNav";

/**
 * Account settings live inside the (app) shell now (auth + chrome come from the
 * shell layout). This adds the settings header + section sub-nav and constrains
 * the forms to a readable width.
 */
export default function AccountLayout({ children }: { children: ReactNode }) {
  return (
    <div className="flex flex-col gap-5">
      <header>
        <h1 className="text-2xl font-semibold text-text-primary">Account settings</h1>
        <p className="text-sm text-text-secondary">
          Manage your profile, security, sessions, and integrations.
        </p>
      </header>
      <AccountNav />
      <div className="max-w-2xl">{children}</div>
    </div>
  );
}
