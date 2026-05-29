-- B03·P10 Concurrency Control
-- =============================================================================
-- One active monthly per (business, workflow_type); adjustments allowed
-- alongside monthlies; one adjustment per parent_run_id. Advisory locks
-- serialise concurrent trigger validation. Shared-phase coordination
-- primitives let OUT_MONTHLY + IN_MONTHLY share work.
--
-- Four new audit actions (text):
--   WORKFLOW_RUN_REJECTED_DUPLICATE, WORKFLOW_RUN_REJECTED_DUPLICATE_ADJUSTMENT,
--   WORKFLOW_SHARED_PHASE_COORDINATED, WORKFLOW_SHARED_PHASE_DEDUP_HIT
-- =============================================================================

ALTER TABLE public.workflow_phase_definitions
  ADD COLUMN is_shared_with_pair boolean NOT NULL DEFAULT false;

-- Mark CLASSIFY as shared per spec (only phase confirmed in both monthlies)
UPDATE public.workflow_phase_definitions
   SET is_shared_with_pair = true
 WHERE phase_name = 'CLASSIFY' AND workflow_type IN ('OUT_MONTHLY','IN_MONTHLY');

-- ---- _acquire_trigger_lock --------------------------------------------------
-- Note: pg_advisory_xact_lock has (bigint) and (int,int) variants — no (bigint,bigint).
-- Using single-key variant with concatenated-string hash.
CREATE OR REPLACE FUNCTION public._acquire_trigger_lock(
  p_business_id    uuid,
  p_workflow_type  public.workflow_type_enum
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE v_k bigint;
BEGIN
  v_k := hashtextextended(p_business_id::text || '|' || p_workflow_type::text, 0);
  PERFORM pg_advisory_xact_lock(v_k);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public._acquire_trigger_lock(uuid, public.workflow_type_enum) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._acquire_trigger_lock(uuid, public.workflow_type_enum) TO service_role;

-- ---- get_coordinated_pair ---------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_coordinated_pair(p_run_id uuid)
RETURNS SETOF public.workflow_runs
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  SELECT wr2.*
    FROM public.workflow_runs wr1
    JOIN public.workflow_runs wr2 ON wr2.trigger_event_id = wr1.trigger_event_id
                                  AND wr2.id <> wr1.id
   WHERE wr1.id = p_run_id
     AND wr1.trigger_event_id IS NOT NULL;
$fn$;
REVOKE EXECUTE ON FUNCTION public.get_coordinated_pair(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_coordinated_pair(uuid) TO authenticated, service_role;

-- ---- check_shared_phase_can_dedup ------------------------------------------
CREATE OR REPLACE FUNCTION public.check_shared_phase_can_dedup(
  p_run_id uuid,
  p_phase_name text
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_run          public.workflow_runs;
  v_is_shared    boolean;
  v_sibling      public.workflow_runs;
  v_sibling_ps   public.workflow_phase_states;
  v_invocations  jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('is_shared', false, 'sibling_run_id', NULL, 'sibling_phase_state_id', NULL,
                              'sibling_phase_completed', false, 'sibling_tool_invocations', '[]'::jsonb);
  END IF;

  SELECT COALESCE(wpd.is_shared_with_pair, false) INTO v_is_shared
    FROM public.workflow_phase_definitions wpd
   WHERE wpd.workflow_type = v_run.workflow_type AND wpd.phase_name = p_phase_name;

  IF NOT COALESCE(v_is_shared, false) THEN
    RETURN jsonb_build_object('is_shared', false, 'sibling_run_id', NULL, 'sibling_phase_state_id', NULL,
                              'sibling_phase_completed', false, 'sibling_tool_invocations', '[]'::jsonb);
  END IF;

  IF v_run.trigger_event_id IS NULL THEN
    RETURN jsonb_build_object('is_shared', true, 'sibling_run_id', NULL, 'sibling_phase_state_id', NULL,
                              'sibling_phase_completed', false, 'sibling_tool_invocations', '[]'::jsonb);
  END IF;

  SELECT * INTO v_sibling FROM public.workflow_runs
   WHERE trigger_event_id = v_run.trigger_event_id AND id <> v_run.id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('is_shared', true, 'sibling_run_id', NULL, 'sibling_phase_state_id', NULL,
                              'sibling_phase_completed', false, 'sibling_tool_invocations', '[]'::jsonb);
  END IF;

  SELECT * INTO v_sibling_ps FROM public.workflow_phase_states
   WHERE workflow_run_id = v_sibling.id AND phase_name = p_phase_name
   ORDER BY phase_order DESC LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('is_shared', true, 'sibling_run_id', v_sibling.id, 'sibling_phase_state_id', NULL,
                              'sibling_phase_completed', false, 'sibling_tool_invocations', '[]'::jsonb);
  END IF;

  IF v_sibling_ps.status = 'COMPLETED' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', ti.id, 'tool_name', ti.tool_name, 'dedup_key', ti.dedup_key,
      'output_hash', ti.output_hash, 'status', ti.status::text, 'attempt_number', ti.attempt_number
    )), '[]'::jsonb)
    INTO v_invocations
      FROM public.tool_invocations ti
     WHERE ti.phase_state_id = v_sibling_ps.id AND ti.status = 'SUCCESS';
  END IF;

  RETURN jsonb_build_object(
    'is_shared',                true,
    'sibling_run_id',           v_sibling.id,
    'sibling_phase_state_id',   v_sibling_ps.id,
    'sibling_phase_completed',  v_sibling_ps.status = 'COMPLETED',
    'sibling_tool_invocations', v_invocations
  );
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.check_shared_phase_can_dedup(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.check_shared_phase_can_dedup(uuid, text) TO authenticated, service_role;

-- ---- record_shared_phase_coordination --------------------------------------
CREATE OR REPLACE FUNCTION public.record_shared_phase_coordination(
  p_run_id         uuid,
  p_sibling_run_id uuid,
  p_phase_name     text,
  p_actor_user_id  uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_run   public.workflow_runs;
  v_audit audit.audit_events;
BEGIN
  IF p_run_id IS NULL OR p_sibling_run_id IS NULL OR p_phase_name IS NULL THEN
    RAISE EXCEPTION 'record_shared_phase_coordination: all params required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'record_shared_phase_coordination: run % not found', p_run_id USING ERRCODE='P0002'; END IF;
  v_audit := audit.emit_audit(
    p_actor_kind     => CASE WHEN p_actor_user_id IS NULL THEN 'SYSTEM'::audit.actor_kind_enum ELSE 'USER'::audit.actor_kind_enum END,
    p_action         => 'WORKFLOW_SHARED_PHASE_COORDINATED',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run.id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_user_id  => p_actor_user_id,
    p_actor_system   => CASE WHEN p_actor_user_id IS NULL THEN 'workflow_engine' ELSE NULL END,
    p_reason         => format('shared phase %s coordinated between runs %s and %s', p_phase_name, p_run_id, p_sibling_run_id),
    p_after_state    => jsonb_build_object('run_id', p_run_id, 'sibling_run_id', p_sibling_run_id, 'phase_name', p_phase_name)
  );
  RETURN jsonb_build_object('audit_event_id', v_audit.event_id);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.record_shared_phase_coordination(uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.record_shared_phase_coordination(uuid, uuid, text, uuid) TO service_role;

-- ---- record_shared_phase_dedup_hit -----------------------------------------
CREATE OR REPLACE FUNCTION public.record_shared_phase_dedup_hit(
  p_run_id                  uuid,
  p_phase_name              text,
  p_sibling_phase_state_id  uuid,
  p_actor_user_id           uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_run   public.workflow_runs;
  v_audit audit.audit_events;
BEGIN
  IF p_run_id IS NULL OR p_phase_name IS NULL OR p_sibling_phase_state_id IS NULL THEN
    RAISE EXCEPTION 'record_shared_phase_dedup_hit: all params required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'record_shared_phase_dedup_hit: run % not found', p_run_id USING ERRCODE='P0002'; END IF;
  v_audit := audit.emit_audit(
    p_actor_kind     => CASE WHEN p_actor_user_id IS NULL THEN 'SYSTEM'::audit.actor_kind_enum ELSE 'USER'::audit.actor_kind_enum END,
    p_action         => 'WORKFLOW_SHARED_PHASE_DEDUP_HIT',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run.id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_user_id  => p_actor_user_id,
    p_actor_system   => CASE WHEN p_actor_user_id IS NULL THEN 'workflow_engine' ELSE NULL END,
    p_reason         => format('shared phase %s reused via sibling phase_state %s', p_phase_name, p_sibling_phase_state_id),
    p_after_state    => jsonb_build_object('run_id', p_run_id, 'phase_name', p_phase_name, 'sibling_phase_state_id', p_sibling_phase_state_id)
  );
  RETURN jsonb_build_object('audit_event_id', v_audit.event_id);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.record_shared_phase_dedup_hit(uuid, text, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.record_shared_phase_dedup_hit(uuid, text, uuid, uuid) TO service_role;

-- ---- Refined trigger_run_manual (adds advisory lock + adjustment dup rule) -
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
  v_is_adjustment boolean;
  v_specific_audit text;
BEGIN
  IF p_actor_user_id IS NULL OR p_business_id IS NULL OR p_workflow_type IS NULL
     OR p_period_start IS NULL OR p_period_end IS NULL OR p_principal_snapshot IS NULL THEN
    RAISE EXCEPTION 'trigger_run_manual: required params missing' USING ERRCODE='22000';
  END IF;

  v_is_adjustment := p_workflow_type IN ('OUT_ADJUSTMENT'::public.workflow_type_enum, 'IN_ADJUSTMENT'::public.workflow_type_enum);

  PERFORM public._acquire_trigger_lock(p_business_id, p_workflow_type);

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

  IF v_reject_code IS NULL AND v_is_adjustment AND p_parent_run_id IS NULL THEN
    v_reject_code := 'PARENT_REQUIRED';
    v_reject_msg  := format('adjustment workflow %s requires parent_run_id', p_workflow_type);
  END IF;

  IF v_reject_code IS NULL THEN
    IF v_is_adjustment THEN
      SELECT count(*) INTO v_active
        FROM public.workflow_runs
       WHERE business_id = p_business_id
         AND workflow_type = p_workflow_type
         AND parent_run_id IS NOT DISTINCT FROM p_parent_run_id
         AND status NOT IN ('FINALIZED'::public.workflow_run_status_enum,
                            'ABORTED'::public.workflow_run_status_enum,
                            'FAILED'::public.workflow_run_status_enum,
                            'CANCELLED'::public.workflow_run_status_enum);
      IF v_active > 0 THEN
        v_reject_code := 'DUPLICATE_ADJUSTMENT';
        v_reject_msg  := format('active adjustment exists for business %s + type %s + parent %s',
                                p_business_id, p_workflow_type, p_parent_run_id);
        v_specific_audit := 'WORKFLOW_RUN_REJECTED_DUPLICATE_ADJUSTMENT';
      END IF;
    ELSE
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
        v_specific_audit := 'WORKFLOW_RUN_REJECTED_DUPLICATE';
      END IF;
    END IF;
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
        'rejection_code', v_reject_code, 'business_id', p_business_id,
        'workflow_type', p_workflow_type::text, 'trigger_kind', 'MANUAL',
        'parent_run_id', p_parent_run_id, 'context', p_context
      )
    );
    IF v_specific_audit IS NOT NULL THEN
      PERFORM audit.emit_audit(
        p_actor_kind     => 'USER'::audit.actor_kind_enum,
        p_action         => v_specific_audit,
        p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
        p_subject_id     => NULL,
        p_business_id    => p_business_id,
        p_organization_id=> v_biz.organization_id,
        p_actor_user_id  => p_actor_user_id,
        p_reason         => v_reject_msg,
        p_after_state    => jsonb_build_object(
          'rejection_code', v_reject_code, 'business_id', p_business_id,
          'workflow_type', p_workflow_type::text, 'parent_run_id', p_parent_run_id
        )
      );
    END IF;
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
      'run_id', v_run_id, 'workflow_type', p_workflow_type::text,
      'business_id', p_business_id, 'period_start', p_period_start,
      'period_end', p_period_end, 'parent_run_id', p_parent_run_id, 'trigger_kind', 'MANUAL'
    )
  );

  RETURN jsonb_build_object('ok', true, 'run_id', v_run_id, 'trigger_kind', 'MANUAL');
END;
$fn$;

-- ---- Refined trigger_run_from_event (adds advisory lock + COORDINATED audit)
CREATE OR REPLACE FUNCTION public.trigger_run_from_event(
  p_event_id        text,
  p_event_kind      text,
  p_business_id     uuid,
  p_organization_id uuid,
  p_period_start    timestamptz,
  p_period_end      timestamptz,
  p_payload         jsonb DEFAULT '{}'::jsonb
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
  v_active_out  integer;
  v_active_in   integer;
BEGIN
  IF p_event_id IS NULL OR p_event_kind IS NULL OR p_business_id IS NULL OR p_organization_id IS NULL
     OR p_period_start IS NULL OR p_period_end IS NULL THEN
    RAISE EXCEPTION 'trigger_run_from_event: required params missing' USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_existing FROM public.trigger_events_processed WHERE event_id = p_event_id;
  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true,
                              'created_run_ids', to_jsonb(v_existing.created_run_ids), 'event_id', p_event_id);
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
        'rejection_code', v_reject_code, 'event_id', p_event_id, 'event_kind', p_event_kind,
        'business_id', p_business_id, 'payload', p_payload
      )
    );
    RETURN jsonb_build_object('ok', false, 'reason', v_reject_code, 'message', v_reject_msg);
  END IF;

  PERFORM public._acquire_trigger_lock(p_business_id, 'OUT_MONTHLY'::public.workflow_type_enum);
  PERFORM public._acquire_trigger_lock(p_business_id, 'IN_MONTHLY'::public.workflow_type_enum);

  SELECT count(*) INTO v_active_out FROM public.workflow_runs
   WHERE business_id = p_business_id AND workflow_type = 'OUT_MONTHLY'
     AND status NOT IN ('FINALIZED','ABORTED','FAILED','CANCELLED');
  SELECT count(*) INTO v_active_in FROM public.workflow_runs
   WHERE business_id = p_business_id AND workflow_type = 'IN_MONTHLY'
     AND status NOT IN ('FINALIZED','ABORTED','FAILED','CANCELLED');

  IF v_active_out > 0 OR v_active_in > 0 THEN
    v_reject_code := 'DUPLICATE_ACTIVE';
    v_reject_msg  := format('active monthly run exists for business %s (OUT=%s, IN=%s)',
                            p_business_id, v_active_out, v_active_in);
    PERFORM audit.emit_audit(
      p_actor_kind     => 'SYSTEM'::audit.actor_kind_enum,
      p_action         => 'WORKFLOW_RUN_REJECTED_DUPLICATE',
      p_subject_type   => 'TRIGGER_EVENT'::audit.subject_type_enum,
      p_business_id    => p_business_id,
      p_organization_id=> p_organization_id,
      p_actor_system   => 'event_pipeline',
      p_reason         => v_reject_msg,
      p_after_state    => jsonb_build_object(
        'rejection_code', v_reject_code, 'event_id', p_event_id, 'event_kind', p_event_kind,
        'active_out', v_active_out, 'active_in', v_active_in
      )
    );
    RETURN jsonb_build_object('ok', false, 'reason', v_reject_code, 'message', v_reject_msg);
  END IF;

  v_principal := jsonb_build_object('kind','SYSTEM','system','event_pipeline',
                                    'event_id', p_event_id, 'event_kind', p_event_kind);

  INSERT INTO public.workflow_runs (organization_id, business_id, principal_snapshot, workflow_type,
                                    period_start, period_end, trigger_kind, trigger_event_id)
  VALUES (p_organization_id, p_business_id, v_principal, 'OUT_MONTHLY'::public.workflow_type_enum,
          p_period_start, p_period_end, 'EVENT'::public.trigger_kind_enum, p_event_id)
  RETURNING id INTO v_out_run_id;

  INSERT INTO public.workflow_runs (organization_id, business_id, principal_snapshot, workflow_type,
                                    period_start, period_end, trigger_kind, trigger_event_id)
  VALUES (p_organization_id, p_business_id, v_principal, 'IN_MONTHLY'::public.workflow_type_enum,
          p_period_start, p_period_end, 'EVENT'::public.trigger_kind_enum, p_event_id)
  RETURNING id INTO v_in_run_id;

  v_run_ids := ARRAY[v_out_run_id, v_in_run_id];

  INSERT INTO public.trigger_events_processed (event_id, event_kind, business_id, organization_id, period_start, period_end, created_run_ids, payload)
  VALUES (p_event_id, p_event_kind, p_business_id, p_organization_id, p_period_start, p_period_end, v_run_ids, p_payload);

  PERFORM audit.emit_audit(
    p_actor_kind => 'SYSTEM'::audit.actor_kind_enum, p_action => 'WORKFLOW_RUN_TRIGGERED_BY_EVENT',
    p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id => v_out_run_id,
    p_business_id => p_business_id, p_organization_id => p_organization_id, p_actor_system => 'event_pipeline',
    p_reason => format('event-triggered OUT_MONTHLY run from %s (%s)', p_event_kind, p_event_id),
    p_after_state => jsonb_build_object(
      'run_id', v_out_run_id, 'workflow_type', 'OUT_MONTHLY',
      'event_id', p_event_id, 'event_kind', p_event_kind, 'trigger_kind', 'EVENT'
    )
  );
  PERFORM audit.emit_audit(
    p_actor_kind => 'SYSTEM'::audit.actor_kind_enum, p_action => 'WORKFLOW_RUN_TRIGGERED_BY_EVENT',
    p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id => v_in_run_id,
    p_business_id => p_business_id, p_organization_id => p_organization_id, p_actor_system => 'event_pipeline',
    p_reason => format('event-triggered IN_MONTHLY run from %s (%s)', p_event_kind, p_event_id),
    p_after_state => jsonb_build_object(
      'run_id', v_in_run_id, 'workflow_type', 'IN_MONTHLY',
      'event_id', p_event_id, 'event_kind', p_event_kind, 'trigger_kind', 'EVENT'
    )
  );

  PERFORM audit.emit_audit(
    p_actor_kind => 'SYSTEM'::audit.actor_kind_enum, p_action => 'WORKFLOW_SHARED_PHASE_COORDINATED',
    p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id => v_out_run_id,
    p_business_id => p_business_id, p_organization_id => p_organization_id, p_actor_system => 'event_pipeline',
    p_reason => format('coordinated pair created from event %s', p_event_id),
    p_after_state => jsonb_build_object(
      'run_id', v_out_run_id, 'sibling_run_id', v_in_run_id,
      'event_id', p_event_id, 'phase_name', NULL,
      'note', 'pair created; shared-phase coordination occurs at phase-entry time'
    )
  );

  RETURN jsonb_build_object('ok', true, 'idempotent_replay', false,
                            'created_run_ids', to_jsonb(v_run_ids), 'event_id', p_event_id);
