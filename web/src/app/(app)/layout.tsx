import { redirect } from "next/navigation";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AppShell } from "@/components/shell/AppShell";

/**
 * Authenticated app shell layout. Gates auth, loads the user profile and the
 * RLS-filtered set of businesses the user can access, and renders the shell.
 */
export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: profile } = await supabase
    .from("users")
    .select("id, display_name, email")
    .eq("auth_user_id", user.id)
    .single();

  const { data: businesses } = await supabase
    .from("business_entities")
    .select("id, display_name, organization_id")
    .order("display_name");

  // First-run: a user with no accessible business is sent to onboarding to
  // create their organization + first business (P0.3 self-serve bootstrap).
  if (!businesses || businesses.length === 0) redirect("/onboarding");

  const now = new Date();
  return (
    <AppShell
      user={{ id: profile?.id ?? "", email: user.email ?? profile?.email ?? "", displayName: profile?.display_name ?? null }}
      businesses={businesses ?? []}
      initialPeriod={{ year: now.getFullYear(), month: now.getMonth() + 1 }}
    >
      {children}
    </AppShell>
  );
}
