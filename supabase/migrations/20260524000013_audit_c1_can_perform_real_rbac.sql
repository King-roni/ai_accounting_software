-- Audit C1 — replace `can_perform` test-stub body with real RBAC
-- =====================================================================
-- Current state (per pg_get_functiondef): can_perform is a test stub that
-- unconditionally returns ALLOW unless the GUC `test.can_perform_decision`
-- is explicitly set to DENY/STEP_UP. In production those GUCs are unset,
-- so 28 user-facing RPCs (transition_run, out_workflow_user_approval,
-- out_workflow_start_run_manually, out_workflow_adjustment_intake,
-- request_statement_upload, complete_statement_upload, all custom-tag
-- CRUD, prompt CRUD, cost-ceiling override) are effectively un-gated.
--
-- This migration keeps the test hooks intact (existing DO-block lifecycle
-- tests rely on them) but adds a real RBAC fallback that fires when no
-- test override is set. RBAC lookup:
--   (actor, business) → business_user_roles.role (filtered to ACTIVE status)
--   (role, surface) → permission_matrix.decision
--
-- Returns the existing envelope shape: {decision, reason_code?, role?,
-- step_up_surface?, cross_tenant?}. Callers that check `decision != 'ALLOW'`
-- continue to work unchanged.
--
-- Audit emission deferred to a separate migration; emitting on every
-- can_perform call would 10× audit volume. Callers that act on a DENY
-- already emit their own rejection audit (per the Wave-1 callers reviewed).
-- =====================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.can_perform(
  p_actor_user_id uuid,
  p_surface text,
  p_action text,
  p_resource jsonb,
  p_business_id uuid DEFAULT NULL,
  p_organization_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_should_raise      text;
  v_decision_override text;
  v_cross_tenant      text;
  v_reason_code       text;
  v_role              public.user_role;
  v_matrix_decision   text;
BEGIN
  -- Test hooks (gated by GUC; left intact so existing DO-block tests keep working)
  v_should_raise := COALESCE(current_setting('test.can_perform_should_raise', true), 'off');
  IF v_should_raise = 'on' THEN
    RAISE EXCEPTION 'can_perform: simulated decision-function bug (test hook)' USING ERRCODE = 'P0001';
  END IF;

  v_decision_override := COALESCE(current_setting('test.can_perform_decision', true), '');

  IF v_decision_override = 'DENY' THEN
    v_cross_tenant := COALESCE(current_setting('test.can_perform_cross_tenant', true), 'false');
    v_reason_code  := COALESCE(NULLIF(current_setting('test.can_perform_reason', true), ''), 'denied_by_test');
    RETURN jsonb_build_object('decision','DENY','reason_code',v_reason_code,'cross_tenant',(v_cross_tenant='true'));
  END IF;
  IF v_decision_override = 'STEP_UP' THEN
    RETURN jsonb_build_object('decision','STEP_UP','step_up_surface',p_surface);
  END IF;
  IF v_decision_override = 'ALLOW' THEN
    RETURN jsonb_build_object('decision','ALLOW','reason_code','allowed_by_test');
  END IF;

  -- Real RBAC path (production behavior when no test GUC set)
  IF p_actor_user_id IS NULL THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','NO_ACTOR');
  END IF;
  IF p_business_id IS NULL THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','NO_BUSINESS_CONTEXT',
      'actor_user_id', p_actor_user_id);
  END IF;

  SELECT role INTO v_role
    FROM public.business_user_roles
   WHERE user_id    = p_actor_user_id
     AND business_id = p_business_id
     AND status     = 'ACTIVE'::public.account_status
   LIMIT 1;

  IF v_role IS NULL THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','NO_ROLE_ASSIGNMENT',
      'actor_user_id', p_actor_user_id, 'business_id', p_business_id);
  END IF;

  SELECT decision INTO v_matrix_decision
    FROM public.permission_matrix
   WHERE role    = v_role
     AND surface = p_surface
   LIMIT 1;

  IF v_matrix_decision IS NULL THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','SURFACE_NOT_IN_MATRIX',
      'surface', p_surface, 'role', v_role::text);
  END IF;

  RETURN jsonb_build_object(
    'decision',    v_matrix_decision,
    'role',        v_role::text,
    'surface',     p_surface,
    'matrix_match', true);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.can_perform(uuid,text,text,jsonb,uuid,uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.can_perform(uuid,text,text,jsonb,uuid,uuid) TO service_role, authenticated;

COMMENT ON FUNCTION public.can_perform(uuid,text,text,jsonb,uuid,uuid) IS
  'Real RBAC permission check (audit C1, 2026-05-24). Joins business_user_roles → permission_matrix. Test GUC hooks remain (test.can_perform_decision / test.can_perform_should_raise) for DO-block lifecycle tests; in production those GUCs are unset and the function returns the matrix decision.';

COMMIT;
