-- =============================================================================
-- Pretest fix (2026-06-02) — N5: populate principal_snapshot at run creation
-- =============================================================================
-- create_paired_workflow_runs persisted principal_snapshot verbatim from the
-- caller, which always passed '{}'. For MANUAL runs started_by is backfilled at
-- start, but EVENT-triggered runs then depend wholly on the settings fallback
-- (WORKER_SYSTEM_ACTOR_USER_ID) for the actor — the actors.py
-- principal_snapshot.actor_user_id resolution path was effectively dead, and
-- "who started this run" was unrecoverable from the run row.
--
-- Fix: when the caller passes an empty snapshot but an actor is known, build a
-- snapshot (actor_user_id + role + source + captured_at) at creation. Callers
-- that pass a real snapshot are unaffected; pure SYSTEM runs with no actor keep
-- '{}'. Body otherwise verbatim.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.create_paired_workflow_runs(p_organization_id uuid, p_business_id uuid, p_statement_upload_id uuid, p_period_start timestamp with time zone, p_period_end timestamp with time zone, p_actor_user_id uuid DEFAULT NULL::uuid, p_trigger_event_id uuid DEFAULT NULL::uuid, p_principal_snapshot jsonb DEFAULT '{}'::jsonb, p_context jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
DECLARE
  v_out_id uuid := public.gen_uuid_v7();
  v_in_id  uuid := public.gen_uuid_v7();
  v_guard  jsonb;
  v_trigger_kind public.trigger_kind_enum :=
    CASE WHEN p_trigger_event_id IS NULL THEN 'MANUAL'::public.trigger_kind_enum
         ELSE 'EVENT'::public.trigger_kind_enum END;
  v_trigger_event_text text :=
    CASE WHEN p_trigger_event_id IS NULL THEN NULL ELSE p_trigger_event_id::text END;
  v_pair_summary jsonb := jsonb_build_object('statement_upload_id', p_statement_upload_id);
  v_snapshot jsonb;
BEGIN
  -- Populate the principal snapshot when the caller passed an empty one but the
  -- actor is known, so event-run provenance (who/role/source) is preserved.
  IF p_principal_snapshot IS NULL OR p_principal_snapshot = '{}'::jsonb THEN
    IF p_actor_user_id IS NOT NULL THEN
      v_snapshot := jsonb_strip_nulls(jsonb_build_object(
        'actor_user_id', p_actor_user_id,
        'role', (SELECT bur.role::text FROM public.business_user_roles bur
                  WHERE bur.user_id = p_actor_user_id
                    AND bur.business_id = p_business_id
                    AND bur.status = 'ACTIVE' LIMIT 1),
        'source', v_trigger_kind::text,
        'captured_at', now()));
    ELSE
      v_snapshot := COALESCE(p_principal_snapshot, '{}'::jsonb);
    END IF;
  ELSE
    v_snapshot := p_principal_snapshot;
  END IF;

  v_guard := public._out_workflow_assert_no_active_run(
    p_organization_id, p_business_id, 'OUT_MONTHLY'::public.workflow_type_enum,
    p_period_start, p_period_end, p_actor_user_id, p_context);
  IF v_guard->>'decision' = 'REJECTED' THEN
    RETURN v_guard || jsonb_build_object('side','OUT_MONTHLY');
  END IF;

  v_guard := public._out_workflow_assert_no_active_run(
    p_organization_id, p_business_id, 'IN_MONTHLY'::public.workflow_type_enum,
    p_period_start, p_period_end, p_actor_user_id, p_context);
  IF v_guard->>'decision' = 'REJECTED' THEN
    RETURN v_guard || jsonb_build_object('side','IN_MONTHLY');
  END IF;

  INSERT INTO public.workflow_runs (
    id, organization_id, business_id, workflow_type, status,
    period_start, period_end, principal_snapshot,
    trigger_kind, trigger_event_id,
    triggered_by_user_id, triggered_by_event_id, paired_run_id, summary_json)
  VALUES
    (v_out_id, p_organization_id, p_business_id, 'OUT_MONTHLY'::public.workflow_type_enum,
     'CREATED'::public.workflow_run_status_enum,
     p_period_start, p_period_end, v_snapshot,
     v_trigger_kind, v_trigger_event_text,
     p_actor_user_id, p_trigger_event_id, v_in_id, v_pair_summary),
    (v_in_id, p_organization_id, p_business_id, 'IN_MONTHLY'::public.workflow_type_enum,
     'CREATED'::public.workflow_run_status_enum,
     p_period_start, p_period_end, v_snapshot,
     v_trigger_kind, v_trigger_event_text,
     p_actor_user_id, p_trigger_event_id, v_out_id, v_pair_summary);

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='OUT_WORKFLOW_PAIRED_RUN_LINKED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=v_out_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_coordinator',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'out_run_id', v_out_id, 'in_run_id', v_in_id,
      'statement_upload_id', p_statement_upload_id,
      'period_start', p_period_start, 'period_end', p_period_end,
      'trigger_kind', v_trigger_kind::text,
      'trigger_event_id', p_trigger_event_id,
      'triggered_by_user_id', p_actor_user_id),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'decision','CREATED',
    'out_run_id', v_out_id, 'in_run_id', v_in_id,
    'paired', true);
END;
$function$;
