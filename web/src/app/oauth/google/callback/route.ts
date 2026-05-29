/**
 * Google OAuth callback (B02·P08).
 *
 * Google redirects here after the user grants consent. We delegate the
 * actual exchange + storage to completeOAuthCallback (server action) and
 * redirect back to /integrations with a status hint.
 */
import { NextRequest, NextResponse } from "next/server";

import { completeOAuthCallback } from "@/app/(settings)/integrations/actions";

export async function GET(request: NextRequest) {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  const errorParam = url.searchParams.get("error");

  const origin = url.origin;
  if (errorParam) {
    return NextResponse.redirect(
      `${origin}/integrations?error=${encodeURIComponent(errorParam)}`,
    );
  }
  if (!code || !state) {
    return NextResponse.redirect(
      `${origin}/integrations?error=missing_code_or_state`,
    );
  }

  const result = await completeOAuthCallback({ code, state });
  if (!result.ok) {
    return NextResponse.redirect(
      `${origin}/integrations?error=${encodeURIComponent(result.error)}`,
    );
  }
  return NextResponse.redirect(`${origin}/integrations?connected=${result.provider}`);
}
