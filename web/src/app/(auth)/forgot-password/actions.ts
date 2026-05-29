"use server";

import { redirect } from "next/navigation";
import { headers } from "next/headers";
import { appOrigin } from "@/lib/app-origin";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { forgotPasswordSchema } from "@/lib/validation";

export async function requestReset(formData: FormData) {
  const parsed = forgotPasswordSchema.safeParse({
    email: formData.get("email"),
  });

  if (!parsed.success) {
    redirect(
      `/forgot-password?error=${encodeURIComponent(parsed.error.issues[0]?.message ?? "Invalid email")}`,
    );
  }

  const supabase = await createSupabaseServerClient();
  const reqHeaders = await headers();
  const origin = reqHeaders.get("origin") ?? appOrigin();

  // Supabase always returns a generic success regardless of whether the
  // email exists — prevents account-enumeration.
  await supabase.auth.resetPasswordForEmail(parsed.data.email, {
    redirectTo: `${origin}/auth/callback?next=/reset-password`,
  });

  redirect(
    `/login?notice=${encodeURIComponent("If an account exists for that email, a reset link has been sent.")}`,
  );
}
