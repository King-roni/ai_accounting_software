/**
 * Browser-side Supabase client.
 *
 * Use this in client components for live auth state and direct DB queries
 * (subject to RLS once it lands in Phase 05). Cookies are read/written
 * automatically by @supabase/ssr's browser helper.
 */
import { createBrowserClient } from "@supabase/ssr";

export function createSupabaseBrowserClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
  );
}
