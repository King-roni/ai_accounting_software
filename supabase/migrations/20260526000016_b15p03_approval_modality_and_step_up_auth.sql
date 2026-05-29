-- B15·P03 — Approval Modality & Step-Up Auth at Finalization
-- ============================================================
-- Closes the hole where any caller could write approval_method='STEP_UP'
-- without proving a step-up challenge actually succeeded. Splits the
-- matrix into APPROVAL_STANDARD / APPROVAL_STEP_UP, makes the approval
-- RPCs the single source of truth for "this row is really backed by a
-- step-up," adds a lockout counter, and emits the five Block-15 audit
-- events from the spec.

INSERT INTO public.permission_matrix (role, surface, decision) VALUES
  ('OWNER',      'APPROVAL_STANDARD', 'ALLOW'),
  ('ADMIN',      'APPROVAL_STANDARD', 'ALLOW'),
  ('BOOKKEEPER', 'APPROVAL_STANDARD', 'ALLOW'),
  ('ACCOUNTANT', 'APPROVAL_STANDARD', 'DENY'),
  ('REVIEWER',   'APPROVAL_STANDARD', 'DENY'),
  ('READ_ONLY',  'APPROVAL_STANDARD', 'DENY'),
  ('OWNER',      'APPROVAL_STEP_UP',  'REQUIRE_STEP_UP'),
  ('ADMIN',      'APPROVAL_STEP_UP',  'REQUIRE_STEP_UP'),
  ('BOOKKEEPER', 'APPROVAL_STEP_UP',  'DENY'),
  ('ACCOUNTANT', 'APPROVAL_STEP_UP',  'DENY'),
  ('REVIEWER',   'APPROVAL_STEP_UP',  'DENY'),
  ('READ_ONLY',  'APPROVAL_STEP_UP',  'DENY')
ON CONFLICT (role, surface) DO UPDATE SET decision = EXCLUDED.decision;

CREATE TABLE IF NOT EXISTS public.step_up_lockouts (
  user_id              uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  business_id          uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  consecutive_failures int  NOT NULL DEFAULT 0,
  locked_until         timestamptz,
  last_failure_at      timestamptz,
  last_success_at      timestamptz,
  PRIMARY KEY (user_id, business_id),
  CONSTRAINT step_up_lockouts_failures_nonneg CHECK (consecutive_failures >= 0)
);
ALTER TABLE public.step_up_lockouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.step_up_lockouts FORCE  ROW LEVEL SECURITY;
CREATE POLICY step_up_lockouts_own ON public.step_up_lockouts
  FOR SELECT TO authenticated
  USING (user_id = (SELECT u.id FROM public.users u WHERE u.auth_user_id = auth.uid()));
CREATE POLICY step_up_lockouts_no_writes_insert ON public.step_up_lockouts FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY step_up_lockouts_no_writes_update ON public.step_up_lockouts FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY step_up_lockouts_no_writes_delete ON public.step_up_lockouts FOR DELETE TO authenticated USING (false);

