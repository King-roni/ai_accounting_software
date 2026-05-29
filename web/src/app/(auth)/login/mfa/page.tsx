import { redirect } from "next/navigation";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import MfaChallenge from "./MfaChallenge";

export default async function LoginMfaPage(props: {
  searchParams: Promise<{ error?: string }>;
}) {
  const searchParams = await props.searchParams;
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: aalData } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  // Already at the required AAL — no challenge needed.
  if (aalData?.currentLevel === aalData?.nextLevel) {
    redirect("/");
  }

  const { data: factorsData } = await supabase.auth.mfa.listFactors();
  const factors =
    factorsData?.totp.filter((f) => f.status === "verified") ?? [];
  if (factors.length === 0) {
    // Shouldn't happen — no verified factor but AAL says we need step-up.
    redirect("/");
  }

  return (
    <div>
      <h2 className="mb-4 text-lg font-medium text-zinc-900 dark:text-zinc-50">
        Verify your second factor
      </h2>
      <p className="mb-4 text-sm text-zinc-500 dark:text-zinc-400">
        Signed in as <span className="font-medium text-zinc-700 dark:text-zinc-300">{user.email}</span>.
        Enter the 6-digit code from your authenticator app to continue.
      </p>
      <MfaChallenge
        factors={factors.map((f) => ({
          id: f.id,
          friendlyName: f.friendly_name ?? "Authenticator app",
        }))}
        initialError={searchParams.error ?? null}
      />
    </div>
  );
}
