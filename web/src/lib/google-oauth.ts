/**
 * Google OAuth helpers (B02·P08).
 *
 * Read-only scopes only — these are asserted at code-exchange time. Any
 * scope returned outside the requested set raises SCOPE_ASSERTION_FAILED.
 * The Google Cloud project, OAuth client IDs, EU consent screen, and
 * redirect URI registration are out-of-band setup (deferred sub-doc).
 */
import { randomBytes } from "node:crypto";

import { appOrigin } from "@/lib/app-origin";

export const GMAIL_READ_SCOPE = "https://www.googleapis.com/auth/gmail.readonly";
export const DRIVE_READ_SCOPE = "https://www.googleapis.com/auth/drive.readonly";

export type GoogleProvider = "GMAIL" | "GOOGLE_DRIVE";

export const PROVIDER_SCOPES: Record<GoogleProvider, string[]> = {
  GMAIL: [GMAIL_READ_SCOPE],
  GOOGLE_DRIVE: [DRIVE_READ_SCOPE],
};

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`${name} env var is required for OAuth flows.`);
  return v;
}

export function generateOAuthState(): string {
  return randomBytes(32).toString("hex");
}

export function buildAuthorizationUrl(input: {
  provider: GoogleProvider;
  state: string;
}): string {
  const clientId = requireEnv("GOOGLE_OAUTH_CLIENT_ID");
  const redirectUri = `${appOrigin()}/oauth/google/callback`;
  const scopes = PROVIDER_SCOPES[input.provider];
  const params = new URLSearchParams({
    client_id: clientId,
    redirect_uri: redirectUri,
    response_type: "code",
    scope: scopes.join(" "),
    access_type: "offline",
    include_granted_scopes: "false",
    prompt: "consent",
    state: input.state,
  });
  return `https://accounts.google.com/o/oauth2/v2/auth?${params.toString()}`;
}

export type GoogleTokenResponse = {
  access_token: string;
  refresh_token?: string;
  expires_in: number;
  scope: string;
  token_type: "Bearer";
};

export async function exchangeAuthorizationCode(input: {
  code: string;
}): Promise<GoogleTokenResponse> {
  const clientId = requireEnv("GOOGLE_OAUTH_CLIENT_ID");
  const clientSecret = requireEnv("GOOGLE_OAUTH_CLIENT_SECRET");
  const redirectUri = `${appOrigin()}/oauth/google/callback`;
  const body = new URLSearchParams({
    code: input.code,
    client_id: clientId,
    client_secret: clientSecret,
    redirect_uri: redirectUri,
    grant_type: "authorization_code",
  });
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`google_oauth_exchange_failed: ${res.status} ${text}`);
  }
  return (await res.json()) as GoogleTokenResponse;
}

export async function refreshAccessToken(input: {
  refreshToken: string;
}): Promise<GoogleTokenResponse> {
  const clientId = requireEnv("GOOGLE_OAUTH_CLIENT_ID");
  const clientSecret = requireEnv("GOOGLE_OAUTH_CLIENT_SECRET");
  const body = new URLSearchParams({
    refresh_token: input.refreshToken,
    client_id: clientId,
    client_secret: clientSecret,
    grant_type: "refresh_token",
  });
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`google_oauth_refresh_failed: ${res.status} ${text}`);
  }
  return (await res.json()) as GoogleTokenResponse;
}

export async function revokeToken(token: string): Promise<void> {
  // Best-effort; ignore non-2xx since the token may already be expired.
  await fetch("https://oauth2.googleapis.com/revoke", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ token }).toString(),
  }).catch(() => {});
}

export function assertScopesGranted(input: {
  expected: string[];
  granted: string;
}): { ok: true; granted: string[] } | { ok: false; missing: string[] } {
  const grantedSet = new Set(input.granted.split(/\s+/).filter(Boolean));
  const missing = input.expected.filter((s) => !grantedSet.has(s));
  if (missing.length > 0) return { ok: false, missing };
  return { ok: true, granted: Array.from(grantedSet) };
}