CREATE OR REPLACE FUNCTION public.fn_record_step_up_failure(
  p_user_id uuid, p_business_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_row public.step_up_lockouts%ROWTYPE;
  v_threshold constant int := 5;
  v_lock_window constant interval := '15 minutes';
BEGIN
  INSERT INTO public.step_up_lockouts (user_id, business_id, consecutive_failures, last_failure_at)
       VALUES (p_user_id, p_business_id, 1, clock_timestamp())
  ON CONFLICT (user_id, business_id) DO UPDATE
    SET consecutive_failures = step_up_lockouts.consecutive_failures + 1,
        last_failure_at      = clock_timestamp(),
        locked_until         = CASE
          WHEN step_up_lockouts.consecutive_failures + 1 >= v_threshold
          THEN clock_timestamp() + v_lock_window
          ELSE step_up_lockouts.locked_until
        END
  RETURNING * INTO v_row;
  RETURN jsonb_build_object(
    'consecutive_failures', v_row.consecutive_failures,
    'locked_until',          v_row.locked_until,
    'threshold',             v_threshold);
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_reset_step_up_failures(
  p_user_id uuid, p_business_id uuid
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
BEGIN
  INSERT INTO public.step_up_lockouts (user_id, business_id, consecutive_failures, last_success_at)
       VALUES (p_user_id, p_business_id, 0, clock_timestamp())
  ON CONFLICT (user_id, business_id) DO UPDATE
    SET consecutive_failures = 0,
        locked_until         = NULL,
        last_success_at      = clock_timestamp();
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_is_step_up_locked(
  p_user_id uuid, p_business_id uuid
) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM public.step_up_lockouts
                  WHERE user_id = p_user_id AND business_id = p_business_id
                    AND locked_until IS NOT NULL AND locked_until > clock_timestamp());
$$;

CREATE OR REPLACE FUNCTION public._consume_step_up_token_for_actor(
  p_token_id uuid, p_business_id uuid, p_surface text, p_user_id uuid, p_action_id uuid
) RETURNS TABLE(consumed boolean, reason text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_row public.step_up_tokens%ROWTYPE;
BEGIN
  SELECT t.* INTO v_row FROM public.step_up_tokens t
   WHERE t.id = p_token_id AND t.user_id = p_user_id AND t.business_id = p_business_id
   FOR UPDATE;
  IF v_row.id IS NULL THEN RETURN QUERY SELECT false, 'TOKEN_NOT_FOUND'::text; RETURN; END IF;
  IF v_row.surface <> p_surface THEN RETURN QUERY SELECT false, 'TOKEN_SURFACE_MISMATCH'::text; RETURN; END IF;
  IF v_row.revoked_at IS NOT NULL THEN RETURN QUERY SELECT false, 'TOKEN_REVOKED'::text; RETURN; END IF;
  IF v_row.consumed_at IS NOT NULL THEN RETURN QUERY SELECT false, 'TOKEN_ALREADY_CONSUMED'::text; RETURN; END IF;
  IF v_row.expires_at <= clock_timestamp() THEN RETURN QUERY SELECT false, 'TOKEN_EXPIRED'::text; RETURN; END IF;
  UPDATE public.step_up_tokens
     SET consumed_at = clock_timestamp(), consumed_for_surface = p_surface, consumed_for_action_id = p_action_id
   WHERE id = p_token_id AND consumed_at IS NULL;
  IF NOT FOUND THEN RETURN QUERY SELECT false, 'TOKEN_RACE_LOST'::text; RETURN; END IF;
  RETURN QUERY SELECT true, 'OK'::text;
END;
$$;

CREATE OR REPLACE FUNCTION public.latest_qualifying_step_up_approval(
  p_business_id uuid, p_run_id uuid
) RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT a.id FROM public.workflow_run_approvals a
   WHERE a.business_id = p_business_id AND a.run_id = p_run_id
     AND a.approval_method = 'STEP_UP'::public.workflow_approval_method_enum
     AND a.revoked_at IS NULL
   ORDER BY a.approved_at DESC
   LIMIT 1;
$$;

DROP FUNCTION IF EXISTS public.out_workflow_user_approval(uuid, uuid, uuid, public.workflow_approval_method_enum, text, uuid, jsonb);
DROP FUNCTION IF EXISTS public.in_workflow_user_approval (uuid, uuid, uuid, public.workflow_approval_method_enum, text, uuid, jsonb);

CREATE OR REPLACE FUNCTION public.out_workflow_user_approval(
  p_organization_id  uuid,
  p_business_id      uuid,
  p_run_id           uuid,
  p_approval_method  public.workflow_approval_method_enum,
  p_approval_note    text,
  p_actor_user_id    uuid,
  p_context          jsonb,
  p_step_up_token_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_surface text;
  v_can jsonb;
  v_approval_id uuid := public.gen_uuid_v7();
  v_now timestamptz := clock_timestamp();
  v_consume record;
  v_lock_state jsonb;
BEGIN
  IF p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'out_workflow.user_approval: actor_user_id required' USING ERRCODE='22000';
  END IF;

  v_surface := CASE p_approval_method
                 WHEN 'STANDARD' THEN 'APPROVAL_STANDARD'
                 WHEN 'STEP_UP'  THEN 'APPROVAL_STEP_UP'
               END;

  IF p_approval_method = 'STEP_UP' AND public.fn_is_step_up_locked(p_actor_user_id, p_business_id) THEN
    RETURN jsonb_build_object('decision','DENIED','reason','LOCKED_OUT');
  END IF;

  v_can := public.can_perform(p_actor_user_id, v_surface, 'RECORD', '{}'::jsonb, p_business_id, p_organization_id);
  IF p_approval_method = 'STANDARD' AND v_can->>'decision' <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision','DENIED','reason','MATRIX_DENY','can_perform', v_can);
  END IF;
  IF p_approval_method = 'STEP_UP' AND v_can->>'decision' <> 'REQUIRE_STEP_UP' THEN
    RETURN jsonb_build_object('decision','DENIED','reason','MATRIX_DENY','can_perform', v_can);
  END IF;

  IF p_approval_method = 'STEP_UP' THEN
    IF p_step_up_token_id IS NULL THEN
      RETURN jsonb_build_object('decision','DENIED','reason','STEP_UP_TOKEN_REQUIRED');
    END IF;
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='FINALIZATION_STEP_UP_CHALLENGED',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
      p_actor_user_id:=p_actor_user_id,
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_after_state:=jsonb_build_object('token_id', p_step_up_token_id, 'surface', v_surface),
      p_request_context:=p_context);

    SELECT * INTO v_consume FROM public._consume_step_up_token_for_actor(
      p_step_up_token_id, p_business_id, v_surface, p_actor_user_id, v_approval_id);

    IF NOT v_consume.consumed THEN
      v_lock_state := public.fn_record_step_up_failure(p_actor_user_id, p_business_id);
      PERFORM audit.emit_audit(
        p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='FINALIZATION_STEP_UP_FAILED',
        p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
        p_actor_user_id:=p_actor_user_id,
        p_organization_id:=p_organization_id, p_business_id:=p_business_id,
        p_after_state:=jsonb_build_object('reason', v_consume.reason, 'lockout', v_lock_state),
        p_request_context:=p_context);
      RETURN jsonb_build_object('decision','DENIED','reason','STEP_UP_TOKEN_INVALID',
                                'token_reason', v_consume.reason, 'lockout', v_lock_state);
    END IF;

    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='FINALIZATION_STEP_UP_PASSED',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
      p_actor_user_id:=p_actor_user_id,
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_after_state:=jsonb_build_object('token_id', p_step_up_token_id, 'approval_id', v_approval_id),
      p_request_context:=p_context);
    PERFORM public.fn_reset_step_up_failures(p_actor_user_id, p_business_id);
  END IF;

  INSERT INTO public.workflow_run_approvals (id, organization_id, business_id, run_id,
    approved_by, approved_at, approval_method, approval_note)
  VALUES (v_approval_id, p_organization_id, p_business_id, p_run_id,
          p_actor_user_id, v_now, p_approval_method, p_approval_note);

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='OUT_HUMAN_REVIEW_APPROVAL_RECORDED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
    p_actor_system:='out_workflow_human_review_hold',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_after_state:=jsonb_build_object(
      'approval_id', v_approval_id, 'approved_by', p_actor_user_id,
      'approved_at', v_now, 'approval_method', p_approval_method::text,
      'approval_note', p_approval_note),
    p_request_context:=p_context);

  IF p_approval_method = 'STEP_UP' THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='FINALIZATION_APPROVAL_QUALIFIED',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
      p_actor_user_id:=p_actor_user_id,
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_after_state:=jsonb_build_object('approval_id', v_approval_id),
      p_request_context:=p_context);
  END IF;

  RETURN jsonb_build_object('decision','APPROVED','approval_id', v_approval_id,
                            'approved_at', v_now, 'method', p_approval_method::text);
