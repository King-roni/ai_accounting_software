/**
 * Helper invoked from src/proxy.ts (the Next.js 16 "proxy" — previously
 * named middleware). Refreshes the Supabase session cookie on every
 * non-static request and redirects unauthenticated traffic away from
 * gated routes.
 */
import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

// Routes that are reachable without a valid session.
const PUBLIC_ROUTES = new Set([
  "/login",
  "/signup",
  "/forgot-password",
  "/reset-password",
  "/auth/callback",
  "/auth/signout",
]);

// Routes that need a session but tolerate aal1 (the MFA challenge itself).
const AAL1_OK_ROUTES = new Set(["/login/mfa"]);

function isPublicPath(pathname: string): boolean {
  if (PUBLIC_ROUTES.has(pathname)) return true;
  // Allow Next.js internals + static assets.
  if (pathname.startsWith("/_next")) return true;
  if (pathname.startsWith("/api/health")) return true;
  return false;
}

function isAal1OkPath(pathname: string): boolean {
  return AAL1_OK_ROUTES.has(pathname);
}

export async function updateSupabaseSession(request: NextRequest) {
  let supabaseResponse = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) =>
            request.cookies.set(name, value),
          );
          supabaseResponse = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) =>
            supabaseResponse.cookies.set(name, value, options),
          );
        },
      },
    },
  );

  // Refreshes the session and re-issues cookies if needed.
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { pathname } = request.nextUrl;

  // If the user is unauthenticated and the route requires auth → /login.
  if (!user && !isPublicPath(pathname)) {
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    url.searchParams.set("next", pathname);
    return NextResponse.redirect(url);
  }

  // Authed but MFA step-up still pending: force /login/mfa.
  if (user) {
    const { data: aalData } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    const needsStepUp =
      !!aalData && aalData.currentLevel !== null && aalData.currentLevel !== aalData.nextLevel;

    if (needsStepUp && !isAal1OkPath(pathname) && pathname !== "/auth/signout") {
      const url = request.nextUrl.clone();
      url.pathname = "/login/mfa";
      return NextResponse.redirect(url);
    }

    // If the user IS authenticated AND not in step-up state, redirect
    // away from auth-entry pages.
    if (!needsStepUp && (pathname === "/login" || pathname === "/signup")) {
      const url = request.nextUrl.clone();
      url.pathname = "/";
      return NextResponse.redirect(url);
    }
  }

  return supabaseResponse;
}
