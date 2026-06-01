"use server";

import { redirect } from "next/navigation";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { generateRecoveryCodeBatch } from "@/lib/recovery-codes";

/**
 * Called from the client EnrollFlow after a TOTP factor is successfully
 * verified. Generates and persists a batch of 8 recovery codes for the
 * user, returning the plaintext so the client can show them once.
 *
 * Idempotent guard: only generates codes if the user has zero
 * unconsumed codes (so accidental double-click doesn't pile up batches).
 */
export async function provisionRecoveryCodes(): Promise<{
  codes?: string[];
  error?: string;
  skipped?: boolean;
}> {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "Not authenticated" };

  const { data: profile, error: profileErr } = await supabase
    .from("users")
    .select("id")
    .eq("auth_user_id", user.id)
    .single();
  if (profileErr || !profile) return { error: "Profile row missing" };

  const { count: existing } = await supabase
    .from("mfa_recovery_codes")
    .select("id", { count: "exact", head: true })
    .eq("user_id", profile.id)
    .is("consumed_at", null);

  if ((existing ?? 0) > 0) {
    return { skipped: true };
  }

  const batch = await generateRecoveryCodeBatch();
  const rows = batch.hashed.map((r) => ({ ...r, user_id: profile.id }));
  const { error: insertErr } = await supabase.from("mfa_recovery_codes").insert(rows);
  if (insertErr) return { error: insertErr.message };

  return { codes: batch.plaintext };
}

/** Remove a verified factor. Re-auth requirement is enforced by Supabase Auth (aal2 session). */
export async function unenrollFactor(formData: FormData) {
  const factorId = String(formData.get("factorId") ?? "");
  if (!factorId) redirect("/account/mfa?error=Missing+factorId");

  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.auth.mfa.unenroll({ factorId });
  if (error) {
    redirect(`/account/mfa?error=${encodeURIComponent(error.message)}`);
  }
  redirect("/account/mfa?removed=1");
}
