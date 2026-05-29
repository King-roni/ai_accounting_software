-- B07·P09 — Fix-up: array concatenation needs ARRAY[…] literal on RHS
--
-- Original 20260522000023 used `v_types_enabled := v_types_enabled || 'OUT_MONTHLY'`
-- which PostgreSQL parses as text → malformed array literal. Use ARRAY['…']
-- literal on the right-hand side.

CREATE OR REPLACE FUNCTION public.consume_statement_upload_completed_event(
  p_event_id uuid, p_actor_user_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_evt public.statement_upload_events_outbox%ROWTYPE;
  v_processed boolean;
  v_run_id uuid;
  v_created_runs uuid[] := '{}';
  v_types_enabled text[] := '{}';
  v_out_disabled boolean; v_in_disabled boolean;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
  v_workflow_type public.workflow_type_enum;
BEGIN
  IF p_event_id IS NULL THEN
    RAISE EXCEPTION 'consume_statement_upload_completed_event: p_event_id is required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_evt FROM public.statement_upload_events_outbox WHERE event_id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'EVENT_NOT_FOUND', 'event_id', p_event_id);
  END IF;
  SELECT EXISTS (SELECT 1 FROM public.trigger_events_processed WHERE event_id = p_event_id::text) INTO v_processed;
  IF v_processed THEN
    IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_upload_trigger';
    ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
    v_audit_row := audit.emit_audit(
      p_actor_kind => v_kind, p_action => 'STATEMENT_UPLOAD_EVENT_REPLAY_NOOP',
      p_subject_type => 'TRIGGER_EVENT'::audit.subject_type_enum,
      p_subject_id => p_event_id,
      p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
      p_organization_id => v_evt.organization_id, p_business_id => v_evt.business_id,
      p_after_state => jsonb_build_object(
        'event_id', p_event_id,
        'created_run_ids', to_jsonb(v_evt.created_run_ids)),
      p_reason => format('replay noop on event %s', p_event_id));
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true,
      'event_id', p_event_id,
      'created_run_ids', to_jsonb(v_evt.created_run_ids),
      'audit_event_id', v_audit_row.id);
  END IF;

  SELECT EXISTS (SELECT 1 FROM public.business_workflow_config
    WHERE business_id = v_evt.business_id
      AND workflow_type = 'OUT_MONTHLY'::public.workflow_type_enum
      AND (enabled_phases IS NULL OR enabled_phases = '[]'::jsonb)) INTO v_out_disabled;
  SELECT EXISTS (SELECT 1 FROM public.business_workflow_config
    WHERE business_id = v_evt.business_id
      AND workflow_type = 'IN_MONTHLY'::public.workflow_type_enum
      AND (enabled_phases IS NULL OR enabled_phases = '[]'::jsonb)) INTO v_in_disabled;

  IF NOT v_out_disabled THEN
    v_workflow_type := 'OUT_MONTHLY'::public.workflow_type_enum;
    v_run_id := public.gen_uuid_v7();
    INSERT INTO public.workflow_runs
      (id, organization_id, business_id, workflow_type, principal_snapshot,
       period_start, period_end, trigger_kind, trigger_event_id, status,
       summary_json, created_at, updated_at)
    VALUES
      (v_run_id, v_evt.organization_id, v_evt.business_id, v_workflow_type,
       jsonb_build_object('actor_user_id', v_evt.actor_user_id,
                          'event_id', v_evt.event_id,
                          'statement_upload_id', v_evt.statement_upload_id),
       v_evt.declared_period_start::timestamptz,
       (v_evt.declared_period_end + 1)::timestamptz,
       'EVENT'::public.trigger_kind_enum, p_event_id::text, 'CREATED',
       '{}'::jsonb, clock_timestamp(), clock_timestamp());
    v_created_runs := v_created_runs || ARRAY[v_run_id];
    v_types_enabled := v_types_enabled || ARRAY['OUT_MONTHLY'];
  END IF;

  IF NOT v_in_disabled THEN
    v_workflow_type := 'IN_MONTHLY'::public.workflow_type_enum;
    v_run_id := public.gen_uuid_v7();
    INSERT INTO public.workflow_runs
      (id, organization_id, business_id, workflow_type, principal_snapshot,
       period_start, period_end, trigger_kind, trigger_event_id, status,
       summary_json, created_at, updated_at)
    VALUES
      (v_run_id, v_evt.organization_id, v_evt.business_id, v_workflow_type,
       jsonb_build_object('actor_user_id', v_evt.actor_user_id,
                          'event_id', v_evt.event_id,
                          'statement_upload_id', v_evt.statement_upload_id),
       v_evt.declared_period_start::timestamptz,
       (v_evt.declared_period_end + 1)::timestamptz,
       'EVENT'::public.trigger_kind_enum, p_event_id::text, 'CREATED',
       '{}'::jsonb, clock_timestamp(), clock_timestamp());
    v_created_runs := v_created_runs || ARRAY[v_run_id];
    v_types_enabled := v_types_enabled || ARRAY['IN_MONTHLY'];
  END IF;

  INSERT INTO public.trigger_events_processed
    (event_id, event_kind, business_id, organization_id, period_start, period_end,
     created_run_ids, payload, processed_at)
  VALUES
    (p_event_id::text, 'STATEMENT_UPLOAD_COMPLETED',
     v_evt.business_id, v_evt.organization_id,
     v_evt.declared_period_start::timestamptz,
     (v_evt.declared_period_end + 1)::timestamptz,
     v_created_runs,
     jsonb_build_object(
       'statement_upload_id', v_evt.statement_upload_id,
       'bank_account_id', v_evt.bank_account_id,
       'declared_period_start', v_evt.declared_period_start,
       'declared_period_end', v_evt.declared_period_end,
       'file_format', v_evt.file_format::text,
       'provider', v_evt.provider,
       'workflow_types_created', to_jsonb(v_types_enabled)),
     clock_timestamp());

  UPDATE public.statement_upload_events_outbox
    SET status = 'CONSUMED'::public.statement_upload_event_status_enum,
        consumed_at = clock_timestamp(),
        created_run_ids = v_created_runs
    WHERE event_id = p_event_id;

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_upload_trigger';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_UPLOAD_EVENT_CONSUMED',
    p_subject_type => 'TRIGGER_EVENT'::audit.subject_type_enum,
    p_subject_id => p_event_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_evt.organization_id, p_business_id => v_evt.business_id,
    p_after_state => jsonb_build_object(
      'event_id', p_event_id,
      'statement_upload_id', v_evt.statement_upload_id,
      'created_run_ids', to_jsonb(v_created_runs),
      'workflow_types_enabled', to_jsonb(v_types_enabled),
      'out_disabled', v_out_disabled,
      'in_disabled', v_in_disabled),
    p_reason => format('consumed event %s: created %s run(s) [%s]',
                       p_event_id, coalesce(array_length(v_created_runs, 1), 0),
                       array_to_string(v_types_enabled, ',')));
  RETURN jsonb_build_object('ok', true,
    'event_id', p_event_id,
    'created_run_ids', to_jsonb(v_created_runs),
    'workflow_types_enabled', to_jsonb(v_types_enabled),
    'audit_event_id', v_audit_row.id);
END;
$function$;
