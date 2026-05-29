-- B12·P08 — Triggers: Manual + Event
-- =====================================================================
-- Wires the two OUT_MONTHLY start mechanisms:
--   1. Manual user action (Start button) — out_workflow_start_run_manually
--   2. Event subscription on STATEMENT_UPLOAD_COMPLETED — handler RPC
--
-- No schema delta. Active-run dedup delegated to B12·P04's
-- _out_workflow_assert_no_active_run (called inside create_paired_workflow_runs).
-- Event-replay dedup via trigger_events_processed PK (event_id text).
-- New checks this phase owns: period-already-finalized + 6-year retention.
--
-- 6 audit actions:
--   OUT_WORKFLOW_RUN_STARTED_MANUALLY
--   OUT_WORKFLOW_RUN_STARTED_BY_EVENT
--   OUT_WORKFLOW_AUTO_START_SUPPRESSED
--   OUT_WORKFLOW_EVENT_TRIGGER_DEDUPLICATED
--   OUT_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED
--   OUT_WORKFLOW_RUN_REJECTED_RETENTION_EXPIRED
-- =====================================================================

BEGIN;

-- 1. Internal period-finalized check
CREATE OR REPLACE FUNCTION public._out_workflow_check_period_finalized(
  p_business_id uuid, p_period_start timestamptz, p_period_end timestamptz
) RETURNS boolean LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.workflow_runs
     WHERE business_id = p_business_id
       AND workflow_type = 'OUT_MONTHLY'
       AND period_start = p_period_start
       AND period_end = p_period_end
       AND status = 'FINALIZED');
$$;
REVOKE EXECUTE ON FUNCTION public._out_workflow_check_period_finalized(uuid,timestamptz,timestamptz) FROM PUBLIC;


-- 2. Internal retention check (Stage 1: 6-year window)
CREATE OR REPLACE FUNCTION public._out_workflow_check_within_retention(
  p_period_end timestamptz
) RETURNS boolean LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT p_period_end >= (clock_timestamp() - interval '6 years');
$$;
REVOKE EXECUTE ON FUNCTION public._out_workflow_check_within_retention(timestamptz) FROM PUBLIC;


-- 3. Manual trigger RPC
CREATE OR REPLACE FUNCTION public.out_workflow_start_run_manually(
  p_organization_id uuid, p_business_id uuid,
  p_period_start timestamptz, p_period_end timestamptz,
  p_started_by uuid, p_manual_trigger_note text DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_can jsonb;
  v_create jsonb;
  v_out_run uuid;
BEGIN
  IF p_started_by IS NULL THEN
    RAISE EXCEPTION 'out_workflow.start_run_manually: started_by required' USING ERRCODE='22000';
  END IF;
  v_can := public.can_perform(p_started_by, 'WORKFLOW_TRIGGER', 'START', '{}'::jsonb, p_business_id, p_organization_id);
  IF v_can->>'decision' <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision','DENIED','can_perform', v_can);
  END IF;

  IF NOT public._out_workflow_check_within_retention(p_period_end) THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='OUT_WORKFLOW_RUN_REJECTED_RETENTION_EXPIRED',
      p_subject_type:='BUSINESS'::audit.subject_type_enum,
      p_subject_id:=p_business_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='out_workflow_trigger',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'period_start', p_period_start, 'period_end', p_period_end,
        'trigger_kind','MANUAL', 'started_by', p_started_by),
      p_reason:='Period older than 6-year retention window',
      p_request_context:=p_context);
    RETURN jsonb_build_object('decision','REJECTED','reason','RETENTION_EXPIRED');
  END IF;

  IF public._out_workflow_check_period_finalized(p_business_id, p_period_start, p_period_end) THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='OUT_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED',
      p_subject_type:='BUSINESS'::audit.subject_type_enum,
      p_subject_id:=p_business_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='out_workflow_trigger',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'period_start', p_period_start, 'period_end', p_period_end,
        'trigger_kind','MANUAL', 'started_by', p_started_by),
      p_reason:='Period already finalized — use OUT_ADJUSTMENT instead',
      p_request_context:=p_context);
    RETURN jsonb_build_object('decision','REJECTED','reason','PERIOD_FINALIZED');
  END IF;

  v_create := public.create_paired_workflow_runs(
    p_organization_id, p_business_id, NULL,
    p_period_start, p_period_end,
    p_started_by, NULL, '{}'::jsonb, p_context);
  IF v_create->>'decision' <> 'CREATED' THEN
    RETURN v_create;
  END IF;
  v_out_run := (v_create->>'out_run_id')::uuid;

  IF p_manual_trigger_note IS NOT NULL THEN
    UPDATE public.workflow_runs
       SET manual_trigger_note = p_manual_trigger_note
     WHERE id = v_out_run;
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='OUT_WORKFLOW_RUN_STARTED_MANUALLY',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=v_out_run,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_trigger',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'started_by', p_started_by,
      'manual_trigger_note', p_manual_trigger_note,
      'out_run_id', v_out_run,
      'in_run_id', v_create->'in_run_id',
      'period_start', p_period_start, 'period_end', p_period_end),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN v_create || jsonb_build_object('decision','STARTED','trigger_kind','MANUAL');
