-- Migration: 20260519000005_mfa_recovery_code_redemption
-- Ticket: Plane BOOK B02P03 (530bca79-637a-441e-aed9-901f66a94df5)
-- Block: 02 — Tenancy & Access Control
-- Phase: 03 — Multi-Factor Authentication
-- Description:
--   Adds a SECURITY DEFINER RPC the client calls from the /login/mfa
--   "use recovery code" path. Validates one of the caller's unconsumed
--   bcrypt-hashed recovery codes via pgcrypto's crypt(), marks it
--   consumed, deletes the user's MFA factors (forcing re-enrollment),
--   and returns the outcome. Runs as the calling user via auth.uid().

CREATE OR REPLACE FUNCTION public.redeem_mfa_recovery_code(submitted_code text)
RETURNS TABLE(redeemed boolean, factors_removed integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_auth_user_id uuid;
  v_profile_id   uuid;
  v_code_id      uuid;
  v_factors      integer;
  v_normalized   text;
BEGIN
  v_auth_user_id := auth.uid();
  IF v_auth_user_id IS NULL THEN
    RETURN QUERY SELECT false, 0;
    RETURN;
  END IF;

  SELECT id INTO v_profile_id FROM public.users WHERE auth_user_id = v_auth_user_id;
  IF v_profile_id IS NULL THEN
    RETURN QUERY SELECT false, 0;
    RETURN;
  END IF;

  -- Normalize once: trim + uppercase. Recovery codes are case-insensitive.
  v_normalized := upper(trim(submitted_code));

  -- Look for an unconsumed code whose bcrypt hash matches.
  SELECT id INTO v_code_id
  FROM public.mfa_recovery_codes
  WHERE user_id = v_profile_id
    AND consumed_at IS NULL
    AND code_hash = extensions.crypt(v_normalized, code_hash)
  FOR UPDATE
  LIMIT 1;

  IF v_code_id IS NULL THEN
    RETURN QUERY SELECT false, 0;
    RETURN;
  END IF;

  -- Mark consumed.
  UPDATE public.mfa_recovery_codes
  SET consumed_at = now()
  WHERE id = v_code_id;

  -- Force re-enrollment: delete all of the user's MFA factors. The
  -- trigger on auth.mfa_factors will refresh public.users counters.
  WITH del AS (
    DELETE FROM auth.mfa_factors WHERE user_id = v_auth_user_id RETURNING 1
  )
  SELECT count(*)::integer INTO v_factors FROM del;

  RETURN QUERY SELECT true, v_factors;
END;
$$;

GRANT EXECUTE ON FUNCTION public.redeem_mfa_recovery_code(text) TO authenticated;

COMMENT ON FUNCTION public.redeem_mfa_recovery_code(text) IS
  'Validates a submitted MFA recovery code (bcrypt-compared via pgcrypto.crypt). On match, consumes the code, deletes all auth.mfa_factors for the caller (forcing re-enrollment), and returns (true, factors_removed). On no match, returns (false, 0).';
