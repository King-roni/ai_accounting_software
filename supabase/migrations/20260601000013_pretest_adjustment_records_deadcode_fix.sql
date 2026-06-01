-- =============================================================================
-- Pretest readiness fix (2026-06-01) — adjustment_records dead-code (H3)
-- =============================================================================
-- public.adjustment_records columns are id/organization_id/business_id/run_id/
-- parent_run_id/parent_period_start/parent_period_end/reason/delta_kind/
-- delta_payload/requesting_user_id/created_at. There is NO workflow_run_id and
-- NO target_record_type. Three functions referenced the non-existent columns →
-- ERROR 42703 if ever reached:
--   * check_adjustment_intake_gate          (workflow_run_id)
--   * record_adjustment_finalization_handoff (workflow_run_id + target_record_type)
--   * fn_check_adjustment_record_run_type     (NEW.workflow_run_id; unattached trigger fn)
-- Live re-finalize uses gate_finalization_adjustment_preconditions_satisfied +
-- execute_adjustment_lock_sequence (not these), so all three are currently
-- dead/unwired — but latent 42703 hazards. Fix the column refs:
-- workflow_run_id → run_id, target_record_type → delta_kind (the real "kind of
-- adjustment" column). Trigger fn left unattached (no behavioural change), now
-- correct-if-attached.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.check_adjustment_intake_gate(p_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_cnt integer;
BEGIN
  IF p_run_id IS NULL THEN
    RAISE EXCEPTION 'check_adjustment_intake_gate: run_id required' USING ERRCODE='22000';
  END IF;
  SELECT count(*) INTO v_cnt FROM public.adjustment_records WHERE run_id = p_run_id;
  IF v_cnt > 0 THEN
    RETURN jsonb_build_object('decision', 'ADVANCE', 'record_count', v_cnt);
  END IF;
  RETURN jsonb_build_object('decision', 'HOLD',
                            'reason', 'ADJUSTMENT_INTAKE: at least one adjustment_record with reason + delta is required',
                            'record_count', 0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_adjustment_finalization_handoff(p_run_id uuid, p_actor_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
DECLARE
  v_run          public.workflow_runs;
  v_record_count integer;
  v_delta_kinds  text[];
  v_audit        audit.audit_events;
BEGIN
  IF p_run_id IS NULL OR p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'record_adjustment_finalization_handoff: run_id + actor required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'record_adjustment_finalization_handoff: run % not found', p_run_id USING ERRCODE='P0002'; END IF;
  IF v_run.workflow_type NOT IN ('OUT_ADJUSTMENT','IN_ADJUSTMENT') THEN
    RAISE EXCEPTION 'record_adjustment_finalization_handoff: run % is type % (must be adjustment)', p_run_id, v_run.workflow_type USING ERRCODE='P0001';
  END IF;

  SELECT count(*), array_agg(DISTINCT delta_kind::text)
    INTO v_record_count, v_delta_kinds
    FROM public.adjustment_records WHERE run_id = p_run_id;

  v_audit := audit.emit_audit(
    p_actor_kind     => 'USER'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_ADJUSTMENT_FINALIZED',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => p_run_id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_user_id  => p_actor_user_id,
    p_reason         => format('adjustment %s finalization handoff (%s records, kinds=%s)',
                               v_run.workflow_type, COALESCE(v_record_count, 0), v_delta_kinds),
    p_after_state    => jsonb_build_object(
      'run_id',         p_run_id,
      'workflow_type',  v_run.workflow_type::text,
      'parent_run_id',  v_run.parent_run_id,
      'record_count',   COALESCE(v_record_count, 0),
      'delta_kinds',    to_jsonb(COALESCE(v_delta_kinds, ARRAY[]::text[])),
      'b15_handoff',    'pending — B15 will swap this stub with archive-additive write'
    )
  );
  RETURN jsonb_build_object('audit_event_id', v_audit.event_id, 'record_count', COALESCE(v_record_count, 0));
END;
$function$;

CREATE OR REPLACE FUNCTION public.fn_check_adjustment_record_run_type()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_type public.workflow_type_enum;
BEGIN
  SELECT workflow_type INTO v_type FROM public.workflow_runs WHERE id = NEW.run_id;
  IF v_type IS NULL THEN
    RAISE EXCEPTION 'adjustment_records: workflow_run % not found', NEW.run_id USING ERRCODE='P0002';
  END IF;
  IF v_type NOT IN ('OUT_ADJUSTMENT','IN_ADJUSTMENT') THEN
    RAISE EXCEPTION 'adjustment_records: workflow_run % is type % (must be OUT_ADJUSTMENT or IN_ADJUSTMENT)', NEW.run_id, v_type
      USING ERRCODE='P0001';
  END IF;
  RETURN NEW;
END;
$function$;
