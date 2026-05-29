import { redirect } from "next/navigation";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import EnrollFlow from "./EnrollFlow";
import { unenrollFactor } from "./actions";

export default async function MfaSettingsPage(props: {
  searchParams: Promise<{ enrolled?: string; removed?: string; error?: string }>;
}) {
  const searchParams = await props.searchParams;
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: factorsData } = await supabase.auth.mfa.listFactors();
  const verifiedTotp = factorsData?.totp.filter((f) => f.status === "verified") ?? [];

  // Remaining unconsumed recovery codes count.
  const { count: remainingCodes } = await supabase
    .from("mfa_recovery_codes")
    .select("id", { count: "exact", head: true })
    .eq("user_id", await getProfileId(supabase, user.id))
    .is("consumed_at", null);

  return (
    <div className="space-y-8">
      <header>
        <h1 className="text-2xl font-semibold text-zinc-900 dark:text-zinc-50">
          Multi-factor authentication
        </h1>
        <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
          B02·P03 baseline. TOTP only in this iteration; WebAuthn / passkeys deferred.
        </p>
      </header>

      {searchParams.enrolled && (
        <Banner kind="success">TOTP factor enrolled.</Banner>
      )}
      {searchParams.removed && (
        <Banner kind="info">Factor removed.</Banner>
      )}
      {searchParams.error && (
        <Banner kind="error">{decodeURIComponent(searchParams.error)}</Banner>
      )}

      <section className="rounded-xl border border-zinc-200 bg-white p-6 shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
        <h2 className="text-lg font-medium text-zinc-900 dark:text-zinc-50">Authenticator app (TOTP)</h2>
        {verifiedTotp.length === 0 ? (
          <>
            <p className="mt-2 text-sm text-zinc-500 dark:text-zinc-400">
              No factor enrolled. Add an authenticator app (Google Authenticator, 1Password, Authy…)
              to protect sign-in for Owner / Admin / Accountant accounts.
            </p>
            <div className="mt-4">
              <EnrollFlow />
            </div>
          </>
        ) : (
          <ul className="mt-4 space-y-3">
            {verifiedTotp.map((f) => (
              <li
                key={f.id}
                className="flex items-center justify-between rounded-md border border-zinc-200 bg-zinc-50 px-4 py-3 dark:border-zinc-700 dark:bg-zinc-800"
              >
                <div>
                  <p className="text-sm font-medium text-zinc-900 dark:text-zinc-50">
                    {f.friendly_name ?? "Authenticator app"}
                  </p>
                  <p className="font-mono text-xs text-zinc-500 dark:text-zinc-400">
                    {f.id.slice(0, 8)}… · enrolled {new Date(f.created_at).toLocaleDateString()}
                  </p>
                </div>
                <form action={unenrollFactor}>
                  <input type="hidden" name="factorId" value={f.id} />
                  <button
                    type="submit"
                    className="rounded-md border border-red-300 px-3 py-1.5 text-xs font-medium text-red-700 hover:bg-red-50 dark:border-red-700 dark:text-red-300 dark:hover:bg-red-950"
                  >
                    Remove
                  </button>
                </form>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="rounded-xl border border-zinc-200 bg-white p-6 shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
        <h2 className="text-lg font-medium text-zinc-900 dark:text-zinc-50">Recovery codes</h2>
        <p className="mt-2 text-sm text-zinc-500 dark:text-zinc-400">
          {remainingCodes ?? 0} unconsumed codes remaining. Recovery codes let you sign in once if
          you lose access to your authenticator.
        </p>
        <p className="mt-2 text-xs text-zinc-400 dark:text-zinc-500">
          Codes are generated once during TOTP enrollment. Regeneration UI lands in a follow-up.
        </p>
      </section>
    </div>
  );
}

/** Resolve the public.users.id for the current auth user. */
async function getProfileId(
  supabase: Awaited<ReturnType<typeof createSupabaseServerClient>>,
  authUserId: string,
): Promise<string | null> {
  const { data } = await supabase
    .from("users")
    .select("id")
    .eq("auth_user_id", authUserId)
    .single();
  return data?.id ?? null;
}

function Banner({ kind, children }: { kind: "success" | "info" | "error"; children: React.ReactNode }) {
  const palette = {
    success: "border-green-300 bg-green-50 text-green-900 dark:border-green-800 dark:bg-green-950 dark:text-green-100",
    info: "border-blue-300 bg-blue-50 text-blue-900 dark:border-blue-800 dark:bg-blue-950 dark:text-blue-100",
    error: "border-red-300 bg-red-50 text-red-900 dark:border-red-800 dark:bg-red-950 dark:text-red-100",
  }[kind];
  return (
    <div className={`rounded-md border px-4 py-3 text-sm ${palette}`}>{children}</div>
  );
}
