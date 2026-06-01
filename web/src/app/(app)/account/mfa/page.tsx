import { redirect } from "next/navigation";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { Alert } from "@/components/ui";
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

  const { count: remainingCodes } = await supabase
    .from("mfa_recovery_codes")
    .select("id", { count: "exact", head: true })
    .eq("user_id", await getProfileId(supabase, user.id))
    .is("consumed_at", null);

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-text-secondary">
        Add an authenticator app to protect sign-in. TOTP only in this iteration; WebAuthn / passkeys
        are deferred.
      </p>

      {searchParams.enrolled && <Alert variant="status-success" title="TOTP factor enrolled." />}
      {searchParams.removed && <Alert variant="status-info" title="Factor removed." />}
      {searchParams.error && (
        <Alert variant="status-danger" title="Something went wrong">{decodeURIComponent(searchParams.error)}</Alert>
      )}

      <section className="rounded-xl border border-border-subtle bg-surface-default p-5 shadow-1">
        <h2 className="text-sm font-semibold text-text-primary">Authenticator app (TOTP)</h2>
        {verifiedTotp.length === 0 ? (
          <>
            <p className="mt-1 text-sm text-text-secondary">
              No factor enrolled. Add an authenticator app (Google Authenticator, 1Password, Authy…)
              to protect Owner / Admin / Accountant accounts.
            </p>
            <div className="mt-4">
              <EnrollFlow />
            </div>
          </>
        ) : (
          <ul className="mt-3 flex flex-col gap-3">
            {verifiedTotp.map((f) => (
              <li
                key={f.id}
                className="flex items-center justify-between rounded-md border border-border-subtle bg-bg-raised px-4 py-3"
              >
                <div>
                  <p className="text-sm font-medium text-text-primary">
                    {f.friendly_name ?? "Authenticator app"}
                  </p>
                  <p className="font-mono text-xs text-text-muted">
                    {f.id.slice(0, 8)}… · enrolled {new Date(f.created_at).toLocaleDateString("en-GB")}
                  </p>
                </div>
                <form action={unenrollFactor}>
                  <input type="hidden" name="factorId" value={f.id} />
                  <button
                    type="submit"
                    className="inline-flex h-8 cursor-pointer items-center rounded-md border border-border-default px-3 text-xs font-medium transition-colors hover:bg-surface-default"
                    style={{ color: "var(--color-status-danger)" }}
                  >
                    Remove
                  </button>
                </form>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="rounded-xl border border-border-subtle bg-surface-default p-5 shadow-1">
        <h2 className="text-sm font-semibold text-text-primary">Recovery codes</h2>
        <p className="mt-1 text-sm text-text-secondary">
          {remainingCodes ?? 0} unconsumed codes remaining. Recovery codes let you sign in once if
          you lose access to your authenticator.
        </p>
        <p className="mt-2 text-xs text-text-muted">
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
