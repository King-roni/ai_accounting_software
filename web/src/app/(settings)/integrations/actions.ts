"use server";

/**
 * Integration server actions (B02·P08).
 *
 *   connectIntegration(businessId, provider) — Owner/Admin only. Returns a
 *       Google OAuth authorization URL with a CSRF state cookie set. Browser
 *       navigates to it; Google redirects back to /oauth/google/callback.
 *   refreshIntegration(integrationId)        — Owner/Admin only.
 *   disconnectIntegration(integrationId,     — Owner/Admin + step-up token.
 *                          stepUpToken)
 *   saveDriveMapping(businessId, folderId,   — Owner/Admin only.
 *                     folderName?)
 */
import { cookies } from "next/headers";
import { revalidatePath } from "next/cache";

import { decryptToken, encryptToken } from "@/lib/integration-token-encryption";
import {
  PROVIDER_SCOPES,
  type GoogleProvider,
  assertScopesGranted,
  buildAuthorizationUrl,
  generateOAuthState,
  refreshAccessToken,
  revokeToken,
} from "@/lib/google-oauth";
import { createSupabaseServerClient } from "@/lib/supabase/server";

const OAUTH_STATE_COOKIE = "google_oauth_state";
const OAUTH_PENDING_COOKIE = "google_oauth_pending";

type ErrorResult = { ok: false; error: string; detail?: string };
type OkResult = { ok: true };

function audit(event: string, payload: Record<string, unknown>) {
  console.info(`[audit] ${event}`, payload);
}

export async function connectIntegration(input: {
  businessId: string;
  provider: GoogleProvider;
}): Promise<({ ok: true; authorizationUrl: string }) | ErrorResult> {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "NOT_AUTHENTICATED" };

  let url: string;
  let state: string;
  try {
    state = generateOAuthState();
    url = buildAuthorizationUrl({ provider: input.provider, state });
  } catch (err) {
    return {
      ok: false,
      error: "OAUTH_NOT_CONFIGURED",
      detail: err instanceof Error ? err.message : String(err),
    };
  }

  const cookieStore = await cookies();
  cookieStore.set(OAUTH_STATE_COOKIE, state, {
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    maxAge: 600,
  });
  cookieStore.set(
    OAUTH_PENDING_COOKIE,
    JSON.stringify({ businessId: input.businessId, provider: input.provider }),
    {
      httpOnly: true,
      sameSite: "lax",
      secure: process.env.NODE_ENV === "production",
      path: "/",
      maxAge: 600,
    },
  );
  audit("INTEGRATION_CONNECT_INITIATED", {
    user_id: user.id,
    business_id: input.businessId,
    provider: input.provider,
  });
  return { ok: true, authorizationUrl: url };
}

export async function refreshIntegration(
  integrationId: string,
): Promise<OkResult | ErrorResult> {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "NOT_AUTHENTICATED" };

  const { data: row, error: fetchErr } = await supabase
    .from("business_integrations")
    .select("id, business_id, provider, oauth_refresh_token_encrypted, status")
    .eq("id", integrationId)
    .single();
  if (fetchErr || !row) return { ok: false, error: "INTEGRATION_NOT_FOUND" };
  if (!row.oauth_refresh_token_encrypted) {
    return { ok: false, error: "INTEGRATION_NO_REFRESH_TOKEN" };
  }

  try {
    const refreshToken = decryptToken(row.oauth_refresh_token_encrypted);
    const fresh = await refreshAccessToken({ refreshToken });
    const encrypted = encryptToken(fresh.access_token);
    const expiresAt = new Date(Date.now() + fresh.expires_in * 1000).toISOString();
    const { error } = await supabase.rpc("record_integration_refresh", {
      p_integration_id: integrationId,
      p_encrypted_access_token: encrypted,
      p_encrypted_refresh_token: fresh.refresh_token
        ? encryptToken(fresh.refresh_token)
        : null,
      p_access_token_expires_at: expiresAt,
    });
    if (error) {
      audit("INTEGRATION_REFRESH_FAILED", {
        integration_id: integrationId,
        reason: error.message,
      });
      return { ok: false, error: "RPC_FAILED", detail: error.message };
    }
    audit("INTEGRATION_REFRESHED", {
      integration_id: integrationId,
      by_user_id: user.id,
    });
    revalidatePath("/integrations");
    return { ok: true };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await supabase.rpc("record_integration_refresh_failed", {
      p_integration_id: integrationId,
      p_error_message: message.slice(0, 1000),
    });
    audit("INTEGRATION_REFRESH_FAILED", {
      integration_id: integrationId,
      reason: message,
    });
    revalidatePath("/integrations");
    return { ok: false, error: "REFRESH_FAILED", detail: message };
  }
}

