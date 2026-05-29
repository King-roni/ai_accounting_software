/**
 * Service-role Supabase client — bypasses RLS and exposes admin APIs.
 *
 * Used by server-only code that performs trusted operations (e.g.,
 * sending invitation emails via `auth.admin.inviteUserByEmail`). Never
 * import this from a client component.
 */
import { createClient } from "@supabase/supabase-js";

export function createSupabaseAdminClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !serviceRoleKey) {
    throw new Error(
      "createSupabaseAdminClient: NEXT_PUBLIC_SUPABASE_URL and " +
        "SUPABASE_SERVICE_ROLE_KEY must be set in the server environment.",
    );
  }

  return createClient(url, serviceRoleKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  });
}