END;
$$;
REVOKE EXECUTE ON FUNCTION public.out_workflow_start_run_manually(uuid,uuid,timestamptz,timestamptz,uuid,text,jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.out_workflow_start_run_manually(uuid,uuid,timestamptz,timestamptz,uuid,text,jsonb) TO service_role;


-- 4. Event-driven trigger handler
CREATE OR REPLACE FUNCTION public.out_workflow_handle_statement_upload_event(
  p_event_id text,
  p_organization_id uuid, p_business_id uuid,
  p_statement_upload_id uuid,
  p_period_start timestamptz, p_period_end timestamptz,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_auto_start boolean;
  v_create jsonb;
  v_out_run uuid;
  v_in_run uuid;
  v_inserted_event boolean;
  v_synthetic_event_id uuid := public.gen_uuid_v7();
BEGIN
  IF p_event_id IS NULL OR length(btrim(p_event_id)) = 0 THEN
    RAISE EXCEPTION 'out_workflow.handle_statement_upload_event: event_id required' USING ERRCODE='22000';
  END IF;

  INSERT INTO public.trigger_events_processed (
    event_id, event_kind, business_id, organization_id,
    period_start, period_end, created_run_ids, payload, processed_at)
  VALUES (
    p_event_id, 'STATEMENT_UPLOAD_COMPLETED', p_business_id, p_organization_id,
    p_period_start, p_period_end, ARRAY[]::uuid[],
    jsonb_build_object('statement_upload_id', p_statement_upload_id), clock_timestamp())
  ON CONFLICT (event_id) DO NOTHING;
  GET DIAGNOSTICS v_inserted_event = ROW_COUNT;

  IF NOT v_inserted_event THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='OUT_WORKFLOW_EVENT_TRIGGER_DEDUPLICATED',
      p_subject_type:='BUSINESS'::audit.subject_type_enum,
      p_subject_id:=p_business_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='out_workflow_trigger',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('event_id', p_event_id, 'event_kind','STATEMENT_UPLOAD_COMPLETED'),
      p_reason:='Event id already processed',
      p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DEDUPLICATED','event_id', p_event_id);
  END IF;

  SELECT auto_start_on_statement_upload INTO v_auto_start
    FROM public.out_workflow_business_config WHERE business_id = p_business_id;
  IF v_auto_start IS NULL THEN v_auto_start := true; END IF;
  IF NOT v_auto_start THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='OUT_WORKFLOW_AUTO_START_SUPPRESSED',
      p_subject_type:='BUSINESS'::audit.subject_type_enum,
      p_subject_id:=p_business_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='out_workflow_trigger',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('event_id', p_event_id, 'statement_upload_id', p_statement_upload_id),
      p_reason:='auto_start_on_statement_upload=false',
      p_request_context:=p_context);
    RETURN jsonb_build_object('decision','SUPPRESSED','event_id', p_event_id);
  END IF;

  IF NOT public._out_workflow_check_within_retention(p_period_end) THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='OUT_WORKFLOW_RUN_REJECTED_RETENTION_EXPIRED',
      p_subject_type:='BUSINESS'::audit.subject_type_enum,
      p_subject_id:=p_business_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='out_workflow_trigger',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'event_id', p_event_id, 'period_start', p_period_start, 'period_end', p_period_end,
        'trigger_kind','EVENT'),
      p_reason:='Period older than 6-year retention window',
      p_request_context:=p_context);
    RETURN jsonb_build_object('decision','REJECTED','reason','RETENTION_EXPIRED');
  END IF;

  IF public._out_workflow_check_period_finalized(p_business_id, p_period_start, p_period_end) THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='OUT_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED',
      p_subject_type:='BUSINESS'::audit.subject_type_enum,
      p_subject_id:=p_business_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='out_workflow_trigger',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'event_id', p_event_id, 'period_start', p_period_start, 'period_end', p_period_end,
        'trigger_kind','EVENT'),
      p_reason:='Period already finalized — use OUT_ADJUSTMENT instead',
      p_request_context:=p_context);
    RETURN jsonb_build_object('decision','REJECTED','reason','PERIOD_FINALIZED');
  END IF;

  v_create := public.create_paired_workflow_runs(
    p_organization_id, p_business_id, p_statement_upload_id,
    p_period_start, p_period_end,
    NULL, v_synthetic_event_id, '{}'::jsonb, p_context);
  IF v_create->>'decision' <> 'CREATED' THEN
    RETURN v_create;
  END IF;
  v_out_run := (v_create->>'out_run_id')::uuid;
  v_in_run  := (v_create->>'in_run_id')::uuid;

  UPDATE public.trigger_events_processed
     SET created_run_ids = ARRAY[v_out_run, v_in_run]
   WHERE event_id = p_event_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='OUT_WORKFLOW_RUN_STARTED_BY_EVENT',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=v_out_run,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_trigger',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'event_id', p_event_id,
      'statement_upload_id', p_statement_upload_id,
      'out_run_id', v_out_run, 'in_run_id', v_in_run,
      'period_start', p_period_start, 'period_end', p_period_end),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN v_create || jsonb_build_object('decision','STARTED','trigger_kind','EVENT');
