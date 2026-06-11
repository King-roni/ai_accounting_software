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

  // BOOK-972: attach the caller's role per business so the shell can gate action
  // affordances by role (the server still enforces can_perform / RLS).
  const { data: roleRows } = await supabase
    .from("business_user_roles")
    .select("business_id, role")
    .eq("user_id", profile?.id ?? "")
    .eq("status", "ACTIVE");
  const roleByBusiness = new Map((roleRows ?? []).map((r) => [r.business_id, r.role as string]));
  const businessesWithRole = businesses.map((b) => ({ ...b, role: roleByBusiness.get(b.id) ?? null }));

  // Default the shell to the period that actually has data so screens don't
  // open on an empty future month. We use the first accessible business — the
  // same default the shell picks client-side — and fall back to the current
  // month if there's no data (or the query fails for any reason).
  const now = new Date();
  let initialPeriod = { year: now.getUTCFullYear(), month: now.getUTCMonth() + 1 };
  try {
    const { data: latestTxn } = await supabase
      .from("transactions")
      .select("transaction_date")
      .eq("business_id", businesses[0].id)
      .order("transaction_date", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (latestTxn?.transaction_date) {
      const d = new Date(latestTxn.transaction_date);
      initialPeriod = { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1 };
    }
  } catch {
    // Keep the current-month fallback — never crash the layout over this.
  }

  return (
    <AppShell
      user={{ id: profile?.id ?? "", email: user.email ?? profile?.email ?? "", displayName: profile?.display_name ?? null }}
      businesses={businessesWithRole}
      initialPeriod={initialPeriod}
    >
      {children}
    </AppShell>
  );
}
