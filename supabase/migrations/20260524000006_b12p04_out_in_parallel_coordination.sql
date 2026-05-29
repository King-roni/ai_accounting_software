-- B12·P04 — OUT/IN Parallel Coordination
-- =====================================================================
-- Cross-workflow coordination layer:
--   * Add reciprocal FK self-ref for workflow_runs.paired_run_id (col + idx
--     already added in B12·P01); guards that paired rows actually exist.
--   * create_paired_workflow_runs RPC — atomic creator that inserts the
--     OUT_MONTHLY + IN_MONTHLY pair from one Statement Upload, sets reciprocal
--     paired_run_id on both, emits OUT_WORKFLOW_PAIRED_RUN_LINKED once.
--   * _out_workflow_assert_no_active_run guard — blocks duplicate-start of the
--     same workflow_type for the same (business_id, period); OUT + IN for the
--     same period coexist by design (they don't collide).
--   * emit_shared_phase_dedup hook — mirrors Block 03's WORKFLOW_TOOL_DEDUP_HIT
--     at the cross-workflow level so dashboards can observe that the shared
--     INGESTION/CLASSIFICATION work happened once across the pair.
--   * get_combined_run_progress RPC — single weighted progress indicator per
--     (business_id, period), source-of-truth for the unified UX (Block 16).
--
-- 3 audit actions:
--   OUT_WORKFLOW_PAIRED_RUN_LINKED               (WORKFLOW_RUN, emitted once per pair on OUT-side)
--   OUT_WORKFLOW_SHARED_PHASE_DEDUP_APPLIED      (WORKFLOW_RUN, per dedup hit)
--   OUT_WORKFLOW_RUN_ALREADY_ACTIVE_REJECTED     (WORKFLOW_RUN-attempted or BUSINESS-scoped reject)
-- =====================================================================

BEGIN;

-- 1. Self-ref FK on paired_run_id (idempotent guard — col + idx exist already)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name
    WHERE tc.table_schema='public' AND tc.table_name='workflow_runs'
      AND tc.constraint_type='FOREIGN KEY' AND kcu.column_name='paired_run_id'
  ) THEN
    ALTER TABLE public.workflow_runs
      ADD CONSTRAINT workflow_runs_paired_run_id_fkey
      FOREIGN KEY (paired_run_id) REFERENCES public.workflow_runs(id) DEFERRABLE INITIALLY DEFERRED;
  END IF;
END $$;

COMMENT ON COLUMN public.workflow_runs.paired_run_id IS
  'Set by OUT/IN parallel coordination (B12·P04): when both OUT_MONTHLY and IN_MONTHLY runs are created from the same Statement Upload, they reciprocally point at each other so dashboards/audit consumers can reconstruct the pair without scanning.';


-- 2. Concurrency guard — per-(business, workflow_type, period) active-run check
--    Active = anything that has not reached a terminal state. FINALIZED runs
--    for a prior period do not block; only an in-flight run for the SAME
--    workflow_type + same period collides. OUT + IN for the same period coexist
--    (different workflow_type → different lock domain).
CREATE OR REPLACE FUNCTION public._out_workflow_assert_no_active_run(
  p_organization_id uuid, p_business_id uuid,
  p_workflow_type public.workflow_type_enum,
  p_period_start timestamptz, p_period_end timestamptz,
  p_actor_user_id uuid DEFAULT NULL, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_active_run_id uuid;
  v_active_status public.workflow_run_status_enum;
BEGIN
  SELECT id, status INTO v_active_run_id, v_active_status
    FROM public.workflow_runs
   WHERE business_id = p_business_id
     AND workflow_type = p_workflow_type
     AND period_start = p_period_start
     AND period_end = p_period_end
     AND status NOT IN ('FINALIZED','FAILED','CANCELLED','ABORTED')
   ORDER BY created_at DESC
   LIMIT 1;

  IF v_active_run_id IS NOT NULL THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='OUT_WORKFLOW_RUN_ALREADY_ACTIVE_REJECTED',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
      p_subject_id:=v_active_run_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='out_workflow_coordinator',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'workflow_type', p_workflow_type::text,
        'period_start', p_period_start, 'period_end', p_period_end,
        'active_run_id', v_active_run_id, 'active_status', v_active_status::text,
        'attempted_by', p_actor_user_id),
      p_reason:='OUT_WORKFLOW_RUN_ALREADY_ACTIVE',
      p_request_context:=p_context);
    RETURN jsonb_build_object(
      'decision','REJECTED',
      'reason','OUT_WORKFLOW_RUN_ALREADY_ACTIVE',
      'active_run_id', v_active_run_id,
      'active_status', v_active_status::text);
  END IF;

  RETURN jsonb_build_object('decision','OK');
