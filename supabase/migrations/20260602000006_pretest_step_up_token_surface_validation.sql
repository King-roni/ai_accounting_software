-- =============================================================================
-- Pretest fix (2026-06-02) — N6: validate surface at issue_step_up_token mint
-- =============================================================================
-- issue_step_up_token minted a token for any free-text p_surface with no
-- validity check (only active-role). This let the finalize UI mint a token for a
-- surface the consumer never expects (the C2 FINALIZATION vs APPROVAL_STEP_UP
-- mismatch). Validate the surface against the known set (the live
-- permission_matrix) at mint so unknown/typo surfaces fail fast instead of
-- producing a token that can never be consumed. Body otherwise verbatim.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.issue_step_up_token(p_business_id uuid, p_surface text, p_factor_id uuid DEFAULT NULL::uuid, p_window interval DEFAULT '00:05:00'::interval)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_user_id         uuid;
  v_organization_id uuid;
  v_token_id        uuid;
BEGIN
  SELECT u.id INTO v_user_id FROM public.users u
  WHERE u.auth_user_id = auth.uid() AND u.is_active = true;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'STEP_UP_NOT_AUTHENTICATED' USING ERRCODE = '28000';
  END IF;

  SELECT bur.organization_id INTO v_organization_id
  FROM public.business_user_roles bur
  WHERE bur.user_id = v_user_id AND bur.business_id = p_business_id AND bur.status = 'ACTIVE'
  LIMIT 1;
  IF v_organization_id IS NULL THEN
    RAISE EXCEPTION 'STEP_UP_NO_ROLE_ON_BUSINESS' USING ERRCODE = '42501';
  END IF;

  -- Reject empty / unknown surfaces: only mint for a surface the matrix knows,
  -- so a token can actually be consumed (defends against the C2-class mismatch).
  IF p_surface IS NULL OR btrim(p_surface) = '' THEN
    RAISE EXCEPTION 'STEP_UP_SURFACE_REQUIRED' USING ERRCODE = '22000';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.permission_matrix WHERE surface = p_surface) THEN
    RAISE EXCEPTION 'STEP_UP_UNKNOWN_SURFACE: %', p_surface USING ERRCODE = '22023';
  END IF;

  v_token_id := public.gen_uuid_v7();
  INSERT INTO public.step_up_tokens (
    id, user_id, organization_id, business_id, surface, factor_id,
    issued_at, expires_at
  ) VALUES (
    v_token_id, v_user_id, v_organization_id, p_business_id,
    p_surface, p_factor_id, now(), now() + p_window
  );

  RETURN v_token_id;
END;
$function$;
