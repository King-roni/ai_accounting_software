-- B12·P09 — OUT_ADJUSTMENT Workflow Type
-- =====================================================================
-- Replaces the 4 placeholder OUT_ADJUSTMENT phase rows in
-- workflow_phase_definitions with the spec's 5-phase sequence:
--   1. ADJUSTMENT_INTAKE
--   2. ADJUSTMENT_LEDGER_PREP
--   3. ADJUSTMENT_AI_REVIEW
--   4. ADJUSTMENT_HUMAN_REVIEW
--   5. ADJUSTMENT_FINALIZATION
--
-- Adds the intake RPC + tool registration. The other 4 phases are owned by
-- their respective blocks (11 LEDGER, 06 AI, 12 HRH adjustment-variant, 15
-- FINALIZATION) — this phase pins the contract only.
--
-- Concurrency: OUT_MONTHLY + OUT_ADJUSTMENT for the same period coexist by
-- design — B12·P04's _out_workflow_assert_no_active_run is keyed per
-- (business, workflow_type, period) so the two types don't collide.
--
-- 5 audit actions:
--   OUT_ADJUSTMENT_RUN_CREATED
--   OUT_ADJUSTMENT_INTAKE_COMPLETED
--   OUT_ADJUSTMENT_REJECTED_RETENTION_EXPIRED
--   OUT_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED
--   OUT_ADJUSTMENT_INTERLEAVED_INTO_ARCHIVE  (owned by Block 15; declared here for contract closure)
-- =====================================================================

BEGIN;

-- 1. Phase sequence rebuild
-- Rename existing 4 placeholder phases first to avoid (workflow_type, phase_name) uniqueness collisions
UPDATE public.workflow_phase_definitions
   SET phase_name = phase_name || '__obsolete'
 WHERE workflow_type='OUT_ADJUSTMENT';
-- Shift their phase_order out of the way (+100) to free 1..5
UPDATE public.workflow_phase_definitions
   SET phase_order = phase_order + 100
 WHERE workflow_type='OUT_ADJUSTMENT';
-- Drop the placeholders
DELETE FROM public.workflow_phase_definitions WHERE workflow_type='OUT_ADJUSTMENT';
-- Insert the 5 spec phases
INSERT INTO public.workflow_phase_definitions (workflow_type, phase_order, phase_name)
VALUES
  ('OUT_ADJUSTMENT', 1, 'ADJUSTMENT_INTAKE'),
  ('OUT_ADJUSTMENT', 2, 'ADJUSTMENT_LEDGER_PREP'),
  ('OUT_ADJUSTMENT', 3, 'ADJUSTMENT_AI_REVIEW'),
  ('OUT_ADJUSTMENT', 4, 'ADJUSTMENT_HUMAN_REVIEW'),
  ('OUT_ADJUSTMENT', 5, 'ADJUSTMENT_FINALIZATION');


-- 2. Helper: check parent run validity for an adjustment
CREATE OR REPLACE FUNCTION public._out_adjustment_check_parent(
  p_parent_run_id uuid, p_business_id uuid
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row record;
BEGIN
  SELECT id, workflow_type::text AS workflow_type, status::text AS status,
         period_start, period_end, business_id
    INTO v_row
    FROM public.workflow_runs WHERE id=p_parent_run_id;
  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'parent_not_found');
  END IF;
  IF v_row.business_id <> p_business_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'parent_business_mismatch');
  END IF;
  IF v_row.workflow_type <> 'OUT_MONTHLY' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'parent_not_out_monthly', 'workflow_type', v_row.workflow_type);
  END IF;
  IF v_row.status <> 'FINALIZED' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'parent_not_finalized', 'status', v_row.status);
  END IF;
  RETURN jsonb_build_object(
    'ok', true,
    'period_start', v_row.period_start,
    'period_end', v_row.period_end);
END;
$$;
REVOKE EXECUTE ON FUNCTION public._out_adjustment_check_parent(uuid,uuid) FROM PUBLIC;


