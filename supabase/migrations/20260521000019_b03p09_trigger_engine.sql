-- B03·P09 Trigger Engine
-- =============================================================================
-- Two trigger chokepoints: manual (user-initiated) and event-based (idempotent).
-- HTTP endpoint + event subscriber live code-side; DB ships the chokepoint RPCs.
--
-- Three new audit actions (text, no enum work):
--   WORKFLOW_RUN_TRIGGERED_MANUAL, WORKFLOW_RUN_TRIGGERED_BY_EVENT,
--   WORKFLOW_RUN_TRIGGER_REJECTED
-- =============================================================================

CREATE TYPE public.trigger_kind_enum AS ENUM ('MANUAL','EVENT');

ALTER TABLE public.workflow_runs
  ADD COLUMN trigger_kind     public.trigger_kind_enum NOT NULL DEFAULT 'MANUAL',
  ADD COLUMN trigger_event_id text,
  ADD CONSTRAINT wr_trigger_kind_event_id_coupling CHECK (
    (trigger_kind = 'EVENT' AND trigger_event_id IS NOT NULL)
    OR (trigger_kind = 'MANUAL' AND trigger_event_id IS NULL)
  );

CREATE INDEX idx_wr_trigger_event_id ON public.workflow_runs (trigger_event_id) WHERE trigger_event_id IS NOT NULL;
CREATE INDEX idx_wr_active_business_type ON public.workflow_runs (business_id, workflow_type)
  WHERE status NOT IN ('FINALIZED','ABORTED','FAILED','CANCELLED');

