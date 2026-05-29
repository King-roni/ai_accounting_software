import Link from "next/link";
import { redirect } from "next/navigation";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export default async function Home() {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // proxy.ts already gates this; redirect defensively if anything slips through.
  if (!user) redirect("/login");

  // Pull the mirrored profile row to confirm the auth-sync trigger fired.
  const { data: profile } = await supabase
    .from("users")
    .select("id, email, display_name, email_verified, mfa_enabled, mfa_factors_count, created_at")
    .eq("auth_user_id", user.id)
    .single();

  const { data: aalData } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();

  return (
    <div className="flex flex-1 items-center justify-center bg-zinc-50 px-4 py-12 dark:bg-zinc-950">
      <div className="w-full max-w-xl rounded-xl border border-zinc-200 bg-white p-8 shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
        <h1 className="text-2xl font-semibold text-zinc-900 dark:text-zinc-50">
          You&apos;re signed in
        </h1>
        <p className="mt-2 text-sm text-zinc-500 dark:text-zinc-400">
          Stage 7-2 (B02·P02) Authentication Baseline. Post-login landing
          page; B16 Dashboard will replace this surface.
        </p>

        <dl className="mt-6 grid grid-cols-[max-content_1fr] gap-x-6 gap-y-3 text-sm">
          <dt className="font-medium text-zinc-700 dark:text-zinc-300">auth.users.id</dt>
          <dd className="font-mono text-zinc-900 dark:text-zinc-50">{user.id}</dd>

          <dt className="font-medium text-zinc-700 dark:text-zinc-300">Auth email</dt>
          <dd className="text-zinc-900 dark:text-zinc-50">{user.email}</dd>

          <dt className="font-medium text-zinc-700 dark:text-zinc-300">Auth verified</dt>
          <dd className="text-zinc-900 dark:text-zinc-50">
            {user.email_confirmed_at ? "yes" : "no"}
          </dd>

          {profile ? (
            <>
              <dt className="font-medium text-zinc-700 dark:text-zinc-300">public.users.id</dt>
              <dd className="font-mono text-zinc-900 dark:text-zinc-50">{profile.id}</dd>

              <dt className="font-medium text-zinc-700 dark:text-zinc-300">Display name</dt>
              <dd className="text-zinc-900 dark:text-zinc-50">
                {profile.display_name ?? "—"}
              </dd>

              <dt className="font-medium text-zinc-700 dark:text-zinc-300">Profile verified</dt>
              <dd className="text-zinc-900 dark:text-zinc-50">
                {profile.email_verified ? "yes" : "no"}
              </dd>

              <dt className="font-medium text-zinc-700 dark:text-zinc-300">MFA</dt>
              <dd className="text-zinc-900 dark:text-zinc-50">
                {profile.mfa_enabled
                  ? `${profile.mfa_factors_count} factor(s) verified · session AAL: ${aalData?.currentLevel ?? "—"}`
                  : "not enrolled"}
              </dd>
            </>
          ) : (
            <>
              <dt className="font-medium text-amber-700 dark:text-amber-400">public.users</dt>
              <dd className="text-amber-700 dark:text-amber-400">
                profile row not found — sync trigger may have failed
              </dd>
            </>
          )}
        </dl>

        <div className="mt-8 flex items-center gap-3">
          <Link
            href="/account/mfa"
            className="rounded-md border border-zinc-300 bg-white px-4 py-2 text-sm font-medium text-zinc-900 hover:bg-zinc-100 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100 dark:hover:bg-zinc-800"
          >
            Manage MFA
          </Link>
          <form action="/auth/signout" method="post">
            <button
              type="submit"
              className="rounded-md border border-zinc-300 bg-white px-4 py-2 text-sm font-medium text-zinc-900 hover:bg-zinc-100 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100 dark:hover:bg-zinc-800"
            >
              Sign out
            </button>
          </form>
        </div>
      </div>
    </div>
  );
}