END;
$$;

CREATE OR REPLACE FUNCTION public.in_workflow_user_approval(
  p_organization_id  uuid,
  p_business_id      uuid,
  p_run_id           uuid,
  p_approval_method  public.workflow_approval_method_enum,
  p_approval_note    text,
  p_actor_user_id    uuid,
  p_context          jsonb,
  p_step_up_token_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_surface text;
  v_can jsonb;
  v_approval_id uuid := public.gen_uuid_v7();
  v_now timestamptz := clock_timestamp();
  v_consume record;
  v_lock_state jsonb;
BEGIN
  IF p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'in_workflow.user_approval: actor_user_id required' USING ERRCODE='22000';
  END IF;

  v_surface := CASE p_approval_method
                 WHEN 'STANDARD' THEN 'APPROVAL_STANDARD'
                 WHEN 'STEP_UP'  THEN 'APPROVAL_STEP_UP'
               END;

  IF p_approval_method = 'STEP_UP' AND public.fn_is_step_up_locked(p_actor_user_id, p_business_id) THEN
    RETURN jsonb_build_object('decision','DENIED','reason','LOCKED_OUT');
  END IF;

  v_can := public.can_perform(p_actor_user_id, v_surface, 'RECORD', '{}'::jsonb, p_business_id, p_organization_id);
  IF p_approval_method = 'STANDARD' AND v_can->>'decision' <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision','DENIED','reason','MATRIX_DENY','can_perform', v_can);
  END IF;
  IF p_approval_method = 'STEP_UP' AND v_can->>'decision' <> 'REQUIRE_STEP_UP' THEN
    RETURN jsonb_build_object('decision','DENIED','reason','MATRIX_DENY','can_perform', v_can);
  END IF;

  IF p_approval_method = 'STEP_UP' THEN
    IF p_step_up_token_id IS NULL THEN
      RETURN jsonb_build_object('decision','DENIED','reason','STEP_UP_TOKEN_REQUIRED');
    END IF;
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='FINALIZATION_STEP_UP_CHALLENGED',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
      p_actor_user_id:=p_actor_user_id,
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_after_state:=jsonb_build_object('token_id', p_step_up_token_id, 'surface', v_surface),
      p_request_context:=p_context);

    SELECT * INTO v_consume FROM public._consume_step_up_token_for_actor(
      p_step_up_token_id, p_business_id, v_surface, p_actor_user_id, v_approval_id);

    IF NOT v_consume.consumed THEN
      v_lock_state := public.fn_record_step_up_failure(p_actor_user_id, p_business_id);
      PERFORM audit.emit_audit(
        p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='FINALIZATION_STEP_UP_FAILED',
        p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
        p_actor_user_id:=p_actor_user_id,
        p_organization_id:=p_organization_id, p_business_id:=p_business_id,
        p_after_state:=jsonb_build_object('reason', v_consume.reason, 'lockout', v_lock_state),
        p_request_context:=p_context);
      RETURN jsonb_build_object('decision','DENIED','reason','STEP_UP_TOKEN_INVALID',
                                'token_reason', v_consume.reason, 'lockout', v_lock_state);
    END IF;

    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='FINALIZATION_STEP_UP_PASSED',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
      p_actor_user_id:=p_actor_user_id,
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_after_state:=jsonb_build_object('token_id', p_step_up_token_id, 'approval_id', v_approval_id),
      p_request_context:=p_context);
    PERFORM public.fn_reset_step_up_failures(p_actor_user_id, p_business_id);
  END IF;

  INSERT INTO public.workflow_run_approvals (id, organization_id, business_id, run_id,
    approved_by, approved_at, approval_method, approval_note)
  VALUES (v_approval_id, p_organization_id, p_business_id, p_run_id,
          p_actor_user_id, v_now, p_approval_method, p_approval_note);

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_HUMAN_REVIEW_APPROVAL_RECORDED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
    p_actor_system:='in_workflow_human_review_hold',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_after_state:=jsonb_build_object(
      'approval_id', v_approval_id, 'approved_by', p_actor_user_id,
      'approved_at', v_now, 'approval_method', p_approval_method::text,
      'approval_note', p_approval_note),
    p_request_context:=p_context);

  IF p_approval_method = 'STEP_UP' THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='FINALIZATION_APPROVAL_QUALIFIED',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
      p_actor_user_id:=p_actor_user_id,
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_after_state:=jsonb_build_object('approval_id', v_approval_id),
      p_request_context:=p_context);
  END IF;

  RETURN jsonb_build_object('decision','APPROVED','approval_id', v_approval_id,
                            'approved_at', v_now, 'method', p_approval_method::text);