CREATE TABLE public.trigger_events_processed (
  event_id         text PRIMARY KEY,
  event_kind       text NOT NULL,
  business_id      uuid NOT NULL REFERENCES public.business_entities(id),
  organization_id  uuid NOT NULL REFERENCES public.organizations(id),
  period_start     timestamptz NOT NULL,
  period_end       timestamptz NOT NULL,
  created_run_ids  uuid[] NOT NULL,
  payload          jsonb NOT NULL DEFAULT '{}'::jsonb,
  processed_at     timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_tep_business ON public.trigger_events_processed (business_id, event_kind);
CREATE INDEX idx_tep_kind     ON public.trigger_events_processed (event_kind);

ALTER TABLE public.trigger_events_processed ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trigger_events_processed FORCE  ROW LEVEL SECURITY;
CREATE POLICY tep_select_all ON public.trigger_events_processed AS PERMISSIVE  FOR SELECT TO authenticated USING (true);
CREATE POLICY tep_no_insert  ON public.trigger_events_processed AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY tep_no_update  ON public.trigger_events_processed AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY tep_no_delete  ON public.trigger_events_processed AS RESTRICTIVE FOR DELETE TO authenticated USING (false);
GRANT SELECT ON public.trigger_events_processed TO authenticated, service_role;

-- ---- trigger_run_manual ----------------------------------------------------
CREATE OR REPLACE FUNCTION public.trigger_run_manual(
  p_actor_user_id      uuid,
  p_business_id        uuid,
  p_workflow_type      public.workflow_type_enum,
  p_period_start       timestamptz,
  p_period_end         timestamptz,
  p_principal_snapshot jsonb,
  p_parent_run_id      uuid DEFAULT NULL,
  p_context            jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_biz       public.business_entities;
  v_def_exists boolean;
  v_perm      jsonb;
  v_perm_dec  text;
  v_active    integer;
  v_run_id    uuid;
  v_reject_code text;
  v_reject_msg  text;
BEGIN
  IF p_actor_user_id IS NULL OR p_business_id IS NULL OR p_workflow_type IS NULL
     OR p_period_start IS NULL OR p_period_end IS NULL OR p_principal_snapshot IS NULL THEN
    RAISE EXCEPTION 'trigger_run_manual: required params missing' USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_biz FROM public.business_entities WHERE id = p_business_id;
  IF NOT FOUND THEN
    v_reject_code := 'BUSINESS_NOT_FOUND';
    v_reject_msg  := format('business %s not found', p_business_id);
  END IF;

  IF v_reject_code IS NULL THEN
    SELECT EXISTS(SELECT 1 FROM public.workflow_type_definitions WHERE workflow_type = p_workflow_type) INTO v_def_exists;
    IF NOT v_def_exists THEN
      v_reject_code := 'UNKNOWN_TYPE';
      v_reject_msg  := format('workflow_type %s not registered', p_workflow_type);
    END IF;
  END IF;

  IF v_reject_code IS NULL THEN
    v_perm := public.can_perform(
      p_actor_user_id   => p_actor_user_id,
      p_surface         => 'workflow_run',
      p_action          => 'execute',
      p_resource        => jsonb_build_object('workflow_type', p_workflow_type, 'business_id', p_business_id),
      p_business_id     => p_business_id,
      p_organization_id => v_biz.organization_id
    );
    v_perm_dec := v_perm->>'decision';
    IF v_perm_dec = 'DENY' THEN
      v_reject_code := 'PERMISSION_DENIED';
      v_reject_msg  := format('actor lacks permission workflow_run:execute (reason=%s)', v_perm->>'reason_code');
    ELSIF v_perm_dec NOT IN ('ALLOW','STEP_UP') THEN
      v_reject_code := 'PERMISSION_DENIED';
      v_reject_msg  := format('unexpected can_perform decision: %s', v_perm_dec);
    END IF;
  END IF;

  IF v_reject_code IS NULL THEN
    SELECT count(*) INTO v_active
      FROM public.workflow_runs
     WHERE business_id = p_business_id
       AND workflow_type = p_workflow_type
       AND status NOT IN ('FINALIZED'::public.workflow_run_status_enum,
                          'ABORTED'::public.workflow_run_status_enum,
                          'FAILED'::public.workflow_run_status_enum,
                          'CANCELLED'::public.workflow_run_status_enum);
    IF v_active > 0 THEN
      v_reject_code := 'DUPLICATE_ACTIVE';
      v_reject_msg  := format('active run exists for business %s + type %s', p_business_id, p_workflow_type);
    END IF;
  END IF;

  IF v_reject_code IS NULL
     AND p_workflow_type IN ('OUT_ADJUSTMENT'::public.workflow_type_enum, 'IN_ADJUSTMENT'::public.workflow_type_enum)
     AND p_parent_run_id IS NULL THEN
    v_reject_code := 'PARENT_REQUIRED';
    v_reject_msg  := format('adjustment workflow %s requires parent_run_id', p_workflow_type);
  END IF;

  IF v_reject_code IS NOT NULL THEN
    PERFORM audit.emit_audit(
      p_actor_kind     => 'USER'::audit.actor_kind_enum,
      p_action         => 'WORKFLOW_RUN_TRIGGER_REJECTED',
      p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
      p_subject_id     => NULL,
      p_business_id    => p_business_id,
      p_organization_id=> v_biz.organization_id,
      p_actor_user_id  => p_actor_user_id,
      p_reason         => v_reject_msg,
      p_after_state    => jsonb_build_object(
        'rejection_code', v_reject_code,
        'business_id',    p_business_id,
        'workflow_type',  p_workflow_type::text,
        'trigger_kind',   'MANUAL',
        'context',        p_context
      )
    );
    RETURN jsonb_build_object('ok', false, 'reason', v_reject_code, 'message', v_reject_msg);
  END IF;

  INSERT INTO public.workflow_runs (
    organization_id, business_id, principal_snapshot, workflow_type,
    period_start, period_end, started_by, parent_run_id,
    trigger_kind, trigger_event_id
  ) VALUES (
    v_biz.organization_id, p_business_id, p_principal_snapshot, p_workflow_type,
    p_period_start, p_period_end, p_actor_user_id, p_parent_run_id,
    'MANUAL'::public.trigger_kind_enum, NULL
  )
  RETURNING id INTO v_run_id;

  PERFORM audit.emit_audit(
    p_actor_kind     => 'USER'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_RUN_TRIGGERED_MANUAL',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run_id,
    p_business_id    => p_business_id,
    p_organization_id=> v_biz.organization_id,
    p_actor_user_id  => p_actor_user_id,
    p_reason         => format('manual trigger of %s for business %s', p_workflow_type, p_business_id),
    p_after_state    => jsonb_build_object(
      'run_id',         v_run_id,
      'workflow_type',  p_workflow_type::text,
      'business_id',    p_business_id,
      'period_start',   p_period_start,
      'period_end',     p_period_end,
      'parent_run_id',  p_parent_run_id,
      'trigger_kind',   'MANUAL'
    )
  );

  RETURN jsonb_build_object('ok', true, 'run_id', v_run_id, 'trigger_kind', 'MANUAL');
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.trigger_run_manual(uuid, uuid, public.workflow_type_enum, timestamptz, timestamptz, jsonb, uuid, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.trigger_run_manual(uuid, uuid, public.workflow_type_enum, timestamptz, timestamptz, jsonb, uuid, jsonb) TO authenticated, service_role;

-- ---- trigger_run_from_event ------------------------------------------------
CREATE OR REPLACE FUNCTION public.trigger_run_from_event(
  p_event_id       text,
  p_event_kind     text,
  p_business_id    uuid,
  p_organization_id uuid,
  p_period_start   timestamptz,
  p_period_end     timestamptz,
  p_payload        jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_existing    public.trigger_events_processed;
  v_out_run_id  uuid;
  v_in_run_id   uuid;
  v_run_ids     uuid[];
  v_principal   jsonb;
  v_reject_code text;
  v_reject_msg  text;
BEGIN
  IF p_event_id IS NULL OR p_event_kind IS NULL OR p_business_id IS NULL OR p_organization_id IS NULL
     OR p_period_start IS NULL OR p_period_end IS NULL THEN
    RAISE EXCEPTION 'trigger_run_from_event: required params missing' USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_existing FROM public.trigger_events_processed WHERE event_id = p_event_id;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'ok', true, 'idempotent_replay', true,
      'created_run_ids', to_jsonb(v_existing.created_run_ids),
      'event_id', p_event_id
    );
  END IF;

  IF p_event_kind <> 'STATEMENT_UPLOAD_COMPLETED' THEN
    v_reject_code := 'UNSUPPORTED_EVENT_KIND';
    v_reject_msg  := format('event_kind %s not supported by trigger engine (MVP supports STATEMENT_UPLOAD_COMPLETED only)', p_event_kind);
    PERFORM audit.emit_audit(
      p_actor_kind     => 'SYSTEM'::audit.actor_kind_enum,
      p_action         => 'WORKFLOW_RUN_TRIGGER_REJECTED',
      p_subject_type   => 'TRIGGER_EVENT'::audit.subject_type_enum,
      p_business_id    => p_business_id,
      p_organization_id=> p_organization_id,
      p_actor_system   => 'event_pipeline',
      p_reason         => v_reject_msg,
      p_after_state    => jsonb_build_object(
        'rejection_code', v_reject_code,
        'event_id',       p_event_id,
        'event_kind',     p_event_kind,
        'business_id',    p_business_id,
        'payload',        p_payload
      )
    );
    RETURN jsonb_build_object('ok', false, 'reason', v_reject_code, 'message', v_reject_msg);
  END IF;

  v_principal := jsonb_build_object(
    'kind',       'SYSTEM',
    'system',     'event_pipeline',
    'event_id',   p_event_id,
    'event_kind', p_event_kind
  );

  INSERT INTO public.workflow_runs (
    organization_id, business_id, principal_snapshot, workflow_type,
    period_start, period_end, trigger_kind, trigger_event_id
  ) VALUES (
    p_organization_id, p_business_id, v_principal, 'OUT_MONTHLY'::public.workflow_type_enum,
    p_period_start, p_period_end, 'EVENT'::public.trigger_kind_enum, p_event_id
  ) RETURNING id INTO v_out_run_id;

  INSERT INTO public.workflow_runs (
    organization_id, business_id, principal_snapshot, workflow_type,
    period_start, period_end, trigger_kind, trigger_event_id
  ) VALUES (
    p_organization_id, p_business_id, v_principal, 'IN_MONTHLY'::public.workflow_type_enum,
    p_period_start, p_period_end, 'EVENT'::public.trigger_kind_enum, p_event_id
  ) RETURNING id INTO v_in_run_id;

  v_run_ids := ARRAY[v_out_run_id, v_in_run_id];

  INSERT INTO public.trigger_events_processed (event_id, event_kind, business_id, organization_id, period_start, period_end, created_run_ids, payload)
  VALUES (p_event_id, p_event_kind, p_business_id, p_organization_id, p_period_start, p_period_end, v_run_ids, p_payload);

  PERFORM audit.emit_audit(
    p_actor_kind     => 'SYSTEM'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_RUN_TRIGGERED_BY_EVENT',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_out_run_id,
    p_business_id    => p_business_id,
    p_organization_id=> p_organization_id,
    p_actor_system   => 'event_pipeline',
    p_reason         => format('event-triggered OUT_MONTHLY run from %s (%s)', p_event_kind, p_event_id),
    p_after_state    => jsonb_build_object(
      'run_id', v_out_run_id, 'workflow_type', 'OUT_MONTHLY',
      'event_id', p_event_id, 'event_kind', p_event_kind, 'trigger_kind', 'EVENT'
    )
  );
  PERFORM audit.emit_audit(
    p_actor_kind     => 'SYSTEM'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_RUN_TRIGGERED_BY_EVENT',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_in_run_id,
    p_business_id    => p_business_id,
    p_organization_id=> p_organization_id,
    p_actor_system   => 'event_pipeline',
    p_reason         => format('event-triggered IN_MONTHLY run from %s (%s)', p_event_kind, p_event_id),
    p_after_state    => jsonb_build_object(
      'run_id', v_in_run_id, 'workflow_type', 'IN_MONTHLY',
      'event_id', p_event_id, 'event_kind', p_event_kind, 'trigger_kind', 'EVENT'
    )
  );

  RETURN jsonb_build_object(
    'ok', true, 'idempotent_replay', false,
    'created_run_ids', to_jsonb(v_run_ids),
    'event_id', p_event_id
  );
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.trigger_run_from_event(text, text, uuid, uuid, timestamptz, timestamptz, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.trigger_run_from_event(text, text, uuid, uuid, timestamptz, timestamptz, jsonb) TO service_role;

COMMENT ON FUNCTION public.trigger_run_manual(uuid, uuid, public.workflow_type_enum, timestamptz, timestamptz, jsonb, uuid, jsonb) IS
'B03·P09 manual trigger chokepoint. Validates type registered, can_perform=ALLOW, no active run, parent_run_id required for adjustment types. Returns {ok, run_id?, reason?, message?}. Emits WORKFLOW_RUN_TRIGGERED_MANUAL on success, WORKFLOW_RUN_TRIGGER_REJECTED with code on failure.';

COMMENT ON FUNCTION public.trigger_run_from_event(text, text, uuid, uuid, timestamptz, timestamptz, jsonb) IS
'B03·P09 event trigger chokepoint. Idempotent by event_id (replay returns existing run_ids). STATEMENT_UPLOAD_COMPLETED creates one OUT_MONTHLY + one IN_MONTHLY run with trigger_kind=EVENT and SYSTEM principal_snapshot. Records processed_event row. Other event kinds rejected with UNSUPPORTED_EVENT_KIND.';

COMMENT ON COLUMN public.workflow_runs.trigger_kind IS 'B03·P09 trigger source. MANUAL = user-initiated via trigger_run_manual; EVENT = event-pipeline-initiated via trigger_run_from_event. Coupling CHECK requires trigger_event_id NOT NULL iff EVENT.';

COMMENT ON TABLE public.trigger_events_processed IS
'B03·P09 idempotency record for event-based triggers. Keyed by event_id. Replaying the same event_id returns existing created_run_ids without creating new runs.';
