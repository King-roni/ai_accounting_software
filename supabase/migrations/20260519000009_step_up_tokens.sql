-- B02·P06 Step-Up Authentication
-- ============================================================================
-- Implements the canonical step_up_tokens lifecycle from
-- Docs/sub/policies/step_up_validity_window_policy.md:
--   - Issue on successful MFA verify (5-minute default window)
--   - Single-use consume bound to (surface, action_id)
--   - Per-business binding (Owner-of-A token can't finalize business B)
--   - Factor binding (re-enrollment invalidates the token)
--   - RPC contract: issue_step_up_token / consume_step_up_token
--   - RLS: users see their own tokens; only SECURITY DEFINER RPCs mutate
-- ============================================================================

-- Validity window default (5 minutes per the policy doc). Per-surface
-- overrides live in the application layer; the DB default is the floor.
CREATE TABLE IF NOT EXISTS public.step_up_tokens (
  id                      uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  user_id                 uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  organization_id         uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id             uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  surface                 text NOT NULL,
  factor_id               uuid,  -- auth.mfa_factors.id; nullable for graceful factor re-enroll
  issued_at               timestamptz NOT NULL DEFAULT now(),
  expires_at              timestamptz NOT NULL,
  consumed_at             timestamptz,
  consumed_for_surface    text,
  consumed_for_action_id  uuid,
  consumed_ip             text,
  revoked_at              timestamptz,
  revoked_reason          text,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT step_up_tokens_lifecycle_chk CHECK (
    (consumed_at IS NULL OR revoked_at IS NULL)  -- can't be both consumed and revoked
  ),
  CONSTRAINT step_up_tokens_expiry_chk CHECK (expires_at > issued_at)
);

CREATE INDEX IF NOT EXISTS idx_step_up_tokens_user_active
  ON public.step_up_tokens (user_id, business_id, expires_at)
  WHERE consumed_at IS NULL AND revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_step_up_tokens_consumed
  ON public.step_up_tokens (business_id, consumed_at)
  WHERE consumed_at IS NOT NULL;

CREATE TRIGGER step_up_tokens_set_updated_at
  BEFORE UPDATE ON public.step_up_tokens
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
ALTER TABLE public.step_up_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.step_up_tokens FORCE  ROW LEVEL SECURITY;

CREATE POLICY step_up_tokens_select_self ON public.step_up_tokens
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (user_id = public.current_user_id());

-- All mutations go through SECURITY DEFINER RPCs.
CREATE POLICY step_up_tokens_no_insert ON public.step_up_tokens
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY step_up_tokens_no_update ON public.step_up_tokens
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY step_up_tokens_no_delete ON public.step_up_tokens
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---------------------------------------------------------------------------
-- Issue a step-up token after successful MFA verify.
--
-- The caller is the Next.js server action; it has already called
-- supabase.auth.mfa.verify() successfully. This RPC trusts the caller and
-- only validates that the user has an active business role on p_business_id.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.issue_step_up_token(
  p_business_id uuid,
  p_surface     text,
  p_factor_id   uuid DEFAULT NULL,
  p_window      interval DEFAULT interval '5 minutes'
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_user_id         uuid;
  v_organization_id uuid;
  v_token_id        uuid;
BEGIN
  SELECT u.id INTO v_user_id
  FROM public.users u
  WHERE u.auth_user_id = auth.uid()
    AND u.is_active = true;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'STEP_UP_NOT_AUTHENTICATED'
      USING ERRCODE = '28000';
  END IF;

  -- Caller must have an ACTIVE role on the target business
  SELECT bur.organization_id INTO v_organization_id
  FROM public.business_user_roles bur
  WHERE bur.user_id     = v_user_id
    AND bur.business_id = p_business_id
    AND bur.status      = 'ACTIVE'
  LIMIT 1;
  IF v_organization_id IS NULL THEN
    RAISE EXCEPTION 'STEP_UP_NO_ROLE_ON_BUSINESS'
      USING ERRCODE = '42501';
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
$$;

REVOKE EXECUTE ON FUNCTION public.issue_step_up_token(uuid, text, uuid, interval) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.issue_step_up_token(uuid, text, uuid, interval) TO authenticated;

-- ---------------------------------------------------------------------------
-- Consume a step-up token. Single-use, bound to (surface, business).
--
-- Returns the token row on success; raises with named ERRCODE on failure so
-- the caller can map to STEP_UP_TOKEN_ALREADY_CONSUMED / _EXPIRED / etc.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.consume_step_up_token(
  p_token_id    uuid,
  p_business_id uuid,
  p_surface     text,
  p_action_id   uuid DEFAULT NULL
) RETURNS TABLE (
  consumed boolean,
  reason   text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_user_id uuid;
  v_row     public.step_up_tokens%ROWTYPE;
BEGIN
  SELECT u.id INTO v_user_id
  FROM public.users u
  WHERE u.auth_user_id = auth.uid() AND u.is_active = true;
  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT false, 'NOT_AUTHENTICATED'; RETURN;
  END IF;

  SELECT t.* INTO v_row
  FROM public.step_up_tokens t
  WHERE t.id = p_token_id
    AND t.user_id = v_user_id
    AND t.business_id = p_business_id
  FOR UPDATE;

  IF v_row.id IS NULL THEN
    RETURN QUERY SELECT false, 'TOKEN_NOT_FOUND'; RETURN;
  END IF;
  IF v_row.surface <> p_surface THEN
    RETURN QUERY SELECT false, 'TOKEN_SURFACE_MISMATCH'; RETURN;
  END IF;
  IF v_row.revoked_at IS NOT NULL THEN
    RETURN QUERY SELECT false, 'TOKEN_REVOKED'; RETURN;
  END IF;
  IF v_row.consumed_at IS NOT NULL THEN
    RETURN QUERY SELECT false, 'TOKEN_ALREADY_CONSUMED'; RETURN;
  END IF;
  IF v_row.expires_at <= now() THEN
    RETURN QUERY SELECT false, 'TOKEN_EXPIRED'; RETURN;
  END IF;

  UPDATE public.step_up_tokens
  SET consumed_at = now(),
      consumed_for_surface = p_surface,
      consumed_for_action_id = p_action_id
  WHERE id = p_token_id
    AND consumed_at IS NULL;

  IF NOT FOUND THEN
    -- raced by another consumer
    RETURN QUERY SELECT false, 'TOKEN_RACE_LOST'; RETURN;
  END IF;

  RETURN QUERY SELECT true, 'OK'::text;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.consume_step_up_token(uuid, uuid, text, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.consume_step_up_token(uuid, uuid, text, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Read helper: latest unconsumed unexpired token for the calling user on
-- a given business+surface. Used by application-layer PrincipalContext
-- resolver to populate mfa_recent_at.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.latest_step_up_for(
  p_business_id uuid,
  p_surface     text
) RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
  SELECT t.issued_at
  FROM public.step_up_tokens t
  JOIN public.users u ON u.id = t.user_id
  WHERE u.auth_user_id = auth.uid()
    AND t.business_id = p_business_id
    AND t.surface = p_surface
    AND t.consumed_at IS NULL
    AND t.revoked_at IS NULL
    AND t.expires_at > now()
  ORDER BY t.issued_at DESC
  LIMIT 1;
$$;

REVOKE EXECUTE ON FUNCTION public.latest_step_up_for(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.latest_step_up_for(uuid, text) TO authenticated;

COMMENT ON TABLE public.step_up_tokens IS
'Single-use MFA step-up tokens (B02·P06). Issued by issue_step_up_token after a successful supabase.auth.mfa.verify and consumed atomically by consume_step_up_token. Per step_up_validity_window_policy: 5-minute window, per-business binding, surface-bound consumption.';
