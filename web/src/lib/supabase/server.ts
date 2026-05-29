/**
 * Server-side Supabase client for Next.js App Router.
 *
 * Reads/writes the session cookie via Next.js `cookies()` (async in v15+).
 * Use this in server components, route handlers, and server actions.
 */
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

export async function createSupabaseServerClient() {
  const cookieStore = await cookies();

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options),
            );
          } catch {
            // `set` can be called from a Server Component which has no
            // write access to cookies. Ignored — proxy.ts refreshes
            // the session on the next request.
          }
        },
      },
    },
  );
}
