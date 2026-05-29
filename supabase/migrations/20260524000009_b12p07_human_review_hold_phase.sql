-- B12·P07 — HUMAN_REVIEW_HOLD Phase
-- =====================================================================
-- Wires the user-action surface for HUMAN_REVIEW_HOLD: explicit approval,
-- revoke-approval, and staleness detection when a new blocking review_issue
-- arrives after a previously-recorded approval.
--
-- No schema delta — workflow_run_approvals (B12·P01) and the gate
-- gate_out_human_review_hold_exit_v1 (B12·P05) are already in place. This
-- phase adds RPCs + tool registrations + audit emissions.
--
-- Permission gate honors public.permission_matrix as-is (Block 02 ownership):
--   WORKFLOW_APPROVE surface — currently OWNER + ADMIN = ALLOW; everything
--   else = DENY. Updating the matrix (e.g., granting BOOKKEEPER per Stage 1
--   prose) is a Block 02 change, NOT this phase.
--
-- 5 audit actions:
--   OUT_HUMAN_REVIEW_HOLD_ENTERED
--   OUT_HUMAN_REVIEW_APPROVAL_RECORDED
--   OUT_HUMAN_REVIEW_APPROVAL_REVOKED
--   OUT_HUMAN_REVIEW_HOLD_CLEARED
--   OUT_HUMAN_REVIEW_APPROVAL_STALENESS_DETECTED
-- =====================================================================

BEGIN;

