-- P0.3 — self-serve org + business creation (first-run onboarding).
--
-- Before this, organizations/businesses existed only via dev seed.sql, and
-- handle_new_auth_user only inserts a public.users row → a fresh signup lands on
-- an empty dashboard with no way to create a business. These RPCs let a new user
-- bootstrap from scratch: create an organization (becoming its member), then a
-- business (becoming its OWNER, with the default Cyprus chart loaded so it can
-- run bookkeeping immediately). grant_business_role is the non-seed path to give
-- additional testers a role.
--
-- Bootstrap note: creating the FIRST org is a chicken-and-egg for can_perform
-- (a brand-new user has no role), so create_organization is SECURITY DEFINER and
-- self-authorizes off current_user_id() — any authenticated user may create one
-- and is recorded as its member. Writes bypass the workflow-first RLS via DEFINER.

-- ── create_organization ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.create_organization(p_name text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_user uuid := public.current_user_id();
  v_org  uuid;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
  IF p_name IS NULL OR length(btrim(p_name)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NAME_REQUIRED');
  END IF;

  INSERT INTO public.organizations (name) VALUES (btrim(p_name)) RETURNING id INTO v_org;
  INSERT INTO public.organization_users (organization_id, user_id) VALUES (v_org, v_user);

  PERFORM audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'ORGANIZATION_CREATED',
    p_subject_type => 'ORGANIZATION'::audit.subject_type_enum,
    p_subject_id => v_org, p_actor_user_id => v_user,
    p_organization_id => v_org,
    p_after_state => jsonb_build_object('name', btrim(p_name)),
    p_reason => format('organization %s created by %s', v_org, v_user));

  RETURN jsonb_build_object('ok', true, 'organization_id', v_org);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.create_organization(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.create_organization(text) TO authenticated, service_role;

-- ── create_business ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.create_business(
  p_organization_id uuid,
  p_display_name    text,
  p_country_code    text DEFAULT 'CY',
  p_currency        text DEFAULT 'EUR',
  p_vat_registered  boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_user uuid := public.current_user_id();
  v_biz  uuid;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
  IF p_organization_id IS NULL OR p_display_name IS NULL OR length(btrim(p_display_name)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'INVALID_INPUT');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.organization_users
     WHERE organization_id = p_organization_id AND user_id = v_user AND status = 'ACTIVE'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'ORG_ACCESS_DENIED');
  END IF;

  INSERT INTO public.business_entities
    (organization_id, display_name, country_code, currency, vat_registered, created_by_user_id)
  VALUES
    (p_organization_id, btrim(p_display_name), upper(p_country_code)::bpchar,
     upper(p_currency)::bpchar, COALESCE(p_vat_registered, false), v_user)
  RETURNING id INTO v_biz;

  INSERT INTO public.business_user_roles
    (organization_id, business_id, user_id, role, assigned_by, status)
  VALUES
    (p_organization_id, v_biz, v_user, 'OWNER'::public.user_role, v_user, 'ACTIVE'::public.account_status);

  -- Default Cyprus chart so the business can run bookkeeping immediately.
  -- Best-effort: a chart issue must not fail business creation.
  BEGIN
    PERFORM public.load_default_chart_for_business(p_organization_id, v_biz, v_user, '{}'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  PERFORM audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'BUSINESS_CREATED',
    p_subject_type => 'BUSINESS'::audit.subject_type_enum,
    p_subject_id => v_biz, p_actor_user_id => v_user,
    p_organization_id => p_organization_id, p_business_id => v_biz,
    p_after_state => jsonb_build_object('display_name', btrim(p_display_name),
      'country_code', upper(p_country_code), 'currency', upper(p_currency),
      'vat_registered', COALESCE(p_vat_registered, false)),
    p_reason => format('business %s created by %s (OWNER)', v_biz, v_user));

  RETURN jsonb_build_object('ok', true, 'business_id', v_biz);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.create_business(uuid, text, text, text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.create_business(uuid, text, text, text, boolean) TO authenticated, service_role;

-- ── grant_business_role (non-seed path to add testers) ───────────────────────
CREATE OR REPLACE FUNCTION public.grant_business_role(
  p_business_id    uuid,
  p_target_user_id uuid,
  p_role           public.user_role
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_user uuid := public.current_user_id();
  v_org  uuid;
  v_new  uuid;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
  IF p_business_id IS NULL OR p_target_user_id IS NULL OR p_role IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'INVALID_INPUT');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.business_user_roles
     WHERE business_id = p_business_id AND user_id = v_user
       AND role IN ('OWNER'::public.user_role, 'ADMIN'::public.user_role) AND status = 'ACTIVE'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'ACCESS_DENIED');
  END IF;

  SELECT organization_id INTO v_org FROM public.business_entities WHERE id = p_business_id;
  IF v_org IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'BUSINESS_NOT_FOUND'); END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.organization_users
     WHERE organization_id = v_org AND user_id = p_target_user_id AND status = 'ACTIVE'
  ) THEN
    INSERT INTO public.organization_users (organization_id, user_id)
    VALUES (v_org, p_target_user_id);
  END IF;

  -- Role change = new ACTIVE row; prior ACTIVE flips to INACTIVE (history kept).
  UPDATE public.business_user_roles
     SET status = 'INACTIVE'::public.account_status, updated_at = now()
   WHERE business_id = p_business_id AND user_id = p_target_user_id AND status = 'ACTIVE';

  INSERT INTO public.business_user_roles
    (organization_id, business_id, user_id, role, assigned_by, status)
  VALUES
    (v_org, p_business_id, p_target_user_id, p_role, v_user, 'ACTIVE'::public.account_status)
  RETURNING id INTO v_new;

  PERFORM audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'BUSINESS_ROLE_GRANTED',
    p_subject_type => 'BUSINESS_USER_ROLE'::audit.subject_type_enum,
    p_subject_id => v_new, p_actor_user_id => v_user,
    p_organization_id => v_org, p_business_id => p_business_id,
    p_after_state => jsonb_build_object('target_user_id', p_target_user_id, 'role', p_role::text),
    p_reason => format('role %s granted to %s on business %s by %s', p_role, p_target_user_id, p_business_id, v_user));

  RETURN jsonb_build_object('ok', true, 'business_user_role_id', v_new);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.grant_business_role(uuid, uuid, public.user_role) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.grant_business_role(uuid, uuid, public.user_role) TO authenticated, service_role;
