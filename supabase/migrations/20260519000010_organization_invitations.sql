-- B02·P07 User Invitation & Management
-- ============================================================================
-- organization_invitations table + lifecycle RPCs:
--   create_invitation     - Owner/Admin only
--   accept_invitation     - authenticated user accepts via token hash
--   revoke_invitation     - Owner/Admin only
--   change_member_role    - Owner/Admin + step-up token
--   remove_member         - Owner/Admin + step-up token
-- Plus list_organization_members (Owner/Admin only).
--
-- Audit emission lives in the Next.js server actions; this layer is data only.
-- ============================================================================

-- Sub-doc rls_helper_functions.md asserts business_user_roles has
-- UNIQUE(business_id, user_id); the original Phase-01 migration missed it.
-- Add it now so accept_invitation / change_member_role can use ON CONFLICT
-- as an idempotent upsert.
ALTER TABLE public.business_user_roles
  ADD CONSTRAINT business_user_roles_business_user_unique
  UNIQUE (business_id, user_id);

CREATE TABLE IF NOT EXISTS public.organization_invitations (
  id                          uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id             uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  email                       text NOT NULL,
  invited_role_per_business   jsonb NOT NULL,  -- [{business_id, role}, ...]
  invited_by                  uuid NOT NULL REFERENCES public.users(id),
  token_hash                  text NOT NULL,
  expires_at                  timestamptz NOT NULL,
  status                      text NOT NULL DEFAULT 'PENDING'
    CHECK (status IN ('PENDING','ACCEPTED','REVOKED','EXPIRED')),
  accepted_at                 timestamptz,
  accepted_by_user_id         uuid REFERENCES public.users(id),
  revoked_at                  timestamptz,
  revoked_by                  uuid REFERENCES public.users(id),
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT org_invitations_token_lifecycle CHECK (
    (status <> 'PENDING') OR (accepted_at IS NULL AND revoked_at IS NULL)
  ),
  CONSTRAINT org_invitations_email_normalized CHECK (email = lower(email))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_org_invitations_token_hash
  ON public.organization_invitations (token_hash)
  WHERE status = 'PENDING';

CREATE INDEX IF NOT EXISTS idx_org_invitations_pending_per_org
  ON public.organization_invitations (organization_id, status, expires_at);

CREATE INDEX IF NOT EXISTS idx_org_invitations_email_pending
  ON public.organization_invitations (organization_id, email)
  WHERE status = 'PENDING';

CREATE TRIGGER organization_invitations_set_updated_at
  BEFORE UPDATE ON public.organization_invitations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.organization_invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organization_invitations FORCE  ROW LEVEL SECURITY;

-- Users can read invitations addressed to them OR within their current org.
-- Writes go through SECURITY DEFINER RPCs only.
CREATE POLICY organization_invitations_select ON public.organization_invitations
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    OR email = (auth.jwt() ->> 'email')
  );