END;
$$;

CREATE OR REPLACE FUNCTION public.gate_finalization_approval_present_and_step_up(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_run record;
  v_any record;
BEGIN
  SELECT business_id, organization_id INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','HOLD','gate','approval_present_and_step_up',
                              'payload', jsonb_build_object('reason','RUN_NOT_FOUND'));
  END IF;
  SELECT a.approval_method, a.revoked_at INTO v_any
    FROM public.workflow_run_approvals a
   WHERE a.run_id = p_run_id
   ORDER BY a.approved_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','HOLD','gate','approval_present_and_step_up',
                              'payload', jsonb_build_object('reason','NO_APPROVAL_FOUND'));
  END IF;
  IF v_any.revoked_at IS NOT NULL THEN
    RETURN jsonb_build_object('decision','HOLD','gate','approval_present_and_step_up',
                              'payload', jsonb_build_object('reason','APPROVAL_REVOKED'));
  END IF;
  IF public.latest_qualifying_step_up_approval(v_run.business_id, p_run_id) IS NOT NULL THEN
    RETURN jsonb_build_object('decision','ADVANCE','gate','approval_present_and_step_up');
  END IF;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='FINALIZATION_APPROVAL_NOT_QUALIFIED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
    p_actor_system:='finalization_gate_composite',
    p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
    p_after_state:=jsonb_build_object('reason','APPROVAL_NOT_STEP_UP'));
  RETURN jsonb_build_object('decision','HOLD','gate','approval_present_and_step_up',
                            'payload', jsonb_build_object('reason','APPROVAL_NOT_STEP_UP'));
END;
$$;