END;
$fn$;

COMMENT ON FUNCTION public._acquire_trigger_lock(uuid, public.workflow_type_enum) IS
'B03·P10 transaction-scoped advisory lock keyed on (business_id, workflow_type). Lock released on commit/rollback. Reentrant within same xact. Internal helper, service_role only. Uses pg_advisory_xact_lock(bigint) single-key variant (no bigint/bigint variant exists in pg).';

COMMENT ON FUNCTION public.get_coordinated_pair(uuid) IS
'B03·P10 returns sibling run(s) sharing the same trigger_event_id. Empty for manual triggers.';

COMMENT ON FUNCTION public.check_shared_phase_can_dedup(uuid, text) IS
'B03·P10 read API for shared-phase coordination. Returns {is_shared, sibling_run_id, sibling_phase_state_id, sibling_phase_completed, sibling_tool_invocations}. Engine uses this when entering a phase: if sibling completed it, loop sibling_tool_invocations and call P07 record_tool_dedup_hit per row instead of running the tool.';

COMMENT ON COLUMN public.workflow_phase_definitions.is_shared_with_pair IS
'B03·P10 flag: phase is shared between OUT_MONTHLY and IN_MONTHLY when both runs originate from the same trigger_event_id. Engine dedups via check_shared_phase_can_dedup.';