END;
$$;
REVOKE EXECUTE ON FUNCTION public._out_workflow_assert_no_active_run(uuid,uuid,public.workflow_type_enum,timestamptz,timestamptz,uuid,jsonb) FROM PUBLIC;


-- 3. Paired-run creator RPC
CREATE OR REPLACE FUNCTION public.create_paired_workflow_runs(
  p_organization_id uuid, p_business_id uuid,
  p_statement_upload_id uuid,
  p_period_start timestamptz, p_period_end timestamptz,
  p_actor_user_id uuid DEFAULT NULL,
  p_trigger_event_id uuid DEFAULT NULL,
  p_principal_snapshot jsonb DEFAULT '{}'::jsonb,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
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
BEGIN
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
     p_period_start, p_period_end, p_principal_snapshot,
     v_trigger_kind, v_trigger_event_text,
     p_actor_user_id, p_trigger_event_id, v_in_id, v_pair_summary),
    (v_in_id, p_organization_id, p_business_id, 'IN_MONTHLY'::public.workflow_type_enum,
     'CREATED'::public.workflow_run_status_enum,
     p_period_start, p_period_end, p_principal_snapshot,
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
$$;
REVOKE EXECUTE ON FUNCTION public.create_paired_workflow_runs(uuid,uuid,uuid,timestamptz,timestamptz,uuid,uuid,jsonb,jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.create_paired_workflow_runs(uuid,uuid,uuid,timestamptz,timestamptz,uuid,uuid,jsonb,jsonb) TO service_role;


-- 4. Shared-phase dedup observation hook
CREATE OR REPLACE FUNCTION public.emit_shared_phase_dedup(
  p_organization_id uuid, p_business_id uuid,
  p_second_workflow_run_id uuid,
  p_phase_name text,
  p_winning_workflow_run_id uuid,
  p_dedup_key text,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
BEGIN
  IF p_phase_name NOT IN ('INGESTION','CLASSIFICATION') THEN
    RAISE EXCEPTION 'OUT_WORKFLOW_SHARED_PHASE_DEDUP only applies to INGESTION or CLASSIFICATION, got %', p_phase_name;
  END IF;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='OUT_WORKFLOW_SHARED_PHASE_DEDUP_APPLIED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_second_workflow_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_coordinator',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'phase_name', p_phase_name,
      'second_workflow_run_id', p_second_workflow_run_id,
      'winning_workflow_run_id', p_winning_workflow_run_id,
      'dedup_key', p_dedup_key),
    p_reason:=NULL, p_request_context:=p_context);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.emit_shared_phase_dedup(uuid,uuid,uuid,text,uuid,text,jsonb) FROM PUBLIC;


-- 5. Combined progress RPC — unified OUT+IN indicator
--    Shared phases (INGESTION, CLASSIFICATION) counted once; OUT and IN parallel
--    phases counted via their per-side workflow_phase_states rows. Weight =
--    completed phases / total phases per side; combined_pct is the equal-weighted
--    average of shared, out_after_shared, in_after_shared progress.
CREATE OR REPLACE FUNCTION public.get_combined_run_progress(
  p_business_id uuid, p_period_start timestamptz, p_period_end timestamptz
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_out_run_id uuid;
  v_in_run_id  uuid;
  v_shared_total int := 2;  -- INGESTION + CLASSIFICATION
  v_shared_done  int := 0;
  v_out_after_total int := 0;
  v_out_after_done  int := 0;
  v_in_after_total  int := 0;
  v_in_after_done   int := 0;
  v_shared_pct numeric;
  v_out_pct    numeric;
  v_in_pct     numeric;
  v_combined   numeric;
BEGIN
  SELECT id INTO v_out_run_id FROM public.workflow_runs
    WHERE business_id = p_business_id AND workflow_type='OUT_MONTHLY'
      AND period_start = p_period_start AND period_end = p_period_end
    ORDER BY created_at DESC LIMIT 1;
  SELECT id INTO v_in_run_id FROM public.workflow_runs
    WHERE business_id = p_business_id AND workflow_type='IN_MONTHLY'
      AND period_start = p_period_start AND period_end = p_period_end
    ORDER BY created_at DESC LIMIT 1;

  -- Shared = INGESTION + CLASSIFICATION (CLASSIFY on IN side) on either run;
  -- whichever side recorded COMPLETED counts the shared phase as done.
  IF v_out_run_id IS NOT NULL OR v_in_run_id IS NOT NULL THEN
    SELECT count(*) INTO v_shared_done
      FROM (
        (SELECT 1 FROM public.workflow_phase_states
          WHERE workflow_run_id IN (v_out_run_id, v_in_run_id)
            AND phase_name = 'INGESTION'
            AND status = 'COMPLETED'
          LIMIT 1)
        UNION ALL
        (SELECT 1 FROM public.workflow_phase_states
          WHERE workflow_run_id IN (v_out_run_id, v_in_run_id)
            AND phase_name IN ('CLASSIFICATION','CLASSIFY')
            AND status = 'COMPLETED'
          LIMIT 1)
      ) s;
  END IF;

  IF v_out_run_id IS NOT NULL THEN
    SELECT count(*) FILTER (WHERE phase_name NOT IN ('INGESTION','CLASSIFICATION')),
           count(*) FILTER (WHERE phase_name NOT IN ('INGESTION','CLASSIFICATION') AND status='COMPLETED')
      INTO v_out_after_total, v_out_after_done
      FROM public.workflow_phase_states WHERE workflow_run_id = v_out_run_id;
    IF v_out_after_total = 0 THEN
      SELECT count(*) INTO v_out_after_total FROM public.workflow_phase_definitions
        WHERE workflow_type='OUT_MONTHLY' AND phase_name NOT IN ('INGESTION','CLASSIFICATION');
    END IF;
  END IF;
  IF v_in_run_id IS NOT NULL THEN
    SELECT count(*) FILTER (WHERE phase_name NOT IN ('INGESTION','CLASSIFICATION','CLASSIFY')),
           count(*) FILTER (WHERE phase_name NOT IN ('INGESTION','CLASSIFICATION','CLASSIFY') AND status='COMPLETED')
      INTO v_in_after_total, v_in_after_done
      FROM public.workflow_phase_states WHERE workflow_run_id = v_in_run_id;
    IF v_in_after_total = 0 THEN
      SELECT count(*) INTO v_in_after_total FROM public.workflow_phase_definitions
        WHERE workflow_type='IN_MONTHLY' AND phase_name NOT IN ('INGESTION','CLASSIFICATION','CLASSIFY');
    END IF;
  END IF;

  v_shared_pct := CASE WHEN v_shared_total=0 THEN 0 ELSE round(100.0*v_shared_done / v_shared_total, 2) END;
  v_out_pct    := CASE WHEN v_out_after_total=0 THEN 0 ELSE round(100.0*v_out_after_done / v_out_after_total, 2) END;
  v_in_pct     := CASE WHEN v_in_after_total=0  THEN 0 ELSE round(100.0*v_in_after_done  / v_in_after_total,  2) END;
  v_combined   := round((v_shared_pct + v_out_pct + v_in_pct) / 3.0, 2);

  RETURN jsonb_build_object(
    'out_run_id', v_out_run_id,
    'in_run_id',  v_in_run_id,
    'shared_progress', jsonb_build_object('done', v_shared_done, 'total', v_shared_total, 'pct', v_shared_pct),
    'out_progress',    jsonb_build_object('done', v_out_after_done, 'total', v_out_after_total, 'pct', v_out_pct),
    'in_progress',     jsonb_build_object('done', v_in_after_done,  'total', v_in_after_total,  'pct', v_in_pct),
    'combined_pct',    v_combined);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_combined_run_progress(uuid,timestamptz,timestamptz) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_combined_run_progress(uuid,timestamptz,timestamptz) TO authenticated, service_role;


-- 6. Tool registry seeds
SELECT public.register_tool(
  p_tool_name=>'out_workflow.create_paired_workflow_runs', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('organization_id','uuid','business_id','uuid','statement_upload_id','uuid','period_start','timestamptz','period_end','timestamptz'),
  p_output_schema=>jsonb_build_object('decision','text','out_run_id','uuid','in_run_id','uuid','paired','boolean'),
  p_side_effect=>'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>'out_workflow.create_paired_workflow_runs.dedup_key_v1',
  p_description=>'Atomic paired OUT_MONTHLY + IN_MONTHLY creator with reciprocal paired_run_id linkage',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);

SELECT public.register_tool(
  p_tool_name=>'out_workflow.get_combined_run_progress', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('business_id','uuid','period_start','timestamptz','period_end','timestamptz'),
  p_output_schema=>jsonb_build_object('out_run_id','uuid','in_run_id','uuid','shared_progress','object','out_progress','object','in_progress','object','combined_pct','number'),
  p_side_effect=>'READ_ONLY'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>NULL,
  p_description=>'Unified OUT+IN combined progress indicator per (business_id, period) — single source of truth for the dashboard',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);

COMMIT;
