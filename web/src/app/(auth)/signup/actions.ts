"use server";

import { redirect } from "next/navigation";
import { headers } from "next/headers";
import { appOrigin } from "@/lib/app-origin";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { signupSchema } from "@/lib/validation";

export async function signup(formData: FormData) {
  const parsed = signupSchema.safeParse({
    email: formData.get("email"),
    password: formData.get("password"),
    displayName: formData.get("displayName"),
  });

  if (!parsed.success) {
    redirect(
      `/signup?error=${encodeURIComponent(parsed.error.issues[0]?.message ?? "Invalid input")}`,
    );
  }

  const supabase = await createSupabaseServerClient();
  const reqHeaders = await headers();
  const origin = reqHeaders.get("origin") ?? appOrigin();

  const { error } = await supabase.auth.signUp({
    email: parsed.data.email,
    password: parsed.data.password,
    options: {
      data: { display_name: parsed.data.displayName },
      emailRedirectTo: `${origin}/auth/callback`,
    },
  });

  if (error) {
    redirect(`/signup?error=${encodeURIComponent(error.message)}`);
  }

  // Supabase Auth's default flow sends a confirmation email; the user
  // clicks the link → /auth/callback → /. Show a "check your email"
  // landing in the meantime.
  redirect(`/login?notice=${encodeURIComponent("Check your email to confirm your account.")}`);
}
