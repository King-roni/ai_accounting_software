-- ============================================================================
-- Block 13 Phase 07 — IN_MONTHLY Workflow Type Definition + Per-Business IN Config
-- ============================================================================

CREATE TABLE public.in_workflow_business_config (
  id                              uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  organization_id                 uuid NOT NULL,
  business_id                     uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE RESTRICT,
  auto_start_on_statement_upload  boolean NOT NULL DEFAULT true,
  created_at                      timestamptz NOT NULL DEFAULT now(),
  updated_at                      timestamptz NOT NULL DEFAULT now(),
  last_updated_by                 uuid NULL,
  CONSTRAINT iwbc_business_uniq UNIQUE (business_id)
);

CREATE INDEX iwbc_business_idx ON public.in_workflow_business_config(business_id);

COMMENT ON TABLE public.in_workflow_business_config IS
  'Block 13 P07 — per-business IN_MONTHLY configuration. Parallel to out_workflow_business_config.';

ALTER TABLE public.in_workflow_business_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.in_workflow_business_config FORCE  ROW LEVEL SECURITY;

CREATE POLICY iwbc_select_tenant ON public.in_workflow_business_config
  FOR SELECT TO authenticated USING (business_id = ANY (public.current_user_businesses()));
CREATE POLICY iwbc_deny_insert ON public.in_workflow_business_config FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY iwbc_deny_update ON public.in_workflow_business_config FOR UPDATE TO authenticated USING (false);
CREATE POLICY iwbc_deny_delete ON public.in_workflow_business_config FOR DELETE TO authenticated USING (false);

INSERT INTO public.permission_matrix (role, surface, decision) VALUES
  ('OWNER',      'WORKFLOW_CONFIG_MANAGE', 'ALLOW'),
  ('ADMIN',      'WORKFLOW_CONFIG_MANAGE', 'ALLOW'),
  ('BOOKKEEPER', 'WORKFLOW_CONFIG_MANAGE', 'DENY'),
  ('ACCOUNTANT', 'WORKFLOW_CONFIG_MANAGE', 'DENY'),
  ('REVIEWER',   'WORKFLOW_CONFIG_MANAGE', 'DENY'),
  ('READ_ONLY',  'WORKFLOW_CONFIG_MANAGE', 'DENY')
ON CONFLICT (role, surface) DO NOTHING;