-- 1. Enter hold (records timestamp + audit)
CREATE OR REPLACE FUNCTION public.out_workflow_enter_human_review_hold(
  p_organization_id uuid, p_business_id uuid, p_run_id uuid,
  p_actor_user_id uuid DEFAULT NULL, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
BEGIN
  UPDATE public.workflow_runs
     SET summary_json = jsonb_set(
           COALESCE(summary_json, '{}'::jsonb),
           '{human_review_hold}',
           jsonb_build_object('entered_at', v_now, 'cleared_at', NULL),
           true)
   WHERE id = p_run_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='OUT_HUMAN_REVIEW_HOLD_ENTERED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_human_review_hold',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('entered_at', v_now, 'initiating_user_id', p_actor_user_id),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','ENTERED','entered_at', v_now);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.out_workflow_enter_human_review_hold(uuid,uuid,uuid,uuid,jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.out_workflow_enter_human_review_hold(uuid,uuid,uuid,uuid,jsonb) TO service_role;


-- 2. User approval RPC (permission-gated via can_perform; writes approval row)
CREATE OR REPLACE FUNCTION public.out_workflow_user_approval(
  p_organization_id uuid, p_business_id uuid, p_run_id uuid,
  p_approval_method public.workflow_approval_method_enum,
  p_approval_note text,
  p_actor_user_id uuid, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_can jsonb;
  v_approval_id uuid := public.gen_uuid_v7();
  v_now timestamptz := clock_timestamp();
BEGIN
  IF p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'out_workflow.user_approval: actor_user_id required' USING ERRCODE='22000';
  END IF;
  v_can := public.can_perform(p_actor_user_id, 'WORKFLOW_APPROVE', 'RECORD', '{}'::jsonb, p_business_id, p_organization_id);
  IF v_can->>'decision' <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision','DENIED','can_perform', v_can);
  END IF;

  INSERT INTO public.workflow_run_approvals (
    id, organization_id, business_id, run_id,
    approved_by, approved_at, approval_method, approval_note)
  VALUES (v_approval_id, p_organization_id, p_business_id, p_run_id,
          p_actor_user_id, v_now, p_approval_method, p_approval_note);

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='OUT_HUMAN_REVIEW_APPROVAL_RECORDED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_human_review_hold',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'approval_id', v_approval_id,
      'approved_by', p_actor_user_id,
      'approved_at', v_now,
      'approval_method', p_approval_method::text,
      'approval_note', p_approval_note),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','APPROVED','approval_id', v_approval_id, 'approved_at', v_now);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.out_workflow_user_approval(uuid,uuid,uuid,public.workflow_approval_method_enum,text,uuid,jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.out_workflow_user_approval(uuid,uuid,uuid,public.workflow_approval_method_enum,text,uuid,jsonb) TO service_role;


-- 3. Revoke approval RPC
CREATE OR REPLACE FUNCTION public.out_workflow_user_revoke_approval(
  p_organization_id uuid, p_business_id uuid, p_run_id uuid,
  p_approval_id uuid,
  p_actor_user_id uuid, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_existing public.workflow_run_approvals%ROWTYPE;
  v_now timestamptz := clock_timestamp();
BEGIN
  IF p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'out_workflow.user_revoke_approval: actor_user_id required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_existing FROM public.workflow_run_approvals
   WHERE id=p_approval_id AND run_id=p_run_id;
  IF v_existing.id IS NULL THEN
    RAISE EXCEPTION 'out_workflow.user_revoke_approval: approval % not found for run %', p_approval_id, p_run_id USING ERRCODE='02000';
  END IF;
  IF v_existing.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'out_workflow.user_revoke_approval: approval % already revoked at %', p_approval_id, v_existing.revoked_at USING ERRCODE='22000';
  END IF;

  UPDATE public.workflow_run_approvals
     SET revoked_by = p_actor_user_id, revoked_at = v_now
   WHERE id = p_approval_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='OUT_HUMAN_REVIEW_APPROVAL_REVOKED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_human_review_hold',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=jsonb_build_object(
      'approval_id', p_approval_id,
      'approved_by', v_existing.approved_by,
      'approved_at', v_existing.approved_at,
      'approval_method', v_existing.approval_method::text),
    p_after_state:=jsonb_build_object(
      'revoked_by', p_actor_user_id, 'revoked_at', v_now),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','REVOKED','approval_id', p_approval_id, 'revoked_at', v_now);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.out_workflow_user_revoke_approval(uuid,uuid,uuid,uuid,uuid,jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.out_workflow_user_revoke_approval(uuid,uuid,uuid,uuid,uuid,jsonb) TO service_role;


-- 4. Approval-staleness detection (per spec: a new blocking issue post-approval
--    makes the prior approval insufficient — the gate already returns HOLD via
--    the blocking-count check, but the staleness audit signals the WHY to the UX)
CREATE OR REPLACE FUNCTION public.out_workflow_check_approval_staleness(
  p_organization_id uuid, p_business_id uuid, p_run_id uuid,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_latest_approval_at timestamptz;
  v_blocking_after int;
  v_stale boolean;
  v_result jsonb;
BEGIN
  SELECT max(approved_at) INTO v_latest_approval_at
    FROM public.workflow_run_approvals
   WHERE run_id = p_run_id AND revoked_at IS NULL;

  IF v_latest_approval_at IS NULL THEN
    RETURN jsonb_build_object('decision','NO_APPROVAL','stale', false);
  END IF;

  SELECT count(*) INTO v_blocking_after
    FROM public.review_issues
   WHERE workflow_run_id = p_run_id
     AND severity IN ('HIGH','BLOCKING')
     AND status = 'OPEN'
     AND created_at > v_latest_approval_at;

  v_stale := v_blocking_after > 0;

  IF v_stale THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='OUT_HUMAN_REVIEW_APPROVAL_STALENESS_DETECTED',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
      p_subject_id:=p_run_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='out_workflow_human_review_hold',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'latest_approval_at', v_latest_approval_at,
        'blocking_issues_after_approval', v_blocking_after),
      p_reason:='New blocking review_issue arrived after the most recent approval',
      p_request_context:=p_context);
  END IF;

  RETURN jsonb_build_object(
    'decision', CASE WHEN v_stale THEN 'STALE' ELSE 'FRESH' END,
    'stale', v_stale,
    'latest_approval_at', v_latest_approval_at,
    'blocking_issues_after_approval', v_blocking_after);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.out_workflow_check_approval_staleness(uuid,uuid,uuid,jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.out_workflow_check_approval_staleness(uuid,uuid,uuid,jsonb) TO service_role;


-- 5. Clear the hold (gate-driven)
CREATE OR REPLACE FUNCTION public.out_workflow_clear_human_review_hold(
  p_organization_id uuid, p_business_id uuid, p_run_id uuid,
  p_actor_user_id uuid DEFAULT NULL, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_gate jsonb;
  v_period_start timestamptz; v_period_end timestamptz;
  v_now timestamptz := clock_timestamp();
BEGIN
  SELECT period_start, period_end INTO v_period_start, v_period_end
    FROM public.workflow_runs WHERE id=p_run_id;
  v_gate := public.gate_out_human_review_hold_exit_v1(p_run_id, p_business_id, v_period_start, v_period_end, p_context);
  IF v_gate->>'decision' <> 'ADVANCE' THEN
    RETURN jsonb_build_object('decision','NOT_READY','gate', v_gate);
  END IF;

  UPDATE public.workflow_runs
     SET summary_json = jsonb_set(
           COALESCE(summary_json, '{}'::jsonb),
           '{human_review_hold,cleared_at}',
           to_jsonb(v_now), true)
   WHERE id = p_run_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='OUT_HUMAN_REVIEW_HOLD_CLEARED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_human_review_hold',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'cleared_at', v_now, 'initiating_user_id', p_actor_user_id,
      'gate_observed', v_gate->'inputs_observed'),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','CLEARED','cleared_at', v_now);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.out_workflow_clear_human_review_hold(uuid,uuid,uuid,uuid,jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.out_workflow_clear_human_review_hold(uuid,uuid,uuid,uuid,jsonb) TO service_role;


-- 6. Tool registry seeds (3 user-action tools)
SELECT public.register_tool(
  p_tool_name=>'out_workflow.user_approval', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('organization_id','uuid','business_id','uuid','workflow_run_id','uuid','approval_method','enum','approval_note','text','actor_user_id','uuid'),
  p_output_schema=>jsonb_build_object('decision','text','approval_id','uuid','approved_at','timestamptz','can_perform','object'),
  p_side_effect=>'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>'out_workflow.user_approval.dedup_key_v1',
  p_description=>'User-driven explicit approval for HUMAN_REVIEW_HOLD (B12·P07) — gated by WORKFLOW_APPROVE permission surface',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);

SELECT public.register_tool(
  p_tool_name=>'out_workflow.user_revoke_approval', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('organization_id','uuid','business_id','uuid','workflow_run_id','uuid','approval_id','uuid','actor_user_id','uuid'),
  p_output_schema=>jsonb_build_object('decision','text','approval_id','uuid','revoked_at','timestamptz'),
  p_side_effect=>'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>'out_workflow.user_revoke_approval.dedup_key_v1',
  p_description=>'User-driven revoke of a previously-recorded approval for HUMAN_REVIEW_HOLD (B12·P07)',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);

SELECT public.register_tool(
  p_tool_name=>'out_workflow.check_approval_staleness', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('organization_id','uuid','business_id','uuid','workflow_run_id','uuid'),
  p_output_schema=>jsonb_build_object('decision','text','stale','boolean','latest_approval_at','timestamptz','blocking_issues_after_approval','int'),
  p_side_effect=>'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>NULL,
  p_description=>'Detects whether a recorded approval is stale due to a new blocking review_issue post-approval (B12·P07)',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);

COMMIT;