END;
$$;
REVOKE EXECUTE ON FUNCTION public.out_workflow_handle_statement_upload_event(text,uuid,uuid,uuid,timestamptz,timestamptz,jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.out_workflow_handle_statement_upload_event(text,uuid,uuid,uuid,timestamptz,timestamptz,jsonb) TO service_role;


-- 5. Tool registry seeds
SELECT public.register_tool(
  p_tool_name=>'out_workflow.start_run_manually', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('organization_id','uuid','business_id','uuid','period_start','timestamptz','period_end','timestamptz','started_by','uuid','manual_trigger_note','text'),
  p_output_schema=>jsonb_build_object('decision','text','out_run_id','uuid','in_run_id','uuid','trigger_kind','text','can_perform','object'),
  p_side_effect=>'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>'out_workflow.start_run_manually.dedup_key_v1',
  p_description=>'Manual OUT_MONTHLY trigger (B12·P08) — gated by WORKFLOW_TRIGGER; active-run/finalized/retention checks; delegates to create_paired_workflow_runs',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);

SELECT public.register_tool(
  p_tool_name=>'out_workflow.handle_statement_upload_event', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('event_id','text','organization_id','uuid','business_id','uuid','statement_upload_id','uuid','period_start','timestamptz','period_end','timestamptz'),
  p_output_schema=>jsonb_build_object('decision','text','out_run_id','uuid','in_run_id','uuid','trigger_kind','text','event_id','text','reason','text'),
  p_side_effect=>'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>'out_workflow.handle_statement_upload_event.dedup_key_v1',
  p_description=>'STATEMENT_UPLOAD_COMPLETED event handler (B12·P08) — replay dedup via trigger_events_processed PK; respects auto_start_on_statement_upload; checks finalized/retention',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);

COMMIT;