CREATE OR REPLACE FUNCTION public.load_in_workflow_config_for_business(
  p_organization_id uuid,
  p_business_id     uuid,
  p_actor_user_id   uuid DEFAULT NULL,
  p_actor_system    text DEFAULT 'business_provisioning',
  p_context         jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_id uuid; v_inserted boolean := false;
BEGIN
  INSERT INTO public.in_workflow_business_config (
    organization_id, business_id, auto_start_on_statement_upload, last_updated_by
  ) VALUES (
    p_organization_id, p_business_id, true, p_actor_user_id
  )
  ON CONFLICT (business_id) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NOT NULL THEN
    v_inserted := true;
    PERFORM audit.emit_audit(
      p_actor_kind:=CASE WHEN p_actor_user_id IS NOT NULL THEN 'USER' ELSE 'SYSTEM' END::audit.actor_kind_enum,
      p_action:='IN_WORKFLOW_CONFIG_INITIALIZED',
      p_subject_type:='BUSINESS'::audit.subject_type_enum, p_subject_id:=p_business_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state :=jsonb_build_object('config_id', v_id, 'auto_start_on_statement_upload', true),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;
  RETURN jsonb_build_object('decision','ALLOW','inserted', v_inserted);
END;
$function$;

CREATE OR REPLACE FUNCTION public.in_config_get(p_business_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_row jsonb;
BEGIN
  SELECT to_jsonb(c) INTO v_row FROM public.in_workflow_business_config c WHERE c.business_id = p_business_id;
  IF v_row IS NULL THEN RETURN jsonb_build_object('decision','DENY','reason_code','CONFIG_NOT_FOUND'); END IF;
  RETURN jsonb_build_object('decision','ALLOW','config', v_row);
END;
$function$;

CREATE OR REPLACE FUNCTION public.in_config_update(
  p_actor_user_id uuid, p_business_id uuid,
  p_auto_start_on_statement_upload boolean DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_cfg public.in_workflow_business_config%ROWTYPE; v_decision jsonb; v_diff jsonb := '{}'::jsonb;
BEGIN
  SELECT * INTO v_cfg FROM public.in_workflow_business_config WHERE business_id = p_business_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','CONFIG_NOT_FOUND'); END IF;
  v_decision := public.can_perform(p_actor_user_id,'WORKFLOW_CONFIG_MANAGE','UPDATE',
    jsonb_build_object('business_id', p_business_id), p_business_id, v_cfg.organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision', 'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;
  IF p_auto_start_on_statement_upload IS NOT NULL
     AND p_auto_start_on_statement_upload IS DISTINCT FROM v_cfg.auto_start_on_statement_upload THEN
    v_diff := v_diff || jsonb_build_object('auto_start_on_statement_upload',
      jsonb_build_object('old', v_cfg.auto_start_on_statement_upload, 'new', p_auto_start_on_statement_upload));
  END IF;
  IF v_diff <> '{}'::jsonb THEN
    UPDATE public.in_workflow_business_config SET
      auto_start_on_statement_upload = COALESCE(p_auto_start_on_statement_upload, auto_start_on_statement_upload),
      updated_at = now(), last_updated_by = p_actor_user_id
     WHERE business_id = p_business_id;
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='IN_WORKFLOW_CONFIG_UPDATED',
      p_subject_type:='BUSINESS'::audit.subject_type_enum, p_subject_id:=p_business_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=v_cfg.organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL, p_after_state:=jsonb_build_object('diff', v_diff),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;
  RETURN jsonb_build_object('decision','ALLOW','business_id', p_business_id, 'diff', v_diff);
END;
$function$;

CREATE OR REPLACE FUNCTION public.register_in_monthly_type(
  p_actor_system text DEFAULT 'engine_bootstrap',
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_count int; v_already_emitted boolean;
BEGIN
  SELECT count(*) INTO v_count FROM public.workflow_phase_definitions WHERE workflow_type='IN_MONTHLY';
  IF v_count <> 8 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','PHASE_SHAPE_INVALID','expected', 8, 'actual', v_count);
  END IF;
  SELECT EXISTS (SELECT 1 FROM audit.audit_events WHERE action='IN_WORKFLOW_TYPE_REGISTERED' LIMIT 1) INTO v_already_emitted;
  IF v_already_emitted THEN
    RETURN jsonb_build_object('decision','ALLOW','idempotent', true, 'phase_count', v_count);
  END IF;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_WORKFLOW_TYPE_REGISTERED',
    p_subject_type:='WORKFLOW_CONFIG'::audit.subject_type_enum, p_subject_id:=gen_uuid_v7(),
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
    p_organization_id:=NULL, p_business_id:=NULL,
    p_before_state:=NULL, p_after_state:=jsonb_build_object('workflow_type','IN_MONTHLY','phase_count', v_count),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW','idempotent', false, 'phase_count', v_count);
END;
$function$;

CREATE OR REPLACE FUNCTION public._in_workflow_validate_period(
  p_business_id uuid, p_period_start date, p_period_end date
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_finalized_exists boolean;
BEGIN
  IF p_period_start IS NULL OR p_period_end IS NULL OR p_period_start > p_period_end THEN
    RETURN jsonb_build_object('ok', false, 'reason_code','INVALID_PERIOD');
  END IF;
  IF p_period_end > CURRENT_DATE THEN RETURN jsonb_build_object('ok', false, 'reason_code','PERIOD_IN_FUTURE'); END IF;
  IF p_period_end < (CURRENT_DATE - INTERVAL '6 years') THEN
    RETURN jsonb_build_object('ok', false, 'reason_code','RETENTION_EXPIRED'); END IF;
  SELECT EXISTS (
    SELECT 1 FROM public.workflow_runs
     WHERE business_id = p_business_id AND workflow_type = 'IN_MONTHLY' AND status = 'FINALIZED'
       AND period_start = p_period_start::timestamptz AND period_end = p_period_end::timestamptz
  ) INTO v_finalized_exists;
  IF v_finalized_exists THEN RETURN jsonb_build_object('ok', false, 'reason_code','PERIOD_FINALIZED'); END IF;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.in_workflow_start_run_manually(
  p_actor_user_id      uuid,
  p_organization_id    uuid,
  p_business_id        uuid,
  p_period_start       date,
  p_period_end         date,
  p_manual_trigger_note text DEFAULT NULL,
  p_context            jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_decision    jsonb;
  v_period_check jsonb;
  v_run_id      uuid := gen_uuid_v7();
  v_active_exists boolean;
BEGIN
  v_decision := public.can_perform(p_actor_user_id,'WORKFLOW_TRIGGER','START_IN_MONTHLY',
    jsonb_build_object('business_id', p_business_id, 'period_start', p_period_start),
    p_business_id, p_organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision', 'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;

  v_period_check := public._in_workflow_validate_period(p_business_id, p_period_start, p_period_end);
  IF (v_period_check->>'ok')::boolean <> true THEN
    IF (v_period_check->>'reason_code') = 'PERIOD_FINALIZED' THEN
      PERFORM audit.emit_audit(
        p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='IN_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED',
        p_subject_type:='BUSINESS'::audit.subject_type_enum, p_subject_id:=p_business_id,
        p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
        p_organization_id:=p_organization_id, p_business_id:=p_business_id,
        p_before_state:=NULL,
        p_after_state :=jsonb_build_object('period_start', p_period_start, 'period_end', p_period_end),
        p_reason:='PERIOD_FINALIZED', p_request_context:=p_context);
    ELSIF (v_period_check->>'reason_code') = 'RETENTION_EXPIRED' THEN
      PERFORM audit.emit_audit(
        p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='IN_WORKFLOW_RUN_REJECTED_RETENTION_EXPIRED',
        p_subject_type:='BUSINESS'::audit.subject_type_enum, p_subject_id:=p_business_id,
        p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
        p_organization_id:=p_organization_id, p_business_id:=p_business_id,
        p_before_state:=NULL,
        p_after_state :=jsonb_build_object('period_start', p_period_start, 'period_end', p_period_end),
        p_reason:='RETENTION_EXPIRED', p_request_context:=p_context);
    END IF;
    RETURN jsonb_build_object('decision','DENY','reason_code', v_period_check->>'reason_code');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_business_id::text || p_period_start::text || p_period_end::text || 'IN_MONTHLY'));

  SELECT EXISTS (
    SELECT 1 FROM public.workflow_runs
     WHERE business_id = p_business_id
       AND workflow_type = 'IN_MONTHLY'
       AND period_start = p_period_start::timestamptz
       AND period_end   = p_period_end::timestamptz
       AND status IN ('CREATED','RUNNING','PAUSED','REVIEW_HOLD','AWAITING_APPROVAL','FINALIZING','COMPENSATING')
  ) INTO v_active_exists;
  IF v_active_exists THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='IN_WORKFLOW_RUN_ALREADY_ACTIVE_REJECTED',
      p_subject_type:='BUSINESS'::audit.subject_type_enum, p_subject_id:=p_business_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state :=jsonb_build_object('period_start', p_period_start, 'period_end', p_period_end),
      p_reason:='RUN_ALREADY_ACTIVE', p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','RUN_ALREADY_ACTIVE');
  END IF;

  INSERT INTO public.workflow_runs (
    id, organization_id, business_id, workflow_type,
    principal_snapshot, status, trigger_kind,
    period_start, period_end,
    triggered_by_user_id, manual_trigger_note
  ) VALUES (
    v_run_id, p_organization_id, p_business_id, 'IN_MONTHLY',
    jsonb_build_object('actor_user_id', p_actor_user_id::text, 'trigger_kind','MANUAL'),
    'CREATED', 'MANUAL',
    p_period_start::timestamptz, p_period_end::timestamptz,
    p_actor_user_id, p_manual_trigger_note
  );

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='IN_WORKFLOW_RUN_STARTED_MANUALLY',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=v_run_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state :=jsonb_build_object('run_id', v_run_id, 'workflow_type','IN_MONTHLY',
      'period_start', p_period_start, 'period_end', p_period_end, 'trigger_kind','MANUAL'),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','ALLOW','run_id', v_run_id, 'workflow_type','IN_MONTHLY');
END;
$function$;

CREATE OR REPLACE FUNCTION public.in_workflow_handle_statement_upload_event(
  p_event_id        text,
  p_organization_id uuid,
  p_business_id     uuid,
  p_period_start    date,
  p_period_end      date,
  p_actor_system    text DEFAULT 'in_workflow_event_handler',
  p_context         jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_already_processed boolean;
  v_cfg public.in_workflow_business_config%ROWTYPE;
  v_period_check jsonb;
  v_active_exists boolean;
  v_paired_run_id uuid;
  v_run_id        uuid := gen_uuid_v7();
BEGIN
  SELECT EXISTS (SELECT 1 FROM public.trigger_events_processed WHERE event_id = p_event_id)
    INTO v_already_processed;
  IF v_already_processed THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_WORKFLOW_EVENT_TRIGGER_DEDUPLICATED',
      p_subject_type:='BUSINESS'::audit.subject_type_enum, p_subject_id:=p_business_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state :=jsonb_build_object('event_id', p_event_id),
      p_reason:='DEDUPLICATED', p_request_context:=p_context);
    RETURN jsonb_build_object('decision','ALLOW','deduplicated', true, 'event_id', p_event_id);
  END IF;

  SELECT * INTO v_cfg FROM public.in_workflow_business_config WHERE business_id = p_business_id;
  IF NOT FOUND OR v_cfg.auto_start_on_statement_upload = false THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_WORKFLOW_AUTO_START_SUPPRESSED',
      p_subject_type:='BUSINESS'::audit.subject_type_enum, p_subject_id:=p_business_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state :=jsonb_build_object('event_id', p_event_id,
        'config_missing', NOT FOUND, 'auto_start_on_statement_upload', v_cfg.auto_start_on_statement_upload),
      p_reason:='AUTO_START_DISABLED', p_request_context:=p_context);
    INSERT INTO public.trigger_events_processed (
      event_id, event_kind, business_id, organization_id,
      period_start, period_end, created_run_ids, processed_at
    ) VALUES (
      p_event_id, 'STATEMENT_UPLOAD_COMPLETED', p_business_id, p_organization_id,
      p_period_start::timestamptz, p_period_end::timestamptz, ARRAY[]::uuid[], now()
    ) ON CONFLICT (event_id) DO NOTHING;
    RETURN jsonb_build_object('decision','ALLOW','suppressed', true);
  END IF;

  v_period_check := public._in_workflow_validate_period(p_business_id, p_period_start, p_period_end);
  IF (v_period_check->>'ok')::boolean <> true THEN
    IF (v_period_check->>'reason_code') = 'PERIOD_FINALIZED' THEN
      PERFORM audit.emit_audit(
        p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED',
        p_subject_type:='BUSINESS'::audit.subject_type_enum, p_subject_id:=p_business_id,
        p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
        p_organization_id:=p_organization_id, p_business_id:=p_business_id,
        p_before_state:=NULL,
        p_after_state :=jsonb_build_object('event_id', p_event_id, 'period_start', p_period_start, 'period_end', p_period_end),
        p_reason:='PERIOD_FINALIZED', p_request_context:=p_context);
    END IF;
    RETURN jsonb_build_object('decision','DENY','reason_code', v_period_check->>'reason_code');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_business_id::text || p_period_start::text || p_period_end::text || 'IN_MONTHLY'));

  SELECT EXISTS (
    SELECT 1 FROM public.workflow_runs
     WHERE business_id = p_business_id
       AND workflow_type = 'IN_MONTHLY'
       AND period_start = p_period_start::timestamptz
       AND period_end   = p_period_end::timestamptz
       AND status IN ('CREATED','RUNNING','PAUSED','REVIEW_HOLD','AWAITING_APPROVAL','FINALIZING','COMPENSATING')
  ) INTO v_active_exists;
  IF v_active_exists THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_WORKFLOW_RUN_ALREADY_ACTIVE_REJECTED',
      p_subject_type:='BUSINESS'::audit.subject_type_enum, p_subject_id:=p_business_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state :=jsonb_build_object('event_id', p_event_id, 'period_start', p_period_start, 'period_end', p_period_end),
      p_reason:='RUN_ALREADY_ACTIVE', p_request_context:=p_context);
    INSERT INTO public.trigger_events_processed (
      event_id, event_kind, business_id, organization_id,
      period_start, period_end, created_run_ids, processed_at
    ) VALUES (
      p_event_id, 'STATEMENT_UPLOAD_COMPLETED', p_business_id, p_organization_id,
      p_period_start::timestamptz, p_period_end::timestamptz, ARRAY[]::uuid[], now()
    ) ON CONFLICT (event_id) DO NOTHING;
    RETURN jsonb_build_object('decision','DENY','reason_code','RUN_ALREADY_ACTIVE');
  END IF;

  SELECT id INTO v_paired_run_id
    FROM public.workflow_runs
   WHERE business_id = p_business_id
     AND workflow_type = 'OUT_MONTHLY'
     AND period_start = p_period_start::timestamptz
     AND period_end   = p_period_end::timestamptz
   ORDER BY created_at DESC LIMIT 1;

  INSERT INTO public.workflow_runs (
    id, organization_id, business_id, workflow_type,
    principal_snapshot, status, trigger_kind,
    period_start, period_end,
    trigger_event_id, paired_run_id
  ) VALUES (
    v_run_id, p_organization_id, p_business_id, 'IN_MONTHLY',
    jsonb_build_object('trigger_kind','EVENT','event_id', p_event_id),
    'CREATED', 'EVENT',
    p_period_start::timestamptz, p_period_end::timestamptz,
    p_event_id, v_paired_run_id
  );

  INSERT INTO public.trigger_events_processed (
    event_id, event_kind, business_id, organization_id,
    period_start, period_end, created_run_ids, processed_at
  ) VALUES (
    p_event_id, 'STATEMENT_UPLOAD_COMPLETED', p_business_id, p_organization_id,
    p_period_start::timestamptz, p_period_end::timestamptz, ARRAY[v_run_id], now()
  );

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_WORKFLOW_RUN_STARTED_BY_EVENT',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=v_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state :=jsonb_build_object('run_id', v_run_id, 'workflow_type','IN_MONTHLY',
      'period_start', p_period_start, 'period_end', p_period_end,
      'event_id', p_event_id, 'paired_run_id', v_paired_run_id),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','ALLOW','run_id', v_run_id, 'paired_run_id', v_paired_run_id, 'event_id', p_event_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.in_workflow_skip_phase_by_config(
  p_run_id      uuid,
  p_phase_name  text,
  p_reason_code text,
  p_actor_system text DEFAULT 'in_workflow_engine',
  p_context     jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_run public.workflow_runs%ROWTYPE;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','RUN_NOT_FOUND'); END IF;
  IF v_run.workflow_type <> 'IN_MONTHLY' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','NOT_IN_MONTHLY');
  END IF;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_WORKFLOW_PHASE_SKIPPED_BY_CONFIG',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
    p_organization_id:=v_run.organization_id, p_business_id:=v_run.business_id,
    p_before_state:=NULL,
    p_after_state :=jsonb_build_object('phase_name', p_phase_name, 'reason_code', p_reason_code),
    p_reason:=p_reason_code, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW','run_id', p_run_id, 'phase_name', p_phase_name);
END;
$function$;
