"use server";

/**
 * Step-up authentication server actions (B02·P06).
 *
 * verifyStepUp performs the full server-side flow:
 *   1. Issue a Supabase Auth MFA challenge for the chosen factor.
 *   2. Verify the user-supplied TOTP code.
 *   3. On success, call issue_step_up_token (Postgres RPC) to mint a
 *      single-use token bound to (user, business, surface, factor).
 *
 * The challenge+verify must happen server-side: if the client could call
 * issue_step_up_token directly it would bypass MFA entirely. The RPC
 * itself only checks active business role, so the server action is the
 * MFA gate.
 *
 * Returns a discriminated result. The caller (StepUpModal) decides how to
 * surface failures and whether to retry.
 */

import { createSupabaseServerClient } from "@/lib/supabase/server";

type VerifyStepUpInput = {
  factorId: string;
  code: string;
  businessId: string;
  surface: string;
};

export type VerifyStepUpResult =
  | { ok: true; tokenId: string }
  | {
      ok: false;
      error:
        | "INVALID_CODE"
        | "NOT_AUTHENTICATED"
        | "NO_BUSINESS_ROLE"
        | "FACTOR_NOT_FOUND"
        | "INTERNAL";
      detail?: string;
    };

export async function verifyStepUp(
  input: VerifyStepUpInput,
): Promise<VerifyStepUpResult> {
  const { factorId, code, businessId, surface } = input;

  if (!factorId || !code || !businessId || !surface) {
    return { ok: false, error: "INTERNAL", detail: "missing required fields" };
  }

  const supabase = await createSupabaseServerClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    return { ok: false, error: "NOT_AUTHENTICATED" };
  }

  // Step 1 — Issue an MFA challenge server-side. The challengeId never
  // leaves the server, so a client can't replay it independently.
  const { data: challengeData, error: challengeErr } =
    await supabase.auth.mfa.challenge({ factorId });
  if (challengeErr || !challengeData) {
    // STEP_UP_FAILED audit
    console.warn("[audit] STEP_UP_CHALLENGE_FAILED", {
      user_id: user.id,
      business_id: businessId,
      surface,
      factor_id: factorId,
      reason: "CHALLENGE_ISSUE_FAILED",
      detail: challengeErr?.message,
    });
    return {
      ok: false,
      error: "FACTOR_NOT_FOUND",
      detail: challengeErr?.message ?? "challenge failed",
    };
  }
  // STEP_UP_CHALLENGE_REQUESTED
  console.info("[audit] STEP_UP_CHALLENGE_REQUESTED", {
    user_id: user.id,
    business_id: businessId,
    surface,
    factor_id: factorId,
    challenge_id: challengeData.id,
  });

  // Step 2 — Verify the user-supplied TOTP code.
  const { error: verifyErr } = await supabase.auth.mfa.verify({
    factorId,
    challengeId: challengeData.id,
    code: code.trim(),
  });
  if (verifyErr) {
    console.warn("[audit] STEP_UP_CHALLENGE_FAILED", {
      user_id: user.id,
      business_id: businessId,
      surface,
      factor_id: factorId,
      reason: "VERIFY_REJECTED",
      detail: verifyErr.message,
    });
    return { ok: false, error: "INVALID_CODE", detail: verifyErr.message };
  }

  // Step 3 — Issue the step-up token. The RPC validates business role.
  const { data: tokenId, error: rpcErr } = await supabase.rpc(
    "issue_step_up_token",
    {
      p_business_id: businessId,
      p_surface: surface,
      p_factor_id: factorId,
    },
  );
  if (rpcErr || !tokenId) {
    // The challenge already succeeded — failure here is a role/integrity issue.
    const code =
      typeof rpcErr?.message === "string" &&
      rpcErr.message.includes("STEP_UP_NO_ROLE_ON_BUSINESS")
        ? "NO_BUSINESS_ROLE"
        : "INTERNAL";
    console.warn("[audit] STEP_UP_CHALLENGE_FAILED", {
      user_id: user.id,
      business_id: businessId,
      surface,
      factor_id: factorId,
      reason: code,
      detail: rpcErr?.message,
    });
    return { ok: false, error: code, detail: rpcErr?.message };
  }

  console.info("[audit] STEP_UP_CHALLENGE_PASSED", {
    user_id: user.id,
    business_id: businessId,
    surface,
    factor_id: factorId,
    token_id: tokenId,
  });

  return { ok: true, tokenId: tokenId as string };
}
