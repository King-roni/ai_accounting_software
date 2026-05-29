/**
 * Next.js 16 "proxy" (formerly `middleware`).
 *
 * Refreshes the Supabase session on every non-static request and
 * gates authenticated routes. See `src/lib/supabase/proxy-helper.ts`.
 */
import type { NextRequest } from "next/server";
import { updateSupabaseSession } from "@/lib/supabase/proxy-helper";

export async function proxy(request: NextRequest) {
  return await updateSupabaseSession(request);
}

export const config = {
  matcher: [
    // Match every path except Next.js internals + static asset extensions.
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)",
  ],
};
