"use server";

/**
 * Export download (P0.5). Generated export artifacts live in the private
 * export-artifacts bucket, so the browser can't fetch them directly. This mints
 * a short-lived signed download URL server-side (service role) for a COMPLETED
 * export the caller can see, and records the download. Generation of the file
 * itself is the R7.1 export worker; until then exports stay PENDING and the
 * Reports download button is disabled.
 */
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { createSupabaseServerClient } from "@/lib/supabase/server";

const EXPORT_BUCKET = "export-artifacts";
const SIGNED_URL_TTL_SECONDS = 300;

export async function getExportDownloadUrl(
  exportId: string,
): Promise<{ ok: true; url: string } | { ok: false; error: string }> {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "NOT_AUTHENTICATED" };

  // RLS-filtered: the caller can only read exports for businesses they can access.
  const { data: exp, error } = await supabase
    .from("exports")
    .select("id, status, storage_object_id")
    .eq("id", exportId)
    .maybeSingle();
  if (error) return { ok: false, error: error.message };
  if (!exp) return { ok: false, error: "EXPORT_NOT_FOUND" };
  if (exp.status !== "COMPLETED" || !exp.storage_object_id) {
    return { ok: false, error: "EXPORT_NOT_READY" };
  }

  const admin = createSupabaseAdminClient();
  const { data: signed, error: signErr } = await admin.storage
    .from(EXPORT_BUCKET)
    .createSignedUrl(exp.storage_object_id, SIGNED_URL_TTL_SECONDS);
  if (signErr || !signed?.signedUrl) {
    return { ok: false, error: signErr?.message ?? "SIGN_FAILED" };
  }

  // Record the download (best-effort) against the public.users actor id.
  const { data: profile } = await admin
    .from("users")
    .select("id")
    .eq("auth_user_id", user.id)
    .maybeSingle();
  if (profile?.id) {
    await admin.rpc("record_export_download", {
      p_export_id: exportId,
      p_actor_user_id: profile.id,
      p_context: {},
    });
  }

  return { ok: true, url: signed.signedUrl };
}
