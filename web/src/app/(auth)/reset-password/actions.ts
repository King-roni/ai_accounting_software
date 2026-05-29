"use server";

import { redirect } from "next/navigation";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { resetPasswordSchema } from "@/lib/validation";

export async function resetPassword(formData: FormData) {
  const parsed = resetPasswordSchema.safeParse({
    password: formData.get("password"),
    confirm: formData.get("confirm"),
  });

  if (!parsed.success) {
    redirect(
      `/reset-password?error=${encodeURIComponent(parsed.error.issues[0]?.message ?? "Invalid input")}`,
    );
  }

  // The user reached this page from /auth/callback after clicking the
  // password-reset link, so a recovery session is attached to the
  // cookie. updateUser() rewrites their password using that session.
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.auth.updateUser({
    password: parsed.data.password,
  });

  if (error) {
    redirect(`/reset-password?error=${encodeURIComponent(error.message)}`);
  }

  // Sign out to invalidate the recovery session and force a fresh login.
  await supabase.auth.signOut();
  redirect(`/login?notice=${encodeURIComponent("Password updated. Sign in to continue.")}`);
}