export async function disconnectIntegration(input: {
  integrationId: string;
  stepUpToken: string;
}): Promise<OkResult | ErrorResult> {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "NOT_AUTHENTICATED" };

  const { data: row } = await supabase
    .from("business_integrations")
    .select("id, oauth_access_token_encrypted")
    .eq("id", input.integrationId)
    .single();
  // Revoke at Google before clearing the row so the token can't outlive us
  if (row?.oauth_access_token_encrypted) {
    try {
      const accessToken = decryptToken(row.oauth_access_token_encrypted);
      await revokeToken(accessToken);
    } catch {
      // best-effort revoke; the row gets disconnected regardless
    }
  }

  const { data: ok, error } = await supabase.rpc("record_integration_disconnect", {
    p_integration_id: input.integrationId,
    p_step_up_token: input.stepUpToken,
  });
  if (error) {
    audit("INTEGRATION_DISCONNECT_FAILED", {
      integration_id: input.integrationId,
      reason: error.message,
    });
    return {
      ok: false,
      error: error.message.startsWith("INTEGRATION_STEP_UP_REJECTED")
        ? "STEP_UP_REJECTED"
        : "RPC_FAILED",
      detail: error.message,
    };
  }
  if (!ok) return { ok: false, error: "INTEGRATION_NOT_FOUND" };
  audit("INTEGRATION_DISCONNECTED", {
    integration_id: input.integrationId,
    by_user_id: user.id,
  });
  revalidatePath("/integrations");
  return { ok: true };
}

export async function saveDriveMapping(input: {
  businessId: string;
  rootFolderId: string;
  rootFolderName?: string;
}): Promise<OkResult | ErrorResult> {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "NOT_AUTHENTICATED" };

  const { error } = await supabase.rpc("save_drive_folder_mapping", {
    p_business_id: input.businessId,
    p_root_folder_id: input.rootFolderId,
    p_root_folder_name: input.rootFolderName ?? null,
  });
  if (error) {
    return { ok: false, error: "RPC_FAILED", detail: error.message };
  }
  audit("DRIVE_FOLDER_MAPPING_SAVED", {
    business_id: input.businessId,
    root_folder_id: input.rootFolderId,
    user_id: user.id,
  });
  revalidatePath("/integrations");
  return { ok: true };
}

/**
 * Completes the OAuth callback. Called from the /oauth/google/callback route
 * handler with the code + state, plus the cookies we set in connectIntegration.
 */
export async function completeOAuthCallback(input: {
  code: string;
  state: string;
}): Promise<
  | { ok: true; integrationId: string; provider: GoogleProvider }
  | ErrorResult
> {
  const cookieStore = await cookies();
  const expectedState = cookieStore.get(OAUTH_STATE_COOKIE)?.value;
  const pendingRaw = cookieStore.get(OAUTH_PENDING_COOKIE)?.value;
  if (!expectedState || !pendingRaw) {
    return { ok: false, error: "OAUTH_STATE_MISSING" };
  }
  if (expectedState !== input.state) {
    return { ok: false, error: "OAUTH_STATE_MISMATCH" };
  }
  let pending: { businessId: string; provider: GoogleProvider };
  try {
    pending = JSON.parse(pendingRaw);
  } catch {
    return { ok: false, error: "OAUTH_PENDING_CORRUPT" };
  }
  cookieStore.delete(OAUTH_STATE_COOKIE);
  cookieStore.delete(OAUTH_PENDING_COOKIE);

  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "NOT_AUTHENTICATED" };

  const { exchangeAuthorizationCode } = await import("@/lib/google-oauth");
  let tokens;
  try {
    tokens = await exchangeAuthorizationCode({ code: input.code });
  } catch (err) {
    return {
      ok: false,
      error: "OAUTH_EXCHANGE_FAILED",
      detail: err instanceof Error ? err.message : String(err),
    };
  }

  const scopeCheck = assertScopesGranted({
    expected: PROVIDER_SCOPES[pending.provider],
    granted: tokens.scope,
  });
  if (!scopeCheck.ok) {
    return {
      ok: false,
      error: "SCOPE_ASSERTION_FAILED",
      detail: `missing: ${scopeCheck.missing.join(", ")}`,
    };
  }

  const expiresAt = new Date(Date.now() + tokens.expires_in * 1000).toISOString();
  const encryptedAccess = encryptToken(tokens.access_token);
  const encryptedRefresh = tokens.refresh_token
    ? encryptToken(tokens.refresh_token)
    : null;

  const { data: integrationId, error: rpcErr } = await supabase.rpc(
    "record_integration_connect",
    {
      p_business_id: pending.businessId,
      p_provider: pending.provider,
      p_scope: scopeCheck.granted,
      p_encrypted_access_token: encryptedAccess,
      p_encrypted_refresh_token: encryptedRefresh,
      p_access_token_expires_at: expiresAt,
    },
  );
  if (rpcErr || !integrationId) {
    return {
      ok: false,
      error: rpcErr?.message?.includes("REQUIRES_OWNER_OR_ADMIN")
        ? "REQUIRES_OWNER_OR_ADMIN"
        : "RPC_FAILED",
      detail: rpcErr?.message,
    };
  }
  audit("INTEGRATION_CONNECTED", {
    integration_id: integrationId,
    business_id: pending.businessId,
    provider: pending.provider,
    by_user_id: user.id,
  });
  revalidatePath("/integrations");
  return {
    ok: true,
    integrationId: integrationId as string,
    provider: pending.provider,
  };
}
