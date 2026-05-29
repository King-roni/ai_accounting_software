"use server";

/**
 * Account settings server actions (B02·P11).
 *
 * Profile field updates flow through the RLS-gated public.users table
 * (users_update_self policy from B02·P05). Password and email changes
 * are performed client-side via supabase.auth.updateUser since they
 * mutate auth.users — the server doesn't proxy those.
 */
import { revalidatePath } from "next/cache";

import { createSupabaseServerClient } from "@/lib/supabase/server";

type ErrorResult = { ok: false; error: string; detail?: string };
type OkResult = { ok: true };

function audit(event: string, payload: Record<string, unknown>) {
  console.info(`[audit] ${event}`, payload);
}

export async function updateProfile(input: {
  displayName: string;
}): Promise<OkResult | ErrorResult> {
  const trimmed = input.displayName.trim();
  if (trimmed.length > 120) {
    return { ok: false, error: "VALIDATION", detail: "display name too long" };
  }

  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "NOT_AUTHENTICATED" };

  const { error } = await supabase
    .from("users")
    .update({ display_name: trimmed || null })
    .eq("auth_user_id", user.id);
  if (error) {
    audit("PROFILE_UPDATE_FAILED", {
      auth_user_id: user.id,
      reason: error.message,
    });
    return { ok: false, error: "RPC_FAILED", detail: error.message };
  }
  audit("PROFILE_UPDATED", {
    auth_user_id: user.id,
    fields: ["display_name"],
  });
  revalidatePath("/account");
  return { ok: true };
}
