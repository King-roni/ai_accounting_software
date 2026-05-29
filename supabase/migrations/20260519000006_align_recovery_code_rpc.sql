-- Stage 7-3 alignment: replace redeem_mfa_recovery_code with a version that
-- invalidates the entire recovery-code batch on success. Without this, the
-- idempotency guard inside provisionRecoveryCodes() (in
-- web/src/app/account/mfa/actions.ts) sees the remaining unconsumed codes
-- from the now-orphaned batch and skips minting a fresh batch when the user
-- re-enrolls their TOTP factor, leaving them without recovery codes for the
-- new factor.

-- Defensive drops in case earlier mis-named variants survive on a fresh DB.
DROP FUNCTION IF EXISTS public.generate_recovery_codes(integer);
DROP FUNCTION IF EXISTS public.redeem_recovery_code(text);

CREATE OR REPLACE FUNCTION public.redeem_mfa_recovery_code(submitted_code text)
RETURNS TABLE(redeemed boolean, codes_remaining integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_auth_user_id uuid;
  v_user_id      uuid;
  v_match_id     uuid;
  v_batch_id     uuid;
  v_normalized   text;
  v_remaining    integer;
BEGIN
  v_auth_user_id := auth.uid();
  IF v_auth_user_id IS NULL THEN
    redeemed := false; codes_remaining := 0; RETURN NEXT; RETURN;
  END IF;

  SELECT id INTO v_user_id FROM public.users WHERE auth_user_id = v_auth_user_id;
  IF v_user_id IS NULL THEN
    redeemed := false; codes_remaining := 0; RETURN NEXT; RETURN;
  END IF;

  v_normalized := upper(regexp_replace(coalesce(submitted_code, ''), '\s', '', 'g'));
  IF length(v_normalized) = 10 AND position('-' IN v_normalized) = 0 THEN
    v_normalized := substring(v_normalized FROM 1 FOR 5) || '-' || substring(v_normalized FROM 6);
  END IF;

  SELECT id, batch_id INTO v_match_id, v_batch_id
  FROM public.mfa_recovery_codes
  WHERE user_id = v_user_id
    AND consumed_at IS NULL
    AND code_hash = extensions.crypt(v_normalized, code_hash)
  FOR UPDATE
  LIMIT 1;

  IF v_match_id IS NULL THEN
    SELECT count(*) INTO v_remaining
    FROM public.mfa_recovery_codes
    WHERE user_id = v_user_id AND consumed_at IS NULL;
    redeemed := false; codes_remaining := v_remaining; RETURN NEXT; RETURN;
  END IF;

  -- Invalidate the entire batch tied to the matched code. A successful
  -- recovery means the user is starting over, and we delete their MFA
  -- factors below; any remaining codes from that batch are orphans.
  UPDATE public.mfa_recovery_codes
  SET consumed_at = now()
  WHERE batch_id = v_batch_id
    AND consumed_at IS NULL;

  DELETE FROM auth.mfa_factors WHERE user_id = v_auth_user_id;

  SELECT count(*) INTO v_remaining
  FROM public.mfa_recovery_codes
  WHERE user_id = v_user_id AND consumed_at IS NULL;
  redeemed := true; codes_remaining := v_remaining; RETURN NEXT; RETURN;
END;
$$;

GRANT EXECUTE ON FUNCTION public.redeem_mfa_recovery_code(text) TO authenticated;

COMMENT ON FUNCTION public.redeem_mfa_recovery_code(text) IS
'Validate and consume an MFA recovery code for the calling auth user. On success, invalidates every remaining unconsumed code in the same batch and removes the user''s MFA factors so the session AAL drops back to aal1 and re-enrollment is required. Returns a single row with { redeemed, codes_remaining }.';