CREATE POLICY organization_invitations_no_insert ON public.organization_invitations
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY organization_invitations_no_update ON public.organization_invitations
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY organization_invitations_no_delete ON public.organization_invitations
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ===========================================================================
-- create_invitation
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.create_invitation(
  p_organization_id uuid,
  p_email           text,
  p_assignments     jsonb,          -- [{"business_id":"<uuid>","role":"BOOKKEEPER"}, ...]
  p_token_hash      text,
  p_ttl             interval DEFAULT interval '7 days'
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_caller_user_id      uuid;
  v_invitation_id       uuid;
  v_assignment          jsonb;
  v_business_id         uuid;
  v_role                public.user_role;
  v_owner_admin_count   integer;
  v_normalized_email    text;
BEGIN
  SELECT u.id INTO v_caller_user_id FROM public.users u
  WHERE u.auth_user_id = auth.uid() AND u.is_active = true;
  IF v_caller_user_id IS NULL THEN
    RAISE EXCEPTION 'INVITATION_NOT_AUTHENTICATED' USING ERRCODE = '28000';
  END IF;

  -- Caller must be Owner or Admin on at least one business in the target org
  SELECT count(*) INTO v_owner_admin_count
  FROM public.business_user_roles bur
  JOIN public.business_entities be ON be.id = bur.business_id
  WHERE bur.user_id = v_caller_user_id
    AND bur.status = 'ACTIVE'
    AND bur.role IN ('OWNER', 'ADMIN')
    AND be.organization_id = p_organization_id;
  IF v_owner_admin_count = 0 THEN
    RAISE EXCEPTION 'INVITATION_REQUIRES_OWNER_OR_ADMIN' USING ERRCODE = '42501';
  END IF;

  -- Validate every assignment references a business in the SAME org and a
  -- valid user_role enum value
  IF jsonb_typeof(p_assignments) <> 'array' OR jsonb_array_length(p_assignments) = 0 THEN
    RAISE EXCEPTION 'INVITATION_ASSIGNMENTS_EMPTY' USING ERRCODE = '22023';
  END IF;
  FOR v_assignment IN SELECT jsonb_array_elements(p_assignments) LOOP
    v_business_id := (v_assignment ->> 'business_id')::uuid;
    v_role := (v_assignment ->> 'role')::public.user_role;
    PERFORM 1 FROM public.business_entities
      WHERE id = v_business_id AND organization_id = p_organization_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'INVITATION_BUSINESS_NOT_IN_ORG' USING ERRCODE = '22023';
    END IF;
  END LOOP;

  v_normalized_email := lower(trim(p_email));

  v_invitation_id := public.gen_uuid_v7();
  INSERT INTO public.organization_invitations (
    id, organization_id, email, invited_role_per_business,
    invited_by, token_hash, expires_at, status
  ) VALUES (
    v_invitation_id, p_organization_id, v_normalized_email, p_assignments,
    v_caller_user_id, p_token_hash, now() + p_ttl, 'PENDING'
  );

  RETURN v_invitation_id;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.create_invitation(uuid, text, jsonb, text, interval) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.create_invitation(uuid, text, jsonb, text, interval) TO authenticated;

-- ===========================================================================
-- accept_invitation
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.accept_invitation(p_token_hash text)
RETURNS TABLE (success boolean, reason text, organization_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_caller_user_id  uuid;
  v_caller_email    text;
  v_row             public.organization_invitations%ROWTYPE;
  v_assignment      jsonb;
  v_business_id     uuid;
  v_role            public.user_role;
BEGIN
  SELECT u.id, u.email INTO v_caller_user_id, v_caller_email
  FROM public.users u
  WHERE u.auth_user_id = auth.uid() AND u.is_active = true;
  IF v_caller_user_id IS NULL THEN
    RETURN QUERY SELECT false, 'NOT_AUTHENTICATED', NULL::uuid; RETURN;
  END IF;

  SELECT * INTO v_row FROM public.organization_invitations
  WHERE token_hash = p_token_hash
  FOR UPDATE;
  IF v_row.id IS NULL THEN
    RETURN QUERY SELECT false, 'INVITATION_NOT_FOUND', NULL::uuid; RETURN;
  END IF;

  IF v_row.status = 'REVOKED' THEN
    RETURN QUERY SELECT false, 'INVITATION_REVOKED', v_row.organization_id; RETURN;
  END IF;
  IF v_row.status = 'ACCEPTED' THEN
    RETURN QUERY SELECT false, 'INVITATION_ALREADY_ACCEPTED', v_row.organization_id; RETURN;
  END IF;
  IF v_row.status = 'EXPIRED' OR v_row.expires_at <= now() THEN
    -- Idempotently mark EXPIRED if not already
    UPDATE public.organization_invitations
       SET status = 'EXPIRED'
     WHERE id = v_row.id AND status = 'PENDING';
    RETURN QUERY SELECT false, 'INVITATION_EXPIRED', v_row.organization_id; RETURN;
  END IF;

  -- Email must match the accepting user
  IF lower(v_row.email) <> lower(coalesce(v_caller_email, '')) THEN
    RETURN QUERY SELECT false, 'INVITATION_EMAIL_MISMATCH', v_row.organization_id; RETURN;
  END IF;

  -- Ensure the user is in organization_users
  INSERT INTO public.organization_users (organization_id, user_id, status, joined_at)
  VALUES (v_row.organization_id, v_caller_user_id, 'ACTIVE', now())
  ON CONFLICT ON CONSTRAINT organization_users_unique
  DO UPDATE SET status = 'ACTIVE', deleted_at = NULL;

  -- Create business_user_roles rows
  FOR v_assignment IN SELECT jsonb_array_elements(v_row.invited_role_per_business) LOOP
    v_business_id := (v_assignment ->> 'business_id')::uuid;
    v_role        := (v_assignment ->> 'role')::public.user_role;
    INSERT INTO public.business_user_roles
      (organization_id, business_id, user_id, role, assigned_by, status, assigned_at)
    VALUES (
      v_row.organization_id, v_business_id, v_caller_user_id,
      v_role, v_row.invited_by, 'ACTIVE', now()
    )
    ON CONFLICT ON CONSTRAINT business_user_roles_business_user_unique
    DO UPDATE SET role = EXCLUDED.role, status = 'ACTIVE', assigned_at = now();
  END LOOP;

  UPDATE public.organization_invitations
     SET status = 'ACCEPTED',
         accepted_at = now(),
         accepted_by_user_id = v_caller_user_id
   WHERE id = v_row.id;

  RETURN QUERY SELECT true, 'OK'::text, v_row.organization_id;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.accept_invitation(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.accept_invitation(text) TO authenticated;

-- ===========================================================================
-- revoke_invitation
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.revoke_invitation(p_invitation_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_caller_user_id uuid;
  v_organization_id uuid;
  v_owner_admin_count integer;
BEGIN
  SELECT u.id INTO v_caller_user_id FROM public.users u
  WHERE u.auth_user_id = auth.uid() AND u.is_active = true;
  IF v_caller_user_id IS NULL THEN
    RAISE EXCEPTION 'INVITATION_NOT_AUTHENTICATED' USING ERRCODE = '28000';
  END IF;

  SELECT organization_id INTO v_organization_id
  FROM public.organization_invitations
  WHERE id = p_invitation_id AND status = 'PENDING';
  IF v_organization_id IS NULL THEN RETURN false; END IF;

  SELECT count(*) INTO v_owner_admin_count
  FROM public.business_user_roles bur
  JOIN public.business_entities be ON be.id = bur.business_id
  WHERE bur.user_id = v_caller_user_id
    AND bur.status = 'ACTIVE'
    AND bur.role IN ('OWNER', 'ADMIN')
    AND be.organization_id = v_organization_id;
  IF v_owner_admin_count = 0 THEN
    RAISE EXCEPTION 'INVITATION_REQUIRES_OWNER_OR_ADMIN' USING ERRCODE = '42501';
  END IF;

  UPDATE public.organization_invitations
     SET status = 'REVOKED', revoked_at = now(), revoked_by = v_caller_user_id
   WHERE id = p_invitation_id AND status = 'PENDING';
  RETURN FOUND;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.revoke_invitation(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.revoke_invitation(uuid) TO authenticated;

-- ===========================================================================
-- change_member_role  (step-up required)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.change_member_role(
  p_business_id     uuid,
  p_target_user_id  uuid,
  p_new_role        public.user_role,
  p_step_up_token   uuid
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_caller_user_id uuid;
  v_caller_role public.user_role;
  v_consumed boolean;
  v_reason text;
BEGIN
  SELECT u.id INTO v_caller_user_id FROM public.users u
  WHERE u.auth_user_id = auth.uid() AND u.is_active = true;
  IF v_caller_user_id IS NULL THEN
    RAISE EXCEPTION 'MEMBER_NOT_AUTHENTICATED' USING ERRCODE = '28000';
  END IF;

  -- Owner/Admin on the business
  SELECT role INTO v_caller_role
  FROM public.business_user_roles
  WHERE user_id = v_caller_user_id AND business_id = p_business_id AND status = 'ACTIVE';
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('OWNER','ADMIN') THEN
    RAISE EXCEPTION 'MEMBER_CHANGE_REQUIRES_OWNER_OR_ADMIN' USING ERRCODE = '42501';
  END IF;

  -- Consume step-up token (USER_INVITE is the surface gating user management)
  SELECT consumed, reason INTO v_consumed, v_reason
  FROM public.consume_step_up_token(p_step_up_token, p_business_id, 'USER_INVITE', NULL);
  IF NOT v_consumed THEN
    RAISE EXCEPTION 'MEMBER_STEP_UP_REJECTED:%', v_reason USING ERRCODE = '42501';
  END IF;

  UPDATE public.business_user_roles
     SET role = p_new_role, updated_at = now()
   WHERE user_id = p_target_user_id
     AND business_id = p_business_id
     AND status = 'ACTIVE';
  RETURN FOUND;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.change_member_role(uuid, uuid, public.user_role, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.change_member_role(uuid, uuid, public.user_role, uuid) TO authenticated;

-- ===========================================================================
-- remove_member  (step-up required; soft delete via status = INACTIVE)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.remove_member(
  p_business_id    uuid,
  p_target_user_id uuid,
  p_step_up_token  uuid
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_caller_user_id uuid;
  v_caller_role public.user_role;
  v_target_role public.user_role;
  v_consumed boolean;
  v_reason text;
BEGIN
  SELECT u.id INTO v_caller_user_id FROM public.users u
  WHERE u.auth_user_id = auth.uid() AND u.is_active = true;
  IF v_caller_user_id IS NULL THEN
    RAISE EXCEPTION 'MEMBER_NOT_AUTHENTICATED' USING ERRCODE = '28000';
  END IF;
  IF v_caller_user_id = p_target_user_id THEN
    RAISE EXCEPTION 'MEMBER_CANNOT_REMOVE_SELF' USING ERRCODE = '42501';
  END IF;

  SELECT role INTO v_caller_role
  FROM public.business_user_roles
  WHERE user_id = v_caller_user_id AND business_id = p_business_id AND status = 'ACTIVE';
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('OWNER','ADMIN') THEN
    RAISE EXCEPTION 'MEMBER_CHANGE_REQUIRES_OWNER_OR_ADMIN' USING ERRCODE = '42501';
  END IF;

  -- Cannot remove the OWNER role with this RPC (ownership transfer is its own flow)
  SELECT role INTO v_target_role
  FROM public.business_user_roles
  WHERE user_id = p_target_user_id AND business_id = p_business_id AND status = 'ACTIVE';
  IF v_target_role = 'OWNER' THEN
    RAISE EXCEPTION 'MEMBER_CANNOT_REMOVE_OWNER' USING ERRCODE = '42501';
  END IF;

  SELECT consumed, reason INTO v_consumed, v_reason
  FROM public.consume_step_up_token(p_step_up_token, p_business_id, 'USER_INVITE', NULL);
  IF NOT v_consumed THEN
    RAISE EXCEPTION 'MEMBER_STEP_UP_REJECTED:%', v_reason USING ERRCODE = '42501';
  END IF;

  UPDATE public.business_user_roles
     SET status = 'INACTIVE', updated_at = now()
   WHERE user_id = p_target_user_id
     AND business_id = p_business_id
     AND status = 'ACTIVE';
  RETURN FOUND;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.remove_member(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.remove_member(uuid, uuid, uuid) TO authenticated;

-- ===========================================================================
-- list_organization_members  (Owner/Admin view)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.list_organization_members(p_organization_id uuid)
RETURNS TABLE (
  user_id           uuid,
  email             text,
  display_name      text,
  business_id       uuid,
  business_name     text,
  role              public.user_role,
  role_status       text,
  joined_at         timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_caller_user_id uuid;
  v_owner_admin_count integer;
BEGIN
  SELECT u.id INTO v_caller_user_id FROM public.users u
  WHERE u.auth_user_id = auth.uid() AND u.is_active = true;
  IF v_caller_user_id IS NULL THEN
    RAISE EXCEPTION 'MEMBERS_NOT_AUTHENTICATED' USING ERRCODE = '28000';
  END IF;

  SELECT count(*) INTO v_owner_admin_count
  FROM public.business_user_roles bur
  JOIN public.business_entities be ON be.id = bur.business_id
  WHERE bur.user_id = v_caller_user_id
    AND bur.status = 'ACTIVE'
    AND bur.role IN ('OWNER','ADMIN')
    AND be.organization_id = p_organization_id;
  IF v_owner_admin_count = 0 THEN
    RAISE EXCEPTION 'MEMBERS_REQUIRES_OWNER_OR_ADMIN' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT u.id, u.email, u.display_name,
         be.id, be.display_name,
         bur.role, bur.status, bur.assigned_at
  FROM public.business_user_roles bur
  JOIN public.users u ON u.id = bur.user_id
  JOIN public.business_entities be ON be.id = bur.business_id
  WHERE be.organization_id = p_organization_id
  ORDER BY u.email ASC, be.display_name ASC;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.list_organization_members(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.list_organization_members(uuid) TO authenticated;

COMMENT ON TABLE public.organization_invitations IS
'Pending/accepted/revoked/expired invitations (B02·P07). Tokens stored as sha256 hex; plain token only lives in the invite email URL. Lifecycle RPCs (create_invitation, accept_invitation, revoke_invitation) are the only mutation paths — direct INSERT/UPDATE/DELETE blocked by RESTRICTIVE policies.';
