import Link from "next/link";

import { createSupabaseServerClient } from "@/lib/supabase/server";
import EmailForm from "./EmailForm";
import PasswordForm from "./PasswordForm";
import ProfileForm from "./ProfileForm";
import PersonalAuditFeed from "./PersonalAuditFeed";

function Section({ title, description, children }: {
  title: string;
  description?: string;
  children: React.ReactNode;
}) {
  return (
    <section className="rounded-xl border border-border-subtle bg-surface-default p-5 shadow-1">
      <h2 className="text-sm font-semibold text-text-primary">{title}</h2>
      {description && <p className="mt-1 text-sm text-text-secondary">{description}</p>}
      <div className="mt-3">{children}</div>
    </section>
  );
}

export default async function AccountSettingsPage() {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null; // shell layout already gates auth.

  const { data: profile } = await supabase
    .from("users")
    .select("display_name")
    .eq("auth_user_id", user.id)
    .maybeSingle();

  const { count: ownerAdminCount } = await supabase
    .from("business_user_roles")
    .select("id", { count: "exact", head: true })
    .eq("status", "ACTIVE")
    .in("role", ["OWNER", "ADMIN"]);

  return (
    <div className="flex flex-col gap-5">
      <Section title="Profile">
        <ProfileForm initialDisplayName={profile?.display_name ?? null} email={user.email ?? ""} />
      </Section>

      <Section title="Email">
        <EmailForm currentEmail={user.email ?? ""} />
      </Section>

      <Section title="Password">
        <PasswordForm />
      </Section>

      {(ownerAdminCount ?? 0) > 0 && (
        <Section
          title="Business integrations"
          description="Connect Gmail and Drive on businesses where you're Owner or Admin."
        >
          <Link
            href="/integrations"
            className="inline-flex h-9 items-center rounded-md border border-border-default px-3 text-sm font-medium text-text-primary transition-colors hover:bg-bg-raised"
          >
            Manage integrations
          </Link>
        </Section>
      )}

      <Section
        title="Personal audit feed"
        description="A 30-day timeline of your own actions from the append-only audit log."
      >
        <PersonalAuditFeed />
      </Section>
    </div>
  );
}
