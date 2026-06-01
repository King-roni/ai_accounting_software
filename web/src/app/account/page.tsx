import Link from "next/link";

import { createSupabaseServerClient } from "@/lib/supabase/server";
import EmailForm from "./EmailForm";
import PasswordForm from "./PasswordForm";
import ProfileForm from "./ProfileForm";
import PersonalAuditFeed from "./PersonalAuditFeed";

export default async function AccountSettingsPage() {
  // Layout already gates auth + provides the chrome; we can read user here.
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null; // Layout will have redirected; safety net.

  const { data: profile } = await supabase
    .from("users")
    .select("display_name, mfa_enabled, mfa_factors_count, email_verified")
    .eq("auth_user_id", user.id)
    .maybeSingle();

  // Owner/Admin gating for the Integrations link: at least one ACTIVE
  // OWNER/ADMIN business role.
  const { count: ownerAdminCount } = await supabase
    .from("business_user_roles")
    .select("id", { count: "exact", head: true })
    .eq("status", "ACTIVE")
    .in("role", ["OWNER", "ADMIN"]);

  return (
    <div className="space-y-8">
      <header>
        <h1 className="text-xl font-medium text-zinc-900 dark:text-zinc-50">
          Account settings
        </h1>
        <p className="mt-1 text-sm text-zinc-500">
          Manage your profile, security, sessions, and integrations.
        </p>
      </header>

      <section className="rounded-lg border border-zinc-200 bg-white p-5 dark:border-zinc-800 dark:bg-zinc-900">
        <h2 className="mb-3 text-base font-medium text-zinc-900 dark:text-zinc-50">Profile</h2>
        <ProfileForm
          initialDisplayName={profile?.display_name ?? null}
          email={user.email ?? ""}
        />
      </section>

      <section className="rounded-lg border border-zinc-200 bg-white p-5 dark:border-zinc-800 dark:bg-zinc-900">
        <h2 className="mb-3 text-base font-medium text-zinc-900 dark:text-zinc-50">Email</h2>
        <EmailForm currentEmail={user.email ?? ""} />
      </section>

      <section className="rounded-lg border border-zinc-200 bg-white p-5 dark:border-zinc-800 dark:bg-zinc-900">
        <h2 className="mb-3 text-base font-medium text-zinc-900 dark:text-zinc-50">Password</h2>
        <PasswordForm />
      </section>

      <section className="rounded-lg border border-zinc-200 bg-white p-5 dark:border-zinc-800 dark:bg-zinc-900">
        <h2 className="mb-2 text-base font-medium text-zinc-900 dark:text-zinc-50">
          Multi-factor authentication
        </h2>
        <p className="mb-2 text-sm text-zinc-500">
          {profile?.mfa_enabled
            ? `${profile.mfa_factors_count} factor(s) enrolled.`
            : "No MFA factors enrolled. Strongly recommended for all roles."}
        </p>
        <Link
          href="/account/mfa"
          className="inline-block rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          Manage MFA
        </Link>
      </section>

      <section className="rounded-lg border border-zinc-200 bg-white p-5 dark:border-zinc-800 dark:bg-zinc-900">
        <h2 className="mb-2 text-base font-medium text-zinc-900 dark:text-zinc-50">Sessions</h2>
        <p className="mb-2 text-sm text-zinc-500">
          See and revoke devices that are signed in to your account.
        </p>
        <Link
          href="/account/sessions"
          className="inline-block rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          Manage sessions
        </Link>
      </section>

      {(ownerAdminCount ?? 0) > 0 && (
        <section className="rounded-lg border border-zinc-200 bg-white p-5 dark:border-zinc-800 dark:bg-zinc-900">
          <h2 className="mb-2 text-base font-medium text-zinc-900 dark:text-zinc-50">
            Business integrations
          </h2>
          <p className="mb-2 text-sm text-zinc-500">
            Connect Gmail and Drive on businesses where you&apos;re Owner or Admin.
          </p>
          <Link
            href="/integrations"
            className="inline-block rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            Manage integrations
          </Link>
        </section>
      )}

      <section className="rounded-lg border border-zinc-200 bg-white p-5 dark:border-zinc-800 dark:bg-zinc-900">
        <h2 className="mb-1 text-base font-medium text-zinc-900 dark:text-zinc-50">
          Personal audit feed
        </h2>
        <p className="mb-3 text-sm text-zinc-500">
          A 30-day timeline of your own actions from the append-only audit log.
        </p>
        <PersonalAuditFeed />
      </section>
    </div>
  );
}