-- 3. Intake RPC
CREATE OR REPLACE FUNCTION public.out_workflow_adjustment_intake(
  p_organization_id uuid, p_business_id uuid,
  p_parent_run_id uuid,
  p_reason text,
  p_delta_kind public.adjustment_delta_kind_enum,
  p_delta_payload jsonb,
  p_requesting_user_id uuid,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_can jsonb;
  v_parent jsonb;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_run_id uuid := public.gen_uuid_v7();
  v_record_id uuid := public.gen_uuid_v7();
  v_now timestamptz := clock_timestamp();
BEGIN
  IF p_requesting_user_id IS NULL THEN
    RAISE EXCEPTION 'out_workflow.adjustment_intake: requesting_user_id required' USING ERRCODE='22000';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'out_workflow.adjustment_intake: reason required (minimum 10 characters)' USING ERRCODE='22000';
  END IF;
  IF p_delta_payload IS NULL THEN
    RAISE EXCEPTION 'out_workflow.adjustment_intake: delta_payload required' USING ERRCODE='22000';
  END IF;

  v_can := public.can_perform(p_requesting_user_id, 'WORKFLOW_TRIGGER', 'START', '{}'::jsonb, p_business_id, p_organization_id);
  IF v_can->>'decision' <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision','DENIED','can_perform', v_can);
  END IF;

  v_parent := public._out_adjustment_check_parent(p_parent_run_id, p_business_id);
  IF NOT (v_parent->>'ok')::boolean THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='OUT_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED',
      p_subject_type:='BUSINESS'::audit.subject_type_enum,
      p_subject_id:=p_business_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='out_adjustment',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('parent_run_id', p_parent_run_id, 'parent_check', v_parent,
                                         'requesting_user_id', p_requesting_user_id),
      p_reason:=v_parent->>'reason',
      p_request_context:=p_context);
    RETURN jsonb_build_object('decision','REJECTED','reason', v_parent->>'reason', 'parent_check', v_parent);
  END IF;

  v_period_start := (v_parent->>'period_start')::timestamptz;
  v_period_end   := (v_parent->>'period_end')::timestamptz;

  IF NOT public._out_workflow_check_within_retention(v_period_end) THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='OUT_ADJUSTMENT_REJECTED_RETENTION_EXPIRED',
      p_subject_type:='BUSINESS'::audit.subject_type_enum,
      p_subject_id:=p_business_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='out_adjustment',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('parent_run_id', p_parent_run_id,
                                         'period_start', v_period_start, 'period_end', v_period_end,
                                         'requesting_user_id', p_requesting_user_id),
      p_reason:='parent period older than 6-year retention window',
      p_request_context:=p_context);
    RETURN jsonb_build_object('decision','REJECTED','reason','RETENTION_EXPIRED');
  END IF;

  INSERT INTO public.workflow_runs (
    id, organization_id, business_id, workflow_type, status,
    period_start, period_end, principal_snapshot,
    trigger_kind, triggered_by_user_id,
    parent_run_id, summary_json)
  VALUES (
    v_run_id, p_organization_id, p_business_id,
    'OUT_ADJUSTMENT'::public.workflow_type_enum,
    'CREATED'::public.workflow_run_status_enum,
    v_period_start, v_period_end, '{}'::jsonb,
    'MANUAL'::public.trigger_kind_enum, p_requesting_user_id,
    p_parent_run_id,
    jsonb_build_object('adjustment_record_id', v_record_id, 'delta_kind', p_delta_kind::text));

  INSERT INTO public.adjustment_records (
    id, organization_id, business_id, run_id, parent_run_id,
    parent_period_start, parent_period_end,
    reason, delta_kind, delta_payload, requesting_user_id, created_at)
  VALUES (
    v_record_id, p_organization_id, p_business_id, v_run_id, p_parent_run_id,
    v_period_start::date, v_period_end::date,
    btrim(p_reason), p_delta_kind, p_delta_payload, p_requesting_user_id, v_now);

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='OUT_ADJUSTMENT_RUN_CREATED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=v_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_adjustment',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'run_id', v_run_id, 'parent_run_id', p_parent_run_id,
      'parent_period_start', v_period_start, 'parent_period_end', v_period_end,
      'requesting_user_id', p_requesting_user_id),
    p_reason:=NULL, p_request_context:=p_context);

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='OUT_ADJUSTMENT_INTAKE_COMPLETED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=v_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_adjustment',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'adjustment_record_id', v_record_id,
      'delta_kind', p_delta_kind::text,
      'reason', btrim(p_reason),
      'delta_payload', p_delta_payload),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'decision','CREATED',
    'run_id', v_run_id,
    'adjustment_record_id', v_record_id,
    'parent_run_id', p_parent_run_id,
    'parent_period_start', v_period_start,
    'parent_period_end', v_period_end);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.out_workflow_adjustment_intake(uuid,uuid,uuid,text,public.adjustment_delta_kind_enum,jsonb,uuid,jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.out_workflow_adjustment_intake(uuid,uuid,uuid,text,public.adjustment_delta_kind_enum,jsonb,uuid,jsonb) TO service_role;


-- 4. Tool registration
SELECT public.register_tool(
  p_tool_name=>'out_workflow.adjustment_intake', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('organization_id','uuid','business_id','uuid','parent_run_id','uuid','reason','text','delta_kind','enum','delta_payload','object','requesting_user_id','uuid'),
  p_output_schema=>jsonb_build_object('decision','text','run_id','uuid','adjustment_record_id','uuid','parent_run_id','uuid','reason','text','can_perform','object'),
  p_side_effect=>'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>'out_workflow.adjustment_intake.dedup_key_v1',
  p_description=>'OUT_ADJUSTMENT intake (B12·P09) — parent-finalized + 6yr retention checks; creates OUT_ADJUSTMENT run + adjustment_records row',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);

COMMIT;
